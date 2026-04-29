//! File-handle-backed Transport.
//!
//! Wraps a pair of `std.Io.File` handles (typically a process's stdin
//! and stdout, or the two ends of a pipe) and frames JSON-RPC messages
//! over them with `Framer`. Synchronous: reads block until at least one
//! whole frame is available. Suitable for foreground client / agent
//! binaries; subprocess agents use this same transport via `Child`.

const std = @import("std");
const acp = @import("acp");
const Framer = @import("frame.zig").Framer;

const Transport = acp.Transport;
const Frame = acp.Frame;
const AcpError = acp.AcpError;

const log = std.log.scoped(.acp_file_transport);

pub const FileTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: std.Io.File,
    writer: std.Io.File,
    /// When true the transport closes both handles on `close`. Pass
    /// `false` for stdin / stdout the runtime owns.
    own_handles: bool,
    framer: Framer,
    closed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        reader: std.Io.File,
        writer: std.Io.File,
        own_handles: bool,
    ) FileTransport {
        return .{
            .allocator = allocator,
            .io = io,
            .reader = reader,
            .writer = writer,
            .own_handles = own_handles,
            .framer = Framer.init(allocator),
        };
    }

    pub fn deinit(self: *FileTransport) void {
        self.framer.deinit();
        if (self.own_handles) {
            self.reader.close(self.io);
            self.writer.close(self.io);
        }
    }

    pub fn transport(self: *FileTransport) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn writeFrame(ctx: *anyopaque, frame: Frame) AcpError!void {
        const self: *FileTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.TransportClosed;

        self.writer.writeStreamingAll(self.io, frame.bytes) catch |err| {
            log.err("write payload failed: {s}", .{@errorName(err)});
            return error.TransportFailed;
        };
        self.writer.writeStreamingAll(self.io, "\n") catch |err| {
            log.err("write delimiter failed: {s}", .{@errorName(err)});
            return error.TransportFailed;
        };
    }

    fn readFrame(ctx: *anyopaque, allocator: std.mem.Allocator) AcpError![]u8 {
        const self: *FileTransport = @ptrCast(@alignCast(ctx));
        if (self.closed) return error.TransportClosed;

        if (self.framer.next() catch return error.OutOfMemory) |frame| {
            defer self.framer.allocator.free(frame);
            return allocator.dupe(u8, frame) catch return error.OutOfMemory;
        }

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = self.reader.readStreaming(self.io, &.{&chunk}) catch |err| {
                log.err("read failed: {s}", .{@errorName(err)});
                return error.TransportFailed;
            };
            if (n == 0) {
                self.closed = true;
                return error.TransportClosed;
            }
            self.framer.feed(chunk[0..n]) catch return error.OutOfMemory;
            if (self.framer.next() catch return error.OutOfMemory) |frame| {
                defer self.framer.allocator.free(frame);
                return allocator.dupe(u8, frame) catch return error.OutOfMemory;
            }
        }
    }

    fn close(ctx: *anyopaque) void {
        const self: *FileTransport = @ptrCast(@alignCast(ctx));
        self.closed = true;
    }
};

const vtable: Transport.VTable = .{
    .write_frame = FileTransport.writeFrame,
    .read_frame = FileTransport.readFrame,
    .close = FileTransport.close,
};
