# AGENTS.md

Agent Context Protocopl for contributors and AI coding agents working on this repository.

## What this repository is

A native Zig implementation of the Agent Client Protocol (ACP) — the JSON-RPC protocol that standardizes communication between code editors and coding agents. Wire format and protocol semantics match the published ACP specification exactly. The Zig API is idiomatic Zig: allocator-aware, vtable-driven, no hidden allocation, no global state.

The repository is one Zig build with multiple internal packages:

- `src/acp-schema/` — wire-format types: requests, responses, notifications, JSON-RPC envelope, capabilities. Pure data + JSON codec.
- `src/acp/` — core SDK: roles (Client, Agent, Proxy, Conductor), connection builders, handlers, typed dispatch, session state.
- `src/acp-async/` — non-blocking transport built on libxev. Spawn subprocess agents, wire stdio.
- `src/acp-conductor/` — proxy-chain orchestration so behavior can be composed without modifying the agent.
- `src/acp-test/` — test harness: in-memory transport, fixtures, contract suites.
- `src/acp-trace-viewer/` — TUI for inspecting captured ACP traces.
- `src/acp-cookbook/` — runnable examples.
- `src/yopo/` — reference agent binary.

There is no separate derive-macro package; comptime reflection in `acp-schema` covers that ground. MCP integration is deferred until a Zig-native MCP client is available.



## Hard constraints

- Zig `0.16.0` exactly. Verify with `zig version` before building.
- Every commit compiles: `zig build` passes.
- Every commit ships tests for new testable code: `zig build test --summary all` passes with zero leaks (`std.testing.allocator`).
- Every commit passes fmt: `zig fmt --check src/`.
- No TODO/FIXME without a referenced ADR or issue URL.
- No mention of brand names, vendor names, language names of other ecosystems, or other tool names in source files, comments, commit messages, or any document under this repository. Code stands on its own.
- No `std.debug.print` in committed code. Use `std.log.scoped(.x)`.

## Dependency policy

Zig-first. Where the Zig ecosystem can't cover a need, fall back to a vetted C library linked through `build.zig`.

- **JSON:** `std.json` (stdlib).
- **Async runtime / event loop:** [`libxev`](https://github.com/mitchellh/libxev) — Zig-native, kqueue/epoll/io_uring. Added at the transport phase.
- **Subprocess + stdio:** `std.process.Child` + libxev for non-blocking I/O.
- **TUI (trace viewer):** [`vaxis`](https://github.com/rockorager/libvaxis).
- **MCP integration:** deferred. ADR required before adoption.

Every external dependency is declared in `build.zig.zon` with a fingerprint and listed in this file. Dependencies are introduced one at a time, in a focused commit, with a passing test that exercises them.

## Build commands

```sh
zig version                         # must report 0.16.0
zig build                           # dev build
zig build test --summary all        # full test suite, must pass with 0 leaks
zig fmt src/                        # format
zig fmt --check src/                # verify formatting
```

Single-file dev loop:

```sh
zig test path/to/file.zig
```

## Build options

Unstable protocol surfaces are gated behind `-Dunstable_*` build flags exposed via `@import("build_options")`. Off by default. New unstable surfaces add a flag in `build.zig` and a conditional re-export in the package root.

Current flags: `unstable_protocol_v2`, `unstable_elicitation`, `unstable_nes`, `unstable_cancel_request`, `unstable_auth_methods`, `unstable_logout`, `unstable_session_fork`, `unstable_session_model`, `unstable_session_usage`, `unstable_session_additional_directories`, `unstable_llm_providers`, `unstable_message_id`, `unstable_boolean_config`.

## Testing

- Unit tests live at the bottom of the file under test, inside `test "name" {}` blocks. Do not create a `tests/` directory inside `src/`.
- `tests/` at the repo root holds integration, contract, and end-to-end tests plus fixtures.
- Every JSON-codec type has a round-trip test: `parse(serialize(x))` equals `x`.
- Every public type has at least one golden-fixture test against canonical JSON.
- Every vtable / handler interface has a contract test suite reused across implementations.
- All tests use `std.testing.allocator`. Every allocation has a matching `defer ... free(x)`. Leak detection is mandatory.
- Tests must be deterministic. Inject clocks, fix seeds, isolate filesystem state with `std.testing.tmpDir(.{})`.
- `builtin.is_test` guards skip side effects (network, process spawn, hardware) in unit tests.
- Test naming: `subject: expected behavior`.

## Logging and tracing

- `const log = std.log.scoped(.acp);` (or the relevant package scope).
- Every error path logs at `err`. Every protocol-relevant decision logs at `debug`.
- The transport layer captures every inbound and outbound JSON-RPC frame to a circular trace buffer; the trace viewer reads from it.

## Architecture rules

- Dependency direction flows inward toward primitives. `acp-schema` is the leaf; `acp` depends on it; `acp-async`, `acp-conductor`, `acp-test`, `acp-trace-viewer`, `acp-cookbook`, `yopo` sit on top.
- Modules within a package must not import each other in cycles. Leaf domain types (`content`, `error`, `plan`, `protocol_level`) before composites (`tool_call`, `agent`, `client`).
- Vtables expose a `ptr: *anyopaque` + `vtable: *const VTable` pair. Every vtable method takes a `*const Context` first argument. Methods return `AcpError!T` — never `anyerror!T` across package boundaries.
- **Ownership rule:** callers own the implementing struct (local var or heap allocation). Never return a vtable interface that points to a temporary — the pointer dangles.
- Module initialization order lives in each package's `root.zig`.
- Subsystems must not import across each other except through declared interfaces.
- Public unions get an `unknown: std.json.Value` variant so new upstream variants don't crash older clients.

## Plans and ADRs

Plans and architecture decision records live outside this repository at `/Users/omkarbhad/Workspace/Code/plans/acp-zig/`. They are not committed here. Code comments must not reference plan files by path; quote the relevant rationale in the comment instead if a comment is genuinely needed.

## Conventions

- Conventional commit subjects with scope: `type(scope): Subject in sentence case`.
  - Types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `ci`, `build`.
  - Scopes: `schema`, `rpc`, `version`, `content`, `tool_call`, `plan`, `agent`, `client`, `ext`, `error`, `serde`, `async`, `conductor`, `test-harness`, `trace-viewer`, `cookbook`, `yopo`, `build`, `deps`.
  - Subject is sentence case, no trailing period, ≤ 72 chars.
  - Examples: `feat(schema): Add tool call status enum`, `fix(rpc): Reject duplicate request ids`, `chore(deps): Pin libxev to v0.x.y`.
- Commit messages describe the engineering change. No tracker references, no sequential numbering, no orchestration metadata, no agent attribution footers.
- Branches follow `{type}/{kebab-description}`: `feat/schema-content-blocks`, `fix/rpc-duplicate-ids`, `chore/bootstrap-repo`.
- Small, focused PRs. One reason to review.
- Files end with a trailing newline.
- Code comments describe *why*, not *what*. Comments must not reference other implementations, prior ports, or external repositories.

## GitHub workflow

GitHub issue/PR triage, contribution strategy, and repo health follow the global agent instructions at `~/.claude/agent-instructions/github-manager.md`.
