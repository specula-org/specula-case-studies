# Bug Report: Recovery TryPreAccept Conflict Status Is Never Propagated

## Summary
The recovery path uses `ConflictStatus` to decide whether to abandon `TryPreAccept`, but `TryPreAcceptReply` is constructed with `confStatus = NONE` even when a conflict is detected. This can force recovery down an incorrect branch.

## Affected Area
- EPaxos recovery logic (`PrepareReply` classification, `TryPreAccept`, `TryPreAcceptReply`)

## Implementation Evidence
- Duplicate subcase predicate (subcase 4 unreachable):
  - `artifact/epaxos/epaxos/epaxos.go:1325`
  - `artifact/epaxos/epaxos/epaxos.go:1327`
- `TryPreAcceptReply` is always populated with `confStatus := NONE`:
  - `artifact/epaxos/epaxos/epaxos.go:1391`
  - `artifact/epaxos/epaxos/epaxos.go:1407`
- Recovery decision consumes `ConflictStatus`:
  - `artifact/epaxos/epaxos/epaxos.go:1511`

## Expected Behavior
When `TryPreAccept` detects a conflicting instance at status `ACCEPTED`/`COMMITTED`/`EXECUTED`, the reply should carry that status so leader recovery can make the intended branch decision.

## Actual Behavior
`TryPreAcceptReply` carries conflict coordinates (`ConflictReplica`, `ConflictInstance`) but leaves `ConflictStatus` as `NONE`, preventing `lb.tpaAccepted` from reflecting accepted/committed conflicts.

## Reproduction (Model Check)
Config:
- `spec/MC_family3_focus.cfg`

Command:
```bash
java -XX:+UseParallelGC -Xmx10G -cp /home/kewbish/Downloads/dev/specula/lib/tla2tools.jar:/home/kewbish/Downloads/dev/specula/lib/CommunityModules-deps.jar tlc2.TLC -cleanup -workers 1 -depth 40 spec/MC.tla -config spec/MC_family3_focus.cfg
```

Observed:
- `Invariant TryPreAcceptConflictStatusPropagated is violated`
- Trace artifact: `spec/MC_TTrace_1771797798.tla`

Counterexample highlights:
- State 5: recovery has `tryingToPreAccept = TRUE`.
- State 6: a `TryPreAcceptReply` exists with `confRep = 1`, `confInst = 0`, but `confStatus = "NONE"`:
  - `spec/MC_TTrace_1771797798.tla:46`

## Safety Impact
This is a recovery-soundness bug path. Incorrect recovery branch selection can eventually violate paper-level safety properties:
- `Consistency` (`invariants/invariants.md:5`)
- `Execution consistency` (`invariants/invariants.md:7`)

The violated checker (`TryPreAcceptConflictStatusPropagated`) is an implementation-level precondition intended to protect those paper invariants.

## Suggested Fix
1. Populate `confStatus` from the conflicting instance in `handleTryPreAccept`.
2. Correct subcase logic so subcase 3/subcase 4 predicates are distinct.
3. Add regression tests for:
   - `TryPreAccept` with conflicting accepted instance,
   - leader-side `tpaAccepted` transitions on conflict status.

