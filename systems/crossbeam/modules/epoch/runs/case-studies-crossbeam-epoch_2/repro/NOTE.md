# Reproduction Directory — crossbeam-epoch_2

No reproduction tests are provided in this directory.

**Reason**: The bug-confirmation phase concluded that this case study has **no new confirmed bugs**.

- **Model checking**: All 6 bug-family hunts (F1–F6) ran via exhaustive BFS without invariant violations on the real protocol. The only violations observed were triggered by explicit fault-injection adversary actions (`MCBuggyRetire`, `MCSkipFence`) that model hypothetical buggy implementations, not crossbeam-epoch's actual code.
- **Code audit**: The two historical protocol bugs in scope (Issue #105 nested-pin advance and Issue #238 MS-Queue retire-before-unlink) are confirmed fixed in source:
  - `if guard_count == 0` gate at `crossbeam-epoch/src/internal.rs:560`
  - Tail-advance CAS before `defer_destroy(head)` at `crossbeam-epoch/src/sync/queue.rs:131-136` and `:163-168`
- **Code review residuals**: The five "Code-Review-Only" notes (CR-1 … CR-5 in `modeling-brief.md` §6.3) are defensive-coding / documentation suggestions with no observable system-level harm; they fail Phase 0 of the bug-confirmation guide and are not bugs.

See `../spec/confirmed-bugs.md` for the full classification rationale.
