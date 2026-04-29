# Agent Client Protocol — Zig

[![Zig 0.16.0](https://img.shields.io/badge/zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/)
[![Tests](https://img.shields.io/badge/tests-119_pass_%2B_11_gated-success)](#testing)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

The **Agent Client Protocol** (ACP) standardises communication between *code editors* — interactive programs for viewing and editing source code — and *coding agents* — programs that use generative AI to autonomously modify code.

This repository is a native **Zig** implementation. It gives you allocator-aware wire types, a transport-agnostic synchronous SDK, proxy orchestration, an interactive trace viewer, a reference agent binary, and a comptime-reflective schema generator.

> **Status:** working core, public API stabilising toward `v0.1.0`. Wire format matches the canonical protocol; the public surface is unstable until tagged.

---

## Packages

**Core SDK**

- [`acp-schema`](./src/acp-schema/) — Wire-format types: methods, requests, responses, notifications, content variants, tool calls, errors. Forward-compatible `unknown` buckets on every public union so newer peers don't crash older clients.
- [`acp`](./src/acp/) — Synchronous `Connection`, vtable-based `Transport`, comptime-typed `Dispatcher`, `Session` state machine, capability negotiation, fixed-capacity trace ring buffer.
- [`acp-async`](./src/acp-async/) — Newline-delimited framer, `BufferPair` deterministic test transport, `FileTransport` over `std.Io.File`, subprocess `Child` spawn.

**Proxy orchestration**

- [`acp-conductor`](./src/acp-conductor/) — Compose N typed interceptors between client and agent ends with pass / short-circuit / drop semantics.
- [`acp-trace-viewer`](./src/acp-trace-viewer/) — Interactive TUI for replaying captured traces.

**Examples and testing**

- [`acp-cookbook`](./src/acp-cookbook/) — Minimal runnable client and agent.
- [`acp-test`](./src/acp-test/) — In-memory `PipePair` transport and end-to-end contract tests.
- [`yopo`](./src/yopo/) — Reference agent binary that drives the full contract over an in-process pipe.

**Tooling**

- [`tools/gen_schema`](./tools/gen_schema/) — Comptime-reflective generator that emits a canonical JSON catalog of the public schema.

---

## Install

```sh
zig fetch --save git+https://github.com/MagnovaAI/acp-zig
```

In your `build.zig`:

```zig
const acp_dep = b.dependency("acp", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("acp", acp_dep.module("acp"));
exe.root_module.addImport("acp-schema", acp_dep.module("acp-schema"));
```

## Quick start

### Drive a connection

```zig
const std = @import("std");
const acp = @import("acp");
const schema = @import("acp-schema");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const transport: acp.Transport = my_transport;          // FileTransport, BufferPair, etc.
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

### Implement an agent

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

A full client+agent round-trip lives in [`src/acp-test/contract_handshake.zig`](./src/acp-test/contract_handshake.zig). The reference contract is in [`src/yopo/main.zig`](./src/yopo/main.zig).

---

## Build and test

```sh
zig version                                # must report 0.16.0
zig build                                  # build all libraries + binaries
zig build test --summary all               # 119 pass + 11 gated skips, zero leaks
zig fmt --check src/ tools/                # formatting check

zig build yopo                             # run the reference contract suite
zig build gen-schema -- /tmp/schema.json   # emit canonical schema catalog
zig build trace-viewer                     # build the TUI viewer
```

### Unstable feature flags

Each unstable method is gated behind its own build flag, off by default:

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
- **Forward-compatible unions.** Public tagged unions expose an `unknown: std.json.Value` variant so a peer running a newer revision never crashes an older client.
- **Comptime-typed dispatch.** `Dispatcher` registers handlers by method name with concrete `Params` / `Result` types. The thunk parses, invokes, and re-marshals through a per-call arena.
- **Per-frame tracing.** Attach a `TraceBuffer` to a `Connection` and every JSON-RPC frame is recorded with direction and a monotonic sequence number. Diagnostics never block the protocol path.

## Layout

```
src/
├── acp-schema/        # wire types + JSON codec
├── acp/               # core SDK
├── acp-async/         # framing + real-IO transports
├── acp-conductor/     # proxy chain
├── acp-test/          # in-memory transport + contract tests
├── acp-trace-viewer/  # TUI viewer
├── acp-cookbook/      # examples
└── yopo/              # reference agent binary
tools/
└── gen_schema/        # canonical schema catalog generator
```

---

## Contributing

- **Bug reports:** open a [bug report issue](.github/ISSUE_TEMPLATE/bug_report.md). Include `zig version`, OS / arch, and a minimal failing snippet.
- **Pull requests:** the PR template lists the merge checklist. Each PR should keep `zig build test` green with zero leaks and `zig fmt --check src/ tools/` clean. Wire-format changes need an explicit note in the PR body.
- **Larger proposals:** open a discussion first so we can align on the wire-format impact before any code lands.

See [CHANGELOG.md](./CHANGELOG.md) for what's in each release.

## License

[MIT](./LICENSE).
