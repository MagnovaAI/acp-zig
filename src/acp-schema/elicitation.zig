//! Elicitation: agent prompts the user (via the client) for structured input
//! mid-session. Gated behind `unstable_elicitation`.

const std = @import("std");
const build_options = @import("build_options");
const RawValue = @import("serde_util.zig").RawValue;

pub const enabled = build_options.unstable_elicitation;

const impl = struct {
    pub const ElicitationAction = enum {
        accept,
        decline,
        cancel,

        pub fn jsonStringify(self: ElicitationAction, jw: anytype) !void {
            try jw.write(@tagName(self));
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !ElicitationAction {
            const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            defer freeToken(allocator, tok);
            const slice = switch (tok) {
                inline .string, .allocated_string => |s| s,
                else => return error.UnexpectedToken,
            };
            return std.meta.stringToEnum(ElicitationAction, slice) orelse error.InvalidEnumTag;
        }

        pub fn jsonParseFromValue(
            _: std.mem.Allocator,
            source: std.json.Value,
            _: std.json.ParseOptions,
        ) !ElicitationAction {
            if (source != .string) return error.UnexpectedToken;
            return std.meta.stringToEnum(ElicitationAction, source.string) orelse error.InvalidEnumTag;
        }
    };

    /// Request to the client to elicit structured input matching `requestedSchema`.
    pub const ElicitRequest = struct {
        message: []const u8,
        requestedSchema: RawValue,
    };

    pub const ElicitResponse = struct {
        action: ElicitationAction,
        content: ?RawValue = null,
    };
};

const disabled = struct {};

pub const types = if (enabled) impl else disabled;

fn freeToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |s| allocator.free(s),
        else => {},
    }
}

test "ElicitRequest round-trip when enabled" {
    if (!enabled) return error.SkipZigTest;
    const src =
        \\{"message":"pick one","requestedSchema":{"type":"object"}}
    ;
    const parsed = try std.json.parseFromSlice(types.ElicitRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("pick one", parsed.value.message);
}

test "ElicitResponse accept with content" {
    if (!enabled) return error.SkipZigTest;
    const src =
        \\{"action":"accept","content":{"name":"x"}}
    ;
    const parsed = try std.json.parseFromSlice(types.ElicitResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(types.ElicitationAction.accept, parsed.value.action);
}

test "ElicitResponse decline omits content" {
    if (!enabled) return error.SkipZigTest;
    const src =
        \\{"action":"decline"}
    ;
    const parsed = try std.json.parseFromSlice(types.ElicitResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.content == null);
}
