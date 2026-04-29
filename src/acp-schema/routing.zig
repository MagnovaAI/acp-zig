//! Routing aggregate unions.
//!
//! These pick a concrete request / response / notification type by the
//! wire-level `method` string. The transport layer parses the envelope,
//! extracts the method, and hands the params object to the matching
//! aggregate via `parseFromMethod`. Stringification re-attaches the method
//! tag.

const std = @import("std");
const agent = @import("agent.zig");
const client = @import("client.zig");

// ---------------------------------------------------------------------------
// Client → Agent
// ---------------------------------------------------------------------------

pub const AgentRequest = union(enum) {
    initialize: agent.InitializeRequest,
    authenticate: agent.AuthenticateRequest,
    new_session: agent.NewSessionRequest,
    load_session: agent.LoadSessionRequest,
    prompt: agent.PromptRequest,
    set_mode: agent.SetModeRequest,

    pub fn methodName(self: AgentRequest) []const u8 {
        return switch (self) {
            .initialize => agent.method_initialize,
            .authenticate => agent.method_authenticate,
            .new_session => agent.method_session_new,
            .load_session => agent.method_session_load,
            .prompt => agent.method_session_prompt,
            .set_mode => agent.method_session_set_mode,
        };
    }

    pub fn parseFromMethod(
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
        options: std.json.ParseOptions,
    ) !AgentRequest {
        if (std.mem.eql(u8, method, agent.method_initialize))
            return .{ .initialize = try std.json.parseFromValueLeaky(agent.InitializeRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, agent.method_authenticate))
            return .{ .authenticate = try std.json.parseFromValueLeaky(agent.AuthenticateRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, agent.method_session_new))
            return .{ .new_session = try std.json.parseFromValueLeaky(agent.NewSessionRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, agent.method_session_load))
            return .{ .load_session = try std.json.parseFromValueLeaky(agent.LoadSessionRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, agent.method_session_prompt))
            return .{ .prompt = try std.json.parseFromValueLeaky(agent.PromptRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, agent.method_session_set_mode))
            return .{ .set_mode = try std.json.parseFromValueLeaky(agent.SetModeRequest, allocator, params, options) };
        return error.MethodNotFound;
    }
};

pub const AgentResponse = union(enum) {
    initialize: agent.InitializeResponse,
    authenticate: agent.AuthenticateResponse,
    new_session: agent.NewSessionResponse,
    load_session: agent.LoadSessionResponse,
    prompt: agent.PromptResponse,
    set_mode: agent.SetModeResponse,

    pub fn parseFromMethod(
        allocator: std.mem.Allocator,
        method: []const u8,
        result: std.json.Value,
        options: std.json.ParseOptions,
    ) !AgentResponse {
        if (std.mem.eql(u8, method, agent.method_initialize))
            return .{ .initialize = try std.json.parseFromValueLeaky(agent.InitializeResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, agent.method_authenticate))
            return .{ .authenticate = try std.json.parseFromValueLeaky(agent.AuthenticateResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, agent.method_session_new))
            return .{ .new_session = try std.json.parseFromValueLeaky(agent.NewSessionResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, agent.method_session_load))
            return .{ .load_session = try std.json.parseFromValueLeaky(agent.LoadSessionResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, agent.method_session_prompt))
            return .{ .prompt = try std.json.parseFromValueLeaky(agent.PromptResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, agent.method_session_set_mode))
            return .{ .set_mode = try std.json.parseFromValueLeaky(agent.SetModeResponse, allocator, result, options) };
        return error.MethodNotFound;
    }
};

pub const AgentNotification = union(enum) {
    cancel: agent.CancelNotification,

    pub fn methodName(self: AgentNotification) []const u8 {
        return switch (self) {
            .cancel => agent.method_session_cancel,
        };
    }

    pub fn parseFromMethod(
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
        options: std.json.ParseOptions,
    ) !AgentNotification {
        if (std.mem.eql(u8, method, agent.method_session_cancel))
            return .{ .cancel = try std.json.parseFromValueLeaky(agent.CancelNotification, allocator, params, options) };
        return error.MethodNotFound;
    }
};

// ---------------------------------------------------------------------------
// Agent → Client
// ---------------------------------------------------------------------------

pub const ClientRequest = union(enum) {
    request_permission: client.RequestPermissionRequest,
    read_text_file: client.ReadTextFileRequest,
    write_text_file: client.WriteTextFileRequest,
    create_terminal: client.CreateTerminalRequest,
    terminal_output: client.TerminalOutputRequest,
    release_terminal: client.ReleaseTerminalRequest,
    wait_for_terminal_exit: client.WaitForTerminalExitRequest,
    kill_terminal: client.KillTerminalRequest,

    pub fn methodName(self: ClientRequest) []const u8 {
        return switch (self) {
            .request_permission => client.method_session_request_permission,
            .read_text_file => client.method_fs_read_text_file,
            .write_text_file => client.method_fs_write_text_file,
            .create_terminal => client.method_terminal_create,
            .terminal_output => client.method_terminal_output,
            .release_terminal => client.method_terminal_release,
            .wait_for_terminal_exit => client.method_terminal_wait_for_exit,
            .kill_terminal => client.method_terminal_kill,
        };
    }

    pub fn parseFromMethod(
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
        options: std.json.ParseOptions,
    ) !ClientRequest {
        if (std.mem.eql(u8, method, client.method_session_request_permission))
            return .{ .request_permission = try std.json.parseFromValueLeaky(client.RequestPermissionRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, client.method_fs_read_text_file))
            return .{ .read_text_file = try std.json.parseFromValueLeaky(client.ReadTextFileRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, client.method_fs_write_text_file))
            return .{ .write_text_file = try std.json.parseFromValueLeaky(client.WriteTextFileRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, client.method_terminal_create))
            return .{ .create_terminal = try std.json.parseFromValueLeaky(client.CreateTerminalRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, client.method_terminal_output))
            return .{ .terminal_output = try std.json.parseFromValueLeaky(client.TerminalOutputRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, client.method_terminal_release))
            return .{ .release_terminal = try std.json.parseFromValueLeaky(client.ReleaseTerminalRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, client.method_terminal_wait_for_exit))
            return .{ .wait_for_terminal_exit = try std.json.parseFromValueLeaky(client.WaitForTerminalExitRequest, allocator, params, options) };
        if (std.mem.eql(u8, method, client.method_terminal_kill))
            return .{ .kill_terminal = try std.json.parseFromValueLeaky(client.KillTerminalRequest, allocator, params, options) };
        return error.MethodNotFound;
    }
};

pub const ClientResponse = union(enum) {
    request_permission: client.RequestPermissionResponse,
    read_text_file: client.ReadTextFileResponse,
    write_text_file: client.WriteTextFileResponse,
    create_terminal: client.CreateTerminalResponse,
    terminal_output: client.TerminalOutputResponse,
    release_terminal: client.ReleaseTerminalResponse,
    wait_for_terminal_exit: client.WaitForTerminalExitResponse,
    kill_terminal: client.KillTerminalResponse,

    pub fn parseFromMethod(
        allocator: std.mem.Allocator,
        method: []const u8,
        result: std.json.Value,
        options: std.json.ParseOptions,
    ) !ClientResponse {
        if (std.mem.eql(u8, method, client.method_session_request_permission))
            return .{ .request_permission = try std.json.parseFromValueLeaky(client.RequestPermissionResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, client.method_fs_read_text_file))
            return .{ .read_text_file = try std.json.parseFromValueLeaky(client.ReadTextFileResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, client.method_fs_write_text_file))
            return .{ .write_text_file = try std.json.parseFromValueLeaky(client.WriteTextFileResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, client.method_terminal_create))
            return .{ .create_terminal = try std.json.parseFromValueLeaky(client.CreateTerminalResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, client.method_terminal_output))
            return .{ .terminal_output = try std.json.parseFromValueLeaky(client.TerminalOutputResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, client.method_terminal_release))
            return .{ .release_terminal = try std.json.parseFromValueLeaky(client.ReleaseTerminalResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, client.method_terminal_wait_for_exit))
            return .{ .wait_for_terminal_exit = try std.json.parseFromValueLeaky(client.WaitForTerminalExitResponse, allocator, result, options) };
        if (std.mem.eql(u8, method, client.method_terminal_kill))
            return .{ .kill_terminal = try std.json.parseFromValueLeaky(client.KillTerminalResponse, allocator, result, options) };
        return error.MethodNotFound;
    }
};

pub const ClientNotification = union(enum) {
    session_update: agent.SessionNotification,

    pub fn methodName(self: ClientNotification) []const u8 {
        return switch (self) {
            .session_update => agent.method_session_update,
        };
    }

    pub fn parseFromMethod(
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
        options: std.json.ParseOptions,
    ) !ClientNotification {
        if (std.mem.eql(u8, method, agent.method_session_update))
            return .{ .session_update = try std.json.parseFromValueLeaky(agent.SessionNotification, allocator, params, options) };
        return error.MethodNotFound;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn parseValue(src: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
}

test "AgentRequest dispatch initialize" {
    const params = try parseValue("{\"protocolVersion\":1}");
    defer params.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try AgentRequest.parseFromMethod(arena.allocator(), agent.method_initialize, params.value, .{});
    try std.testing.expect(req == .initialize);
    try std.testing.expectEqualStrings(agent.method_initialize, req.methodName());
}

test "AgentRequest dispatch session/prompt" {
    const params = try parseValue("{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}");
    defer params.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try AgentRequest.parseFromMethod(arena.allocator(), agent.method_session_prompt, params.value, .{});
    try std.testing.expect(req == .prompt);
    try std.testing.expectEqualStrings("s1", req.prompt.sessionId.value);
}

test "AgentRequest unknown method returns MethodNotFound" {
    const params = try parseValue("{}");
    defer params.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MethodNotFound, AgentRequest.parseFromMethod(arena.allocator(), "no/such", params.value, .{}));
}

test "AgentResponse dispatch initialize" {
    const result = try parseValue("{\"protocolVersion\":1}");
    defer result.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const resp = try AgentResponse.parseFromMethod(arena.allocator(), agent.method_initialize, result.value, .{});
    try std.testing.expect(resp == .initialize);
    try std.testing.expectEqual(@as(u16, 1), resp.initialize.protocolVersion.value);
}

test "AgentResponse dispatch session/prompt" {
    const result = try parseValue("{\"stopReason\":\"end_turn\"}");
    defer result.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const resp = try AgentResponse.parseFromMethod(arena.allocator(), agent.method_session_prompt, result.value, .{});
    try std.testing.expect(resp == .prompt);
}

test "AgentNotification dispatch session/cancel" {
    const params = try parseValue("{\"sessionId\":\"s1\"}");
    defer params.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try AgentNotification.parseFromMethod(arena.allocator(), agent.method_session_cancel, params.value, .{});
    try std.testing.expect(n == .cancel);
    try std.testing.expectEqualStrings(agent.method_session_cancel, n.methodName());
}

test "ClientRequest dispatch fs/read_text_file" {
    const params = try parseValue("{\"sessionId\":\"s1\",\"path\":\"/x\"}");
    defer params.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try ClientRequest.parseFromMethod(arena.allocator(), client.method_fs_read_text_file, params.value, .{});
    try std.testing.expect(req == .read_text_file);
    try std.testing.expectEqualStrings("/x", req.read_text_file.path);
}

test "ClientRequest dispatch terminal/create" {
    const params = try parseValue("{\"sessionId\":\"s1\",\"command\":\"ls\"}");
    defer params.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const req = try ClientRequest.parseFromMethod(arena.allocator(), client.method_terminal_create, params.value, .{});
    try std.testing.expect(req == .create_terminal);
    try std.testing.expectEqualStrings(client.method_terminal_create, req.methodName());
}

test "ClientRequest methodName per variant" {
    const cases: [8]ClientRequest = .{
        .{ .request_permission = .{
            .sessionId = .{ .value = "s" },
            .toolCall = .{ .toolCallId = .{ .value = "c" } },
            .options = &.{},
        } },
        .{ .read_text_file = .{ .sessionId = .{ .value = "s" }, .path = "/" } },
        .{ .write_text_file = .{ .sessionId = .{ .value = "s" }, .path = "/", .content = "" } },
        .{ .create_terminal = .{ .sessionId = .{ .value = "s" }, .command = "x" } },
        .{ .terminal_output = .{ .sessionId = .{ .value = "s" }, .terminalId = .{ .value = "t" } } },
        .{ .release_terminal = .{ .sessionId = .{ .value = "s" }, .terminalId = .{ .value = "t" } } },
        .{ .wait_for_terminal_exit = .{ .sessionId = .{ .value = "s" }, .terminalId = .{ .value = "t" } } },
        .{ .kill_terminal = .{ .sessionId = .{ .value = "s" }, .terminalId = .{ .value = "t" } } },
    };
    for (cases) |req| try std.testing.expect(req.methodName().len > 0);
}

test "ClientResponse dispatch terminal/output" {
    const result = try parseValue("{\"output\":\"hi\",\"truncated\":false}");
    defer result.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const resp = try ClientResponse.parseFromMethod(arena.allocator(), client.method_terminal_output, result.value, .{});
    try std.testing.expect(resp == .terminal_output);
    try std.testing.expectEqualStrings("hi", resp.terminal_output.output);
}

test "ClientNotification dispatch session/update" {
    const params = try parseValue("{\"sessionId\":\"s1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}}");
    defer params.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const n = try ClientNotification.parseFromMethod(arena.allocator(), agent.method_session_update, params.value, .{});
    try std.testing.expect(n == .session_update);
    try std.testing.expect(n.session_update.update == .agent_message_chunk);
}
