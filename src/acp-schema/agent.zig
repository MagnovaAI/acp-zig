//! Client → Agent method surface.
//!
//! Each method's request and response live here. Method names are wire-level
//! constants (the JSON-RPC `method` string). Sub-commits land additional
//! method groups (session/*, terminal/*, etc.) iteratively.

const std = @import("std");
const ProtocolVersion = @import("version.zig").ProtocolVersion;

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
