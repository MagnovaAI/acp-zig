//! Transport vtable.
//!
//! Synchronous, line-oriented. Every JSON-RPC message occupies exactly one
//! frame; the transport buffers bytes until a whole frame is available.
//! Implementations: an in-memory pipe in `acp-test/`, and stdio /
//! subprocess adapters in `acp-async/` (libxev-backed).

const std = @import("std");
const AcpError = @import("errors.zig").AcpError;

pub const Frame = struct {
    bytes: []const u8,
};

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Write a frame containing exactly one JSON-RPC message. The
        /// transport owns the framing (newline / length prefix / etc).
        write_frame: *const fn (ctx: *anyopaque, frame: Frame) AcpError!void,

        /// Read the next frame. Allocator is used for the returned slice.
        /// Returns `error.TransportClosed` on clean EOF.
        read_frame: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) AcpError![]u8,

        /// Release any internal resources.
        close: *const fn (ctx: *anyopaque) void,
    };

    pub fn writeFrame(self: Transport, frame: Frame) AcpError!void {
        return self.vtable.write_frame(self.ptr, frame);
    }

    pub fn readFrame(self: Transport, allocator: std.mem.Allocator) AcpError![]u8 {
        return self.vtable.read_frame(self.ptr, allocator);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};
