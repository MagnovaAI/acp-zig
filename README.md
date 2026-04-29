# acp-zig

A native Zig implementation of the Agent Client Protocol (ACP) — the JSON-RPC protocol that standardizes communication between code editors and coding agents. The package gives you allocator-aware wire-format types, a transport-agnostic synchronous SDK, and an in-memory pipe for tests.

> Status: under construction. Public API is unstable until the first tagged release.

## Requirements

- Zig `0.16.0` exactly.

## Build and test

```sh
zig version                         # must report 0.16.0
zig build                           # dev build
zig build test --summary all        # full test suite, zero leaks
zig fmt --check src/                # formatting check
```

## Quick start

A minimal client that hands a transport to a `Connection`, sends `initialize`, and prints the negotiated protocol version:

```zig
const std = @import("std");
const acp = @import("acp");
const schema = @import("acp-schema");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Replace `my_transport` with a real Transport (stdio adapter, pipe, etc.).
    const transport: acp.Transport = my_transport;
    var conn = acp.Connection.init(allocator, transport);

    const params = .{ .protocolVersion = schema.ProtocolVersion.V1 };
    const resp = try conn.request(
        schema.agent.InitializeResponse,
        schema.agent.method_initialize,
        params,
    );
    defer resp.deinit();

    std.debug.print("agent speaks v{d}\n", .{resp.value.protocolVersion.value});
}
```

For a runnable end-to-end example see `src/acp-test/contract_handshake.zig`, which drives a client and an agent over an in-memory pipe.

## Layout

The repo is one Zig build with multiple internal packages:

| Package | Role |
|---|---|
| `src/acp-schema/` | Wire-format types + JSON codec |
| `src/acp/` | Core SDK: roles, handlers, dispatch, session state |
| `src/acp-async/` | Non-blocking transport on libxev |
| `src/acp-conductor/` | Proxy-chain orchestration |
| `src/acp-test/` | In-memory transport + contract suites |
| `src/acp-trace-viewer/` | TUI for captured traces |
| `src/acp-cookbook/` | Runnable examples |
| `src/yopo/` | Reference agent binary |

## Contributing

Read [AGENTS.md](./AGENTS.md) before opening a PR. It is the authoritative engineering protocol — scope, build commands, dependency policy, test discipline, layout conventions, and hard constraints.

## License

TBD.
