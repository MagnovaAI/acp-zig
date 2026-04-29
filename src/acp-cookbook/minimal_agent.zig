//! Minimal agent example.
//!
//! Demonstrates the agent-side surface — `Connection` + `Dispatcher` with
//! typed request handlers — by serving a simulated client over an
//! in-memory pipe. When the async stdio transport lands, swapping the
//! pipe for a real stdio transport is a one-line change.

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

    var dispatcher = acp.Dispatcher.init(allocator);
    defer dispatcher.deinit();

    var init_handler: InitializeHandler = .{};
    try dispatcher.registerRequest(
        schema.agent.method_initialize,
        InitializeHandler,
        &init_handler,
    );

    var prompt_handler: PromptHandler = .{};
    try dispatcher.registerRequest(
        schema.agent.method_session_prompt,
        PromptHandler,
        &prompt_handler,
    );

    var agent_conn = acp.Connection.init(allocator, pair.transportB());
    agent_conn.setRequestHandler(dispatcher.requestHandler());

    var client_conn = acp.Connection.init(allocator, pair.transportA());

    // Drive one round of each method against the dispatcher and print the
    // replies — same semantics a real stdio agent would expose.
    try writeRequest(&client_conn, schema.agent.method_initialize, .{
        .protocolVersion = schema.ProtocolVersion.V1,
    });
    try agent_conn.pumpOne();
    {
        const Init = struct { protocolVersion: schema.ProtocolVersion };
        const resp = try readResponse(Init, &client_conn);
        defer resp.deinit();
        const line = try std.fmt.allocPrint(
            allocator,
            "agent replied initialize -> protocolVersion={d}\n",
            .{resp.value.protocolVersion.value},
        );
        defer allocator.free(line);
        try std.Io.File.writeStreamingAll(stdout, io, line);
    }

    try writeRequest(&client_conn, schema.agent.method_session_prompt, .{
        .sessionId = schema.agent.SessionId{ .value = "demo" },
        .prompt = &[_]schema.ContentBlock{.{ .text = .{ .text = "hello" } }},
    });
    try agent_conn.pumpOne();
    {
        const Prompt = struct { stopReason: schema.agent.StopReason };
        const resp = try readResponse(Prompt, &client_conn);
        defer resp.deinit();
        const line = try std.fmt.allocPrint(
            allocator,
            "agent replied session/prompt -> stopReason={s}\n",
            .{@tagName(resp.value.stopReason)},
        );
        defer allocator.free(line);
        try std.Io.File.writeStreamingAll(stdout, io, line);
    }
}

const InitializeHandler = struct {
    pub const Params = struct {
        protocolVersion: schema.ProtocolVersion,
    };
    pub const Result = struct {
        protocolVersion: schema.ProtocolVersion,
    };

    pub fn handle(
        _: *InitializeHandler,
        _: std.mem.Allocator,
        params: Params,
    ) acp.AcpError!Result {
        return .{ .protocolVersion = params.protocolVersion };
    }
};

const PromptHandler = struct {
    pub const Params = struct {
        sessionId: schema.agent.SessionId,
        prompt: []const schema.ContentBlock,
    };
    pub const Result = struct {
        stopReason: schema.agent.StopReason,
    };

    pub fn handle(
        _: *PromptHandler,
        _: std.mem.Allocator,
        _: Params,
    ) acp.AcpError!Result {
        // Fixed greeting: a real agent would generate a reply and stream
        // session/update notifications. The point here is the dispatch
        // surface, not content generation.
        return .{ .stopReason = .end_turn };
    }
};

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
