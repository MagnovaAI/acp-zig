//! Extension envelopes — allow vendors to ship out-of-band methods and
//! notifications without touching the core schema. Params and results are
//! kept as opaque JSON; routing is done on `method` only.

const std = @import("std");
const RawValue = @import("serde_util.zig").RawValue;

pub const ExtRequest = struct {
    method: []const u8,
    params: ?RawValue = null,
};

pub const ExtResponse = struct {
    result: ?RawValue = null,
};

pub const ExtNotification = struct {
    method: []const u8,
    params: ?RawValue = null,
};

test "ExtRequest with raw params round-trips" {
    const src =
        \\{"method":"vendor/foo","params":{"x":1,"y":[true,null]}}
    ;
    const parsed = try std.json.parseFromSlice(ExtRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("vendor/foo", parsed.value.method);
    try std.testing.expect(parsed.value.params != null);
}

test "ExtNotification without params" {
    const src =
        \\{"method":"vendor/ping"}
    ;
    const parsed = try std.json.parseFromSlice(ExtNotification, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.params == null);
}
