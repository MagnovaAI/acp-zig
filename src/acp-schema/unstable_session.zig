//! Unstable Client → Agent session methods.
//!
//! Each method is gated behind its own build flag — the wire shape
//! upstream is still in flux and shouldn't appear in the stable
//! public surface. The `types` namespace expands to an empty struct
//! when its flag is off, so disabled methods add no symbols.

const std = @import("std");
const build_options = @import("build_options");
const SessionId = @import("agent.zig").SessionId;

// ---------------------------------------------------------------------------
// logout — gated by unstable_logout
// ---------------------------------------------------------------------------

pub const logout_enabled = build_options.unstable_logout;

const logout_impl = struct {
    pub const method_logout: []const u8 = "logout";
    pub const LogoutRequest = struct {};
    pub const LogoutResponse = struct {};
};

pub const logout = if (logout_enabled) logout_impl else struct {};

// ---------------------------------------------------------------------------
// session/fork — gated by unstable_session_fork
// ---------------------------------------------------------------------------

pub const fork_enabled = build_options.unstable_session_fork;

const fork_impl = struct {
    pub const method_session_fork: []const u8 = "session/fork";
    pub const ForkSessionRequest = struct {
        sessionId: SessionId,
    };
    pub const ForkSessionResponse = struct {
        sessionId: SessionId,
    };
};

pub const fork = if (fork_enabled) fork_impl else struct {};

// ---------------------------------------------------------------------------
// session/resume — gated by unstable_session_resume
// ---------------------------------------------------------------------------

pub const resume_enabled = build_options.unstable_session_resume;

const resume_impl = struct {
    pub const method_session_resume: []const u8 = "session/resume";
    pub const ResumeSessionRequest = struct {
        sessionId: SessionId,
    };
    pub const ResumeSessionResponse = struct {};
};

pub const session_resume = if (resume_enabled) resume_impl else struct {};

// ---------------------------------------------------------------------------
// session/close — gated by unstable_session_close
// ---------------------------------------------------------------------------

pub const close_enabled = build_options.unstable_session_close;

const close_impl = struct {
    pub const method_session_close: []const u8 = "session/close";
    pub const CloseSessionRequest = struct {
        sessionId: SessionId,
    };
    pub const CloseSessionResponse = struct {};
};

pub const close = if (close_enabled) close_impl else struct {};

// ---------------------------------------------------------------------------
// session/set_model — gated by unstable_session_model
// ---------------------------------------------------------------------------

pub const set_model_enabled = build_options.unstable_session_model;

const set_model_impl = struct {
    pub const method_session_set_model: []const u8 = "session/set_model";
    pub const SetModelRequest = struct {
        sessionId: SessionId,
        modelId: []const u8,
    };
    pub const SetModelResponse = struct {};
};

pub const set_model = if (set_model_enabled) set_model_impl else struct {};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "LogoutRequest round-trip when enabled" {
    if (!logout_enabled) return error.SkipZigTest;
    const parsed = try std.json.parseFromSlice(logout.LogoutRequest, std.testing.allocator, "{}", .{});
    defer parsed.deinit();
    _ = parsed.value;
}

test "ForkSessionRequest round-trip when enabled" {
    if (!fork_enabled) return error.SkipZigTest;
    const src = "{\"sessionId\":\"s1\"}";
    const parsed = try std.json.parseFromSlice(fork.ForkSessionRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s1", parsed.value.sessionId.value);
}

test "ResumeSessionRequest round-trip when enabled" {
    if (!resume_enabled) return error.SkipZigTest;
    const src = "{\"sessionId\":\"s1\"}";
    const parsed = try std.json.parseFromSlice(session_resume.ResumeSessionRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
}

test "CloseSessionRequest round-trip when enabled" {
    if (!close_enabled) return error.SkipZigTest;
    const src = "{\"sessionId\":\"s1\"}";
    const parsed = try std.json.parseFromSlice(close.CloseSessionRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
}

test "SetModelRequest round-trip when enabled" {
    if (!set_model_enabled) return error.SkipZigTest;
    const src = "{\"sessionId\":\"s1\",\"modelId\":\"opus-4\"}";
    const parsed = try std.json.parseFromSlice(set_model.SetModelRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("opus-4", parsed.value.modelId);
}
