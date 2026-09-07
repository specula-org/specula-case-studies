# CR-4 Investigation

## Step 1: Code Audit

Finding source: code review. There is no model-checking counterexample for this finding.

Relevant code:

- `lib.rs:14-21`: library-level contract says only `view_number()` survives a crash; the owner must persist it after each step, before delivering the step outputs.
- `README.md:50-72`: public API contract says owners call `on_message`, `on_idle`, and `on_reply`, then drain messages/replies and deliver them; transport may lose, duplicate, or reorder messages, and the one durable field is the view number.
- `lib.rs:522-541`: `Replica::recover` creates a memory-empty recovering replica in the persisted view and emits `Recovery` messages.
- `lib.rs:545-552`: a recovering replica ignores all non-`RecoveryResponse` messages.
- `lib.rs:923-959`: `StartViewChange` / `DoViewChange` are handled through normal public `on_message` delivery.
- `lib.rs:1059-1108`: once a new primary records a quorum of `DoViewChange`s, it installs the chosen log, commits the carried commit prefix with client replies enabled, enters normal status, and sends `StartView` messages.
- `lib.rs:1159-1177`: `Recovery(view_number)` from a replica with a higher persisted view moves non-recovering older peers into that view change instead of answering stale state.
- `lib.rs:1180-1242`: recovery completes only with a quorum of responses including primary state for the latest observed view, which prevents a replica that persisted a new view from rejoining an older view.
- `lib.rs:1270-1320`: idle periods resend recovery, view-change, state-transfer, commit, and uncommitted prepare messages.
- `lib.rs:1384-1422`: `commit_up_to(..., reply=true)` can produce more than one reply from a single local step.
- `lib.rs:1513-1520`: `drain_messages` and `drain_replies` drain the in-memory output buffers.
- `examples/kvstore/main.rs:552-567` and `examples/kvstore/main.rs:756-757`: the example persists the view after each event and then flushes messages and replies one by one.

Reachability:

The suspected publication boundary is reachable without private state. A real public sequence can make a new primary produce both `StartView` messages and multiple regenerated commit replies:

1. Two real clients submit `Add(10)` and `Add(20)` to old primary replica 0.
2. The old primary sends `Prepare`s; the schedule delivers only replica 2's `PrepareOk`s back, so replica 0 commits both operations while old replies are lost.
3. Replicas 1 and 2 time out through `on_idle` and enter view 1.
4. Replica 1, the primary of view 1, records its own `DoViewChange`, then receives replica 0's real `DoViewChange` with the committed log.
5. Replica 1 installs the log, commits the prefix, emits two client replies, and emits two `StartView` messages.
6. The owner has persisted view 1, publishes only a strict prefix of these outputs, and replica 1 reboots through `Replica::recover(..., view_number=1, ...)`.

Safeguards encountered:

- Published `StartView` messages either move peers into the new view or are harmless if later replayed.
- Lost `StartView` / reply suffixes are ordinary message/reply loss under the documented transport contract.
- Recovery does not let the rebooted replica act on normal messages until it has primary state for the latest view it sees.
- If the persisted-view primary crashed before it can answer recovery, surviving replicas time out and advance to a later view whose primary can provide state.
- Clients retain pending requests and resend them with `Client::on_idle`; committed client-table entries regenerate replies for duplicate requests.

## Step 2: Developer-Knowledge Search

Issue tracker / PRs:

- `gh issue list --repo penberg/vsr-rs --state all --limit 100` found issues #1, #4, #5, #7, #8, and #9.
- `gh pr list --repo penberg/vsr-rs --state all --limit 100` found PRs #2, #3, #6, and #10.
- Issue #9 reports kvstore connection lifecycle issues: connect backoff after connection reset, missing disconnect cleanup after client errors, and client ID reuse. It does not report durable-view partial output publication.
- PR #10, merged 2026-09-06, fixes #9's connection reset/backoff and disconnect cleanup. It does not touch the core durable-view/output publication boundary.
- Issues #1/#4/#7/#8 and PRs #2/#3/#6 do not describe this exact mechanism.

Commits / blame:

- Local `HEAD` is `3ac0104a567092139534c9022205d02281a2da41`.
- `git log -- lib.rs examples/kvstore/main.rs README.md` shows a short history: initial implementation, kvstore example, simulator coverage, README changes, and the DoViewChange rename. No commit message reports CR-4's exact mechanism.
- `git blame` shows the persisted-view contract and core output/recovery logic originated in the initial commit, with DoViewChange renaming in `3ac0104`.

Comments / docs / tests:

- The README explicitly states the library owner supplies transport and that messages may or may not arrive.
- The code comments describe recovery's persisted-view guard and client resend / protocol retransmission.
- Existing tests cover normal recovery, view change after primary crash, retransmission, duplicate handling, and view-change backoff, but not this exact partial-output crash window.
- Simulator code persists `durable_view[id] = replica.view_number()` before draining messages/replies and models message loss, replay, delay, crashes, restarts, and reboots.

## Step 3: Known Status / Precedent

No existing upstream issue, closed/merged PR, or local commit message found reports the same durable-view / partial-output-publication mechanism at this site. This finding is not an exact duplicate of upstream issue #9 / PR #10 because those concern kvstore connection backoff, disconnect cleanup, and client ID reuse.

Known-status result for Phase 2: `NEW` based on upstream issue/PR search plus local git history search.
