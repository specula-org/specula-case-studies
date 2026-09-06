# CR-2 Investigation

## Scope

- Finding: CR-2, "Accepted self-quorum never triggers commit".
- Source: Code Review. The finding has no model-checking counterexample.
- Worktree HEAD: `3ac0104a567092139534c9022205d02281a2da41`.
- Pre-existing worktree state before this investigation: `Cargo.toml` and `lib.rs` were modified by trace-harness instrumentation, and `tla_trace/` was untracked. I did not rely on those edits for the singleton behavior.

## Code Audit

Relevant code:

- `lib.rs:94-102`: `Config::add_replica` accepts each pushed replica ID; `Config::quorum` is `replicas.len() / 2 + 1`, so a one-member config has quorum 1.
- `lib.rs:296-333`: `Client::new` accepts the supplied `Config`; `Client::on_request` routes the request to `config.primary_id(view_number)`.
- `lib.rs:660-710`: `Replica::on_request` is reached through public `Replica::on_message(Message::Request { .. })`. A normal primary appends the request, then records its own ack with `self.acks.insert(op_number, BTreeSet::from([self.self_id]))`.
- `lib.rs:749-783`: the only normal-case quorum evaluation for a primary occurs in `on_prepare_ok`; after registering a peer ack, it calls `commit_up_to(op_number, true)` only if the ack set length equals `config.quorum()`.
- `lib.rs:1233-1271`: `Replica::on_idle` for a normal primary sends commit heartbeats and re-sends `Prepare` for uncommitted ops to other replicas.
- `lib.rs:1424-1429`: `send_to_others` skips `self_id`, so a singleton primary emits no self-loop `Prepare` or `PrepareOk`.
- `lib.rs:1365-1372` and `lib.rs:1380-1396`: `commit_up_to` applies the state machine and queues a client reply only when called.
- `simulator/lib.rs:258-260`: simulator options validation accepts `replica_count >= 1`.

Reachability:

1. A real caller can create `Config::new()`, call `add_replica()` once, create `Client::new(0, config.clone())`, and create `Replica::new(0, config, state_machine)`.
2. The public client API `Client::on_request(op)` emits `Message::Request { client_id: 0, request_number: 0, op }` addressed to replica 0.
3. Delivering that public message with `Replica::on_message` reaches `on_request` on the singleton primary in normal status.
4. The primary appends op 1 and records ack set `{0}`. Since quorum is 1, the ack set already satisfies quorum, but no code path checks it at this point.
5. No peer exists to emit `PrepareOk`; `send_to_others` emits no messages in a singleton. Later `Replica::on_idle` re-sends `Commit` and `Prepare` only to other replicas, so it also emits nothing.

Trigger scenario:

- Start a one-replica cluster using only the public library API.
- Client submits one request.
- The owner loop drains the client's request and delivers it to the sole replica.
- Repeated owner-loop idle/drain rounds produce no messages or replies. The replica remains normal primary with `op_number == 1`, `commit_number == 0`, and the state machine output is never produced.

Safeguards encountered:

- No library guard rejects a one-member `Config`.
- No documented owner-side guard in `README.md` says a cluster must have at least three replicas. The README example uses three replicas and describes a majority, but `Config` and simulator validation do not enforce that.
- No loopback path sends a singleton primary a synthetic `PrepareOk`. `accept_from_primary` would reject normal-case primary messages on the primary (`Status::Normal => !self.is_primary()`), and `send_to_others` never targets self.

## Developer Knowledge Search

Local comments/docs:

- `README.md:50-58` documents the public owner loop: feed incoming messages, call `on_idle`, then drain and deliver messages/replies.
- `README.md:62-63` says the library calls the state machine "for every committed operation".
- `README.md:91-134` shows a three-replica example, but does not state that one replica is rejected or unsupported.
- `README.md:176-185` describes simulator safety checks and says the seed determines cluster size and fault rates.
- `lib.rs:171-173` says `PrepareOk` quorum counts the primary itself and each backup once.
- `lib.rs:749-752` says the primary commits once it has received `PrepareOk` messages from a quorum.
- `simulator/lib.rs:226` randomized swarm configs draw `replica_count` from 3 to 7, while `simulator/lib.rs:258-260` still validates manually supplied `replica_count >= 1`.

Tests:

- `tests/cluster.rs` has a generic `Cluster::new(replica_count)`, but existing tests use three or more replicas for normal operation and quorum behavior.
- Existing tests cover duplicate requests, lost request retry, lost `PrepareOk` retry, and duplicate `PrepareOk`, but none covers `replica_count == 1`.

Git history/blame:

- `Config::add_replica`, `Config::quorum`, `Replica::on_request`, and `Replica::on_prepare_ok` are from the initial commit `716c5bf`.
- Simulator validation accepting `replica_count >= 1` is from commit `2686986` ("Deterministic simulator").
- `git log --all -S'pub fn quorum' -- lib.rs simulator/lib.rs tests/cluster.rs` found only the initial quorum introduction.
- `git log --all -S'replica_count >= 1' -- simulator/lib.rs` found the deterministic simulator introduction.
- `git log --all -G'single|singleton|one replica|replica_count|PrepareOk|quorum' -- lib.rs simulator/lib.rs tests/cluster.rs README.md` found only broad simulator/readme/quorum-related commits, not a singleton self-ack fix/report.

Issue/PR tracker:

- `gh issue list -R penberg/vsr-rs --state all --limit 100` showed issues #1, #4, #5, #7, #8, #9.
- `gh pr list -R penberg/vsr-rs --state all --limit 100` showed PRs #2, #3, #6, #10.
- Search queries for `single replica`, `replica_count 1`, and `PrepareOk` across open/closed issues and PRs found no exact singleton self-quorum report.
- Issue #4 ("Resend messages after timeout", https://github.com/penberg/vsr-rs/issues/4) is about resending messages after lost/dead `GetState` paths, not singleton quorum evaluation.
- Issue #9 ("A couple issues in the kvstore example", https://github.com/penberg/vsr-rs/issues/9) reports kvstore connection-reset/view-change, client disconnect cleanup, and client-id reuse. It does not report singleton library progress.
- PR #10 ("Fix connection-lifecycles bugs in kvstore example", https://github.com/penberg/vsr-rs/pull/10) addresses issue #9 items (1) and (2), not singleton library progress.
- PR #2 ("Handle duplicate messages", https://github.com/penberg/vsr-rs/pull/2) handled duplicate-message behavior in older `src/replica.rs`, not a one-member commit path.
- PR #6 ("View change protocol", https://github.com/penberg/vsr-rs/pull/6) is broad view-change work and does not report this mechanism.

Known-status record:

- No public issue, PR, CVE/advisory, or local git-history evidence found reporting this exact defect at this exact site.
- Proceed to Phase 2 with novelty `NEW`.
