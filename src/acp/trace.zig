//! Fixed-capacity trace ring buffer.
//!
//! Captures every JSON-RPC frame a transport sees alongside its direction
//! and a wall-clock timestamp. When the ring is full new entries
//! overwrite the oldest — diagnostics never block the hot path or grow
//! memory unboundedly. Consumers (a viewer, a log dump, a contract test)
//! snapshot the ring and walk it in chronological order.

const std = @import("std");

pub const Direction = enum {
    /// Sent to the peer.
    outbound,
    /// Received from the peer.
    inbound,
};

pub const Entry = struct {
    /// Monotonic sequence number. Cheap to capture and ordering-only —
    /// callers who need wall-clock timestamps should attach them at the
    /// point they snapshot the buffer.
    sequence: u64,
    direction: Direction,
    /// Borrowed slice owned by the buffer's allocator until the entry is
    /// evicted. Snapshots dupe the bytes so callers can hold references
    /// past the next push.
    bytes: []const u8,
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    entries: []Slot,
    head: usize = 0,
    len: usize = 0,
    /// Monotonic count of entries ever pushed. `dropped()` derives from
    /// this minus current `len`.
    total: u64 = 0,

    const Slot = struct {
        sequence: u64 = 0,
        direction: Direction = .outbound,
        bytes: []u8 = &.{},
        used: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Buffer {
        std.debug.assert(capacity > 0);
        const slots = try allocator.alloc(Slot, capacity);
        for (slots) |*s| s.* = .{};
        return .{ .allocator = allocator, .entries = slots };
    }

    pub fn deinit(self: *Buffer) void {
        for (self.entries) |*s| if (s.used) self.allocator.free(s.bytes);
        self.allocator.free(self.entries);
    }

    /// Record a frame. The bytes are duped into the buffer's allocator
    /// so callers can free their copy immediately.
    pub fn push(self: *Buffer, direction: Direction, bytes: []const u8) !void {
        const idx = (self.head + self.len) % self.entries.len;
        const slot = &self.entries[idx];

        if (slot.used) {
            self.allocator.free(slot.bytes);
        }

        slot.bytes = try self.allocator.dupe(u8, bytes);
        slot.sequence = self.total;
        slot.direction = direction;
        slot.used = true;

        if (self.len < self.entries.len) {
            self.len += 1;
        } else {
            self.head = (self.head + 1) % self.entries.len;
        }
        self.total += 1;
    }

    /// Number of entries silently dropped because the ring was full.
    pub fn dropped(self: *const Buffer) u64 {
        return self.total - @as(u64, self.len);
    }

    /// Walk entries oldest-to-newest. The borrowed slices are valid until
    /// the next `push` — copy if you need them longer.
    pub fn iterator(self: *const Buffer) Iterator {
        return .{ .buffer = self, .visited = 0 };
    }

    pub const Iterator = struct {
        buffer: *const Buffer,
        visited: usize,

        pub fn next(self: *Iterator) ?Entry {
            if (self.visited >= self.buffer.len) return null;
            const idx = (self.buffer.head + self.visited) % self.buffer.entries.len;
            const slot = self.buffer.entries[idx];
            self.visited += 1;
            return .{
                .sequence = slot.sequence,
                .direction = slot.direction,
                .bytes = slot.bytes,
            };
        }
    };
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Buffer records entries in order" {
    var b = try Buffer.init(std.testing.allocator, 4);
    defer b.deinit();

    try b.push(.outbound, "{\"a\":1}");
    try b.push(.inbound, "{\"b\":2}");

    var it = b.iterator();
    const e1 = it.next().?;
    try std.testing.expectEqual(Direction.outbound, e1.direction);
    try std.testing.expectEqualStrings("{\"a\":1}", e1.bytes);
    const e2 = it.next().?;
    try std.testing.expectEqual(Direction.inbound, e2.direction);
    try std.testing.expectEqualStrings("{\"b\":2}", e2.bytes);
    try std.testing.expect(it.next() == null);

    try std.testing.expectEqual(@as(u64, 0), b.dropped());
}

test "Buffer evicts oldest entries when full" {
    var b = try Buffer.init(std.testing.allocator, 3);
    defer b.deinit();

    try b.push(.outbound, "1");
    try b.push(.outbound, "2");
    try b.push(.outbound, "3");
    try b.push(.outbound, "4"); // evicts "1"
    try b.push(.outbound, "5"); // evicts "2"

    var it = b.iterator();
    try std.testing.expectEqualStrings("3", it.next().?.bytes);
    try std.testing.expectEqualStrings("4", it.next().?.bytes);
    try std.testing.expectEqualStrings("5", it.next().?.bytes);
    try std.testing.expect(it.next() == null);

    try std.testing.expectEqual(@as(u64, 2), b.dropped());
}

test "Buffer iterator yields entries oldest-to-newest after wrap" {
    var b = try Buffer.init(std.testing.allocator, 2);
    defer b.deinit();

    try b.push(.outbound, "a");
    try b.push(.inbound, "b");
    try b.push(.outbound, "c"); // wraps; "a" evicted

    var it = b.iterator();
    const first = it.next().?;
    try std.testing.expectEqualStrings("b", first.bytes);
    try std.testing.expectEqual(Direction.inbound, first.direction);
    const second = it.next().?;
    try std.testing.expectEqualStrings("c", second.bytes);
    try std.testing.expectEqual(Direction.outbound, second.direction);
    try std.testing.expect(it.next() == null);
}

test "Buffer sequence numbers are strictly increasing across wraps" {
    var b = try Buffer.init(std.testing.allocator, 2);
    defer b.deinit();

    try b.push(.outbound, "1");
    try b.push(.outbound, "2");
    try b.push(.outbound, "3"); // wraps; "1" evicted

    var it = b.iterator();
    var prev: u64 = 0;
    var first = true;
    while (it.next()) |e| {
        if (!first) try std.testing.expect(e.sequence > prev);
        prev = e.sequence;
        first = false;
    }
    try std.testing.expectEqual(@as(u64, 2), prev);
}
