//! Wire-level protocol version.
//!
//! Encoded as a JSON number on output. On input we accept both numbers and
//! decimal strings — older peers were observed to emit string-encoded versions
//! and the on-wire contract has to tolerate that for forward/backward compat.

const std = @import("std");

/// On-wire protocol version. Compare with `eql`; never read `value` directly
/// when negotiating since older peers send it as a decimal string.
pub const ProtocolVersion = struct {
    value: u16,

    /// First (and currently only) shipped protocol revision.
    pub const V1: ProtocolVersion = .{ .value = 1 };
    /// Convenience alias for the newest revision this build understands.
    pub const LATEST: ProtocolVersion = V1;

    pub fn init(value: u16) ProtocolVersion {
        return .{ .value = value };
    }

    pub fn eql(a: ProtocolVersion, b: ProtocolVersion) bool {
        return a.value == b.value;
    }

    pub fn jsonStringify(self: ProtocolVersion, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !ProtocolVersion {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer freeToken(allocator, token);
        const slice = switch (token) {
            inline .number, .allocated_number, .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        const v = std.fmt.parseInt(u16, slice, 10) catch return error.UnexpectedToken;
        return .{ .value = v };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !ProtocolVersion {
        _ = allocator;
        _ = options;
        switch (source) {
            .integer => |i| {
                if (i < 0 or i > std.math.maxInt(u16)) return error.UnexpectedToken;
                return .{ .value = @intCast(i) };
            },
            .number_string, .string => |s| {
                const v = std.fmt.parseInt(u16, s, 10) catch return error.UnexpectedToken;
                return .{ .value = v };
            },
            else => return error.UnexpectedToken,
        }
    }
};

fn freeToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |s| allocator.free(s),
        else => {},
    }
}

test "ProtocolVersion encodes as number" {
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, ProtocolVersion.V1, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("1", out);
}

test "ProtocolVersion parses from number" {
    const parsed = try std.json.parseFromSlice(ProtocolVersion, std.testing.allocator, "7", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 7), parsed.value.value);
}

test "ProtocolVersion parses from decimal string fallback" {
    const parsed = try std.json.parseFromSlice(ProtocolVersion, std.testing.allocator, "\"3\"", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 3), parsed.value.value);
}

test "ProtocolVersion round-trips" {
    const v: ProtocolVersion = .{ .value = 42 };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, v, .{});
    defer std.testing.allocator.free(out);
    const parsed = try std.json.parseFromSlice(ProtocolVersion, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.eql(v));
}
