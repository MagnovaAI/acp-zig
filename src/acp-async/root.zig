//! Async-ready transport adapters: framing + buffer-backed transport.
//!
//! The framer is the line-oriented framing used by every concrete
//! transport: one JSON-RPC message per `\n`-terminated line.
//!
//! BufferTransport is a deterministic byte-queue pair that exercises the
//! framer end-to-end. Real I/O (file handles, subprocess pipes, sockets)
//! arrives in a follow-up that pulls in an event-loop dependency.

const std = @import("std");

pub const frame = @import("frame.zig");
pub const Framer = frame.Framer;

pub const buffer_transport = @import("buffer_transport.zig");
pub const BufferPair = buffer_transport.BufferPair;

pub const file_transport = @import("file_transport.zig");
pub const FileTransport = file_transport.FileTransport;

pub const child_mod = @import("child.zig");
pub const Child = child_mod.Child;
pub const SpawnOptions = child_mod.SpawnOptions;

test {
    std.testing.refAllDecls(@This());
}
