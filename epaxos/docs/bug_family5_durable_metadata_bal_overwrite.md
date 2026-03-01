# Bug Report: Durable Metadata Encoding Overwrites `bal` With `vbal`

## Summary
Durable metadata serialization writes `bal` and then immediately overwrites the same byte range with `vbal`. This can corrupt persisted ballot state and alter post-crash recovery behavior.

## Affected Area
- Durable instance metadata encoding/decoding path
- Crash/restart recovery initialization

## Implementation Evidence
- Overwrite at serialization:
  - `artifact/epaxos/epaxos/epaxos.go:205`
  - `artifact/epaxos/epaxos/epaxos.go:206`
- Recovery path depends on persisted ballot metadata:
  - `artifact/epaxos/epaxos/epaxos.go:1187`
  - `artifact/epaxos/epaxos/epaxos.go:1194`

## Expected Behavior
Durable record should preserve both `bal` and `vbal` in distinct fields. After restart, recovered ballot state should be monotonic with pre-crash state.

## Actual Behavior
Serialized `bal` bytes are overwritten by `vbal`. On restart, effective ballot history may be lowered or otherwise altered from pre-crash values.

## Reproduction (Model Check)
Config:
- `spec/MC_family5_focus.cfg`

Command:
```bash
java -XX:+UseParallelGC -Xmx10G -cp /home/kewbish/Downloads/dev/specula/lib/tla2tools.jar:/home/kewbish/Downloads/dev/specula/lib/CommunityModules-deps.jar tlc2.TLC -cleanup -workers 1 -depth 40 spec/MC.tla -config spec/MC_family5_focus.cfg
```

Observed:
- `Invariant CrashRecoveryBallotMonotonicity is violated`
- Trace artifact: `spec/MC_TTrace_1771797786.tla`

Counterexample highlights:
- State 2: prepare path raises ballot metadata.
- State 3: crash records pre-crash floor:
  - `crashBalFloor` shows `(replica=1,row=1,instance=0) -> 1`
  - `spec/MC_TTrace_1771797786.tla:36`
- State 4: after restart, recovered state violates monotonic floor (invariant failure).

## Safety Impact
This is a crash-recovery ballot-safety bug path. Ballot regression/corruption can re-enable stale decisions and threaten paper-level safety:
- `Stability` (`invariants/invariants.md:3`)
- `Consistency` (`invariants/invariants.md:5`)

`CrashRecoveryBallotMonotonicity` is an implementation-level guard invariant that protects those paper-level properties.

## Suggested Fix
1. Serialize `bal` and `vbal` into distinct non-overlapping byte ranges.
2. Add round-trip encode/decode tests validating both fields.
3. Add crash/restart tests that assert ballot monotonicity across recovery.

