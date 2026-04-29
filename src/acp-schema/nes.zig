//! Next-edit-suggestions surface. Gated behind `unstable_nes`.
//!
//! Lets an agent stream proposed file edits the user can accept or reject
//! ahead of execution.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.unstable_nes;

const impl = struct {
    pub const NesEditKind = enum {
        replace,
        insert,
        delete,

        pub fn jsonStringify(self: NesEditKind, jw: anytype) !void {
            try jw.write(@tagName(self));
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !NesEditKind {
            const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            defer freeToken(allocator, tok);
            const slice = switch (tok) {
                inline .string, .allocated_string => |s| s,
                else => return error.UnexpectedToken,
            };
            return std.meta.stringToEnum(NesEditKind, slice) orelse error.InvalidEnumTag;
        }

        pub fn jsonParseFromValue(
            _: std.mem.Allocator,
            source: std.json.Value,
            _: std.json.ParseOptions,
        ) !NesEditKind {
            if (source != .string) return error.UnexpectedToken;
            return std.meta.stringToEnum(NesEditKind, source.string) orelse error.InvalidEnumTag;
        }
    };

    pub const NesRange = struct {
        startLine: u32,
        startColumn: u32,
        endLine: u32,
        endColumn: u32,
    };

    pub const NesEdit = struct {
        path: []const u8,
        kind: NesEditKind,
        range: NesRange,
        newText: []const u8,
    };

    pub const NesSuggestion = struct {
        suggestionId: []const u8,
        edits: []const NesEdit,
        rationale: ?[]const u8 = null,
    };

    pub const NesAction = enum {
        accept,
        reject,
        defer_,

        pub fn jsonStringify(self: NesAction, jw: anytype) !void {
            try jw.write(switch (self) {
                .accept => "accept",
                .reject => "reject",
                .defer_ => "defer",
            });
        }

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !NesAction {
            const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            defer freeToken(allocator, tok);
            const slice = switch (tok) {
                inline .string, .allocated_string => |s| s,
                else => return error.UnexpectedToken,
            };
            return decode(slice);
        }

        pub fn jsonParseFromValue(
            _: std.mem.Allocator,
            source: std.json.Value,
            _: std.json.ParseOptions,
        ) !NesAction {
            if (source != .string) return error.UnexpectedToken;
            return decode(source.string);
        }

        fn decode(s: []const u8) !NesAction {
            if (std.mem.eql(u8, s, "accept")) return .accept;
            if (std.mem.eql(u8, s, "reject")) return .reject;
            if (std.mem.eql(u8, s, "defer")) return .defer_;
            return error.InvalidEnumTag;
        }
    };

    pub const NesDecision = struct {
        suggestionId: []const u8,
        action: NesAction,
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

test "NesSuggestion round-trip when enabled" {
    if (!enabled) return error.SkipZigTest;
    const src =
        \\{"suggestionId":"s1","edits":[{"path":"/a","kind":"replace","range":{"startLine":1,"startColumn":0,"endLine":1,"endColumn":3},"newText":"foo"}]}
    ;
    const parsed = try std.json.parseFromSlice(types.NesSuggestion, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s1", parsed.value.suggestionId);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.edits.len);
    try std.testing.expectEqual(types.NesEditKind.replace, parsed.value.edits[0].kind);
}

test "NesAction defer keyword is wire-encoded as defer" {
    if (!enabled) return error.SkipZigTest;
    const action: types.NesAction = .defer_;
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, action, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\"defer\"", out);

    const parsed = try std.json.parseFromSlice(types.NesAction, std.testing.allocator, "\"defer\"", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(types.NesAction.defer_, parsed.value);
}
