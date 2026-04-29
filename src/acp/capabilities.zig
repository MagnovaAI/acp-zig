//! Capability negotiation helpers.
//!
//! Tiny: most of the work is just intersecting what each side declared in
//! initialize. Kept here so transports and conductors can share one
//! implementation.

const schema = @import("acp-schema");

pub const Negotiated = struct {
    protocol_version: schema.ProtocolVersion,
    fs_read: bool,
    fs_write: bool,
    terminal: bool,
    prompt_image: bool,
    prompt_audio: bool,
    prompt_embedded_context: bool,
    load_session: bool,
};

pub fn negotiate(
    client: schema.agent.ClientCapabilities,
    agent: schema.agent.AgentCapabilities,
    version: schema.ProtocolVersion,
) Negotiated {
    const fs = client.fs orelse schema.agent.ClientCapabilities.FsCapabilities{};
    const prompt = agent.promptCapabilities orelse schema.agent.AgentCapabilities.PromptCapabilities{};
    return .{
        .protocol_version = version,
        .fs_read = fs.readTextFile orelse false,
        .fs_write = fs.writeTextFile orelse false,
        .terminal = client.terminal orelse false,
        .prompt_image = prompt.image orelse false,
        .prompt_audio = prompt.audio orelse false,
        .prompt_embedded_context = prompt.embeddedContext orelse false,
        .load_session = agent.loadSession orelse false,
    };
}

const std = @import("std");

test "negotiate intersects declared capabilities" {
    const c: schema.agent.ClientCapabilities = .{
        .fs = .{ .readTextFile = true, .writeTextFile = false },
        .terminal = true,
    };
    const a: schema.agent.AgentCapabilities = .{
        .promptCapabilities = .{ .image = true, .audio = false, .embeddedContext = true },
        .loadSession = true,
    };
    const n = negotiate(c, a, schema.ProtocolVersion.V1);
    try std.testing.expect(n.fs_read);
    try std.testing.expect(!n.fs_write);
    try std.testing.expect(n.terminal);
    try std.testing.expect(n.prompt_image);
    try std.testing.expect(!n.prompt_audio);
    try std.testing.expect(n.prompt_embedded_context);
    try std.testing.expect(n.load_session);
}

test "negotiate defaults to false when peer omits a flag" {
    const n = negotiate(.{}, .{}, schema.ProtocolVersion.V1);
    try std.testing.expect(!n.fs_read);
    try std.testing.expect(!n.fs_write);
    try std.testing.expect(!n.terminal);
    try std.testing.expect(!n.load_session);
}
