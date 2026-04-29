//! Protocol-level control messages.
//!
//! `cancel_request` is gated behind `unstable_cancel_request` — the v2
//! cancellation flow is still being shaped upstream and shouldn't appear in
//! stable surface area.

const std = @import("std");
const build_options = @import("build_options");
const RequestId = @import("rpc.zig").RequestId;

pub const cancel_request_enabled = build_options.unstable_cancel_request;

const cancel_impl = struct {
    pub const CancelRequest = struct {
        id: RequestId,
        reason: ?[]const u8 = null,
    };
};

const cancel_disabled = struct {};

pub const cancel = if (cancel_request_enabled) cancel_impl else cancel_disabled;

test "CancelRequest round-trip when enabled" {
    if (!cancel_request_enabled) return error.SkipZigTest;
    const src =
        \\{"id":7,"reason":"user aborted"}
    ;
    const parsed = try std.json.parseFromSlice(cancel.CancelRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 7), parsed.value.id.integer);
}
