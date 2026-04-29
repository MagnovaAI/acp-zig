//! Conductor: composes proxies between a client and an agent.
//!
//! Today this package exposes the data structures (chain + interceptor
//! vtables). Wiring a chain to live `acp.Connection` instances at both
//! ends is left to whoever embeds the conductor — they own the
//! transports and the lifecycle.

const std = @import("std");

pub const interceptor = @import("interceptor.zig");
pub const RequestInterceptor = interceptor.RequestInterceptor;
pub const NotificationInterceptor = interceptor.NotificationInterceptor;
pub const RequestContext = interceptor.RequestContext;
pub const NotificationContext = interceptor.NotificationContext;
pub const RequestOutcome = interceptor.RequestOutcome;
pub const NotificationOutcome = interceptor.NotificationOutcome;
pub const Direction = interceptor.Direction;

pub const chain = @import("chain.zig");
pub const Chain = chain.Chain;

test {
    std.testing.refAllDecls(@This());
}
