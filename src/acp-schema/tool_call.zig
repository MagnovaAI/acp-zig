//! Tool call wire types.
//!
//! Tool calls flow Agent → Client as the agent reports each tool invocation,
//! its locations, content, and status transitions. Updates carry an id plus
//! a partial set of fields — only changed fields are sent.

const std = @import("std");
const RawValue = @import("serde_util.zig").RawValue;
const ContentBlock = @import("content.zig").ContentBlock;

/// Opaque tool-call identifier minted by the agent. Used to correlate a
/// `tool_call` first emission with subsequent `tool_call_update` events.
pub const ToolCallId = struct {
    value: []const u8,

    pub fn jsonStringify(self: ToolCallId, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ToolCallId {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const slice = switch (tok) {
            .string => |s| try allocator.dupe(u8, s),
            .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return .{ .value = slice };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !ToolCallId {
        if (source != .string) return error.UnexpectedToken;
        return .{ .value = try allocator.dupe(u8, source.string) };
    }
};

/// Lifecycle of a tool call. Monotonic except `failed`, which terminates.
pub const ToolCallStatus = enum {
    pending,
    in_progress,
    completed,
    failed,

    pub fn jsonStringify(self: ToolCallStatus, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ToolCallStatus {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer freeToken(allocator, tok);
        const slice = switch (tok) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return std.meta.stringToEnum(ToolCallStatus, slice) orelse error.InvalidEnumTag;
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !ToolCallStatus {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(ToolCallStatus, source.string) orelse error.InvalidEnumTag;
    }
};

/// Coarse classification of tool intent. Used by clients for icons / styling.
pub const ToolKind = enum {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    other,

    pub fn jsonStringify(self: ToolKind, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ToolKind {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer freeToken(allocator, tok);
        const slice = switch (tok) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return std.meta.stringToEnum(ToolKind, slice) orelse .other;
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !ToolKind {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(ToolKind, source.string) orelse .other;
    }
};

/// File location an agent is touching as part of a tool call.
pub const ToolCallLocation = struct {
    path: []const u8,
    line: ?u32 = null,
};

/// Content emitted by a tool call: either rendered content or a diff.
pub const ToolCallContent = union(enum) {
    content: ContentBlockEntry,
    diff: Diff,

    pub const ContentBlockEntry = struct {
        content: ContentBlock,
    };

    pub const Diff = struct {
        path: []const u8,
        oldText: ?[]const u8 = null,
        newText: []const u8,
    };

    pub fn jsonStringify(self: ToolCallContent, jw: anytype) !void {
        switch (self) {
            .content => |c| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("content");
                try jw.objectField("content");
                try jw.write(c.content);
                try jw.endObject();
            },
            .diff => |d| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("diff");
                try jw.objectField("path");
                try jw.write(d.path);
                if (d.oldText) |o| {
                    try jw.objectField("oldText");
                    try jw.write(o);
                }
                try jw.objectField("newText");
                try jw.write(d.newText);
                try jw.endObject();
            },
        }
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ToolCallContent {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !ToolCallContent {
        if (source != .object) return error.UnexpectedToken;
        const tag_v = source.object.get("type") orelse return error.MissingField;
        if (tag_v != .string) return error.UnexpectedToken;
        const tag = tag_v.string;

        if (std.mem.eql(u8, tag, "content")) {
            const inner = source.object.get("content") orelse return error.MissingField;
            const cb = try std.json.parseFromValueLeaky(ContentBlock, allocator, inner, options);
            return .{ .content = .{ .content = cb } };
        }
        if (std.mem.eql(u8, tag, "diff")) {
            const path_v = source.object.get("path") orelse return error.MissingField;
            const new_v = source.object.get("newText") orelse return error.MissingField;
            if (path_v != .string or new_v != .string) return error.UnexpectedToken;
            var diff: Diff = .{
                .path = try allocator.dupe(u8, path_v.string),
                .newText = try allocator.dupe(u8, new_v.string),
            };
            if (source.object.get("oldText")) |o| {
                if (o != .string) return error.UnexpectedToken;
                diff.oldText = try allocator.dupe(u8, o.string);
            }
            return .{ .diff = diff };
        }
        return error.UnexpectedToken;
    }
};

/// Full tool call snapshot. Sent on first emission.
pub const ToolCall = struct {
    toolCallId: ToolCallId,
    title: []const u8,
    kind: ?ToolKind = null,
    status: ?ToolCallStatus = null,
    content: ?[]const ToolCallContent = null,
    locations: ?[]const ToolCallLocation = null,
    rawInput: ?RawValue = null,
    rawOutput: ?RawValue = null,
};

/// Partial update to an existing tool call. All fields except `toolCallId`
/// are optional — only changed fields are sent.
pub const ToolCallUpdate = struct {
    toolCallId: ToolCallId,
    title: ?[]const u8 = null,
    kind: ?ToolKind = null,
    status: ?ToolCallStatus = null,
    content: ?[]const ToolCallContent = null,
    locations: ?[]const ToolCallLocation = null,
    rawInput: ?RawValue = null,
    rawOutput: ?RawValue = null,
};

fn freeToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |s| allocator.free(s),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ToolCallStatus enum codec" {
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, ToolCallStatus.in_progress, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\"in_progress\"", out);
}

test "ToolKind unknown falls back to other" {
    const parsed = try std.json.parseFromSlice(ToolKind, std.testing.allocator, "\"some_future_kind\"", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(ToolKind.other, parsed.value);
}

test "ToolCallId round-trip" {
    const src = "\"call_42\"";
    const parsed = try std.json.parseFromSlice(ToolCallId, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("call_42", parsed.value.value);

    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}

test "ToolCall full round-trip" {
    const src =
        \\{"toolCallId":"c1","title":"reading file","kind":"read","status":"in_progress","locations":[{"path":"/tmp/a","line":7}]}
    ;
    const parsed = try std.json.parseFromSlice(ToolCall, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("c1", parsed.value.toolCallId.value);
    try std.testing.expectEqual(ToolKind.read, parsed.value.kind.?);
    try std.testing.expectEqual(ToolCallStatus.in_progress, parsed.value.status.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.locations.?.len);
    try std.testing.expectEqual(@as(u32, 7), parsed.value.locations.?[0].line.?);
}

test "ToolCallContent diff round-trip" {
    const src =
        \\{"type":"diff","path":"/tmp/a","oldText":"x","newText":"y"}
    ;
    const parsed = try std.json.parseFromSlice(ToolCallContent, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .diff);
    try std.testing.expectEqualStrings("y", parsed.value.diff.newText);
    try std.testing.expectEqualStrings("x", parsed.value.diff.oldText.?);
}

test "ToolCallContent content variant wraps ContentBlock" {
    const src =
        \\{"type":"content","content":{"type":"text","text":"hello"}}
    ;
    const parsed = try std.json.parseFromSlice(ToolCallContent, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .content);
    try std.testing.expect(parsed.value.content.content == .text);
}

test "ToolCallUpdate carries only changed fields" {
    const src =
        \\{"toolCallId":"c1","status":"completed"}
    ;
    const parsed = try std.json.parseFromSlice(ToolCallUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(ToolCallStatus.completed, parsed.value.status.?);
    try std.testing.expect(parsed.value.title == null);
    try std.testing.expect(parsed.value.kind == null);
}

test "ToolCallUpdate stringifies skipping null fields" {
    const u: ToolCallUpdate = .{
        .toolCallId = .{ .value = "c1" },
        .status = .completed,
    };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, u, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "title") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "kind") == null);
}
