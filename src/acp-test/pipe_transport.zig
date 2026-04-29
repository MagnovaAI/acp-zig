//! In-memory pipe transport.
//!
//! Two `Transport` ends share an explicit FIFO of frames in each direction.
//! Reads block on an empty queue (we don't actually block — they return
//! `error.TransportClosed` if the peer has closed and the queue is drained).
//! Tests drive both ends from a single thread by alternating `request` and
//! `pumpOne` calls.

const std = @import("std");
const acp = @import("acp");
const Transport = acp.Transport;
const Frame = acp.Frame;
const AcpError = acp.AcpError;

/// Two-ended in-memory pipe. Each end exposes a `Transport` that writes into
/// the peer's read queue. Frames are owned slices duplicated on push and
/// freed on pop. Heap-allocated so transports can hold stable pointers.
pub const PipePair = struct {
    allocator: std.mem.Allocator,
    a_to_b: Queue,
    b_to_a: Queue,
    a_closed: bool = false,
    b_closed: bool = false,
    end_a: End,
    end_b: End,

    pub fn init(allocator: std.mem.Allocator) !*PipePair {
        const self = try allocator.create(PipePair);
        self.* = .{
            .allocator = allocator,
            .a_to_b = .{},
            .b_to_a = .{},
            .end_a = undefined,
            .end_b = undefined,
        };
        self.end_a = .{ .pair = self, .side = .a };
        self.end_b = .{ .pair = self, .side = .b };
        return self;
    }

    pub fn deinit(self: *PipePair) void {
        self.a_to_b.deinit(self.allocator);
        self.b_to_a.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn transportA(self: *PipePair) Transport {
        return .{ .ptr = &self.end_a, .vtable = &end_vtable };
    }

    pub fn transportB(self: *PipePair) Transport {
        return .{ .ptr = &self.end_b, .vtable = &end_vtable };
    }

    pub fn closeA(self: *PipePair) void {
        self.a_closed = true;
    }

    pub fn closeB(self: *PipePair) void {
        self.b_closed = true;
    }
};

const Side = enum { a, b };

const End = struct {
    pair: *PipePair,
    side: Side,
};

const Queue = struct {
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        for (self.items.items) |b| allocator.free(b);
        self.items.deinit(allocator);
    }

    fn push(self: *Queue, allocator: std.mem.Allocator, bytes: []const u8) AcpError!void {
        const owned = allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        self.items.append(allocator, owned) catch return error.OutOfMemory;
    }

    fn pop(self: *Queue, _: std.mem.Allocator) ?[]u8 {
        if (self.items.items.len == 0) return null;
        return self.items.orderedRemove(0);
    }
};

fn writeFrame(ctx: *anyopaque, frame: Frame) AcpError!void {
    const end: *End = @ptrCast(@alignCast(ctx));
    const pair = end.pair;
    const peer_closed = switch (end.side) {
        .a => pair.b_closed,
        .b => pair.a_closed,
    };
    if (peer_closed) return error.TransportClosed;
    const queue = switch (end.side) {
        .a => &pair.a_to_b,
        .b => &pair.b_to_a,
    };
    try queue.push(pair.allocator, frame.bytes);
}

fn readFrame(ctx: *anyopaque, allocator: std.mem.Allocator) AcpError![]u8 {
    const end: *End = @ptrCast(@alignCast(ctx));
    const pair = end.pair;
    const queue = switch (end.side) {
        .a => &pair.b_to_a,
        .b => &pair.a_to_b,
    };
    if (queue.pop(pair.allocator)) |bytes| {
        defer pair.allocator.free(bytes);
        return allocator.dupe(u8, bytes) catch return error.OutOfMemory;
    }
    return error.TransportClosed;
}

fn close(ctx: *anyopaque) void {
    const end: *End = @ptrCast(@alignCast(ctx));
    switch (end.side) {
        .a => end.pair.closeA(),
        .b => end.pair.closeB(),
    }
}

const end_vtable: Transport.VTable = .{
    .write_frame = writeFrame,
    .read_frame = readFrame,
    .close = close,
};

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------

test "PipePair routes bytes A→B and B→A" {
    const pair = try PipePair.init(std.testing.allocator);
    defer pair.deinit();

    const ta = pair.transportA();
    const tb = pair.transportB();

    try ta.writeFrame(.{ .bytes = "hello" });
    try tb.writeFrame(.{ .bytes = "world" });

    const got_b = try tb.readFrame(std.testing.allocator);
    defer std.testing.allocator.free(got_b);
    try std.testing.expectEqualStrings("hello", got_b);

    const got_a = try ta.readFrame(std.testing.allocator);
    defer std.testing.allocator.free(got_a);
    try std.testing.expectEqualStrings("world", got_a);
}

test "PipePair returns TransportClosed on empty drained queue" {
    const pair = try PipePair.init(std.testing.allocator);
    defer pair.deinit();
    const ta = pair.transportA();
    try std.testing.expectError(error.TransportClosed, ta.readFrame(std.testing.allocator));
}
