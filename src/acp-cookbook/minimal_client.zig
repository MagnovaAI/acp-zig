//! Minimal client example.
//!
//! Real stdio framing is not yet available in the public API — that lands
//! with the async transport. Until then, this binary demonstrates the
//! client-side surface end-to-end against an in-memory peer so the example
//! exercises the same `Connection` plumbing the eventual stdio binary will
//! use.

const std = @import("std");
const acp = @import("acp");
const acp_test = @import("acp-test");
const schema = acp.schema;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io_impl = std.Io.Threaded.init(allocator, .{});
    defer io_impl.deinit();
    const io = io_impl.io();
    const stdout = std.Io.File.stdout();

    const pair = try acp_test.PipePair.init(allocator);
    defer pair.deinit();

    var agent_ctx: AgentStub = .{};
    var agent_conn = acp.Connection.init(allocator, pair.transportB());
    agent_conn.setRequestHandler(.{
        .ptr = &agent_ctx,
        .vtable = &agent_request_vtable,
    });

    var client_conn = acp.Connection.init(allocator, pair.transportA());

    // initialize
    try writeRequest(
        &client_conn,
        schema.agent.method_initialize,
        .{ .protocolVersion = schema.ProtocolVersion.V1 },
    );
    try agent_conn.pumpOne();
    {
        const Init = struct { protocolVersion: schema.ProtocolVersion };
        const resp = try readResponse(Init, &client_conn);
        defer resp.deinit();
        const line = try std.fmt.allocPrint(
            allocator,
            "initialize -> protocolVersion={d}\n",
            .{resp.value.protocolVersion.value},
        );
        defer allocator.free(line);
        try std.Io.File.writeStreamingAll(stdout, io, line);
    }

    // session/prompt
    {
        const params = .{
            .sessionId = schema.agent.SessionId{ .value = "demo" },
            .prompt = &[_]schema.ContentBlock{.{ .text = .{ .text = "ping" } }},
        };
        try writeRequest(&client_conn, schema.agent.method_session_prompt, params);
        try agent_conn.pumpOne();
        const Prompt = struct { stopReason: schema.agent.StopReason };
        const resp = try readResponse(Prompt, &client_conn);
        defer resp.deinit();
        const line = try std.fmt.allocPrint(
            allocator,
            "session/prompt -> stopReason={s}\n",
            .{@tagName(resp.value.stopReason)},
        );
        defer allocator.free(line);
        try std.Io.File.writeStreamingAll(stdout, io, line);
    }
}

// Writing the request through the public transport rather than via
// `Connection.request` keeps this single-threaded: we control the
// interleave of write -> peer pump -> read explicitly.
fn writeRequest(
    conn: *acp.Connection,
    method: []const u8,
    params: anytype,
) !void {
    var buf: std.Io.Writer.Allocating = .init(conn.allocator);
    defer buf.deinit();
    const w = &buf.writer;
    const id = conn.next_id;
    conn.next_id += 1;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
    try std.json.Stringify.value(method, .{}, w);
    try w.writeAll(",\"params\":");
    try std.json.Stringify.value(params, .{}, w);
    try w.writeAll("}");
    try conn.transport.writeFrame(.{ .bytes = buf.written() });
}

fn readResponse(
    comptime ResultT: type,
    conn: *acp.Connection,
) !std.json.Parsed(ResultT) {
    const frame_bytes = try conn.transport.readFrame(conn.allocator);
    defer conn.allocator.free(frame_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, conn.allocator, frame_bytes, .{});
    defer parsed.deinit();
    const result_v = parsed.value.object.get("result") orelse return error.PeerError;
    return std.json.parseFromValue(ResultT, conn.allocator, result_v, .{ .ignore_unknown_fields = true });
}

const AgentStub = struct {
    fn handle(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        _: std.json.Value,
    ) acp.AcpError!std.json.Value {
        if (std.mem.eql(u8, method, schema.agent.method_initialize)) {
            return parse(allocator, "{\"protocolVersion\":1}");
        }
        if (std.mem.eql(u8, method, schema.agent.method_session_prompt)) {
            return parse(allocator, "{\"stopReason\":\"end_turn\"}");
        }
        return error.MethodNotFound;
    }
};

const agent_request_vtable: acp.handler.RequestHandler.VTable = .{ .handle = AgentStub.handle };

fn parse(allocator: std.mem.Allocator, comptime src: []const u8) acp.AcpError!std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, src, .{}) catch error.InvalidMessage;
}
