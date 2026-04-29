//! JSON-RPC 2.0 envelopes used by the Agent Client Protocol.
//!
//! The wire shape is fixed: `jsonrpc` is always the literal "2.0"; `id` is a
//! string or integer; the `method` + `params` shape is shared by requests and
//! notifications (notifications omit `id`). Responses carry exactly one of
//! `result` or `error`.

const std = @import("std");
const RawValue = @import("serde_util.zig").RawValue;

pub const JSONRPC_VERSION: []const u8 = "2.0";

/// Request id: a JSON string or integer. Null is permitted on the wire for
/// responses that fail to associate to a request, but live requests always
/// carry one of the two concrete variants.
pub const RequestId = union(enum) {
    string: []const u8,
    integer: i64,

    pub fn jsonStringify(self: RequestId, jw: anytype) !void {
        switch (self) {
            .string => |s| try jw.write(s),
            .integer => |i| try jw.write(i),
        }
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !RequestId {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        switch (token) {
            .number, .allocated_number => |slice| {
                const i = std.fmt.parseInt(i64, slice, 10) catch return error.UnexpectedToken;
                if (token == .allocated_number) allocator.free(token.allocated_number);
                return .{ .integer = i };
            },
            .string => |s| {
                const owned = try allocator.dupe(u8, s);
                return .{ .string = owned };
            },
            .allocated_string => |s| {
                return .{ .string = s };
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !RequestId {
        _ = options;
        switch (source) {
            .integer => |i| return .{ .integer = i },
            .string => |s| return .{ .string = try allocator.dupe(u8, s) },
            else => return error.UnexpectedToken,
        }
    }
};

/// Outgoing/incoming request envelope.
pub const Request = struct {
    jsonrpc: []const u8 = JSONRPC_VERSION,
    id: RequestId,
    method: []const u8,
    params: ?RawValue = null,
};

/// Outgoing/incoming notification envelope (no id).
pub const Notification = struct {
    jsonrpc: []const u8 = JSONRPC_VERSION,
    method: []const u8,
    params: ?RawValue = null,
};

/// Protocol-level error attached to a Response.
pub const ResponseError = struct {
    code: i32,
    message: []const u8,
    data: ?RawValue = null,
};

/// JSON-RPC response. The `result`/`error` mutual exclusion is enforced via
/// a tagged union; the JSON shape uses two optional fields per the spec.
pub const Response = struct {
    jsonrpc: []const u8 = JSONRPC_VERSION,
    id: RequestId,
    payload: Payload,

    pub const Payload = union(enum) {
        result: RawValue,
        @"error": ResponseError,
    };

    pub fn jsonStringify(self: Response, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write(self.jsonrpc);
        try jw.objectField("id");
        try jw.write(self.id);
        switch (self.payload) {
            .result => |r| {
                try jw.objectField("result");
                try jw.write(r);
            },
            .@"error" => |e| {
                try jw.objectField("error");
                try jw.write(e);
            },
        }
        try jw.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Response {
        const v = try std.json.innerParse(std.json.Value, allocator, source, options);
        return jsonParseFromValue(allocator, v, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Response {
        if (source != .object) return error.UnexpectedToken;
        const obj = source.object;

        const jsonrpc_v = obj.get("jsonrpc") orelse return error.MissingField;
        if (jsonrpc_v != .string) return error.UnexpectedToken;

        const id_v = obj.get("id") orelse return error.MissingField;
        const id = try RequestId.jsonParseFromValue(allocator, id_v, options);

        const has_result = obj.get("result");
        const has_error = obj.get("error");
        if ((has_result == null) == (has_error == null)) return error.UnexpectedToken;

        const payload: Payload = if (has_result) |r|
            .{ .result = .{ .value = r } }
        else
            .{ .@"error" = try std.json.parseFromValueLeaky(ResponseError, allocator, has_error.?, options) };

        return .{
            .jsonrpc = try allocator.dupe(u8, jsonrpc_v.string),
            .id = id,
            .payload = payload,
        };
    }
};

/// Top-level message frame as it appears on the wire. Used when peeking before
/// dispatch — concrete handlers parse straight into Request / Response /
/// Notification once routing has been resolved.
pub const JsonRpcMessage = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "RequestId integer round-trip" {
    const id: RequestId = .{ .integer = 42 };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, id, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("42", out);
    const parsed = try std.json.parseFromSlice(RequestId, std.testing.allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 42), parsed.value.integer);
}

test "RequestId string round-trip" {
    const parsed = try std.json.parseFromSlice(RequestId, std.testing.allocator, "\"abc\"", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc", parsed.value.string);
}

test "Request envelope round-trips with params" {
    const src =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
    ;
    const parsed = try std.json.parseFromSlice(Request, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("initialize", parsed.value.method);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.id.integer);
    try std.testing.expect(parsed.value.params != null);
}

test "Notification envelope has no id" {
    const src =
        \\{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s1"}}
    ;
    const parsed = try std.json.parseFromSlice(Notification, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("session/cancel", parsed.value.method);
}

test "Response with result parses" {
    const src =
        \\{"jsonrpc":"2.0","id":1,"result":{"ok":true}}
    ;
    const parsed = try std.json.parseFromSlice(Response, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.payload == .result);
}

test "Response with error parses" {
    const src =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}
    ;
    const parsed = try std.json.parseFromSlice(Response, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.payload == .@"error");
    try std.testing.expectEqual(@as(i32, -32601), parsed.value.payload.@"error".code);
}

test "Response rejects both result and error" {
    const src =
        \\{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":"x"}}
    ;
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Response, std.testing.allocator, src, .{}));
}

test "Response stringifies result" {
    const r: Response = .{
        .id = .{ .integer = 7 },
        .payload = .{ .result = .{ .value = .{ .bool = true } } },
    };
    const out = try std.json.Stringify.valueAlloc(std.testing.allocator, r, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"result\":true") != null);
}
