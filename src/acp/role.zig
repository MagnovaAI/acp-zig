//! Role taxonomy.
//!
//! Each peer in an ACP exchange plays exactly one role. Roles determine
//! which method surface a connection exposes (Client speaks the Agent
//! surface to its peer, Agent speaks the Client surface, and so on) and
//! which handlers a built connection requires.

pub const Role = enum {
    /// IDE / editor side — sends prompts, receives streamed updates.
    client,
    /// LLM-backed assistant side — handles prompts, emits tool calls.
    agent,
    /// Sits between a client and an agent, modifying traffic in flight.
    proxy,
    /// Composes multiple proxies and exposes a single agent surface.
    conductor,
};
