//! Proxy chain.
//!
//! A `Chain` composes N interceptors between a client and an agent. Each
//! call walks the chain in order on its way out and in reverse on its
//! way back. An interceptor that short-circuits a request causes the
//! call to unwind immediately — later interceptors don't see it.
//!
//! The chain is data-structured: it owns no transports. Pair it with a
//! pair of `acp.Connection` instances (one toward the client, one toward
//! the agent) to wire it into a real flow.

const std = @import("std");
const acp = @import("acp");
const interceptor_mod = @import("interceptor.zig");

const AcpError = acp.AcpError;
const RequestInterceptor = interceptor_mod.RequestInterceptor;
const NotificationInterceptor = interceptor_mod.NotificationInterceptor;
const RequestContext = interceptor_mod.RequestContext;
const NotificationContext = interceptor_mod.NotificationContext;
const RequestOutcome = interceptor_mod.RequestOutcome;
const NotificationOutcome = interceptor_mod.NotificationOutcome;
const Direction = interceptor_mod.Direction;

pub const Chain = struct {
    allocator: std.mem.Allocator,
    request_links: std.ArrayList(RequestInterceptor) = .empty,
    notification_links: std.ArrayList(NotificationInterceptor) = .empty,

    pub fn init(allocator: std.mem.Allocator) Chain {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Chain) void {
        self.request_links.deinit(self.allocator);
        self.notification_links.deinit(self.allocator);
    }

    pub fn appendRequest(self: *Chain, link: RequestInterceptor) !void {
        try self.request_links.append(self.allocator, link);
    }

    pub fn appendNotification(self: *Chain, link: NotificationInterceptor) !void {
        try self.notification_links.append(self.allocator, link);
    }

    /// Walk the chain forward. Returns the outcome of the final link, or
    /// the first short-circuit / failure encountered.
    pub fn dispatchRequest(
        self: *Chain,
        direction: Direction,
        method: []const u8,
        params: std.json.Value,
        allocator: std.mem.Allocator,
    ) AcpError!RequestOutcome {
        var current = params;
        for (self.request_links.items) |link| {
            const outcome = try link.onRequest(.{
                .direction = direction,
                .method = method,
                .params = current,
                .allocator = allocator,
            });
            switch (outcome) {
                .pass => |p| current = p,
                .short_circuit, .fail => return outcome,
            }
        }
        return .{ .pass = current };
    }

    pub fn dispatchNotification(
        self: *Chain,
        direction: Direction,
        method: []const u8,
        params: std.json.Value,
        allocator: std.mem.Allocator,
    ) AcpError!NotificationOutcome {
        var current = params;
        for (self.notification_links.items) |link| {
            const outcome = try link.onNotification(.{
                .direction = direction,
                .method = method,
                .params = current,
                .allocator = allocator,
            });
            switch (outcome) {
                .pass => |p| current = p,
                .drop => return .drop,
            }
        }
        return .{ .pass = current };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Tagger = struct {
    tag: []const u8,
    seen: u32 = 0,
    allocator: std.mem.Allocator,

    fn onRequest(ctx: *anyopaque, call: RequestContext) AcpError!RequestOutcome {
        const self: *Tagger = @ptrCast(@alignCast(ctx));
        self.seen += 1;

        // Append our tag onto a "tags" array in the params object.
        if (call.params != .object) return .{ .pass = call.params };

        var obj = call.params.object;
        var tags_arr: std.json.Array = if (obj.get("tags")) |existing| blk: {
            if (existing != .array) return error.InvalidMessage;
            break :blk existing.array;
        } else std.json.Array.init(call.allocator);

        const tag_dup = call.allocator.dupe(u8, self.tag) catch return error.OutOfMemory;
        tags_arr.append(.{ .string = tag_dup }) catch return error.OutOfMemory;
        obj.put(call.allocator, "tags", .{ .array = tags_arr }) catch return error.OutOfMemory;
        return .{ .pass = .{ .object = obj } };
    }
};

const tagger_vtable: RequestInterceptor.VTable = .{ .on_request = Tagger.onRequest };

const Blocker = struct {
    fn onRequest(_: *anyopaque, call: RequestContext) AcpError!RequestOutcome {
        if (std.mem.eql(u8, call.method, "session/cancel"))
            return .{ .short_circuit = .{ .bool = true } };
        return .{ .pass = call.params };
    }
};

const blocker_vtable: RequestInterceptor.VTable = .{ .on_request = Blocker.onRequest };

const Filter = struct {
    fn onNotification(_: *anyopaque, call: NotificationContext) AcpError!NotificationOutcome {
        if (std.mem.eql(u8, call.method, "session/update")) return .drop;
        return .{ .pass = call.params };
    }
};

const filter_vtable: NotificationInterceptor.VTable = .{ .on_notification = Filter.onNotification };

test "Chain walks request interceptors in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var chain = Chain.init(std.testing.allocator);
    defer chain.deinit();

    var t1: Tagger = .{ .tag = "first", .allocator = a };
    var t2: Tagger = .{ .tag = "second", .allocator = a };
    try chain.appendRequest(.{ .ptr = &t1, .vtable = &tagger_vtable });
    try chain.appendRequest(.{ .ptr = &t2, .vtable = &tagger_vtable });

    var obj: std.json.ObjectMap = .empty;
    const params: std.json.Value = .{ .object = obj };
    obj = params.object;

    const outcome = try chain.dispatchRequest(.forward, "initialize", params, a);
    try std.testing.expect(outcome == .pass);
    try std.testing.expectEqual(@as(u32, 1), t1.seen);
    try std.testing.expectEqual(@as(u32, 1), t2.seen);

    const tags = outcome.pass.object.get("tags").?.array;
    try std.testing.expectEqual(@as(usize, 2), tags.items.len);
    try std.testing.expectEqualStrings("first", tags.items[0].string);
    try std.testing.expectEqualStrings("second", tags.items[1].string);
}

test "Chain short-circuit stops downstream interceptors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var chain = Chain.init(std.testing.allocator);
    defer chain.deinit();

    var t: Tagger = .{ .tag = "tail", .allocator = a };
    chain.appendRequest(.{ .ptr = undefined, .vtable = &blocker_vtable }) catch unreachable;
    try chain.appendRequest(.{ .ptr = &t, .vtable = &tagger_vtable });

    const outcome = try chain.dispatchRequest(.forward, "session/cancel", .null, a);
    try std.testing.expect(outcome == .short_circuit);
    try std.testing.expectEqual(@as(u32, 0), t.seen);
}

test "Chain notification filter drops matching method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var chain = Chain.init(std.testing.allocator);
    defer chain.deinit();

    try chain.appendNotification(.{ .ptr = undefined, .vtable = &filter_vtable });

    const dropped = try chain.dispatchNotification(.reverse, "session/update", .null, a);
    try std.testing.expect(dropped == .drop);

    const passed = try chain.dispatchNotification(.reverse, "session/cancel", .null, a);
    try std.testing.expect(passed == .pass);
}
