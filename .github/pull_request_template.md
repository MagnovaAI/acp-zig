## Summary

<!-- One paragraph: what this PR changes and why. -->

## Wire-format impact

<!-- Does this change a JSON shape on the wire? Affect a method name?
     Add a new variant to a public union? If yes, list every change. -->

## Test plan

- [ ] `zig build` clean
- [ ] `zig build test --summary all` green, zero leaks
- [ ] `zig fmt --check src/ tools/` passes
- [ ] Behaviour exercised by a new or existing test:

## Notes for the reviewer

<!-- Anything non-obvious: trade-offs, follow-ups, decisions left open. -->
