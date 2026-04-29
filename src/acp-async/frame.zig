//! Newline-delimited JSON-RPC framing.
//!
//! Each frame is one JSON object terminated by a single `\n`. The framer
//! accumulates incoming bytes in an internal buffer and yields complete
//! frames as they arrive; partial input stays buffered for the next read.
//!
//! Embedded newlines inside JSON strings are illegal at the framing layer
//! (peers must emit each message on one line). We don't try to recover —
//! a stray newline is treated as a frame boundary, and the broken half
//! parses as `error.InvalidMessage` at the next layer.

const std = @import("std");

pub const Framer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Framer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Framer) void {
        self.buffer.deinit(self.allocator);
    }

    /// Feed raw bytes from the transport into the framer.
    pub fn feed(self: *Framer, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    /// Try to extract one complete frame. Returns `null` if the buffer
    /// doesn't yet contain a `\n`. The returned slice is owned by the
    /// caller (allocated via the framer's allocator).
    pub fn next(self: *Framer) !?[]u8 {
        const idx = std.mem.indexOfScalar(u8, self.buffer.items, '\n') orelse return null;
        // Slice off the frame, including any trailing `\r` for tolerance.
        const end = if (idx > 0 and self.buffer.items[idx - 1] == '\r') idx - 1 else idx;
        const owned = try self.allocator.dupe(u8, self.buffer.items[0..end]);
        // Shift remaining bytes left.
        const remaining = self.buffer.items.len - (idx + 1);
        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[idx + 1 ..]);
        self.buffer.shrinkRetainingCapacity(remaining);
        return owned;
    }

    /// Encode a frame: append `\n` and write to `writer`.
    pub fn writeFrame(writer: anytype, bytes: []const u8) !void {
        try writer.writeAll(bytes);
        try writer.writeByte('\n');
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Framer yields nothing on empty buffer" {
    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    try std.testing.expect((try f.next()) == null);
}

test "Framer holds partial frames until newline arrives" {
    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    try f.feed("{\"x\":1");
    try std.testing.expect((try f.next()) == null);
    try f.feed("}\n");
    const got = try f.next();
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualStrings("{\"x\":1}", got.?);
}

test "Framer yields multiple frames in one feed" {
    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    try f.feed("{\"a\":1}\n{\"b\":2}\n");
    const a = try f.next();
    defer std.testing.allocator.free(a.?);
    try std.testing.expectEqualStrings("{\"a\":1}", a.?);
    const b = try f.next();
    defer std.testing.allocator.free(b.?);
    try std.testing.expectEqualStrings("{\"b\":2}", b.?);
    try std.testing.expect((try f.next()) == null);
}

test "Framer tolerates CRLF" {
    var f = Framer.init(std.testing.allocator);
    defer f.deinit();
    try f.feed("{\"x\":1}\r\n");
    const got = try f.next();
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualStrings("{\"x\":1}", got.?);
}

test "Framer.writeFrame appends newline" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try Framer.writeFrame(&aw.writer, "{\"x\":1}");
    try std.testing.expectEqualStrings("{\"x\":1}\n", aw.written());
}
