//! yopo — reference agent binary.
//!
//! Implements every method on the agent surface using the public SDK
//! API. The handlers don't talk to a real model — they reply with
//! deterministic fixtures so contract tests can assert wire shapes.
//!
//! Today yopo runs against an in-process `acp-test.PipePair`, which
//! lets the same binary exercise the full protocol round-trip
//! end-to-end inside `pub fn main`. When the real-IO stdio transport
//! lands, swapping the transport pair is a one-line change.

const std = @import("std");
const acp = @import("acp");
const acp_test = @import("acp-test");
const schema = @import("acp-schema");

const log = std.log.scoped(.yopo);

const Agent = struct {
    allocator: std.mem.Allocator,
    sessions: acp.SessionRegistry,
    next_session: u32 = 1,

    fn init(gpa: std.mem.Allocator) Agent {
        return .{
            .allocator = gpa,
            .sessions = acp.SessionRegistry.init(gpa),
        };
    }

    fn deinit(self: *Agent) void {
        self.sessions.deinit();
    }

    pub const InitializeHandler = struct {
        agent: *Agent,
        pub const Params = schema.agent.InitializeRequest;
        pub const Result = schema.agent.InitializeResponse;
        pub fn handle(_: *@This(), _: std.mem.Allocator, params: Params) acp.AcpError!Result {
            return .{
                .protocolVersion = params.protocolVersion,
                .agentCapabilities = .{
                    .promptCapabilities = .{ .image = true, .audio = false, .embeddedContext = true },
                    .loadSession = true,
                },
            };
        }
    };

    pub const AuthenticateHandler = struct {
        pub const Params = schema.agent.AuthenticateRequest;
        pub const Result = schema.agent.AuthenticateResponse;
        pub fn handle(_: *@This(), _: std.mem.Allocator, _: Params) acp.AcpError!Result {
            return .{};
        }
    };

    pub const NewSessionHandler = struct {
        agent: *Agent,
        pub const Params = schema.agent.NewSessionRequest;
        pub const Result = schema.agent.NewSessionResponse;
        pub fn handle(self: *@This(), arena: std.mem.Allocator, params: Params) acp.AcpError!Result {
            const id_str = std.fmt.allocPrint(arena, "sess_{d}", .{self.agent.next_session}) catch return error.OutOfMemory;
            self.agent.next_session += 1;
            const sess = try self.agent.sessions.create(.{ .value = id_str }, params.cwd);
            try sess.markInitialized();
            return .{ .sessionId = sess.id };
        }
    };

    pub const LoadSessionHandler = struct {
        agent: *Agent,
        pub const Params = schema.agent.LoadSessionRequest;
        pub const Result = schema.agent.LoadSessionResponse;
        pub fn handle(self: *@This(), _: std.mem.Allocator, params: Params) acp.AcpError!Result {
            // Treat load as create-if-absent so the reference fixture is
            // self-contained.
            const existing = self.agent.sessions.get(params.sessionId) catch null;
            if (existing == null) {
                const sess = try self.agent.sessions.create(params.sessionId, params.cwd);
                try sess.markInitialized();
            }
            return .{};
        }
    };

    pub const PromptHandler = struct {
        agent: *Agent,
        pub const Params = schema.agent.PromptRequest;
        pub const Result = schema.agent.PromptResponse;
        pub fn handle(self: *@This(), _: std.mem.Allocator, params: Params) acp.AcpError!Result {
            const sess = try self.agent.sessions.get(params.sessionId);
            try sess.beginPrompt();
            defer sess.endPrompt() catch {};
            return .{ .stopReason = .end_turn };
        }
    };

    pub const SetModeHandler = struct {
        pub const Params = schema.agent.SetModeRequest;
        pub const Result = schema.agent.SetModeResponse;
        pub fn handle(_: *@This(), _: std.mem.Allocator, _: Params) acp.AcpError!Result {
            return .{};
        }
    };

    pub const CancelHandler = struct {
        agent: *Agent,
        pub const Params = schema.agent.CancelNotification;
        pub fn handle(self: *@This(), _: std.mem.Allocator, params: Params) acp.AcpError!void {
            const sess = self.agent.sessions.get(params.sessionId) catch return;
            // Cancel is observed by clearing the prompting state if any.
            sess.endPrompt() catch {};
        }
    };
};

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;

    const pair = try acp_test.PipePair.init(a);
    defer pair.deinit();

    var agent_state = Agent.init(a);
    defer agent_state.deinit();

    var dispatcher = acp.Dispatcher.init(a);
    defer dispatcher.deinit();

    var init_h: Agent.InitializeHandler = .{ .agent = &agent_state };
    var auth_h: Agent.AuthenticateHandler = .{};
    var new_h: Agent.NewSessionHandler = .{ .agent = &agent_state };
    var load_h: Agent.LoadSessionHandler = .{ .agent = &agent_state };
    var prompt_h: Agent.PromptHandler = .{ .agent = &agent_state };
    var mode_h: Agent.SetModeHandler = .{};
    var cancel_h: Agent.CancelHandler = .{ .agent = &agent_state };

    try dispatcher.registerRequest(schema.agent.method_initialize, Agent.InitializeHandler, &init_h);
    try dispatcher.registerRequest(schema.agent.method_authenticate, Agent.AuthenticateHandler, &auth_h);
    try dispatcher.registerRequest(schema.agent.method_session_new, Agent.NewSessionHandler, &new_h);
    try dispatcher.registerRequest(schema.agent.method_session_load, Agent.LoadSessionHandler, &load_h);
    try dispatcher.registerRequest(schema.agent.method_session_prompt, Agent.PromptHandler, &prompt_h);
    try dispatcher.registerRequest(schema.agent.method_session_set_mode, Agent.SetModeHandler, &mode_h);
    try dispatcher.registerNotification(schema.agent.method_session_cancel, Agent.CancelHandler, &cancel_h);

    var agent_conn = acp.Connection.init(a, pair.transportB());
    agent_conn.setRequestHandler(dispatcher.requestHandler());
    agent_conn.setNotificationHandler(dispatcher.notificationHandler());

    var client_conn = acp.Connection.init(a, pair.transportA());

    log.info("yopo: driving reference contract suite over pipe", .{});
    try driveContract(&client_conn, &agent_conn);
    log.info("yopo: contract suite passed", .{});
}

fn driveContract(client: *acp.Connection, agent: *acp.Connection) !void {
    // initialize
    {
        const params = .{ .protocolVersion = schema.ProtocolVersion.V1 };
        const resp = try clientRoundTrip(
            schema.agent.InitializeResponse,
            client,
            agent,
            schema.agent.method_initialize,
            params,
        );
        defer resp.deinit();
        if (resp.value.protocolVersion.value != 1) return error.ProtocolMismatch;
    }

    // session/new
    var session_id_buf: [32]u8 = undefined;
    const session_id_str = blk: {
        const params = .{ .cwd = "/tmp/yopo" };
        const resp = try clientRoundTrip(
            schema.agent.NewSessionResponse,
            client,
            agent,
            schema.agent.method_session_new,
            params,
        );
        defer resp.deinit();
        const len = resp.value.sessionId.value.len;
        if (len == 0 or len > session_id_buf.len) return error.UnexpectedSessionId;
        @memcpy(session_id_buf[0..len], resp.value.sessionId.value);
        break :blk session_id_buf[0..len];
    };

    // session/prompt
    {
        const params = .{
            .sessionId = schema.agent.SessionId{ .value = session_id_str },
            .prompt = &[_]schema.ContentBlock{.{ .text = .{ .text = "ping" } }},
        };
        const resp = try clientRoundTrip(
            schema.agent.PromptResponse,
            client,
            agent,
            schema.agent.method_session_prompt,
            params,
        );
        defer resp.deinit();
        if (resp.value.stopReason != .end_turn) return error.UnexpectedStopReason;
    }

    // session/set_mode
    {
        const params = .{
            .sessionId = schema.agent.SessionId{ .value = session_id_str },
            .modeId = "default",
        };
        const resp = try clientRoundTrip(
            schema.agent.SetModeResponse,
            client,
            agent,
            schema.agent.method_session_set_mode,
            params,
        );
        defer resp.deinit();
    }

    // session/cancel — notification, no response.
    {
        const params = .{ .sessionId = schema.agent.SessionId{ .value = session_id_str } };
        try client.notify(schema.agent.method_session_cancel, params);
        try agent.pumpOne();
    }
}

fn clientRoundTrip(
    comptime ResultT: type,
    client: *acp.Connection,
    agent: *acp.Connection,
    method: []const u8,
    params: anytype,
) !std.json.Parsed(ResultT) {
    var buf: std.Io.Writer.Allocating = .init(client.allocator);
    defer buf.deinit();
    const w = &buf.writer;

    const id = client.next_id;
    client.next_id += 1;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
    try std.json.Stringify.value(method, .{}, w);
    try w.writeAll(",\"params\":");
    try std.json.Stringify.value(params, .{}, w);
    try w.writeAll("}");
    try client.transport.writeFrame(.{ .bytes = buf.written() });

    try agent.pumpOne();

    const frame_bytes = try client.transport.readFrame(client.allocator);
    defer client.allocator.free(frame_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, client.allocator, frame_bytes, .{});
    defer parsed.deinit();

    const result_v = parsed.value.object.get("result") orelse return error.PeerError;
    return std.json.parseFromValue(ResultT, client.allocator, result_v, .{ .ignore_unknown_fields = true });
}
