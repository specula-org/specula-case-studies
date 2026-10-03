# Model-checking report — etcd-raft V02

## Result

The incremental suite produced one implementation finding, MC-2. A complete
299-event source trace violated `JointSnapshotMemberAcceptance` after exact
post-state matching, and a public RawNode test reproduced the same recovery
failure. The supplied old-source control behaves identically, so the finding is
pre-existing rather than introduced by this update.

Prior MC-1 is fixed by complete ConfState reconstruction. No other unexpected
counterexample was reported by the standard, full-update, focused, or scenario
campaigns.

## Broad checking

| Configuration | Task | Last depth | Last distinct states | Outcome |
|---|---|---:|---:|---|
| `MC.cfg` | `085f5b72dee2438aa2c16eabdfdc815b` | 3 | 64,900,008 | planned 30-minute budget; no violation |
| `Update_full.cfg` | `c5b9d23c65434e049e85934f9d05bed6` | 3 | 50,743,367 | planned 30-minute budget; no violation |
| `Update_focused.cfg` | `3d8784b5b38f48fc96bb95b2643ae4cf` | 4 | 99,849,260 | planned 30-minute budget; no violation |

All queues were nonempty at the final sample. These runs provide bounded
interaction coverage and are not exhaustive proofs.

## Update-scenario checking

The auto-leave BFS reached its planned budget without a violation. The joint,
outgoing-snapshot, learner-vote, recovery, and Ready-output BFS jobs ended on
run-local state-storage exhaustion after reaching depths 4–17 and 13.3–135.3
million distinct states. Their logs report no preceding target-property or
canary violation.

Six depth-100 simulations ran for 30 minutes each and checked 61.9–170.8
million states, without a canary or other reported property violation. Because
random traces did not reliably traverse every deep update sequence, six
source-backed `UpdateWitness` runs independently reached every intended
scenario canary with exact post-state matching and empty queues.

## MC-2

The live snapshot restore check in `raft.go` searches the snapshot's incoming
voters and current learners, but not outgoing voters or staged learners. A node
represented only in `VotersOutgoing` therefore rejects a newer valid joint
snapshot. After log compaction, this can prevent that voter from catching up and
can block progress when the outgoing majority needs it.

- Trace evidence: task `40bef3078c294f93b76020a5b85557c9`
  violates only `JointSnapshotMemberAcceptance`; task
  `c18633d6e80a4d4099f5bd6492d106d8` passes strict correspondence.
- Source evidence: `../repro/MC-2/confirmation.md`.
- Durable finding: `persistent-findings/MC-2.json`.
- Confirmation status: `REPRODUCED`.
- Attribution: pre-existing in the supplied old source.

## Limits

The retained V01 model, property, and harness limitations still apply. This
incremental run does not establish exhaustive safety, general temporal
liveness, physical WAL/OS behavior, lease reads, or behavior in excluded
system layers. Exact current limits are maintained in
`remaining-validation-work.md`.

