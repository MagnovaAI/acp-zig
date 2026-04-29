//! Agent → Client method surface.
//!
//! Permission prompts, file system bridge, and the terminal sub-protocol.

const std = @import("std");
const ToolCallUpdate = @import("tool_call.zig").ToolCallUpdate;
const SessionId = @import("agent.zig").SessionId;

// ---------------------------------------------------------------------------
// session/request_permission
// ---------------------------------------------------------------------------

pub const method_session_request_permission: []const u8 = "session/request_permission";

pub const PermissionOption = struct {
    optionId: []const u8,
    name: []const u8,
    kind: PermissionOptionKind,
};

pub const PermissionOptionKind = enum {
    allow_once,
    allow_always,
    reject_once,
    reject_always,

    pub fn jsonStringify(self: PermissionOptionKind, jw: anytype) !void {
        try jw.write(@tagName(self));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !PermissionOptionKind {
        const tok = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        defer freeToken(allocator, tok);
        const slice = switch (tok) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        return std.meta.stringToEnum(PermissionOptionKind, slice) orelse error.InvalidEnumTag;
    }

    pub fn jsonParseFromValue(
        _: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !PermissionOptionKind {
        if (source != .string) return error.UnexpectedToken;
        return std.meta.stringToEnum(PermissionOptionKind, source.string) orelse error.InvalidEnumTag;
    }
};

pub const RequestPermissionRequest = struct {
    sessionId: SessionId,
    toolCall: ToolCallUpdate,
    options: []const PermissionOption,
};

/// User decision on a permission prompt. `cancelled` means the dialog was
/// dismissed without picking an option.
pub const RequestPermissionOutcome = union(enum) {
    selected: Selected,
    cancelled,

    pub const Selected = struct {
        optionId: []const u8,
    };

    pub fn jsonStringify(self: RequestPermissionOutcome, jw: anytype) !void {
        switch (self) {
            .selected => |s| {
                try jw.beginObject();
                try jw.objectField("outcome");
                try jw.write("selected");
                try jw.objectField("optionId");
                try jw.write(s.optionId);
                try jw.endObject();
            },
            .cancelled => {
                try jw.beginObject();
                try jw.objectField("outcome");
                try jw.write("cancelled");
                try jw.endObject();
            },
        }
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !RequestPermissionOutcome {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        _: std.json.ParseOptions,
    ) !RequestPermissionOutcome {
        if (source != .object) return error.UnexpectedToken;
        const tag_v = source.object.get("outcome") orelse return error.MissingField;
        if (tag_v != .string) return error.UnexpectedToken;
        if (std.mem.eql(u8, tag_v.string, "cancelled")) return .cancelled;
        if (std.mem.eql(u8, tag_v.string, "selected")) {
            const opt_v = source.object.get("optionId") orelse return error.MissingField;
            if (opt_v != .string) return error.UnexpectedToken;
            return .{ .selected = .{ .optionId = try allocator.dupe(u8, opt_v.string) } };
        }
        return error.UnexpectedToken;
    }
};

pub const RequestPermissionResponse = struct {
    outcome: RequestPermissionOutcome,
};

// ---------------------------------------------------------------------------
// fs/read_text_file, fs/write_text_file
// ---------------------------------------------------------------------------

pub const method_fs_read_text_file: []const u8 = "fs/read_text_file";

pub const ReadTextFileRequest = struct {
    sessionId: SessionId,
    path: []const u8,
    line: ?u32 = null,
    limit: ?u32 = null,
};

pub const ReadTextFileResponse = struct {
    content: []const u8,
};

pub const method_fs_write_text_file: []const u8 = "fs/write_text_file";

pub const WriteTextFileRequest = struct {
    sessionId: SessionId,
    path: []const u8,
    content: []const u8,
};

pub const WriteTextFileResponse = struct {};

// ---------------------------------------------------------------------------
// terminal/*
// ---------------------------------------------------------------------------

/// Opaque terminal handle minted by the client on `terminal/create`.
pub const TerminalId = struct {
    value: []const u8,

    pub fn jsonStringify(self: TerminalId, jw: anytype) !void {
        try jw.write(self.value);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !TerminalId {
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
    ) !TerminalId {
        if (source != .string) return error.UnexpectedToken;
        return .{ .value = try allocator.dupe(u8, source.string) };
    }
};

pub const method_terminal_create: []const u8 = "terminal/create";

pub const TerminalEnv = struct {
    name: []const u8,
    value: []const u8,
};

pub const CreateTerminalRequest = struct {
    sessionId: SessionId,
    command: []const u8,
    args: ?[]const []const u8 = null,
    env: ?[]const TerminalEnv = null,
    cwd: ?[]const u8 = null,
    outputByteLimit: ?u64 = null,
};

pub const CreateTerminalResponse = struct {
    terminalId: TerminalId,
};

pub const method_terminal_output: []const u8 = "terminal/output";

pub const TerminalOutputRequest = struct {
    sessionId: SessionId,
    terminalId: TerminalId,
};

pub const TerminalExitStatus = struct {
    exitCode: ?i32 = null,
    signal: ?[]const u8 = null,
};

pub const TerminalOutputResponse = struct {
    output: []const u8,
    truncated: bool = false,
    exitStatus: ?TerminalExitStatus = null,
};

pub const method_terminal_release: []const u8 = "terminal/release";

pub const ReleaseTerminalRequest = struct {
    sessionId: SessionId,
    terminalId: TerminalId,
};

pub const ReleaseTerminalResponse = struct {};

pub const method_terminal_wait_for_exit: []const u8 = "terminal/wait_for_exit";

pub const WaitForTerminalExitRequest = struct {
    sessionId: SessionId,
    terminalId: TerminalId,
};

pub const WaitForTerminalExitResponse = struct {
    exitStatus: TerminalExitStatus,
};

pub const method_terminal_kill: []const u8 = "terminal/kill";

pub const KillTerminalRequest = struct {
    sessionId: SessionId,
    terminalId: TerminalId,
};

pub const KillTerminalResponse = struct {};

fn freeToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |s| allocator.free(s),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PermissionOptionKind round-trip every variant" {
    inline for (.{ "allow_once", "allow_always", "reject_once", "reject_always" }) |name| {
        const src = "\"" ++ name ++ "\"";
        const parsed = try std.json.parseFromSlice(PermissionOptionKind, std.testing.allocator, src, .{});
        defer parsed.deinit();
        const out = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(src, out);
    }
}

test "RequestPermissionRequest round-trip" {
    const src =
        \\{"sessionId":"s1","toolCall":{"toolCallId":"c1","status":"pending"},"options":[{"optionId":"o1","name":"Allow","kind":"allow_once"},{"optionId":"o2","name":"Reject","kind":"reject_once"}]}
    ;
    const parsed = try std.json.parseFromSlice(RequestPermissionRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s1", parsed.value.sessionId.value);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.options.len);
    try std.testing.expectEqual(PermissionOptionKind.allow_once, parsed.value.options[0].kind);
}

test "RequestPermissionOutcome selected variant" {
    const src =
        \\{"outcome":"selected","optionId":"o1"}
    ;
    const parsed = try std.json.parseFromSlice(RequestPermissionOutcome, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .selected);
    try std.testing.expectEqualStrings("o1", parsed.value.selected.optionId);
}

test "RequestPermissionOutcome cancelled variant" {
    const src =
        \\{"outcome":"cancelled"}
    ;
    const parsed = try std.json.parseFromSlice(RequestPermissionOutcome, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .cancelled);
}

test "RequestPermissionOutcome stringifies cancelled" {
    const o: RequestPermissionOutcome = .cancelled;
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, o, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"outcome\":\"cancelled\"}", out);
}

test "ReadTextFileRequest with line range" {
    const src =
        \\{"sessionId":"s1","path":"/x","line":10,"limit":50}
    ;
    const parsed = try std.json.parseFromSlice(ReadTextFileRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 10), parsed.value.line.?);
    try std.testing.expectEqual(@as(u32, 50), parsed.value.limit.?);
}

test "ReadTextFileResponse" {
    const src =
        \\{"content":"hello"}
    ;
    const parsed = try std.json.parseFromSlice(ReadTextFileResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hello", parsed.value.content);
}

test "WriteTextFileRequest" {
    const src =
        \\{"sessionId":"s1","path":"/x","content":"data"}
    ;
    const parsed = try std.json.parseFromSlice(WriteTextFileRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("data", parsed.value.content);
}

test "CreateTerminalRequest full" {
    const src =
        \\{"sessionId":"s1","command":"ls","args":["-la","/tmp"],"env":[{"name":"K","value":"v"}],"cwd":"/home","outputByteLimit":4096}
    ;
    const parsed = try std.json.parseFromSlice(CreateTerminalRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ls", parsed.value.command);
    try std.testing.expectEqual(@as(u64, 4096), parsed.value.outputByteLimit.?);
}

test "CreateTerminalResponse" {
    const src =
        \\{"terminalId":"t1"}
    ;
    const parsed = try std.json.parseFromSlice(CreateTerminalResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("t1", parsed.value.terminalId.value);
}

test "TerminalOutputResponse exit status with code" {
    const src =
        \\{"output":"done\n","truncated":false,"exitStatus":{"exitCode":0}}
    ;
    const parsed = try std.json.parseFromSlice(TerminalOutputResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("done\n", parsed.value.output);
    try std.testing.expectEqual(@as(i32, 0), parsed.value.exitStatus.?.exitCode.?);
}

test "TerminalOutputResponse exit status with signal" {
    const src =
        \\{"output":"","exitStatus":{"signal":"SIGTERM"}}
    ;
    const parsed = try std.json.parseFromSlice(TerminalOutputResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("SIGTERM", parsed.value.exitStatus.?.signal.?);
}

test "WaitForTerminalExitResponse" {
    const src =
        \\{"exitStatus":{"exitCode":1}}
    ;
    const parsed = try std.json.parseFromSlice(WaitForTerminalExitResponse, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 1), parsed.value.exitStatus.exitCode.?);
}

test "ReleaseTerminalRequest" {
    const src =
        \\{"sessionId":"s1","terminalId":"t1"}
    ;
    const parsed = try std.json.parseFromSlice(ReleaseTerminalRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("t1", parsed.value.terminalId.value);
}

test "KillTerminalRequest" {
    const src =
        \\{"sessionId":"s1","terminalId":"t1"}
    ;
    const parsed = try std.json.parseFromSlice(KillTerminalRequest, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("s1", parsed.value.sessionId.value);
}
