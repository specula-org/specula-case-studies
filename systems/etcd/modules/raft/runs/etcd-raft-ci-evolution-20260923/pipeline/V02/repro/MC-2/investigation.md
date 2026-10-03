# MC-2 investigation — outgoing-only joint voter snapshot recovery

## Code audit

- Public call chain: `RawNode.Step` (`source/rawnode.go:107-116`) admits a
  non-local `MsgSnap`; follower handling routes it through `stepFollower`
  (`source/raft.go:1300-1326`) to `handleSnapshot` and `restore`
  (`source/raft.go:1381-1397`).
- `restore` requires a fresh snapshot and follower state, then searches only
  `ConfState.Voters` and `ConfState.Learners` (`source/raft.go:1398-1435`). It
  does not search `VotersOutgoing` or `LearnersNext`, even though those are
  members of a valid joint configuration and the new constructor restoration
  path reconstructs both fields (`source/confchange/restore.go:55-95`).
- Trigger: a leader enters joint configuration `{1,2,4} && {1,2,3}`, node 3
  falls behind, the leader snapshots and compacts through the joint entry, and
  sends that snapshot to node 3. Node 3 is an outgoing-only voter and is needed
  for the outgoing majority when node 2 is unavailable. The membership check
  rejects the snapshot and returns a stale `MsgAppResp`; subsequent compacted
  recovery attempts have the same result.
- Safeguards checked: the snapshot is newer, node 3 is a follower, the message
  uses the public protocol step, and the ConfState is a valid joint state. None
  of the earlier freshness/role guards prevents the path. The omitted-set check
  itself is the observed rejection.

## Developer and test evidence

- The nearby source comment calls this check defense-in-depth and says the
  recipient should be in the progress tracker (`source/raft.go:1414-1416`).
- `TestRestoreVoterToLearner` documents the matching recovery contract: a node
  represented by the snapshot configuration must accept it or be "permanently
  cut off from the Raft log" (`source/raft_test.go:2795-2813`).
- Supplied tests cover incoming voters, current learners, and complete
  constructor restoration, but contain no live-restore case where the receiver
  appears only in `VotersOutgoing` or `LearnersNext`.
- External trackers and revisions outside the supplied inputs were not searched,
  as prohibited by this CI run. No supplied prior finding reports this same
  live-restore membership check; prior MC-1 concerns constructor/restart
  projection at different code sites.

## Model/trace correspondence

- Full source trace: `traces/outgoing-snapshot-restore.ndjson`.
- TLC task `40bef3078c294f93b76020a5b85557c9` consumes 299 matching states and
  violates `JointSnapshotMemberAcceptance` on the restore event.
- Terminal observation: `fresh=TRUE`, `follower=TRUE`, `fullMember=TRUE`,
  `sourceMember=FALSE`, snapshot index 5, commit remains 4, and configuration
  remains `{1,2,3}`.
- Correspondence-only task `c18633d6e80a4d4099f5bd6492d106d8` consumes all
  299 events with zero queued states and no other error.

## Old-version control and attribution

- The source-compatible control in `old-control/` uses the supplied old source
  and its `Nodes`/`NodesJoint` field names. It also rejects the fresh index-5
  joint snapshot and returns index 4 (`old-control/result.log`).
- Therefore this finding is pre-existing. The current update repairs complete
  constructor/restart restoration but neither introduces nor removes the
  independent live-restore membership check at `raft.go:1417-1435`.
