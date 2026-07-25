# Bug Archaeology: etcd-raft

## Bug Pattern Classification

### Category A: Confirmed Bugs (Fixed)

| ID | Source | Summary | Root Cause | Affected Component | Commit/Issue |
|----|--------|---------|------------|-------------------|--------------|
| B1 | commit bd3c759 | Auto-leave joint config buggy: launched multiple attempts when conf change not last in log | Missing check `oldApplied < pendingConfIndex`, pendingConfIndex not bumped | Config change + auto-leave | bd3c759 |
| B2 | commit e515a67 | Restoring joint configurations dropped joint config on floor | restore() had no notion of joint config | Config change + snapshot restore | e515a67 |
| B3 | commit a370b6f | Unbounded log growth: uncommitted size tracker got permanently stuck | Size tracked with proto Size() which included Index/Term mutated after sizing | Log management / proposals | a370b6f |
| B4 | commit 3c7359d | Pre-Vote migration deadlock: cluster could deadlock if MsgPreVote at lower term dropped | Missing response to MsgPreVote when `m.Term < r.Term` and preVote enabled | PreVote + term handling | 3c7359d |
| B5 | issue #48 | Cluster struggles to elect leader when all peers started simultaneously | Election timeout randomization insufficient | Election | issue #48 |
| B6 | commit 76f1249 | Panic on MsgApp after log truncation | Log term lookup on truncated index | Log management | 76f1249 |
| B7 | issue #148 | Probe from index less than match | Progress Next could be set below Match | Progress tracking | issue #148 |

### Category B: Suspected Weak Spots (Not Yet Confirmed)

| ID | Component | Why Suspicious | Evidence |
|----|-----------|----------------|----------|
| W1 | Config change + election interleaving | Issue #372: EnterJoint() allows config changes without quorum overlap. Old quorum {1,2} doesn't overlap with new config {3} when removing 2 nodes at once. Could lead to data loss. | Issue #372, detailed reproduction |
| W2 | Async storage writes + config change | Issue #234: Apply-after-commit style for membership changes + async storage can cause split brain when apply thread stalls | Issue #234, 7 comments |
| W3 | Config change validation false positives | Issue #80: Validation at proposal time has false positives, could refuse valid changes or (hypothetically) accept invalid ones | Issue #80, milestone v4.0.0 |
| W4 | ConfChange silently converted to no-op | Issue #354: No error returned when ConfChange rejected, caller thinks it succeeded | Issue #354 |
| W5 | Stale snapshot commit | Issue #157: unstable invariant violation possible when fromIndex < offset, snapshot could be committed out of order | Issue #157, pav-kv |
| W6 | pendingConfIndex guard | raft.go:1318: `alreadyPending = pendingConfIndex > raftLog.applied` but applied can lag behind commit | Multiple conf change refactors |
| W7 | Leader self-removal timing | raft.go:1989-2001: stepDownOnRemoval is optional, and conf change application may race with new proposals | Issue #83 |

### Category C: Implementation Deviations from Raft Paper

| ID | Deviation | Reason | Risk |
|----|-----------|--------|------|
| D1 | PreVote phase (StatePreCandidate) | Prevent disruption from partitioned nodes (thesis 9.6) | Adds complexity to vote handling; past bugs (B4) |
| D2 | CheckQuorum: leader steps down if quorum inactive | Prevent stale leaders | Interacts with PreVote and config changes |
| D3 | Joint Consensus (Voters[0] incoming, Voters[1] outgoing) | Multi-node config changes via joint config | Past bugs (B1, B2), ongoing issues (W1, W2) |
| D4 | Config applied at commit time, not append time | Different from paper which applies at append time | Requires quorum overlap guarantee (issue #372) |
| D5 | `lead` field tracks current leader | Optimization for forwarding | Used in canVote logic (raft.go:1208) |
| D6 | Two message queues (msgs, msgsAfterAppend) | Durability requirements for vote/append responses | Complexity in message ordering |
| D7 | pendingConfIndex guards concurrent config changes | Only 1 config change in flight | Can have false positives (W3) |
| D8 | Leader sends MsgAppResp to self | Self-ack mechanism for leader's own appends | Non-standard self-message pattern |
| D9 | Progress state machine (Probe/Replicate/Snapshot) | Flow control optimization | Adds complexity beyond paper's nextIndex/matchIndex |
| D10 | campaignTransfer bypasses PreVote | Leadership transfers don't need pre-vote | Could interact with concurrent elections |
