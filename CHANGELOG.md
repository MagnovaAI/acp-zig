# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches `1.0.0`. Until then, breaking changes can land in any minor.

## [0.1.0] — Unreleased

First public preview. Public API is still subject to change.

### Added
- `acp-schema`: complete stable wire surface — Initialize, Authenticate,
  session/{new,load,list,prompt,set_mode,set_config_option,update,cancel},
  session/request_permission, fs/{read,write}_text_file, terminal/* —
  with forward-compatible `unknown` buckets on every public union.
- Five gated unstable session methods: `logout`, `session/fork`,
  `session/resume`, `session/close`, `session/set_model`.
- `acp`: synchronous `Connection`, vtable-based `Transport`, typed
  `Dispatcher`, `Session` state machine + `Registry`, capability
  negotiation, fixed-capacity trace ring buffer wired into the
  `Connection` write/read path.
- `acp-async`: newline-delimited `Framer`, `BufferPair` deterministic
  test transport, `FileTransport` over `std.Io.File`, subprocess
  `Child` spawn.
- `acp-conductor`: proxy chain composing N typed interceptors with
  pass / short-circuit / drop semantics.
- `acp-test`: in-memory `PipePair` and end-to-end contract tests.
- `acp-trace-viewer`: TUI for replaying captured traces.
- `acp-cookbook`: minimal client and minimal agent examples.
- `yopo`: reference agent binary that drives the full contract over
  an in-process pipe.
- `tools/gen_schema`: comptime-reflective generator emitting a
  canonical JSON catalog of the public schema.

### Tests

130 total: 119 pass + 11 gated skips (the skips become passes when
their unstable flag is set). Zero leaks.
