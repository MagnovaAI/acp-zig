//! Shared JSON codec helpers for schema types.
//!
//! Kept intentionally small: helpers are added as later phases discover real
//! needs, not speculatively.

const std = @import("std");

/// A wrapper around `std.json.Value` that preserves an arbitrary JSON payload
/// without forcing the schema to commit to a concrete shape. Used for
/// extension envelopes and forward-compat `unknown` variants.
pub const RawValue = struct {
    value: std.json.Value,

    pub fn jsonStringify(self: RawValue, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !RawValue {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return .{ .value = v };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !RawValue {
        _ = allocator;
        _ = options;
        return .{ .value = source };
    }
};

test "RawValue round-trips arbitrary JSON" {
    const src = "{\"a\":1,\"b\":[true,null,\"x\"]}";
    const parsed = try std.json.parseFromSlice(RawValue, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(out);
    const a = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
    defer a.deinit();
    const b = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer b.deinit();
    try std.testing.expectEqual(a.value.object.count(), b.value.object.count());
}
