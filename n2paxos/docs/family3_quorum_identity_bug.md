# Bug: Quorum Counting Accepts Non-Member Sender IDs (Family 3)

## Summary

`n2paxos` can transition a slot to `COMMIT` based on vote cardinality that does not enforce replica membership in the default majority quorum path.

If an attacker/environment can inject `M2B` messages with arbitrary `Replica` IDs, those IDs can be counted toward quorum and trigger commit.

## Impact

- Safety/robustness risk: a slot may be committed without receiving votes from a true majority of configured replicas.
- This is especially relevant when transport/auth layers do not strictly bind message identity to cluster membership.

## Affected Code Paths

- `handle2B` adds sender ID directly to vote set:
  - `artifact/n2paxos/n2paxos/n2paxos.go:258`
  - `artifact/n2paxos/n2paxos/n2paxos.go:266`
- `MsgSet.Add` accepts IDs based on quorum `Contains` and commits on `len(msgs)`:
  - `artifact/n2paxos/replica/mset.go:45`
  - `artifact/n2paxos/replica/mset.go:75`
- Default majority quorum membership check is permissive:
  - `artifact/n2paxos/replica/quorum.go:26`

## Reproduction (Model Checking)

### Model setup

A focused checker was added:

- `spec/MC_Family3.tla`
- `spec/MC_Family3.cfg`

It allows `Handle2B` from spoof sender IDs `{"X","Y"}` and checks invariant `CommitUsesMembersOnly`.

### Run

```bash
cd spec
java -cp /home/kewbish/Downloads/dev/specula/lib/tla2tools.jar:/home/kewbish/Downloads/dev/specula/lib/CommunityModules-deps.jar tlc2.TLC -depth 10 -config MC_Family3.cfg MC_Family3.tla
```

### Observed result

TLC reports:

- `Invariant CommitUsesMembersOnly is violated`
- Counterexample reaches violation in 4 states.

Counterexample artifact:

- `spec/MC_Family3_TTrace_1771818983.tla`

## Minimal Counterexample Sketch

1. Initial state.
2. `Handle2B(rep="0", from="X", slot=0)`.
3. `Handle2B(rep="0", from="Y", slot=0)`.
4. `Succeed("0",0)` sets `phase=COMMIT`.

At state 4, commit is reached with only spoof/non-member votes.

## Expected vs Actual

- Expected: commit requires votes from a majority of configured members.
- Actual: commit can be triggered by non-member sender IDs when using default majority `Contains` behavior.

## Scope / Assumptions

- This is a confirmed bug under a threat/environment model where sender IDs can be spoofed or are not strictly authenticated.
- If identity is strongly authenticated and restricted to cluster members by lower layers, this is still a robustness gap (defense-in-depth issue) in protocol logic.

## Suggested Fixes

1. Enforce membership in quorum `Contains` for `Majority`/`ThreeQuarters`, or use explicit `Quorum` sets for voting paths.
2. Validate `msg.Replica` against configured membership before `desc.twoBs.Add(...)`.
3. Add regression tests:
   - unit test for `MsgSet.Add` rejecting out-of-membership IDs in N2Paxos voting path
   - integration test injecting out-of-range vote senders to verify no commit.

## Notes

This issue corresponds to `Family 3` in `docs/modelling_brief.md`.
