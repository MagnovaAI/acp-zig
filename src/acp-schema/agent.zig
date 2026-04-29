//! Client → Agent method surface.
//!
//! Each method's request and response live here. Method names are wire-level
//! constants (the JSON-RPC `method` string). Sub-commits land additional
//! method groups (session/*, terminal/*, etc.) iteratively.

const std = @import("std");
const ProtocolVersion = @import("version.zig").ProtocolVersion;
const ContentBlock = @import("content.zig").ContentBlock;

// ---------------------------------------------------------------------------
// initialize
// ---------------------------------------------------------------------------

pub const method_initialize: []const u8 = "initialize";

/// Capabilities the client offers to the agent.
pub const ClientCapabilities = struct {
    fs: ?FsCapabilities = null,
    terminal: ?bool = null,

    pub const FsCapabilities = struct {
        readTextFile: ?bool = null,
        writeTextFile: ?bool = null,
    };
};

/// Capabilities the agent reports back to the client.
pub const AgentCapabilities = struct {
    promptCapabilities: ?PromptCapabilities = null,
    loadSession: ?bool = null,

    pub const PromptCapabilities = struct {
        image: ?bool = null,
        audio: ?bool = null,
        embeddedContext: ?bool = null,
    };
};

pub const InitializeRequest = struct {
    protocolVersion: ProtocolVersion,
    clientCapabilities: ?ClientCapabilities = null,
};

pub const InitializeResponse = struct {
    protocolVersion: ProtocolVersion,
    agentCapabilities: ?AgentCapabilities = null,
    authMethods: ?[]const AuthMethod = null,
};

pub const AuthMethod = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// authenticate
// ---------------------------------------------------------------------------

pub const method_authenticate: []const u8 = "authenticate";

pub const AuthenticateRequest = struct {
    methodId: []const u8,
};

pub const AuthenticateResponse = struct {};

// ---------------------------------------------------------------------------
// session/*
// ---------------------------------------------------------------------------

pub const SessionId = struct {
    value: []const u8,

    pub fn jsonStringify(self: SessionId, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !SessionId {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const slice = switch (tok) {
            .string => |s| try allocator.dupe(u8, s),
            .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return .{ .value = slice };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !SessionId {
        if (source != .string) return error.UnexpectedToken;
        return .{ .value = try allocator.dupe(u8, source.string) };
    }
};

pub const McpServerConfig = struct {
    name: []const u8,
    command: []const u8,
    args: ?[]const []const u8 = null,
    env: ?[]const McpEnv = null,

    pub const McpEnv = struct {
        name: []const u8,
        value: []const u8,
    };
};

pub const method_session_new: []const u8 = "session/new";

pub const NewSessionRequest = struct {
    cwd: []const u8,
    mcpServers: ?[]const McpServerConfig = null,
};

pub const NewSessionResponse = struct {
    sessionId: SessionId,
};

pub const method_session_load: []const u8 = "session/load";

pub const LoadSessionRequest = struct {
    sessionId: SessionId,
    cwd: []const u8,
    mcpServers: ?[]const McpServerConfig = null,
};

pub const LoadSessionResponse = struct {};

pub const method_session_prompt: []const u8 = "session/prompt";

pub const PromptRequest = struct {
    sessionId: SessionId,
    prompt: []const ContentBlock,
};

pub const PromptResponse = struct {
    stopReason: StopReason,
};

pub const StopReason = enum {
    end_turn,
    max_tokens,
    refusal,
    cancelled,

    pub fn jsonStringify(self: StopReason, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !StopReason {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer freeToken(allocator, tok);
        const slice = switch (tok) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return std.meta.stringToEnum(StopReason, slice) orelse error.InvalidEnumTag;
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !StopReason {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(StopReason, source.string) orelse error.InvalidEnumTag;
    }
};

pub const method_session_cancel: []const u8 = "session/cancel";

pub const CancelNotification = struct {
    sessionId: SessionId,
};

pub const method_session_set_mode: []const u8 = "session/set-mode";

pub const SetModeRequest = struct {
    sessionId: SessionId,
    modeId: []const u8,
};

pub const SetModeResponse = struct {};

fn freeToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |s| allocator.free(s),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "InitializeRequest minimal round-trip" {
    const src =
        \\{"protocolVersion":1}
    ;
    const parsed = try std.json.parseFromSlice(InitializeRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 1), parsed.value.protocolVersion.value);
    try std.testing.expect(parsed.value.clientCapabilities == null);
}

test "InitializeRequest with capabilities" {
    const src =
        \\{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":false},"terminal":true}}
    ;
    const parsed = try std.json.parseFromSlice(InitializeRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.clientCapabilities.?.fs.?.readTextFile.?);
    try std.testing.expect(!parsed.value.clientCapabilities.?.fs.?.writeTextFile.?);
    try std.testing.expect(parsed.value.clientCapabilities.?.terminal.?);
}

test "InitializeResponse with auth methods" {
    const src =
        \\{"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":true,"audio":false,"embeddedContext":true},"loadSession":true},"authMethods":[{"id":"oauth","name":"OAuth","description":"Sign in with provider"}]}
    ;
    const parsed = try std.json.parseFromSlice(InitializeResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.authMethods.?.len);
    try std.testing.expectEqualStrings("oauth", parsed.value.authMethods.?[0].id);
    try std.testing.expect(parsed.value.agentCapabilities.?.promptCapabilities.?.image.?);
}

test "AuthenticateRequest round-trip" {
    const src =
        \\{"methodId":"oauth"}
    ;
    const parsed = try std.json.parseFromSlice(AuthenticateRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("oauth", parsed.value.methodId);
}

test "InitializeRequest stringifies omitting null capabilities" {
    const req: InitializeRequest = .{ .protocolVersion = ProtocolVersion.V1 };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, req, .{ .emit_null_optional_fields = false });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"protocolVersion\":1}", out);
}

test "NewSessionRequest with mcp servers" {
    const src =
        \\{"cwd":"/home/u/proj","mcpServers":[{"name":"git","command":"mcp-git","args":["--repo","."],"env":[{"name":"K","value":"v"}]}]}
    ;
    const parsed = try std.json.parseFromSlice(NewSessionRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/home/u/proj", parsed.value.cwd);
    try std.testing.expectEqualStrings("git", parsed.value.mcpServers.?[0].name);
    try std.testing.expectEqualStrings("v", parsed.value.mcpServers.?[0].env.?[0].value);
}

test "NewSessionResponse session id round-trip" {
    const src =
        \\{"sessionId":"sess_42"}
    ;
    const parsed = try std.json.parseFromSlice(NewSessionResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("sess_42", parsed.value.sessionId.value);
}

test "PromptRequest with text content" {
    const src =
        \\{"sessionId":"s1","prompt":[{"type":"text","text":"hi"}]}
    ;
    const parsed = try std.json.parseFromSlice(PromptRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.prompt.len);
    try std.testing.expect(parsed.value.prompt[0] == .text);
}

test "PromptResponse stop reasons" {
    inline for (.{ "end_turn", "max_tokens", "refusal", "cancelled" }) |name| {
        const src = "{\"stopReason\":\"" ++ name ++ "\"}";
        const parsed = try std.json.parseFromSlice(PromptResponse, std.testing.allocator, src, .{});
        defer parsed.deinit();
    }
}

test "CancelNotification carries session id" {
    const src =
        \\{"sessionId":"s1"}
    ;
    const parsed = try std.json.parseFromSlice(CancelNotification, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s1", parsed.value.sessionId.value);
}

test "SetModeRequest" {
    const src =
        \\{"sessionId":"s1","modeId":"reasoning"}
    ;
    const parsed = try std.json.parseFromSlice(SetModeRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("reasoning", parsed.value.modeId);
}
