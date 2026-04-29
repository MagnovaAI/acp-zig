//! End-to-end contract: client and agent driven over an in-memory pipe
//! complete a full handshake → prompt → response → cancel loop.
//!
//! Single-threaded. We send a request from one end, hand control to the
//! other end via `pumpOne` to dispatch and respond, then read the response
//! at the originator. The pipe transport's `read_frame` returns
//! `TransportClosed` on an empty queue, so order matters.

const std = @import("std");
const acp = @import("acp");
const schema = @import("acp-schema");
const PipePair = @import("pipe_transport.zig").PipePair;

const Agent = struct {
    seen_initialize: bool = false,
    seen_prompt: bool = false,
    seen_cancel: bool = false,

    fn handleRequest(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
    ) acp.AcpError!std.json.Value {
        _ = params;
        const self: *Agent = @ptrCast(@alignCast(ctx));

        if (std.mem.eql(u8, method, schema.agent.method_initialize)) {
            self.seen_initialize = true;
            return jsonValue(allocator,
                \\{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}
            );
        }
        if (std.mem.eql(u8, method, schema.agent.method_session_prompt)) {
            self.seen_prompt = true;
            return jsonValue(allocator,
                \\{"stopReason":"end_turn"}
            );
        }
        return error.MethodNotFound;
    }

    fn handleNotification(
        ctx: *anyopaque,
        _: std.mem.Allocator,
        method: []const u8,
        _: std.json.Value,
    ) acp.AcpError!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, method, schema.agent.method_session_cancel)) {
            self.seen_cancel = true;
        }
    }
};

const agent_request_vtable: acp.handler.RequestHandler.VTable = .{ .handle = Agent.handleRequest };
const agent_notification_vtable: acp.handler.NotificationHandler.VTable = .{ .handle = Agent.handleNotification };

fn jsonValue(allocator: std.mem.Allocator, comptime src: []const u8) acp.AcpError!std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, src, .{}) catch return error.InvalidMessage;
    defer parsed.deinit();
    return clone(allocator, parsed.value) catch return error.OutOfMemory;
}

fn clone(allocator: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(allocator);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try clone(allocator, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .empty;
            try out.ensureTotalCapacity(allocator, obj.count());
            var it = obj.iterator();
            while (it.next()) |entry| {
                const k = try allocator.dupe(u8, entry.key_ptr.*);
                out.putAssumeCapacity(k, try clone(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

/// Synchronously do one client request → agent response round-trip.
fn requestRoundTrip(
    comptime ResultT: type,
    client_conn: *acp.Connection,
    agent_conn: *acp.Connection,
    method: []const u8,
    params: anytype,
) !std.json.Parsed(ResultT) {
    // Step 1: client writes its request frame to the pipe.
    {
        var buf: std.Io.Writer.Allocating = .init(client_conn.allocator);
        defer buf.deinit();
        const w = &buf.writer;
        const id = client_conn.next_id;
        client_conn.next_id += 1;
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
        try std.json.Stringify.value(method, .{}, w);
        try w.writeAll(",\"params\":");
        try std.json.Stringify.value(params, .{}, w);
        try w.writeAll("}");
        try client_conn.transport.writeFrame(.{ .bytes = buf.written() });

        // Step 2: agent dispatches the inbound request and writes a response.
        try agent_conn.pumpOne();

        // Step 3: client reads the response frame.
        const frame_bytes = try client_conn.transport.readFrame(client_conn.allocator);
        defer client_conn.allocator.free(frame_bytes);

        const parsed = try std.json.parseFromSlice(std.json.Value, client_conn.allocator, frame_bytes, .{});
        defer parsed.deinit();

        const result_v = parsed.value.object.get("result") orelse return error.PeerError;
        return std.json.parseFromValue(ResultT, client_conn.allocator, result_v, .{ .ignore_unknown_fields = true });
    }
}

test "client and agent complete handshake -> prompt -> cancel loop" {
    const a = std.testing.allocator;
    const pair = try PipePair.init(a);
    defer pair.deinit();

    var agent_ctx: Agent = .{};
    var agent_conn = acp.Connection.init(a, pair.transportB());
    agent_conn.setRequestHandler(.{ .ptr = &agent_ctx, .vtable = &agent_request_vtable });
    agent_conn.setNotificationHandler(.{ .ptr = &agent_ctx, .vtable = &agent_notification_vtable });

    var client_conn = acp.Connection.init(a, pair.transportA());

    // 1. initialize
    {
        const Init = struct { protocolVersion: schema.ProtocolVersion };
        const params = .{ .protocolVersion = schema.ProtocolVersion.V1 };
        const resp = try requestRoundTrip(Init, &client_conn, &agent_conn, schema.agent.method_initialize, params);
        defer resp.deinit();
        try std.testing.expectEqual(@as(u16, 1), resp.value.protocolVersion.value);
    }

    // 2. session/prompt
    {
        const Prompt = struct { stopReason: schema.agent.StopReason };
        const params = .{
            .sessionId = schema.agent.SessionId{ .value = "s1" },
            .prompt = &[_]schema.ContentBlock{.{ .text = .{ .text = "hi" } }},
        };
        const resp = try requestRoundTrip(Prompt, &client_conn, &agent_conn, schema.agent.method_session_prompt, params);
        defer resp.deinit();
        try std.testing.expectEqual(schema.agent.StopReason.end_turn, resp.value.stopReason);
    }

    // 3. session/cancel notification
    {
        const params = .{ .sessionId = schema.agent.SessionId{ .value = "s1" } };
        try client_conn.notify(schema.agent.method_session_cancel, params);
        try agent_conn.pumpOne();
    }

    try std.testing.expect(agent_ctx.seen_initialize);
    try std.testing.expect(agent_ctx.seen_prompt);
    try std.testing.expect(agent_ctx.seen_cancel);
}

test "Connection records frames into an attached trace buffer" {
    const a = std.testing.allocator;
    const pair = try PipePair.init(a);
    defer pair.deinit();

    var agent_ctx: Agent = .{};
    var agent_conn = acp.Connection.init(a, pair.transportB());
    agent_conn.setNotificationHandler(.{ .ptr = &agent_ctx, .vtable = &agent_notification_vtable });

    var client_conn = acp.Connection.init(a, pair.transportA());

    var client_trace = try acp.TraceBuffer.init(a, 16);
    defer client_trace.deinit();
    var agent_trace = try acp.TraceBuffer.init(a, 16);
    defer agent_trace.deinit();

    client_conn.setTraceBuffer(&client_trace);
    agent_conn.setTraceBuffer(&agent_trace);

    // notify() routes through the traced write helper; pumpOne() routes
    // through the traced read helper. One frame visible on each side.
    const params = .{ .sessionId = schema.agent.SessionId{ .value = "s1" } };
    try client_conn.notify(schema.agent.method_session_cancel, params);
    try agent_conn.pumpOne();

    var client_it = client_trace.iterator();
    const c1 = client_it.next().?;
    try std.testing.expectEqual(acp.TraceDirection.outbound, c1.direction);
    try std.testing.expect(std.mem.indexOf(u8, c1.bytes, "session/cancel") != null);
    try std.testing.expect(client_it.next() == null);

    var agent_it = agent_trace.iterator();
    const a1 = agent_it.next().?;
    try std.testing.expectEqual(acp.TraceDirection.inbound, a1.direction);
    try std.testing.expect(std.mem.indexOf(u8, a1.bytes, "session/cancel") != null);
    try std.testing.expect(agent_it.next() == null);

    try std.testing.expect(agent_ctx.seen_cancel);
}
