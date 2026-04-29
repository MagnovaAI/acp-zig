//! Plan, PlanEntry, status and priority enums.

const std = @import("std");

pub const PlanEntryStatus = enum {
    pending,
    in_progress,
    completed,

    pub fn jsonStringify(self: PlanEntryStatus, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !PlanEntryStatus {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer freeToken(allocator, tok);
        const slice = switch (tok) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return std.meta.stringToEnum(PlanEntryStatus, slice) orelse error.InvalidEnumTag;
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !PlanEntryStatus {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(PlanEntryStatus, source.string) orelse error.InvalidEnumTag;
    }
};

pub const Priority = enum {
    low,
    medium,
    high,

    pub fn jsonStringify(self: Priority, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Priority {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer freeToken(allocator, tok);
        const slice = switch (tok) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return std.meta.stringToEnum(Priority, slice) orelse error.InvalidEnumTag;
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !Priority {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(Priority, source.string) orelse error.InvalidEnumTag;
    }
};

pub const PlanEntry = struct {
    content: []const u8,
    status: PlanEntryStatus,
    priority: Priority = .medium,
};

pub const Plan = struct {
    entries: []const PlanEntry,
};

fn freeToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |s| allocator.free(s),
        else => {},
    }
}

test "PlanEntryStatus enum codec" {
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, PlanEntryStatus.in_progress, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\"in_progress\"", out);

    const parsed = try std.json.parseFromSlice(PlanEntryStatus, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(PlanEntryStatus.in_progress, parsed.value);
}

test "Plan round-trip" {
    const src =
        \\{"entries":[{"content":"step 1","status":"pending","priority":"high"},{"content":"step 2","status":"completed","priority":"low"}]}
    ;
    const parsed = try std.json.parseFromSlice(Plan, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
    try std.testing.expectEqual(Priority.high, parsed.value.entries[0].priority);
    try std.testing.expectEqual(PlanEntryStatus.completed, parsed.value.entries[1].status);
}
