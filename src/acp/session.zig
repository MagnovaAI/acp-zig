//! Session state machine.
//!
//! A session is the unit of conversation between a client and an agent.
//! It moves through a small set of states; transitions are explicit so
//! handlers can reject methods that don't make sense in the current state
//! (e.g. session/prompt before initialize).
//!
//! Lifecycle:
//!     idle → initialized → prompting → idle → … → closed
//!
//! `idle` after `initialized` means "ready for the next prompt." `closed`
//! is terminal.

const std = @import("std");
const schema = @import("acp-schema");
const AcpError = @import("errors.zig").AcpError;

pub const State = enum {
    idle,
    initialized,
    prompting,
    closed,
};

pub const Session = struct {
    id: schema.agent.SessionId,
    state: State = .idle,
    cwd: []const u8,
    /// Per-session arena. The owner deinits it on close.
    arena: std.heap.ArenaAllocator,

    pub fn init(
        gpa: std.mem.Allocator,
        id: schema.agent.SessionId,
        cwd: []const u8,
    ) !Session {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const owned_cwd = try arena.allocator().dupe(u8, cwd);
        return .{
            .id = .{ .value = try arena.allocator().dupe(u8, id.value) },
            .cwd = owned_cwd,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
    }

    /// Reset the per-session arena. Useful between turns when the agent
    /// has finished emitting tool calls and content for one prompt.
    pub fn resetArena(self: *Session) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn markInitialized(self: *Session) AcpError!void {
        if (self.state != .idle) return error.InvalidParams;
        self.state = .initialized;
    }

    pub fn beginPrompt(self: *Session) AcpError!void {
        switch (self.state) {
            .initialized, .idle => self.state = .prompting,
            .prompting => return error.InvalidParams,
            .closed => return error.SessionNotFound,
        }
    }

    pub fn endPrompt(self: *Session) AcpError!void {
        if (self.state != .prompting) return error.InvalidParams;
        self.state = .initialized;
        self.resetArena();
    }

    pub fn close(self: *Session) void {
        self.state = .closed;
    }
};

/// Owning registry of sessions keyed by id. Multiple sessions per peer is
/// the normal case (an editor with several tabs / agents).
pub const Registry = struct {
    gpa: std.mem.Allocator,
    sessions: std.StringHashMap(*Session),

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{
            .gpa = gpa,
            .sessions = std.StringHashMap(*Session).init(gpa),
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit();
    }

    pub fn create(
        self: *Registry,
        id: schema.agent.SessionId,
        cwd: []const u8,
    ) AcpError!*Session {
        if (self.sessions.contains(id.value)) return error.InvalidParams;
        const sess = self.gpa.create(Session) catch return error.OutOfMemory;
        errdefer self.gpa.destroy(sess);
        sess.* = Session.init(self.gpa, id, cwd) catch return error.OutOfMemory;
        self.sessions.put(sess.id.value, sess) catch return error.OutOfMemory;
        return sess;
    }

    pub fn get(self: *Registry, id: schema.agent.SessionId) AcpError!*Session {
        return self.sessions.get(id.value) orelse error.SessionNotFound;
    }

    pub fn remove(self: *Registry, id: schema.agent.SessionId) void {
        if (self.sessions.fetchRemove(id.value)) |kv| {
            kv.value.deinit();
            self.gpa.destroy(kv.value);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Session moves through lifecycle" {
    var s = try Session.init(std.testing.allocator, .{ .value = "s1" }, "/tmp");
    defer s.deinit();

    try std.testing.expectEqual(State.idle, s.state);
    try s.markInitialized();
    try std.testing.expectEqual(State.initialized, s.state);

    try s.beginPrompt();
    try std.testing.expectEqual(State.prompting, s.state);
    try s.endPrompt();
    try std.testing.expectEqual(State.initialized, s.state);

    s.close();
    try std.testing.expectEqual(State.closed, s.state);
}

test "Session rejects beginPrompt while already prompting" {
    var s = try Session.init(std.testing.allocator, .{ .value = "s1" }, "/tmp");
    defer s.deinit();
    try s.markInitialized();
    try s.beginPrompt();
    try std.testing.expectError(error.InvalidParams, s.beginPrompt());
}

test "Session rejects markInitialized twice" {
    var s = try Session.init(std.testing.allocator, .{ .value = "s1" }, "/tmp");
    defer s.deinit();
    try s.markInitialized();
    try std.testing.expectError(error.InvalidParams, s.markInitialized());
}

test "Session rejects beginPrompt after close" {
    var s = try Session.init(std.testing.allocator, .{ .value = "s1" }, "/tmp");
    defer s.deinit();
    s.close();
    try std.testing.expectError(error.SessionNotFound, s.beginPrompt());
}

test "Registry create / get / remove" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const s = try reg.create(.{ .value = "s1" }, "/tmp");
    try std.testing.expectEqualStrings("s1", s.id.value);
    try std.testing.expectEqualStrings("/tmp", s.cwd);

    const got = try reg.get(.{ .value = "s1" });
    try std.testing.expectEqual(s, got);

    reg.remove(.{ .value = "s1" });
    try std.testing.expectError(error.SessionNotFound, reg.get(.{ .value = "s1" }));
}

test "Registry rejects duplicate create" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    _ = try reg.create(.{ .value = "s1" }, "/tmp");
    try std.testing.expectError(error.InvalidParams, reg.create(.{ .value = "s1" }, "/tmp"));
}

test "Registry deinit cleans up open sessions" {
    var reg = Registry.init(std.testing.allocator);
    _ = try reg.create(.{ .value = "a" }, "/x");
    _ = try reg.create(.{ .value = "b" }, "/y");
    reg.deinit();
}
