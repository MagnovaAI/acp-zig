//! Trace viewer.
//!
//! Reads a captured trace from a file (one frame per line, prefixed with
//! `< ` or `> ` for direction) and renders it interactively. Up/Down
//! navigate, q quits.
//!
//! The trace file format is what `acp.TraceBuffer` produces when you
//! dump it via the helper in this binary's library shim — keeping the
//! viewer dependency-light means it works against any tool that emits
//! the same line shape.

const std = @import("std");
const vaxis = @import("vaxis");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const Direction = enum { outbound, inbound };

const Entry = struct {
    direction: Direction,
    bytes: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args_it.deinit();
    _ = args_it.next();
    const path = args_it.next() orelse std.process.exit(2);

    const entries = try loadTrace(alloc, io, path);
    defer freeTrace(alloc, entries);

    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    var selected: usize = 0;

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or (key.codepoint == 'c' and key.mods.ctrl)) break;
                if (key.matches(vaxis.Key.up, .{}) and selected > 0) selected -= 1;
                if (key.matches(vaxis.Key.down, .{}) and selected + 1 < entries.len) selected += 1;
            },
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }

        const win = vx.window();
        win.clear();
        try render(win, entries, selected);
        try vx.render(tty.writer());
    }
}

fn loadTrace(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]Entry {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    try reader.interface.appendRemainingUnlimited(alloc, &content);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeTrace(alloc, entries.items);

    var it = std.mem.splitScalar(u8, content.items, '\n');
    while (it.next()) |line| {
        if (line.len < 2) continue;
        const dir: Direction = switch (line[0]) {
            '<' => .inbound,
            '>' => .outbound,
            else => continue,
        };
        if (line[1] != ' ') continue;
        const owned = try alloc.dupe(u8, line[2..]);
        try entries.append(alloc, .{ .direction = dir, .bytes = owned });
    }
    return entries.toOwnedSlice(alloc);
}

fn freeTrace(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| alloc.free(e.bytes);
    alloc.free(entries);
}

fn render(win: vaxis.Window, entries: []const Entry, selected: usize) !void {
    if (entries.len == 0) {
        _ = win.printSegment(.{ .text = "(empty trace)" }, .{ .row_offset = 0 });
        return;
    }

    const visible_rows: usize = @intCast(@max(@as(i32, @intCast(win.height)) - 2, 1));
    const start = if (selected >= visible_rows) selected - visible_rows + 1 else 0;
    const end = @min(start + visible_rows, entries.len);

    var row: u16 = 0;
    for (entries[start..end], start..) |entry, idx| {
        const arrow = if (entry.direction == .outbound) "->" else "<-";
        const style: vaxis.Style = if (idx == selected)
            .{ .reverse = true }
        else
            .{};

        var buf: [256]u8 = undefined;
        const summary = entry.bytes[0..@min(entry.bytes.len, 200)];
        const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ arrow, summary }) catch arrow;

        _ = win.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row });
        row += 1;
    }

    var status_buf: [128]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "[{d}/{d}]  ↑/↓ navigate · q quit", .{ selected + 1, entries.len }) catch "";
    _ = win.printSegment(.{ .text = status, .style = .{ .bold = true } }, .{ .row_offset = win.height - 1 });
}
