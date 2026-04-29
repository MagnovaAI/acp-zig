# acp-zig

A native Zig implementation of the Agent Client Protocol (ACP) — the JSON-RPC protocol that standardizes communication between code editors and coding agents.

> Status: under construction. Public API is unstable until the first tagged release.

## Why

ACP lets any compliant editor talk to any compliant agent. This package is for projects that want to write a client, agent, proxy, or conductor in Zig without depending on a non-Zig runtime.

## Requirements

- Zig `0.16.0` exactly.

## Build and test

```sh
zig build                           # dev build
zig build test --summary all        # full test suite, zero leaks
zig fmt --check src/                # formatting check
```

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

Read [AGENTS.md](./AGENTS.md) before opening a PR. It is the authoritative engineering protocol.

## License

TBD.
