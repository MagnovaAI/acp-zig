//! Client → Agent method surface.
//!
//! Each method's request and response live here. Method names are wire-level
//! constants (the JSON-RPC `method` string). Sub-commits land additional
//! method groups (session/*, terminal/*, etc.) iteratively.

const std = @import("std");
const ProtocolVersion = @import("version.zig").ProtocolVersion;
const ContentBlock = @import("content.zig").ContentBlock;
const Plan = @import("plan.zig").Plan;
const ToolCall = @import("tool_call.zig").ToolCall;
const ToolCallUpdate = @import("tool_call.zig").ToolCallUpdate;

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

// session/update is a notification streamed from agent → client during a
// prompt. Each update has a `sessionId` plus a tagged `update` payload
// keyed on `sessionUpdate`.

pub const method_session_update: []const u8 = "session/update";

pub const SessionUpdate = union(enum) {
    user_message_chunk: ContentChunk,
    agent_message_chunk: ContentChunk,
    agent_thought_chunk: ContentChunk,
    tool_call: ToolCall,
    tool_call_update: ToolCallUpdate,
    plan: PlanWrapper,
    /// Forward-compat: unknown variants from peers running newer revisions.
    unknown: @import("serde_util.zig").RawValue,

    pub const ContentChunk = struct {
        content: ContentBlock,
    };

    pub const PlanWrapper = struct {
        plan: Plan,
    };

    pub fn jsonStringify(self: SessionUpdate, jw: anytype) !void {
        switch (self) {
            .user_message_chunk => |c| try writeChunk(jw, "user_message_chunk", c.content),
            .agent_message_chunk => |c| try writeChunk(jw, "agent_message_chunk", c.content),
            .agent_thought_chunk => |c| try writeChunk(jw, "agent_thought_chunk", c.content),
            .tool_call => |t| try writeFlat(jw, "tool_call", t),
            .tool_call_update => |t| try writeFlat(jw, "tool_call_update", t),
            .plan => |p| try writePlan(jw, p.plan),
            .unknown => |raw| try jw.write(raw),
        }
    }

    fn writeChunk(jw: anytype, comptime tag: []const u8, content: ContentBlock) !void {
        try jw.beginObject();
        try jw.objectField("sessionUpdate");
        try jw.write(tag);
        try jw.objectField("content");
        try jw.write(content);
        try jw.endObject();
    }

    fn writeFlat(jw: anytype, comptime tag: []const u8, payload: anytype) !void {
        try jw.beginObject();
        try jw.objectField("sessionUpdate");
        try jw.write(tag);
        const T = @TypeOf(payload);
        inline for (@typeInfo(T).@"struct".fields) |f| {
            const v = @field(payload, f.name);
            const skip = @typeInfo(f.type) == .optional and v == null;
            if (!skip) {
                try jw.objectField(f.name);
                try jw.write(v);
            }
        }
        try jw.endObject();
    }

    fn writePlan(jw: anytype, plan: Plan) !void {
        try jw.beginObject();
        try jw.objectField("sessionUpdate");
        try jw.write("plan");
        try jw.objectField("entries");
        try jw.write(plan.entries);
        try jw.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !SessionUpdate {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !SessionUpdate {
        if (source != .object) return error.UnexpectedToken;
        const tag_v = source.object.get("sessionUpdate") orelse return error.MissingField;
        if (tag_v != .string) return error.UnexpectedToken;
        const tag = tag_v.string;

        if (std.mem.eql(u8, tag, "user_message_chunk") or
            std.mem.eql(u8, tag, "agent_message_chunk") or
            std.mem.eql(u8, tag, "agent_thought_chunk"))
        {
            const content_v = source.object.get("content") orelse return error.MissingField;
            const cb = try std.json.parseFromValueLeaky(ContentBlock, allocator, content_v, options);
            const chunk: ContentChunk = .{ .content = cb };
            if (std.mem.eql(u8, tag, "user_message_chunk")) return .{ .user_message_chunk = chunk };
            if (std.mem.eql(u8, tag, "agent_message_chunk")) return .{ .agent_message_chunk = chunk };
            return .{ .agent_thought_chunk = chunk };
        }

        if (std.mem.eql(u8, tag, "tool_call")) {
            const inner = try stripTag(allocator, source);
            const tc = try std.json.parseFromValueLeaky(ToolCall, allocator, inner, options);
            return .{ .tool_call = tc };
        }
        if (std.mem.eql(u8, tag, "tool_call_update")) {
            const inner = try stripTag(allocator, source);
            const tc = try std.json.parseFromValueLeaky(ToolCallUpdate, allocator, inner, options);
            return .{ .tool_call_update = tc };
        }
        if (std.mem.eql(u8, tag, "plan")) {
            const entries_v = source.object.get("entries") orelse return error.MissingField;
            const plan = try std.json.parseFromValueLeaky(Plan, allocator, .{ .object = blk: {
                var m: std.json.ObjectMap = .empty;
                try m.ensureTotalCapacity(allocator, 1);
                m.putAssumeCapacity("entries", entries_v);
                break :blk m;
            } }, options);
            return .{ .plan = .{ .plan = plan } };
        }

        return .{ .unknown = .{ .value = source } };
    }
};

pub const SessionNotification = struct {
    sessionId: SessionId,
    update: SessionUpdate,
};

fn stripTag(allocator: std.mem.Allocator, source: std.json.Value) !std.json.Value {
    var copy: std.json.ObjectMap = .empty;
    try copy.ensureTotalCapacity(allocator, source.object.count());
    var it = source.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "sessionUpdate")) continue;
        copy.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    }
    return .{ .object = copy };
}

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

test "SessionUpdate agent_message_chunk round-trip" {
    const src =
        \\{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .agent_message_chunk);
    try std.testing.expect(parsed.value.agent_message_chunk.content == .text);
}

test "SessionUpdate user_message_chunk variant" {
    const src =
        \\{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"q?"}}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .user_message_chunk);
}

test "SessionUpdate agent_thought_chunk variant" {
    const src =
        \\{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"…"}}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .agent_thought_chunk);
}

test "SessionUpdate tool_call inlines fields" {
    const src =
        \\{"sessionUpdate":"tool_call","toolCallId":"c1","title":"reading","kind":"read","status":"pending"}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .tool_call);
    try std.testing.expectEqualStrings("c1", parsed.value.tool_call.toolCallId.value);
}

test "SessionUpdate tool_call_update partial" {
    const src =
        \\{"sessionUpdate":"tool_call_update","toolCallId":"c1","status":"completed"}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .tool_call_update);
}

test "SessionUpdate plan variant" {
    const src =
        \\{"sessionUpdate":"plan","entries":[{"content":"step","status":"pending","priority":"medium"}]}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .plan);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.plan.plan.entries.len);
}

test "SessionUpdate unknown variant survives" {
    const src =
        \\{"sessionUpdate":"future_kind","x":1}
    ;
    const parsed = try std.json.parseFromSlice(SessionUpdate, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .unknown);
}

test "SessionUpdate stringifies chunk with sessionUpdate tag first" {
    const u: SessionUpdate = .{ .agent_message_chunk = .{ .content = .{ .text = .{ .text = "hi" } } } };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, u, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sessionUpdate\":\"agent_message_chunk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"text\":\"hi\"") != null);
}

test "SessionNotification carries session id and update" {
    const src =
        \\{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}
    ;
    const parsed = try std.json.parseFromSlice(SessionNotification, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s1", parsed.value.sessionId.value);
    try std.testing.expect(parsed.value.update == .agent_message_chunk);
}

test "SetModeRequest" {
    const src =
        \\{"sessionId":"s1","modeId":"reasoning"}
    ;
    const parsed = try std.json.parseFromSlice(SetModeRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("reasoning", parsed.value.modeId);
}
