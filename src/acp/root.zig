//! Core SDK: roles, handler abstractions, and connection plumbing.
//!
//! This package is transport-agnostic and synchronous. The async transport
//! (libxev) and the in-memory pipe used for tests live in sibling packages.

const std = @import("std");

pub const schema = @import("acp-schema");

pub const errors = @import("errors.zig");
pub const AcpError = errors.AcpError;

pub const role = @import("role.zig");
pub const Role = role.Role;

pub const handler = @import("handler.zig");
pub const RequestHandler = handler.RequestHandler;
pub const NotificationHandler = handler.NotificationHandler;

pub const transport = @import("transport.zig");
pub const Transport = transport.Transport;
pub const Frame = transport.Frame;

pub const connection = @import("connection.zig");
pub const Connection = connection.Connection;

pub const capabilities = @import("capabilities.zig");

test {
    std.testing.refAllDecls(@This());
}
