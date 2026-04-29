//! Synchronous JSON-RPC connection.
//!
//! Owns a transport, a request handler, and a notification handler. Drives
//! the loop in two modes: `serve()` reads frames forever and dispatches them;
//! `request()` sends a request and pumps frames until the matching response
//! arrives, dispatching any incoming requests / notifications in the
//! interim. No threads, no background tasks — the caller drives.

const std = @import("std");
const schema = @import("acp-schema");
const AcpError = @import("errors.zig").AcpError;
const Transport = @import("transport.zig").Transport;
const Frame = @import("transport.zig").Frame;
const RequestHandler = @import("handler.zig").RequestHandler;
const NotificationHandler = @import("handler.zig").NotificationHandler;

const log = std.log.scoped(.acp_connection);

pub const Connection = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    request_handler: ?RequestHandler = null,
    notification_handler: ?NotificationHandler = null,
    next_id: i64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        transport: Transport,
    ) Connection {
        return .{ .allocator = allocator, .transport = transport };
    }

    pub fn setRequestHandler(self: *Connection, h: RequestHandler) void {
        self.request_handler = h;
    }

    pub fn setNotificationHandler(self: *Connection, h: NotificationHandler) void {
        self.notification_handler = h;
    }

    /// Send a notification (no response expected).
    pub fn notify(
        self: *Connection,
        method: []const u8,
        params: anytype,
    ) AcpError!void {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        const w = &buf.writer;

        w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":") catch return error.OutOfMemory;
        std.json.Stringify.value(method, .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"params\":") catch return error.OutOfMemory;
        std.json.Stringify.value(params, .{}, w) catch return error.OutOfMemory;
        w.writeAll("}") catch return error.OutOfMemory;

        try self.transport.writeFrame(.{ .bytes = buf.written() });
    }

    /// Send a request, then pump frames until the matching response arrives.
    /// Incoming requests and notifications during the wait are dispatched.
    pub fn request(
        self: *Connection,
        comptime ResultT: type,
        method: []const u8,
        params: anytype,
    ) AcpError!std.json.Parsed(ResultT) {
        const id = self.next_id;
        self.next_id += 1;

        {
            var buf: std.Io.Writer.Allocating = .init(self.allocator);
            defer buf.deinit();
            const w = &buf.writer;
            w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id}) catch return error.OutOfMemory;
            std.json.Stringify.value(method, .{}, w) catch return error.OutOfMemory;
            w.writeAll(",\"params\":") catch return error.OutOfMemory;
            std.json.Stringify.value(params, .{}, w) catch return error.OutOfMemory;
            w.writeAll("}") catch return error.OutOfMemory;
            try self.transport.writeFrame(.{ .bytes = buf.written() });
        }

        // Pump frames until we see id == our id.
        while (true) {
            const frame_bytes = try self.transport.readFrame(self.allocator);
            defer self.allocator.free(frame_bytes);

            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame_bytes, .{}) catch {
                return error.InvalidMessage;
            };
            defer parsed.deinit();

            const obj = switch (parsed.value) {
                .object => |o| o,
                else => return error.InvalidMessage,
            };

            // Response to our request?
            if (obj.get("id")) |id_v| {
                if (matchId(id_v, id)) {
                    if (obj.get("error")) |err_v| {
                        log.warn("peer error: {f}", .{std.json.fmt(err_v, .{})});
                        return error.PeerError;
                    }
                    const result_v = obj.get("result") orelse return error.InvalidMessage;
                    return std.json.parseFromValue(ResultT, self.allocator, result_v, .{}) catch
                        return error.InvalidParams;
                }
                // Not our response — could be an incoming request from peer.
                if (obj.get("method")) |m_v| {
                    if (m_v != .string) return error.InvalidMessage;
                    try self.dispatchRequest(id_v, m_v.string, obj.get("params") orelse .null);
                    continue;
                }
                // Unknown response id — drop.
                continue;
            }

            // No id: notification.
            if (obj.get("method")) |m_v| {
                if (m_v != .string) return error.InvalidMessage;
                try self.dispatchNotification(m_v.string, obj.get("params") orelse .null);
                continue;
            }

            return error.InvalidMessage;
        }
    }

    /// Read one frame and dispatch it. Returns `error.TransportClosed` on EOF.
    pub fn pumpOne(self: *Connection) AcpError!void {
        const frame_bytes = try self.transport.readFrame(self.allocator);
        defer self.allocator.free(frame_bytes);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame_bytes, .{}) catch {
            return error.InvalidMessage;
        };
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidMessage,
        };

        if (obj.get("method")) |m_v| {
            if (m_v != .string) return error.InvalidMessage;
            const params = obj.get("params") orelse .null;
            if (obj.get("id")) |id_v| {
                try self.dispatchRequest(id_v, m_v.string, params);
            } else {
                try self.dispatchNotification(m_v.string, params);
            }
            return;
        }
        // Stray response with no live request — ignore.
    }

    /// Drive `pumpOne` in a loop until the transport closes.
    pub fn serve(self: *Connection) AcpError!void {
        while (true) {
            self.pumpOne() catch |err| switch (err) {
                error.TransportClosed => return,
                else => return err,
            };
        }
    }

    fn dispatchRequest(
        self: *Connection,
        id_v: std.json.Value,
        method: []const u8,
        params: std.json.Value,
    ) AcpError!void {
        const handler = self.request_handler orelse {
            try self.writeError(id_v, -32601, "method not found");
            return;
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const result = handler.handle(arena.allocator(), method, params) catch |err| switch (err) {
            error.MethodNotFound => {
                try self.writeError(id_v, -32601, "method not found");
                return;
            },
            error.InvalidParams => {
                try self.writeError(id_v, -32602, "invalid params");
                return;
            },
            else => {
                try self.writeError(id_v, -32603, "internal error");
                return;
            },
        };
        try self.writeResult(id_v, result);
    }

    fn dispatchNotification(
        self: *Connection,
        method: []const u8,
        params: std.json.Value,
    ) AcpError!void {
        const handler = self.notification_handler orelse return;
        handler.handle(self.allocator, method, params) catch |err| {
            log.warn("notification handler failed for '{s}': {s}", .{ method, @errorName(err) });
        };
    }

    fn writeResult(self: *Connection, id_v: std.json.Value, result: std.json.Value) AcpError!void {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        const w = &buf.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
        std.json.Stringify.value(id_v, .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"result\":") catch return error.OutOfMemory;
        std.json.Stringify.value(result, .{}, w) catch return error.OutOfMemory;
        w.writeAll("}") catch return error.OutOfMemory;
        try self.transport.writeFrame(.{ .bytes = buf.written() });
    }

    fn writeError(self: *Connection, id_v: std.json.Value, code: i32, message: []const u8) AcpError!void {
        var buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        const w = &buf.writer;
        w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":") catch return error.OutOfMemory;
        std.json.Stringify.value(id_v, .{}, w) catch return error.OutOfMemory;
        w.print(",\"error\":{{\"code\":{d},\"message\":", .{code}) catch return error.OutOfMemory;
        std.json.Stringify.value(message, .{}, w) catch return error.OutOfMemory;
        w.writeAll("}}") catch return error.OutOfMemory;
        try self.transport.writeFrame(.{ .bytes = buf.written() });
    }
};

fn matchId(v: std.json.Value, id: i64) bool {
    return switch (v) {
        .integer => |i| i == id,
        else => false,
    };
}

comptime {
    _ = schema;
}
