# CLAUDE.md

This file is for AI coding agents (Claude Code et al.) working in this repository.

## Read first, every session

1. **[AGENTS.md](./AGENTS.md)** — authoritative engineering protocol. Scope, build commands, dependency policy, test discipline, layout, conventions, hard constraints. Read before any code change.
2. The active phase plan at `/Users/omkarbhad/Workspace/Code/plans/acp-zig/PLAN.md`.

Don't ask permission to read those — read them.

## Reference material (read-only, off-tree)

The user maintains reference SDK repositories on the local machine outside this repository for protocol semantics and wire-format truth. The user will point you at specific paths when relevant.

These are reference material only. Do not vendor them. Do not name them, their language, or their owners in source files, comments, commit messages, plans, ADRs, or any other document under this repository.

## Build and test loop

```sh
zig version                         # must be 0.16.0
zig build                           # dev build
zig build test --summary all        # zero leaks required
zig fmt --check src/                # verify formatting
```

Run a single file during dev: `zig test path/to/file.zig`.

## Workflow rules

- One branch per phase. Branch name: `{type}/{kebab-description}` (e.g. `feat/schema-content-blocks`).
- Conventional commits, sentence-case subject, scoped: `feat(schema): Add tool call status enum`.
- Each commit compiles, passes tests with zero leaks, passes fmt.
- No agent attribution footers in commits. No "Co-Authored-By" lines. No tracker IDs. No phase numbering in subjects.
- Write plans at `/Users/omkarbhad/Workspace/Code/plans/acp-zig/`. Do not commit plan files into this repo.
- Code comments explain *why*, not *what*, and never reference other implementations or external repos.
- Use `std.log.scoped(...)` — never `std.debug.print` in committed code.

## When unsure

Ask the user. Do not invent scope. Do not bundle changes. Do not skip tests to "ship faster."

## GitHub work

Follow `~/.claude/agent-instructions/github-manager.md` for issue/PR triage and contribution strategy.
