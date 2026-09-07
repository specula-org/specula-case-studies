# CR-3 Investigation

## Finding

- ID: CR-3
- Source: Code Review
- Title: Arrival-order recovery responses during changing views
- Source revision: `3ac0104a567092139534c9022205d02281a2da41`
- Primary location: `lib.rs:1204`

## Step 1: Code Audit

### Cited Code

- `lib.rs:528-541`: `Replica::recover` creates a `Status::Recovering` replica, restores only the persisted view number, sets `recovery_nonce`, and sends `Recovery` to the other replicas.
- `lib.rs:545-553`: a recovering replica drops all messages except `RecoveryResponse`.
- `lib.rs:1159-1178`: `on_recovery` answers only while the responder is `Status::Normal`; if the recovering replica reports a future persisted view, the responder starts that view change instead of answering. The primary of the responder's current view includes state, and backups send `state: None`.
- `lib.rs:1187-1205`: `on_recovery_response` accepts responses for the current nonce and stores them in `recovery_responses` keyed only by `replica_id`. A later-delivered response from the same sender and nonce overwrites the previously stored response, regardless of view.
- `lib.rs:1206-1228`: recovery proceeds only after a quorum is present, `latest_view >= self.view_number`, and the primary of `latest_view` has a response with `state: Some(...)` whose response view equals `latest_view`.
- `lib.rs:1236-1242`: successful recovery clears stored responses, installs the selected primary state, commits through the selected commit number, and enters normal status.

### Call Chain and Reachability

The path is reachable through public APIs:

1. The owner restarts a crashed replica with `Replica::recover(...)`.
2. The recovering replica's `drain_messages()` emits `Recovery` messages.
3. Normal peers receive those messages through `Replica::on_message(Message::Recovery { ... })` and generate authentic `RecoveryResponse`s.
4. The owner/network may delay, duplicate, and reorder transport messages; the README explicitly makes transport responsible for whether messages "arrive, are duplicated, or are reordered" (`README.md:64-66`).
5. The recovering replica receives those authentic responses through `Replica::on_message(Message::RecoveryResponse { ... })`, reaching `on_recovery_response`.

A same-sender overwrite is reachable without state injection: a sender can answer an old `Recovery` in view 0, later change to view 1 and answer a retransmitted `Recovery`, while the network delivers the newer response before the old response.

### Trigger Scenario

Concrete three-replica scenario used for reproduction:

1. View 0 commits `Put(A)` on replicas 0, 1, and 2.
2. Replica 2 crashes and recovers from persisted view 0 with nonce 7.
3. Its first `Recovery` reaches replica 0 while replica 0 is the view-0 primary, producing a view-0 response with state commit 1; it also reaches replica 1 while replica 1 is a view-0 backup, producing a view-0 non-state response.
4. Replica 1 times out and, with replica 0, completes view 1 while replica 2 remains recovering.
5. View 1 primary replica 1 commits `Put(B)` with replica 0, and replies to the client.
6. Replica 2 retransmits `Recovery`; replica 1 answers as view-1 primary with state commit 2.
7. The network delivers replica 1's newer view-1 state response to replica 2 first, then delivers replica 1's older view-0 non-state response, overwriting the stored sender-1 response.
8. The old replica-0 view-0 state response then completes the quorum, so replica 2 recovers into stale view 0 with commit 1, despite having already received a newer view-1 primary state with commit 2.

Safeguards observed in code:

- `latest_view < self.view_number` rejects responses below the recovering replica's persisted-view floor (`lib.rs:1215-1216`).
- Recovery requires state from the primary of the stored latest view (`lib.rs:1218-1228`).
- A recovered replica in a lower view that receives a higher-view `Commit` or `Prepare` calls `catch_up_with_view`, enters view-change/catch-up status, and requests suffix state from the higher-view primary (`lib.rs:725-727`, `lib.rs:987-1008`, `lib.rs:1124-1136`).
- `on_new_state` in catch-up mode truncates only after the committed prefix and installs the higher-view suffix before entering normal (`lib.rs:892-906`).

## Step 2: Developer Knowledge Search

- Code comments at `lib.rs:1180-1186` state the intended recovery rule: collect a quorum, include the primary of the latest view among stored responses, and reject recovery below the persisted view.
- README design notes at `README.md:46-72` state the library is a pure state-machine library; callers deliver messages and persist `view_number` after each step before delivering outputs.
- README status table at `README.md:80-87` says recovery is done with a persisted view number.
- Existing upstream test `tests/cluster.rs:575-620` covers ordinary reboot recovery and subsequent participation, but not the same-sender mixed-view overwrite.
- Generated local scenario `examples/kvstore/specula_scenarios.rs:158-214` covers delayed recovery responses during a view change and explicitly notes that a newer response is overwritten by an older authentic response from the same sender; it then checks recovery and later committed state. This is local generated coverage evidence, not an upstream issue report.
- `git blame -L 1124,1205 -- lib.rs` attributes the recovery and response-storage logic to the initial commit `716c5bf`; local uncommitted changes in this range are Specula observation hooks only, not behavior changes.
- `git log --oneline -- lib.rs` on the checked-out head shows `3ac0104 Drop Raft's "vote" vocabulary from the view change` and `716c5bf Initial commit`; no commit message reports this same recovery-response overwrite defect.

## Step 3: Known-Status / Precedent

Upstream tracker and PR search performed on 2026-09-06:

- `gh issue list --repo penberg/vsr-rs --state all --limit 100 --json number,title,state,closedAt,url,body` returned issues #1, #4, #5, #7, #8, and #9. Issue #9 reports kvstore reconnect/disconnect/client-ID issues, not recovery-response overwrite in `lib.rs`.
- `gh pr list --repo penberg/vsr-rs --state all --limit 100 --json number,title,state,mergedAt,closedAt,url,body` returned PRs #2, #3, #6, and #10. PR #10 fixes parts of issue #9; it does not report or fix this recovery path.
- `gh search issues --repo penberg/vsr-rs RecoveryResponse --limit 20 --json number,title,state,url,body,closedAt` returned `[]`.
- `gh search issues --repo penberg/vsr-rs "recovery response" --limit 20 --json number,title,state,url,body,closedAt` returned `[]`.
- `gh search prs --repo penberg/vsr-rs RecoveryResponse --limit 20 --json number,title,state,url,body,closedAt` returned `[]`.

Known-status evidence: no upstream issue or PR found that reports the same mechanism at the same site. Novelty remains `NEW` for the final entry unless reproduction proves no finding.
