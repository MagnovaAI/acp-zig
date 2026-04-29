//! Test fixtures: an in-memory transport that lets two Connections speak
//! to each other inside a single test process, and contract-level helpers
//! for asserting wire shapes.

const std = @import("std");

pub const pipe_transport = @import("pipe_transport.zig");
pub const PipePair = pipe_transport.PipePair;

pub const contract_handshake = @import("contract_handshake.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(contract_handshake);
}
