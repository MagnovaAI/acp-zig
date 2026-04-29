//! Canonical schema catalog generator.
//!
//! The output is a single JSON document describing every wire-format type and
//! method-name constant exposed by the schema package. Keys are sorted so the
//! file diffs cleanly across runs and across machines. Comptime reflection
//! drives the walk so the generator stays in lock-step with the schema
//! source — adding a new public type or method here costs nothing at the
//! generator side.

const std = @import("std");
const schema = @import("acp-schema");

const log = std.log.scoped(.gen_schema);

const max_depth: usize = 6;

comptime {
    // Comptime sorting and reflection over the full schema package easily
    // overruns the default branch budget; this generator is not on a hot
    // path so a generous ceiling is fine.
    @setEvalBranchQuota(50_000);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next();
    const out_path: ?[]const u8 = blk: {
        if (args_iter.next()) |a| break :blk try allocator.dupe(u8, a);
        break :blk null;
    };
    defer if (out_path) |p| allocator.free(p);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var ws: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try emitRoot(&ws);
    try out.writer.writeByte('\n');

    const bytes = out.written();
    const io = init.io;
    if (out_path) |p| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = bytes });
    } else {
        try std.Io.File.stdout().writeStreamingAll(io, bytes);
    }
}

fn emitRoot(ws: *std.json.Stringify) !void {
    try ws.beginObject();

    try ws.objectField("format");
    try ws.write("acp-schema-catalog/v1");

    try ws.objectField("methods");
    try emitMethods(ws);

    try ws.objectField("types");
    try emitTypes(ws);

    try ws.endObject();
}

// -- methods -----------------------------------------------------------------

const NamedString = struct { name: []const u8, value: []const u8 };

fn collectMethodsFromNamespace(comptime Namespace: type, comptime prefix: []const u8) []const NamedString {
    comptime {
        var out: []const NamedString = &.{};
        for (@typeInfo(Namespace).@"struct".decls) |d| {
            if (!std.mem.startsWith(u8, d.name, "method_")) continue;
            const v = @field(Namespace, d.name);
            const VT = @TypeOf(v);
            switch (@typeInfo(VT)) {
                .pointer => |p| {
                    if (p.size == .slice and p.child == u8) {
                        out = out ++ &[_]NamedString{.{ .name = prefix ++ "." ++ d.name, .value = v }};
                    }
                },
                else => {},
            }
        }
        return out;
    }
}

fn lessNamed(_: void, a: NamedString, b: NamedString) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn emitMethods(ws: *std.json.Stringify) !void {
    const combined = comptime blk: {
        @setEvalBranchQuota(50_000);
        const agent_methods = collectMethodsFromNamespace(schema.agent, "agent");
        const client_methods = collectMethodsFromNamespace(schema.client, "client");
        var arr: [agent_methods.len + client_methods.len]NamedString = undefined;
        var i: usize = 0;
        for (agent_methods) |m| {
            arr[i] = m;
            i += 1;
        }
        for (client_methods) |m| {
            arr[i] = m;
            i += 1;
        }
        std.sort.insertion(NamedString, &arr, {}, lessNamed);
        const final = arr;
        break :blk final;
    };

    try ws.beginObject();
    inline for (combined) |m| {
        try ws.objectField(m.name);
        try ws.write(m.value);
    }
    try ws.endObject();
}

// -- types -------------------------------------------------------------------

const NamedType = struct { name: []const u8, T: type };

fn lessType(_: void, a: NamedType, b: NamedType) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn collectTypes() []const NamedType {
    comptime {
        @setEvalBranchQuota(50_000);
        var out: []const NamedType = &.{};
        for (@typeInfo(schema).@"struct".decls) |d| {
            const v = @field(schema, d.name);
            const VT = @TypeOf(v);
            if (VT != type) continue;
            const T = v;
            switch (@typeInfo(T)) {
                .@"struct", .@"enum", .@"union" => {
                    out = out ++ &[_]NamedType{.{ .name = d.name, .T = T }};
                },
                else => {},
            }
        }
        var arr: [out.len]NamedType = undefined;
        for (out, 0..) |x, i| arr[i] = x;
        std.sort.insertion(NamedType, &arr, {}, lessType);
        const final = arr;
        return &final;
    }
}

fn emitTypes(ws: *std.json.Stringify) !void {
    const list = comptime collectTypes();
    try ws.beginObject();
    inline for (list) |entry| {
        try ws.objectField(entry.name);
        try emitTypeShape(ws, entry.T, 0);
    }
    try ws.endObject();
}

fn emitTypeShape(ws: *std.json.Stringify, comptime T: type, depth: usize) !void {
    if (depth > max_depth) {
        try ws.beginObject();
        try ws.objectField("kind");
        try ws.write("truncated");
        try ws.endObject();
        return;
    }

    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            try ws.beginObject();
            try ws.objectField("kind");
            try ws.write(if (s.is_tuple) "tuple" else "struct");
            try ws.objectField("fields");
            try ws.beginObject();

            const SortedField = struct { name: []const u8, idx: usize };
            const sorted = comptime blk: {
                @setEvalBranchQuota(50_000);
                var arr: [s.fields.len]SortedField = undefined;
                for (s.fields, 0..) |f, i| arr[i] = .{ .name = f.name, .idx = i };
                std.sort.insertion(SortedField, &arr, {}, struct {
                    fn lt(_: void, a: SortedField, b: SortedField) bool {
                        return std.mem.lessThan(u8, a.name, b.name);
                    }
                }.lt);
                const final = arr;
                break :blk final;
            };
            inline for (sorted) |sf| {
                const f = s.fields[sf.idx];
                try ws.objectField(f.name);
                try emitFieldType(ws, f.type, f.default_value_ptr != null);
            }
            try ws.endObject();
            try ws.endObject();
        },
        .@"enum" => |e| {
            try ws.beginObject();
            try ws.objectField("kind");
            try ws.write("enum");
            try ws.objectField("tag_type");
            try ws.write(@typeName(e.tag_type));
            try ws.objectField("variants");
            try ws.beginArray();

            const SortedVar = struct { name: []const u8, value: i128 };
            const sv = comptime blk: {
                @setEvalBranchQuota(50_000);
                var arr: [e.fields.len]SortedVar = undefined;
                for (e.fields, 0..) |f, i| arr[i] = .{ .name = f.name, .value = @as(i128, f.value) };
                std.sort.insertion(SortedVar, &arr, {}, struct {
                    fn lt(_: void, a: SortedVar, b: SortedVar) bool {
                        return std.mem.lessThan(u8, a.name, b.name);
                    }
                }.lt);
                const final = arr;
                break :blk final;
            };
            inline for (sv) |variant| {
                try ws.beginObject();
                try ws.objectField("name");
                try ws.write(variant.name);
                try ws.objectField("value");
                try ws.write(variant.value);
                try ws.endObject();
            }
            try ws.endArray();
            try ws.endObject();
        },
        .@"union" => |u| {
            try ws.beginObject();
            try ws.objectField("kind");
            try ws.write("union");
            if (u.tag_type) |TT| {
                try ws.objectField("tag_type");
                try ws.write(@typeName(TT));
            }
            try ws.objectField("variants");
            try ws.beginObject();

            const SortedV = struct { name: []const u8, idx: usize };
            const sv = comptime blk: {
                @setEvalBranchQuota(50_000);
                var arr: [u.fields.len]SortedV = undefined;
                for (u.fields, 0..) |f, i| arr[i] = .{ .name = f.name, .idx = i };
                std.sort.insertion(SortedV, &arr, {}, struct {
                    fn lt(_: void, a: SortedV, b: SortedV) bool {
                        return std.mem.lessThan(u8, a.name, b.name);
                    }
                }.lt);
                const final = arr;
                break :blk final;
            };
            inline for (sv) |variant| {
                const f = u.fields[variant.idx];
                try ws.objectField(f.name);
                try emitFieldType(ws, f.type, false);
            }
            try ws.endObject();
            try ws.endObject();
        },
        else => {
            try ws.beginObject();
            try ws.objectField("kind");
            try ws.write("scalar");
            try ws.objectField("type");
            try ws.write(@typeName(T));
            try ws.endObject();
        },
    }
}

fn emitFieldType(ws: *std.json.Stringify, comptime T: type, has_default: bool) !void {
    try ws.beginObject();
    try ws.objectField("has_default");
    try ws.write(has_default);
    try ws.objectField("type");
    try ws.write(@typeName(T));

    const info = @typeInfo(T);
    switch (info) {
        .optional => |o| {
            try ws.objectField("optional_of");
            try ws.write(@typeName(o.child));
        },
        .pointer => |p| {
            try ws.objectField("pointer_child");
            try ws.write(@typeName(p.child));
            try ws.objectField("pointer_size");
            try ws.write(@tagName(p.size));
        },
        .array => |a| {
            try ws.objectField("array_child");
            try ws.write(@typeName(a.child));
            try ws.objectField("array_len");
            try ws.write(a.len);
        },
        else => {},
    }
    try ws.endObject();
}
