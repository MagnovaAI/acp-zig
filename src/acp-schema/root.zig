//! Public surface of the wire-format schema package.
//!
//! Phase 1 establishes the foundation: the protocol version newtype, the
//! shared codec helpers, and the JSON-RPC envelope shapes. Domain types
//! land in subsequent phases under `v1/`.

const std = @import("std");

pub const build_options = @import("build_options");

pub const version = @import("version.zig");
pub const ProtocolVersion = version.ProtocolVersion;

pub const serde_util = @import("serde_util.zig");
pub const RawValue = serde_util.RawValue;

pub const rpc = @import("rpc.zig");
pub const RequestId = rpc.RequestId;
pub const Request = rpc.Request;
pub const Response = rpc.Response;
pub const ResponseError = rpc.ResponseError;
pub const Notification = rpc.Notification;
pub const JsonRpcMessage = rpc.JsonRpcMessage;
pub const JSONRPC_VERSION = rpc.JSONRPC_VERSION;

test {
    std.testing.refAllDecls(@This());
}
