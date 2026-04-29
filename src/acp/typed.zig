//! Typed request dispatch.
//!
//! Wraps a string-keyed `RequestHandler` so callers can register
//! per-method handlers with concrete param/result types. The wrapper
//! parses the inbound `std.json.Value` into the declared param type,
//! invokes the typed handler, and serialises the result back into
//! `std.json.Value` against the dispatcher's arena.

const std = @import("std");
const AcpError = @import("errors.zig").AcpError;
const handler_mod = @import("handler.zig");
const RequestHandler = handler_mod.RequestHandler;
const NotificationHandler = handler_mod.NotificationHandler;

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    request_entries: std.ArrayList(RequestEntry) = .empty,
    notification_entries: std.ArrayList(NotificationEntry) = .empty,

    pub const RequestEntry = struct {
        method: []const u8,
        ptr: *anyopaque,
        thunk: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: std.json.Value,
        ) AcpError!std.json.Value,
    };

    pub const NotificationEntry = struct {
        method: []const u8,
        ptr: *anyopaque,
        thunk: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            params: std.json.Value,
        ) AcpError!void,
    };

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.request_entries.deinit(self.allocator);
        self.notification_entries.deinit(self.allocator);
    }

    /// Register a typed request handler.
    ///
    /// `Handler` is an instance type that defines `pub const Params = ...`,
    /// `pub const Result = ...`, and `pub fn handle(self, allocator,
    /// params: Params) AcpError!Result`.
    pub fn registerRequest(
        self: *Dispatcher,
        method: []const u8,
        comptime Handler: type,
        instance: *Handler,
    ) !void {
        const Thunk = struct {
            fn invoke(
                ctx: *anyopaque,
                allocator: std.mem.Allocator,
                params: std.json.Value,
            ) AcpError!std.json.Value {
                const inst: *Handler = @ptrCast(@alignCast(ctx));
                const parsed = std.json.parseFromValueLeaky(
                    Handler.Params,
                    allocator,
                    params,
                    .{ .ignore_unknown_fields = true },
                ) catch return error.InvalidParams;
                const result = try inst.handle(allocator, parsed);
                return marshal(allocator, result);
            }
        };
        try self.request_entries.append(self.allocator, .{
            .method = method,
            .ptr = instance,
            .thunk = Thunk.invoke,
        });
    }

    pub fn registerNotification(
        self: *Dispatcher,
        method: []const u8,
        comptime Handler: type,
        instance: *Handler,
    ) !void {
        const Thunk = struct {
            fn invoke(
                ctx: *anyopaque,
                allocator: std.mem.Allocator,
                params: std.json.Value,
            ) AcpError!void {
                const inst: *Handler = @ptrCast(@alignCast(ctx));
                const parsed = std.json.parseFromValueLeaky(
                    Handler.Params,
                    allocator,
                    params,
                    .{ .ignore_unknown_fields = true },
                ) catch return error.InvalidParams;
                try inst.handle(allocator, parsed);
            }
        };
        try self.notification_entries.append(self.allocator, .{
            .method = method,
            .ptr = instance,
            .thunk = Thunk.invoke,
        });
    }

    pub fn requestHandler(self: *Dispatcher) RequestHandler {
        return .{ .ptr = self, .vtable = &request_vtable };
    }

    pub fn notificationHandler(self: *Dispatcher) NotificationHandler {
        return .{ .ptr = self, .vtable = &notification_vtable };
    }

    fn handleRequest(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
    ) AcpError!std.json.Value {
        const self: *Dispatcher = @ptrCast(@alignCast(ctx));
        for (self.request_entries.items) |entry| {
            if (std.mem.eql(u8, entry.method, method)) {
                return entry.thunk(entry.ptr, allocator, params);
            }
        }
        return error.MethodNotFound;
    }

    fn handleNotification(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
    ) AcpError!void {
        const self: *Dispatcher = @ptrCast(@alignCast(ctx));
        for (self.notification_entries.items) |entry| {
            if (std.mem.eql(u8, entry.method, method)) {
                return entry.thunk(entry.ptr, allocator, params);
            }
        }
        // Unhandled notifications are silently dropped — that's the
        // JSON-RPC contract for notifications.
    }
};

const request_vtable: RequestHandler.VTable = .{ .handle = Dispatcher.handleRequest };
const notification_vtable: NotificationHandler.VTable = .{ .handle = Dispatcher.handleNotification };

/// Stringify a value into a `std.json.Value` whose payload lives in
/// `allocator` (typically the per-dispatch arena).
pub fn marshal(allocator: std.mem.Allocator, value: anytype) AcpError!std.json.Value {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    std.json.Stringify.value(value, .{}, &buf.writer) catch return error.OutOfMemory;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, buf.written(), .{}) catch
        return error.InvalidMessage;
    return parsed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const EchoHandler = struct {
    last_seen: ?i64 = null,

    pub const Params = struct { n: i64 };
    pub const Result = struct { n: i64 };

    pub fn handle(self: *EchoHandler, _: std.mem.Allocator, params: Params) AcpError!Result {
        self.last_seen = params.n;
        return .{ .n = params.n + 1 };
    }
};

const PingHandler = struct {
    count: u32 = 0,

    pub const Params = struct { tag: []const u8 };

    pub fn handle(self: *PingHandler, _: std.mem.Allocator, params: Params) AcpError!void {
        _ = params;
        self.count += 1;
    }
};

test "Dispatcher routes typed request" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    var h: EchoHandler = .{};
    try d.registerRequest("echo", EchoHandler, &h);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"n\":5}", .{});
    const handler = d.requestHandler();
    const result = try handler.handle(arena.allocator(), "echo", params);

    try std.testing.expectEqual(@as(i64, 5), h.last_seen.?);
    try std.testing.expectEqual(@as(i64, 6), result.object.get("n").?.integer);
}

test "Dispatcher returns MethodNotFound for unregistered method" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    const handler = d.requestHandler();
    try std.testing.expectError(error.MethodNotFound, handler.handle(std.testing.allocator, "missing", .null));
}

test "Dispatcher returns InvalidParams when params don't match" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    var h: EchoHandler = .{};
    try d.registerRequest("echo", EchoHandler, &h);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // n is missing
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{}", .{});
    const handler = d.requestHandler();
    try std.testing.expectError(error.InvalidParams, handler.handle(arena.allocator(), "echo", params));
}

test "Dispatcher routes typed notification" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();

    var h: PingHandler = .{};
    try d.registerNotification("ping", PingHandler, &h);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"tag\":\"x\"}", .{});

    const handler = d.notificationHandler();
    try handler.handle(arena.allocator(), "ping", params);
    try handler.handle(arena.allocator(), "ping", params);

    try std.testing.expectEqual(@as(u32, 2), h.count);
}

test "Dispatcher silently drops unregistered notifications" {
    var d = Dispatcher.init(std.testing.allocator);
    defer d.deinit();
    const handler = d.notificationHandler();
    try handler.handle(std.testing.allocator, "no/such", .null);
}
