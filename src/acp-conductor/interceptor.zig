//! Per-method interceptors.
//!
//! An interceptor sees a request or notification on its way through a
//! proxy and may rewrite the params, replace the response, or pass the
//! call along untouched. Interceptors are typed against the wire `method`
//! string, not the schema's tagged unions, so vendors can attach
//! behaviour to extension methods the core schema doesn't know about.

const std = @import("std");
const acp = @import("acp");

const AcpError = acp.AcpError;

pub const Direction = enum {
    /// Client → Agent: request flowing toward the agent end of the chain.
    forward,
    /// Agent → Client: response or notification flowing back toward the
    /// originating client.
    reverse,
};

pub const RequestContext = struct {
    direction: Direction,
    method: []const u8,
    params: std.json.Value,
    /// Per-call arena. Anything the interceptor allocates from here lives
    /// until the call completes.
    allocator: std.mem.Allocator,
};

pub const RequestOutcome = union(enum) {
    /// Forward the (possibly rewritten) params to the next link.
    pass: std.json.Value,
    /// Short-circuit with this result; the call never reaches the agent.
    short_circuit: std.json.Value,
    /// Short-circuit with a protocol error.
    fail: AcpError,
};

pub const NotificationContext = struct {
    direction: Direction,
    method: []const u8,
    params: std.json.Value,
    allocator: std.mem.Allocator,
};

pub const NotificationOutcome = union(enum) {
    /// Forward the (possibly rewritten) params.
    pass: std.json.Value,
    /// Drop the notification — downstream peers never see it.
    drop,
};

pub const RequestInterceptor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        on_request: *const fn (
            ctx: *anyopaque,
            call: RequestContext,
        ) AcpError!RequestOutcome,
    };

    pub fn onRequest(self: RequestInterceptor, call: RequestContext) AcpError!RequestOutcome {
        return self.vtable.on_request(self.ptr, call);
    }
};

pub const NotificationInterceptor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        on_notification: *const fn (
            ctx: *anyopaque,
            call: NotificationContext,
        ) AcpError!NotificationOutcome,
    };

    pub fn onNotification(
        self: NotificationInterceptor,
        call: NotificationContext,
    ) AcpError!NotificationOutcome {
        return self.vtable.on_notification(self.ptr, call);
    }
};

// ---------------------------------------------------------------------------
// Tests via a small recording interceptor
// ---------------------------------------------------------------------------

const Recorder = struct {
    last_method: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    fn onRequest(ctx: *anyopaque, call: RequestContext) AcpError!RequestOutcome {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.last_method = self.allocator.dupe(u8, call.method) catch return error.OutOfMemory;
        return .{ .pass = call.params };
    }

    fn deinit(self: *Recorder) void {
        if (self.last_method) |s| self.allocator.free(s);
    }
};

const recorder_vtable: RequestInterceptor.VTable = .{ .on_request = Recorder.onRequest };

test "RequestInterceptor passes params through" {
    var rec: Recorder = .{ .allocator = std.testing.allocator };
    defer rec.deinit();
    const i: RequestInterceptor = .{ .ptr = &rec, .vtable = &recorder_vtable };

    const params: std.json.Value = .{ .integer = 42 };
    const out = try i.onRequest(.{
        .direction = .forward,
        .method = "initialize",
        .params = params,
        .allocator = std.testing.allocator,
    });

    try std.testing.expect(out == .pass);
    try std.testing.expectEqualStrings("initialize", rec.last_method.?);
}
