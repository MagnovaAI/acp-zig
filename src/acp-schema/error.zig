//! Protocol-level Error value (a domain type, not a Zig error union).
//!
//! Mirrors the JSON-RPC error object plus an optional structured `data`
//! payload. Standard JSON-RPC reserved codes are exposed as constants.

const std = @import("std");
const RawValue = @import("serde_util.zig").RawValue;

pub const Code = i32;

pub const parse_error: Code = -32700;
pub const invalid_request: Code = -32600;
pub const method_not_found: Code = -32601;
pub const invalid_params: Code = -32602;
pub const internal_error: Code = -32603;

/// ACP-specific reserved range starts at -32000 (per JSON-RPC convention for
/// implementation-defined server errors).
pub const auth_required: Code = -32000;
pub const session_not_found: Code = -32001;

pub const Error = struct {
    code: Code,
    message: []const u8,
    data: ?RawValue = null,

    pub fn methodNotFound(method: []const u8) Error {
        _ = method;
        return .{ .code = method_not_found, .message = "Method not found" };
    }

    pub fn invalidParams(message: []const u8) Error {
        return .{ .code = invalid_params, .message = message };
    }
};

test "Error round-trips with data" {
    const src =
        \\{"code":-32602,"message":"bad","data":{"field":"x"}}
    ;
    const parsed = try std.json.parseFromSlice(Error, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(invalid_params, parsed.value.code);
    try std.testing.expect(parsed.value.data != null);
}

test "Error stringifies without data when null" {
    const e: Error = .{ .code = method_not_found, .message = "nope" };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, e, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "data") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-32601") != null);
}
