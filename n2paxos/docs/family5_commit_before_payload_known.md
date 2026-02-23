# Bug: `Succeed/COMMIT` Can Occur Before Local Payload Is Known (Family 5)

## Summary

`n2paxos` can mark a slot `COMMIT` after collecting enough `M2B` votes even when that replica has not yet processed the corresponding `M2A` payload for the slot.

This creates an implementation state where commit is recorded without a known command (`cmdId` remains sentinel `seq=-42`).

## Caveat (Intent Ambiguity)

It is not clear from current code/docs whether `Succeed`/`COMMIT` is intended to mean:

1. quorum reached (payload may still be unknown locally), or
2. locally commit-ready (payload already known).

This report treats the behavior as a bug candidate under interpretation (2), and as a semantics/documentation gap under interpretation (1).

## Impact

- Semantic risk: `COMMIT` does not imply "value known at this replica."
- Can produce surprising states for downstream logic/monitoring that treats commit as payload-resolved.
- In traces, this is not rare; it appears repeatedly across all merged runs.

## Affected Code Paths

- `M2B` handling accepts votes without requiring payload:
  - `artifact/n2paxos/n2paxos/n2paxos.go:258`
  - `artifact/n2paxos/n2paxos/n2paxos.go:266`
- Quorum callback immediately sets `desc.phase = COMMIT`:
  - `artifact/n2paxos/n2paxos/n2paxos.go:271`
- Descriptor sentinel for unknown payload (`cmdId.SeqNum = -42`):
  - `artifact/n2paxos/n2paxos/n2paxos.go:392`

## Reproduction (Model Checking)

### Model setup

Focused checker:

- `spec/MC_Family5.tla`
- `spec/MC_Family5.cfg`

Invariant:

- `CommitRequiresCommandKnown == \A p \in phases : p.phase = COMMIT => HasCmdAt(p.rep, p.slot)`

### Run

```bash
cd spec
java -cp /home/kewbish/Downloads/dev/specula/lib/tla2tools.jar:/home/kewbish/Downloads/dev/specula/lib/CommunityModules-deps.jar tlc2.TLC -workers 4 -depth 20 -config MC_Family5.cfg MC_Family5.tla
```

### Observed result

TLC reports:

- `Invariant CommitRequiresCommandKnown is violated`
- Violation depth: 4 states

Counterexample artifact:

- `spec/MC_Family5_TTrace_1771820524.tla`

## Strict Variant Trace Validation

To separate "spec permissiveness" from implementation behavior, a strict trace-validation variant was added:

- `spec/TraceStrict.tla`
- `spec/TraceStrict.cfg`

`TraceStrict` changes only `Succeed` handling:

- `Succeed` is treated as `COMMIT_READY` and requires `HasCmdAt(rep, slot)` in addition to quorum.

Validation result on 500-line prefixes of all merged traces:

- Input set: `/tmp/n2paxos_trace500/merged1..merged20.ndjson`
- Result: `0 passed / 20 failed`
- All failures occur at the same trace line: `374`
- Debug suggestion from validator: `TLCGet("level") = 410`

Focused debug at the failing state (strict spec):

- `l = 374`
- `ev.name = "Succeed"`
- `ev.nid = "2"`
- `ev.slot = 12`
- `VotesAt(ev.nid, ev.slot) = 2`
- `HasCmdAt(ev.nid, ev.slot) = FALSE`

This pinpoints the mismatch to "commit event without local payload-known."

## Concrete Trace Evidence

Production traces show `Succeed` with sentinel payload id (`seq=-42`), then payload arrival later for same slot/replica:

- `artifact/n2paxos/traces/n2paxos/merged1.ndjson:374`
  - `Succeed`, `nid="2"`, `slot=12`, `cmd.seq=-42`
- `artifact/n2paxos/traces/n2paxos/merged1.ndjson:397`
  - `ReceiveBeginBallot`, `nid="2"`, `slot=12` (arrives after commit)

Across all merged traces (`merged1..merged20`), count of `Succeed` events with `cmd.seq=-42`:

- Total: `4867` occurrences (non-zero in every merged trace).

## Expected vs Actual

- Expected (strict): local `COMMIT` implies local payload is known for that slot.
- Actual: local `COMMIT` can happen before local payload is known.

## Scope / Assumptions

- This is an implementation-faithful behavior observed in both model checking and execution traces.
- Classification depends on intended threshold/meaning of `Succeed`:
  - If `Succeed` means local commit-ready, this is a bug.
  - If `Succeed` means quorum reached only, this is likely intentional but under-documented.

## Suggested Fixes

1. Clarify semantics explicitly in code/docs first (required to avoid false alarms).
2. If strict local-commit semantics are intended: require payload-known before setting `desc.phase = COMMIT`.
3. Otherwise split states explicitly, e.g. `QUORUM_REACHED` then `COMMIT_READY` after payload known.
4. Add regression checks:
   - unit/integration assertions that `Succeed` is not emitted with sentinel `cmdId`
   - or, if relaxed semantics are intended, assert no execution/reply occurs before payload-known.

## Notes

This issue corresponds to `Family 5` adversarial check and is implementation-level (not a protocol-only abstraction artifact).
