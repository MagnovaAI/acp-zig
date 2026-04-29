# acp-zig

[![Zig 0.16.0](https://img.shields.io/badge/zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![Tests](https://img.shields.io/badge/tests-119%2B11_skip-success)](#testing)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](#license)

A native Zig implementation of the **Agent Client Protocol** — the JSON-RPC surface that lets code editors and coding agents talk over a single wire format. acp-zig ships allocator-aware wire types, a transport-agnostic SDK, conductor proxies, a TUI trace viewer, and a reference agent binary.

> Status: working core, public API stabilising toward `v0.1.0`. Wire format matches the canonical protocol; the surface is unstable until tagged.

---

## Why this exists

Editors and agents are converging on a shared protocol. A first-party Zig implementation gives Zig-based editors and agents a foothold without binding to a runtime from another ecosystem — every type owns an allocator, the dispatch is comptime-typed, and the transport layer is a vtable so you can drop in stdio, libxev, or your own loop.

## What's in the box

| Package | What it gives you |
|---|---|
| `acp-schema` | Every wire type — methods, requests, responses, notifications, content variants, tool calls, errors. Forward-compat `unknown` buckets so newer peers don't crash older clients. |
| `acp` | Synchronous `Connection`, vtable-based `Transport`, typed `Dispatcher`, session state machine, capability negotiation, fixed-capacity trace ring buffer. |
| `acp-async` | Newline-delimited framer, `BufferPair` for tests, `FileTransport` over `std.Io.File`, subprocess `Child` spawn. |
| `acp-conductor` | Proxy-chain orchestration with typed per-method interceptors. |
| `acp-test` | `PipePair` in-memory transport plus end-to-end contract tests. |
| `acp-trace-viewer` | TUI for replaying captured traces (depends on the upstream TUI toolkit). |
| `acp-cookbook` | Minimal runnable client and agent examples. |
| `yopo` | Reference agent binary that drives the full protocol contract over an in-process pipe. |
| `tools/gen_schema` | Comptime-reflective generator that emits a canonical JSON catalog of the public schema. |

## Status

| Area | State |
|---|---|
| Schema parity | Stable surface complete, wire shapes match canonical names. Five unstable methods gated behind build flags. |
| Sync transport | `BufferPair`, `FileTransport`, subprocess `Child` |
| Async transport | Pluggable via `std.Io`; event-loop integration is the next milestone. |
| Tests | 130 total: 119 pass + 11 gated skips (the skips become passes when their unstable flag is set). Zero leaks. |
| Public API freeze | Pending `v0.1.0`. |

---

## Requirements

- **Zig 0.16.0** exactly. Earlier and later versions will not build.

## Quick start

### 1. Add as a dependency

```sh
zig fetch --save git+https://github.com/MagnovaAI/acp-zig
```

Then in your `build.zig`:

```zig
const acp_dep = b.dependency("acp", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("acp", acp_dep.module("acp"));
exe.root_module.addImport("acp-schema", acp_dep.module("acp-schema"));
```

### 2. Drive a connection

```zig
const std = @import("std");
const acp = @import("acp");
const schema = @import("acp-schema");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Replace with a real Transport — FileTransport, BufferPair, etc.
    const transport: acp.Transport = undefined;
    var conn = acp.Connection.init(allocator, transport);

    const resp = try conn.request(
        schema.agent.InitializeResponse,
        schema.agent.method_initialize,
        .{ .protocolVersion = schema.ProtocolVersion.V1 },
    );
    defer resp.deinit();

    std.debug.print("peer speaks protocol v{d}\n", .{resp.value.protocolVersion.value});
}
```

### 3. Implement an agent

```zig
const Agent = struct {
    pub const Params = schema.agent.InitializeRequest;
    pub const Result = schema.agent.InitializeResponse;
    pub fn handle(_: *@This(), _: std.mem.Allocator, params: Params) acp.AcpError!Result {
        return .{ .protocolVersion = params.protocolVersion };
    }
};

var dispatcher = acp.Dispatcher.init(allocator);
defer dispatcher.deinit();
var agent: Agent = .{};
try dispatcher.registerRequest(schema.agent.method_initialize, Agent, &agent);

var conn = acp.Connection.init(allocator, transport);
conn.setRequestHandler(dispatcher.requestHandler());
try conn.serve();
```

For a fully wired example see `src/acp-test/contract_handshake.zig` (client and agent talk over an in-memory pipe through the full handshake → prompt → cancel loop) and `src/yopo/main.zig` (reference agent binary that exercises every method).

---

## Build and test

```sh
zig version                                # must report 0.16.0
zig build                                  # build all libraries + binaries
zig build test --summary all               # 119/130 pass, 11 gated skips
zig fmt --check src/                       # formatting check

# Binaries
zig build yopo                             # run reference contract suite
zig build gen-schema -- /tmp/schema.json   # emit canonical schema catalog
zig build trace-viewer                     # build TUI viewer
```

### Unstable feature flags

Each unstable method is gated behind its own flag, off by default. Enable individually:

```sh
zig build test \
    -Dunstable_logout=true \
    -Dunstable_session_fork=true \
    -Dunstable_session_resume=true \
    -Dunstable_session_close=true \
    -Dunstable_session_model=true
```

Other flags: `unstable_elicitation`, `unstable_nes`, `unstable_cancel_request`, `unstable_session_usage`, `unstable_session_additional_directories`, `unstable_llm_providers`, `unstable_message_id`, `unstable_boolean_config`, `unstable_auth_methods`.

---

## Design notes

- **One error set across boundaries.** `AcpError` is the only error type returned across package boundaries — never `anyerror!T`. Failure modes are explicit.
- **Allocator-aware everywhere.** Every owning type takes an allocator and exposes a matching `deinit`. No global allocator, no hidden heap.
- **Forward-compatible unions.** Every public tagged union exposes an `unknown: std.json.Value` variant so a peer running a newer revision can't crash an older client.
- **Comptime-typed dispatch.** `Dispatcher` registers handlers by method name with concrete `Params`/`Result` types; the thunk parses, invokes, and re-marshals through a per-call arena.
- **Per-frame tracing.** Attach a `TraceBuffer` to a `Connection` and every JSON-RPC frame is recorded with direction and a monotonic sequence number. Used by the trace viewer.
- **No third-party brand bleed.** The codebase, comments, and commit messages stay vendor-neutral.

## Layout

```
src/
├── acp-schema/      # wire types + JSON codec
├── acp/             # core SDK
├── acp-async/       # framing + real-IO transports
├── acp-conductor/   # proxy chain
├── acp-test/        # in-memory transport + contract tests
├── acp-trace-viewer/# TUI viewer
├── acp-cookbook/    # examples
└── yopo/            # reference agent binary
tools/
└── gen_schema/      # canonical schema catalog generator
```

## License

MIT.
