//! Handler vtables.
//!
//! A `RequestHandler` answers incoming requests with a result `std.json.Value`
//! or an `AcpError`. A `NotificationHandler` consumes incoming notifications
//! and never produces a reply. The transport owns dispatch — handlers are
//! called from whichever thread or task the transport runs on.

const std = @import("std");
const AcpError = @import("errors.zig").AcpError;

pub const RequestHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            method: []const u8,
            params: std.json.Value,
        ) AcpError!std.json.Value,
    };

    pub fn handle(
        self: RequestHandler,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
    ) AcpError!std.json.Value {
        return self.vtable.handle(self.ptr, allocator, method, params);
    }
};

pub const NotificationHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            method: []const u8,
            params: std.json.Value,
        ) AcpError!void,
    };

    pub fn handle(
        self: NotificationHandler,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
    ) AcpError!void {
        return self.vtable.handle(self.ptr, allocator, method, params);
    }
};

// Test helpers: a handler that records every call and returns a fixed reply.
const Recorder = struct {
    calls: std.ArrayList(Call) = .empty,
    allocator: std.mem.Allocator,

    pub const Call = struct {
        method: []const u8,
        params_kind: std.meta.Tag(std.json.Value),
    };

    fn handleReq(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
    ) AcpError!std.json.Value {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.calls.append(self.allocator, .{
            .method = self.allocator.dupe(u8, method) catch return error.OutOfMemory,
            .params_kind = std.meta.activeTag(params),
        }) catch return error.OutOfMemory;
        _ = allocator;
        return .{ .bool = true };
    }

    fn handleNotif(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
    ) AcpError!void {
        _ = allocator;
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.calls.append(self.allocator, .{
            .method = self.allocator.dupe(u8, method) catch return error.OutOfMemory,
            .params_kind = std.meta.activeTag(params),
        }) catch return error.OutOfMemory;
    }

    fn deinit(self: *Recorder) void {
        for (self.calls.items) |c| self.allocator.free(c.method);
        self.calls.deinit(self.allocator);
    }
};

const recorder_request_vtable: RequestHandler.VTable = .{ .handle = Recorder.handleReq };
const recorder_notification_vtable: NotificationHandler.VTable = .{ .handle = Recorder.handleNotif };

test "RequestHandler dispatches through vtable" {
    var rec: Recorder = .{ .allocator = std.testing.allocator };
    defer rec.deinit();
    const h: RequestHandler = .{ .ptr = &rec, .vtable = &recorder_request_vtable };
    const result = try h.handle(std.testing.allocator, "initialize", .{ .object = .empty });
    try std.testing.expect(result.bool);
    try std.testing.expectEqual(@as(usize, 1), rec.calls.items.len);
    try std.testing.expectEqualStrings("initialize", rec.calls.items[0].method);
}

test "NotificationHandler dispatches through vtable" {
    var rec: Recorder = .{ .allocator = std.testing.allocator };
    defer rec.deinit();
    const h: NotificationHandler = .{ .ptr = &rec, .vtable = &recorder_notification_vtable };
    try h.handle(std.testing.allocator, "session/cancel", .{ .object = .empty });
    try std.testing.expectEqual(@as(usize, 1), rec.calls.items.len);
    try std.testing.expectEqualStrings("session/cancel", rec.calls.items[0].method);
}
