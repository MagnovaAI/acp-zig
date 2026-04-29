//! Buffer-backed Transport for testing the framer end-to-end.
//!
//! Two `BufferTransport` instances point at the same byte queue and
//! exercise `Framer` exactly the way a real stdio adapter would, without
//! needing OS handles or an event loop. Useful for golden tests of
//! transport-layer behaviour and for examples that want a deterministic
//! pair of peers.

const std = @import("std");
const acp = @import("acp");
const Framer = @import("frame.zig").Framer;

const Transport = acp.Transport;
const Frame = acp.Frame;
const AcpError = acp.AcpError;

pub const BufferPair = struct {
    allocator: std.mem.Allocator,
    a_to_b: std.ArrayList(u8) = .empty,
    b_to_a: std.ArrayList(u8) = .empty,
    a_closed: bool = false,
    b_closed: bool = false,
    end_a: End,
    end_b: End,

    pub fn init(allocator: std.mem.Allocator) !*BufferPair {
        const self = try allocator.create(BufferPair);
        self.* = .{ .allocator = allocator, .end_a = undefined, .end_b = undefined };
        self.end_a = .{ .pair = self, .side = .a, .framer = Framer.init(allocator) };
        self.end_b = .{ .pair = self, .side = .b, .framer = Framer.init(allocator) };
        return self;
    }

    pub fn deinit(self: *BufferPair) void {
        self.a_to_b.deinit(self.allocator);
        self.b_to_a.deinit(self.allocator);
        self.end_a.framer.deinit();
        self.end_b.framer.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn transportA(self: *BufferPair) Transport {
        return .{ .ptr = &self.end_a, .vtable = &vtable };
    }

    pub fn transportB(self: *BufferPair) Transport {
        return .{ .ptr = &self.end_b, .vtable = &vtable };
    }
};

const Side = enum { a, b };

const End = struct {
    pair: *BufferPair,
    side: Side,
    framer: Framer,
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
    queue.appendSlice(pair.allocator, frame.bytes) catch return error.OutOfMemory;
    queue.append(pair.allocator, '\n') catch return error.OutOfMemory;
}

fn readFrame(ctx: *anyopaque, allocator: std.mem.Allocator) AcpError![]u8 {
    const end: *End = @ptrCast(@alignCast(ctx));
    const pair = end.pair;
    const queue = switch (end.side) {
        .a => &pair.b_to_a,
        .b => &pair.a_to_b,
    };

    if (end.framer.next() catch return error.OutOfMemory) |frame| {
        defer end.framer.allocator.free(frame);
        return allocator.dupe(u8, frame) catch return error.OutOfMemory;
    }
    if (queue.items.len == 0) return error.TransportClosed;

    end.framer.feed(queue.items) catch return error.OutOfMemory;
    queue.clearRetainingCapacity();

    if (end.framer.next() catch return error.OutOfMemory) |frame| {
        defer end.framer.allocator.free(frame);
        return allocator.dupe(u8, frame) catch return error.OutOfMemory;
    }
    return error.TransportClosed;
}

fn close(ctx: *anyopaque) void {
    const end: *End = @ptrCast(@alignCast(ctx));
    switch (end.side) {
        .a => end.pair.a_closed = true,
        .b => end.pair.b_closed = true,
    }
}

const vtable: Transport.VTable = .{
    .write_frame = writeFrame,
    .read_frame = readFrame,
    .close = close,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "BufferPair frames a single message A->B" {
    const pair = try BufferPair.init(std.testing.allocator);
    defer pair.deinit();
    const ta = pair.transportA();
    const tb = pair.transportB();

    try ta.writeFrame(.{ .bytes = "{\"x\":1}" });
    const got = try tb.readFrame(std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("{\"x\":1}", got);
}

test "BufferPair handles back-to-back frames in one write batch" {
    const pair = try BufferPair.init(std.testing.allocator);
    defer pair.deinit();
    const ta = pair.transportA();
    const tb = pair.transportB();

    try ta.writeFrame(.{ .bytes = "{\"a\":1}" });
    try ta.writeFrame(.{ .bytes = "{\"b\":2}" });

    const a = try tb.readFrame(std.testing.allocator);
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("{\"a\":1}", a);

    const b = try tb.readFrame(std.testing.allocator);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("{\"b\":2}", b);
}
