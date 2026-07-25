# EPaxos Instrumentation Spec

Action-to-code mapping for `spec/base.tla`.

| Spec Action | Code Location | Trigger Point | Event Fields |
|---|---|---|---|
| ClientRequest | `artifact/epaxos/epaxos/epaxos.go:742` | In `handlePropose`, after `crtInstance` increment and before `startPhase1` | `nid`, `iid.replica`, `iid.instance`, `command`, `clientId` |
| PreAccept | `artifact/epaxos/epaxos/epaxos.go:803` | In `handlePreAccept`, after attribute update and before reply | `nid`, `iid`, `state.ballot`, `state.seq`, `state.status`, `state.deps`, `command`, `leader` |
| PreAcceptOK | `artifact/epaxos/epaxos/epaxos.go:900` | In `handlePreAcceptReply`, after `preAcceptOKs++` | `nid`, `iid`, `preAcceptOKs`, `state.seq`, `state.status`, `state.deps` |
| FastPathCommit | `artifact/epaxos/epaxos/epaxos.go:948` | In `handlePreAcceptReply`, inside fast-path branch after local commit state assignment | `nid`, `iid`, `state.ballot`, `state.seq`, `state.status`, `state.deps`, `preAcceptOKs` |
| Accept | `artifact/epaxos/epaxos/epaxos.go:1006` | In `handleAccept`, before `replyAccept` | `nid`, `iid`, `leader`, `state.ballot`, `state.seq`, `state.status`, `state.deps` |
| AcceptOK | `artifact/epaxos/epaxos/epaxos.go:1070` | In `handleAcceptReply`, after `acceptOKs++` | `nid`, `iid`, `acceptOKs`, `state.ballot`, `state.seq`, `state.status`, `state.deps` |
| Commit | `artifact/epaxos/epaxos/epaxos.go:1104` | In `handleCommit`, after local fields/status updated | `nid`, `iid`, `leader`, `command`, `state.ballot`, `state.seq`, `state.status`, `state.deps` |
| Execute | `artifact/epaxos/epaxos/exec.go:143` | In `strongconnect`, right after `w.Status = EXECUTED` | `nid`, `iid`, `command(s)`, `state.ballot`, `state.seq`, `state.status`, `state.deps` |
| Prepare | `artifact/epaxos/epaxos/epaxos.go:1169` | In `startRecoveryForInstance`, after `bcastPrepare` decision | `nid`, `iid`, `recovery`, `state.ballot`, `state.seq`, `state.status`, `state.deps` |
| PrepareOK | `artifact/epaxos/epaxos/epaxos.go:1272` | In `handlePrepareReply`, after append to `prepareReplies` | `nid`, `iid`, `from`, `prepareAcks`, `targetBallot`, `state.seq`, `state.status`, `state.deps` |
| RecoveryAccept | `artifact/epaxos/epaxos/epaxos.go:1357` and `artifact/epaxos/epaxos/epaxos.go:1492` | In recovery accept branches before `bcastAccept` | `nid`, `iid`, `subCase`, `state.ballot`, `state.seq`, `state.status`, `state.deps` |
| Join | `artifact/epaxos/epaxos/epaxos.go:1231` | In `handlePrepare`, when joining higher ballot | `nid`, `iid`, `state.ballot`, `oldBallot` |

## Notes

- Trace event names already emitted in implementation (`trace_helpers.go`) are reused directly by `spec/Trace.tla` wrappers.
- `PrepareReply`, `PreAcceptReply`, and `AcceptReply` are modeled via the `PrepareOK`, `PreAcceptOK`, and `AcceptOK` handling actions.
