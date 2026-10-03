# MC-2 confirmation

- **Source:** MC (fresh trace-validation counterexample)
- **Novelty:** NEW within the supplied evidence; external trackers were out of
  scope, and no supplied prior finding covers this live-restore check.
- **Status:** REPRODUCED
- **Escalation:** Level 0, public `RawNode` protocol interface; higher levels
  were unnecessary because the observable recovery failure occurred
  deterministically.
- **Location:** `source/raft.go:1414-1435`
- **Command:** `GO111MODULE=on timeout 5m go test -count=1 -run
  '^TestOutgoingOnlyJointVoterSnapshotRecovery$' -v .` from `repro/MC-2`.
- **Observed result:** three valid index-5 joint recovery snapshots were
  rejected, and each public response remained at index 4. See `result.log`.
- **Expected result:** because node 3 is a voter in `VotersOutgoing`, it is a
  full member of the joint configuration and must accept the recovery snapshot.
- **Counterexample match:** the operation order, `MsgSnap` path, violated
  `JointSnapshotMemberAcceptance`, omitted outgoing membership set, and stale
  commit/configuration exactly match TLC task
  `40bef3078c294f93b76020a5b85557c9`.
- **Attribution:** pre-existing; `old-control/result.log` shows the same result
  on the supplied old source.
- **Consequence:** an outgoing-only voter can remain unable to catch up after
  compaction. If that voter is needed for the outgoing majority, the joint
  configuration cannot make further quorum-backed progress.
- **Recommendation:** include `VotersOutgoing` and `LearnersNext` in the live
  snapshot recipient-membership check, using the same complete ConfState
  membership represented by the progress tracker.
