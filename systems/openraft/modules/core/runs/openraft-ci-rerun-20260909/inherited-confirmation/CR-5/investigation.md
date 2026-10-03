# CR-5 Phase 1 investigation

## Finding metadata

- Source: Code Review. The finding supplies no TLC counterexample or violation trace.
- Target revision: `d5da3a0f168c532fa348edda44427649b422139e` (`v0.10.0-alpha.11-81-gd5da3a0f`).
- Target checkout note: the checkout already contains Specula instrumentation edits, but none of the cited CR-5 paths is modified in the worktree.

## Step 1: code audit

### Public call chain and reachability

The read path is reachable through the normal public API:

1. `Raft::ensure_linearizable(ReadPolicy::ReadIndex)` promises successful leadership confirmation and calls the app API (`openraft/src/raft/mod.rs:725-769`). `Raft::get_read_linearizer()` exposes the same operation directly (`openraft/src/raft/mod.rs:793-844`).
2. `AppApi::get_read_linearizer()` sends `RaftMsg::EnsureLinearizableRead` and awaits its oneshot response (`openraft/src/raft/api/app.rs:36-44`; message definition at `openraft/src/core/raft_msg/mod.rs:40-41,81-84`).
3. RaftCore dispatches that message to `handle_ensure_linearizable_read()` (`openraft/src/core/raft_core.rs:1325-1327`).
4. The handler captures the current vote and effective membership (`openraft/src/core/raft_core.rs:305-309`), sends one `AppendEntries` probe per voter in independently spawned tasks (`openraft/src/core/raft_core.rs:319-377`), and spawns another detached task to join replies (`openraft/src/core/raft_core.rs:379-444`).

The detached join task only treats `AppendEntriesResponse::HigherVote` returned by one of its own probes as leadership loss (`openraft/src/core/raft_core.rs:394-420`). Every other valid reply adds the target to the captured voter set and can complete the public request successfully (`openraft/src/core/raft_core.rs:422-427`). It does not retain a task handle, send a session identifier back through RaftCore, or re-read RaftCore's current vote/membership before sending `Ok(resp)`.

Independently, a legitimate higher vote received by RaftCore updates the local vote (`openraft/src/core/raft_core.rs:1468-1484`). `VoteHandler::update_vote()` changes the vote and server state (`openraft/src/engine/handler/vote_handler/mod.rs:94-150`), and `become_following()` clears leader state (`openraft/src/engine/handler/vote_handler/mod.rs:221-235`). At the target revision, that transition does not cancel or fail already-spawned read tasks.

### Natural trigger scenario

For a three-voter cluster `{L, A, B}`:

1. `L` is leader and a caller invokes public `get_read_linearizer(ReadIndex)` or `ensure_linearizable(ReadIndex)`.
2. The read path captures `L`'s old vote and membership, counts `L` itself, and sends normal `AppendEntries` probes to `A` and `B`.
3. Delay `A`'s legitimate success reply. In parallel, `L` accepts a legitimate higher vote for `B` and becomes a follower; the new leadership quorum can be `{L, B}`.
4. Deliver `A`'s already-produced success for the old vote. The detached read task still combines captured self-vote `L` with `A`, reaches the old quorum, and sends `Ok(resp)` without consulting current RaftCore state.

This is a real-API/message sequence, not injected state. The public consumer is `Raft::get_read_linearizer()` / `Raft::ensure_linearizable()` (`openraft/src/raft/mod.rs:761-769,839-844`), whose documented contract says success confirms current leadership (`openraft/src/raft/mod.rs:793-807`). The read protocol then authorizes the application state-machine read (`openraft/src/docs/protocol/read.md:30-60`).

### Safeguards and the two other cited paths

- Replication and dedicated-heartbeat notifications carry `ReplicationSessionId`. RaftCore validates both current committed leader vote and current effective membership log id in `does_replication_session_match()` (`openraft/src/core/raft_core.rs:1715-1762`).
- `Notification::ReplicationProgress` and `Notification::HeartbeatProgress` are passed through that check before they update replication progress or the leader clock (`openraft/src/core/raft_core.rs:1561-1588`).
- `Notification::HigherVote` is fenced by the originating leader vote (`openraft/src/core/raft_core.rs:1468-1484`).
- A scheduled heartbeat is also compared with the current leader/membership session before broadcast (`openraft/src/core/raft_core.rs:1765-1803`).
- The heartbeat worker can finish an old RPC and enqueue feedback (`openraft/src/core/heartbeat/worker.rs:94-156`), but the above RaftCore checks discard that feedback after a leadership or membership-session change.

Thus the cited heartbeat and replication feedback paths have explicit consumer-side session fencing. The unfenced path at this revision is the separately spawned ReadIndex join task.

## Step 2: developer-knowledge search

### Comments, documentation, history, and tests

- The target code itself has `TODO: do not spawn, manage read requests with a queue by RaftCore` immediately before spawning the detached join task (`openraft/src/core/raft_core.rs:440-444`). This comment is intent evidence, not by itself a prior bug report.
- The public documentation promises that the read call confirms leadership and that the returned linearizer authorizes a subsequent state-machine read (`openraft/src/raft/mod.rs:793-815`; `openraft/src/docs/protocol/read.md:15-60`).
- Blame attributes the per-read task design to earlier revisions; target history contains no test that re-checks the current vote after the read task has been spawned.
- Repository history after the target revision contains commit `f0d59e0e44c738c3d7088d45e666c1333ec04e1f`, whose message says linearizable reads previously spawned independent per-follower probes and a join task, then introduces a RaftCore-owned queue. It explicitly adds `FailPendingReads`, which drains all queued reads with `ForwardToLeader` when leadership is lost.

### Issue and recently merged/closed PR search

The search covered open and closed issues/PRs using `linearizable`, `ReadIndex`, `pending read`, `per-read probes`, `leadership loss`, `stale read`, and `FailPendingReads`, plus the commit-to-PR association API.

Exact match found: [databendlabs/openraft PR #1993](https://github.com/databendlabs/openraft/pull/1993), **feat: linearizable-read: queue quorum confirmations**, merged 2026-08-18. Its report states that it replaces "independent per-read heartbeat probes" with RaftCore's pending-read queue and that the queue "fails queued reads on leadership loss." The merge contains commit `f0d59e0e44c738c3d7088d45e666c1333ec04e1f`; local history shows that commit on `origin/main` and included in release tags after the target snapshot.

Related but narrower precedent: [issue #1747](https://github.com/databendlabs/openraft/issues/1747) reported that ReadIndex probes continued during leadership transfer, while LeaseRead could return stale data. It was fixed before PR #1993. This is corroborating intent evidence; PR #1993 is the exact same-mechanism/same-site match for CR-5.

## Step 3: known status and pre-filter

- Novelty: `KNOWN (cite: https://github.com/databendlabs/openraft/pull/1993; fix-status: fixed)`.
- Exactness: PR #1993 removes the independently spawned probes/joiner at `handle_ensure_linearizable_read`, moves completion into RaftCore, and fails outstanding reads when the node leaves leadership. Those are the exact mechanism, site, and missing lifecycle fence described by CR-5.
- Status: `DROPPED (code-review × known, cite: https://github.com/databendlabs/openraft/pull/1993)`.
- Per the bug-confirmation skill's sole Phase-1 pre-filter, Phase 2 is not run and no `repro/test_bugCR-5_*` file is written for a code-review finding already reported in an issue/PR, whether the fix is open or merged.
