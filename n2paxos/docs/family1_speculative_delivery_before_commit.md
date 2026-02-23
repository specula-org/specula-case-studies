# Bug: Leader Can Execute Slot Before Commit (Family 1)

## Summary

The implementation permits leader-side execution/delivery of a slot even when that slot is not in `COMMIT` phase.

This is due to the delivery guard allowing leader bypass of the commit check, plus chained local delivery to `slot+1`.

## Impact

- Violates strict "execute only after commit" semantics.
- Can expose speculative execution behavior that diverges from classic Paxos safety assumptions if external effects are not rollback-safe.

## Affected Code Paths

- Leader commit callback invokes delivery:
  - `artifact/n2paxos/n2paxos/n2paxos.go:269`
  - `artifact/n2paxos/n2paxos/n2paxos.go:278`
- Delivery guard allows leader pre-commit execution:
  - `artifact/n2paxos/n2paxos/n2paxos.go:289`
- Delivery chain enqueues next slot:
  - `artifact/n2paxos/n2paxos/n2paxos.go:308`
  - `artifact/n2paxos/n2paxos/n2paxos.go:153`
  - `artifact/n2paxos/n2paxos/n2paxos.go:436`

## Reproduction (Model Checking)

### Model setup

Focused adversarial checker:

- `spec/MC_Family1.tla`
- `spec/MC_Family1.cfg`

Checked invariant:

- `StrictExecuteAfterCommit == \A d \in delivered : PhaseAt(d.rep, d.slot) = COMMIT`

### Run

```bash
cd spec
java -cp /home/kewbish/Downloads/dev/specula/lib/tla2tools.jar:/home/kewbish/Downloads/dev/specula/lib/CommunityModules-deps.jar tlc2.TLC -depth 12 -config MC_Family1.cfg MC_Family1.tla
```

### Observed result

- TLC reports `Invariant StrictExecuteAfterCommit is violated`.
- Counterexample artifact:
  - `spec/MC_Family1_TTrace_1771820139.tla`

## Minimal Counterexample Sketch

1. Leader proposes commands for slots 0 and 1.
2. Slot 0 collects enough votes and moves to `COMMIT`.
3. `EmitSuccess` and delivery of slot 0 occur.
4. Delivery chain advances to slot 1 (`deliverQueued` style progression).
5. Slot 1 is delivered while slot 1 phase remains `START`.

## Expected vs Actual

- Expected (strict): a slot is delivered/executed only after `COMMIT`.
- Actual: leader may deliver a slot pre-commit via local delivery chain.

## Scope / Assumptions

- This is a real implementation-level behavior.
- Whether it is treated as a "bug" depends on intended semantics:
  - Strict Paxos-style execution discipline: bug.
  - Intended speculative execution optimization: expected behavior, but requires explicit safety argument.

## Suggested Actions

1. Clarify intended semantics in code/docs (speculative vs strict commit-gated execution).
2. If strict behavior is required, tighten delivery guard (`desc.phase == COMMIT` for leaders too).
3. Add tests/invariants ensuring no externally visible effects from pre-commit slots unless explicitly intended.

## Notes

This issue corresponds to Family 1 in `docs/modelling_brief.md`.
