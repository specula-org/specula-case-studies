# CR-5 Investigation

## Step 1: Code Audit

Finding source is code review: there is no supplied model-checking violation trace, invariant, or config.

Relevant code and behavior:

- `lib.rs:91-98`: `Config::primary_id(view_number)` chooses the primary as `replicas[view_number % replicas.len()]`, and `add_replica` assigns fixed, contiguous replica IDs. A permanently down replica can therefore be primary for some views.
- `lib.rs:317-331`: `Client::on_request` sends a new request only to the client's current-view primary.
- `lib.rs:355-380`: `Client::on_idle` resends a pending request to every configured replica because the primary may have changed; backups ignore requests.
- `lib.rs:663-710`: `Replica::on_request` accepts client requests only at the normal primary. It appends a new request, records the primary's own ack, and sends `Prepare` to backups.
- `lib.rs:725-747`: backups accept in-view `Prepare`s from the primary, fill gaps by state transfer, commit up to the primary's commit number bounded by their own log, and resend `PrepareOk` for duplicate prepares.
- `lib.rs:760-784`: the primary commits once the ack set for an op reaches `Config::quorum()`, counting distinct replicas only. With 3 replicas and 1 down, primary plus one healthy backup is a quorum.
- `lib.rs:987-1008`, `lib.rs:1019-1056`, `lib.rs:1059-1108`: a timed-out backup starts a view change, replicas send `DoViewChange` once enough `StartViewChange` messages are seen, and the new primary starts the view after a quorum of `DoViewChange`s.
- `lib.rs:965-984`: a backup that receives `StartView` installs the view log, enters normal status, clears stale ack state, and sends `PrepareOk`.
- `lib.rs:1254-1323`: `Replica::on_idle` drives primary heartbeats, retransmission of uncommitted prepares, state-transfer/recovery retry, primary-failure timers, and view-change retry. A view change that does not complete eventually starts the next view.
- `lib.rs:1325-1343`: completed stable normal operation resets view-change backoff after `primary_timeout` stable idle periods; otherwise consecutive incomplete view changes use capped exponential backoff.
- `lib.rs:1384-1392`: `commit_up_to` commits every operation in order and emits replies when called on a primary path with `reply = true`.
- `lib.rs:1513-1520`: the public owner-facing drains expose messages and replies for delivery.

Call chain from public APIs:

1. Owner creates `Config`, `Replica::new`, and `Client::new`.
2. Client calls `Client::on_request`; owner delivers `Client::drain()` output as `Message::Request` to the target replica through `Replica::on_message`.
3. Normal primary executes `Replica::on_request`, sends `Prepare`, receives `PrepareOk`, commits with `commit_up_to`, and exposes a `Reply` via `Replica::drain_replies`.
4. If the current primary is unavailable, healthy backups call `Replica::on_idle`; after `primary_timeout`, they enter view change and exchange `StartViewChange`/`DoViewChange` through `Replica::on_message`.
5. If a round-robin view names the unavailable replica as primary, that view does not complete, but healthy replicas remain in `Status::ViewChange`; later `on_idle` calls trigger `start_view_change(view + 1)`.
6. When the next view names a healthy primary, the healthy quorum can complete the view, clients resend pending requests to all replicas through `Client::on_idle`, and the healthy primary can commit with one healthy backup.

Constructed trigger scenario:

- Three replicas, primary timeout 2, replica 1 permanently unavailable.
- A finite fault prefix lets replica 2 miss primary 0's heartbeat and start view 1, whose round-robin primary is the unavailable replica 1.
- Healthy replicas 0 and 2 exchange all subsequent messages and receive periodic `on_idle` calls; messages to replica 1 are discarded.
- A client request issued during the stalled view 1 is initially dropped because the live replicas are not normal primaries. Under later client retry and replica timers, the healthy replicas time out view 1, enter view 2 with healthy primary 2, and complete the pending request.

Safeguards and progress mechanisms recorded for Phase 2:

- Client retry to all replicas (`lib.rs:355-380`) prevents a client from being permanently stuck on an obsolete or unavailable primary.
- View-change retry (`lib.rs:1307-1319`) and timeout advancement (`lib.rs:1335-1343`) allow healthy replicas to skip an unavailable round-robin primary view.
- Distinct quorum acking (`lib.rs:760-784`) permits normal operation with one unavailable member in a 3-replica configuration.
- The library has no shared FIFO sender; the target instructions explicitly exclude the separate shared-sender obstruction.

## Step 2: Developer-Knowledge Search

Issue tracker and PR search performed through the upstream GitHub issue/PR API for:

- `repo:penberg/vsr-rs unavailable minority`
- `repo:penberg/vsr-rs permanent minority`
- `repo:penberg/vsr-rs progress primary down`
- `repo:penberg/vsr-rs round-robin primary`
- `repo:penberg/vsr-rs view change backoff`
- `repo:penberg/vsr-rs stalled peer`
- `repo:penberg/vsr-rs liveness`
- `repo:penberg/vsr-rs Client::on_idle`
- `repo:penberg/vsr-rs Replica::on_idle`
- `repo:penberg/vsr-rs primary_timeout`

Results:

- No issues or PRs were returned for unavailable/permanent minority, round-robin primary, stalled peer, or liveness queries.
- `https://github.com/penberg/vsr-rs/issues/4` ("Resend messages after timeout") is related developer context, but it reports lost `GetState`/message retry progress. A maintainer comment says replicas resend unanswered protocol messages from idle periods, clients resend unanswered requests to every replica, view-change messages are resent, and recovery is resent. This is not the same mechanism as a permanently unavailable minority or skipped primary preventing service.
- `https://github.com/penberg/vsr-rs/issues/7` ("Remove on_idle() from Replica") is related developer context. A maintainer comment says replicas count idle periods and detect a silent primary on their own, then change view with exponential backoff between incomplete view changes. This supports the intended behavior but is not a filed bug for this finding.
- `https://github.com/penberg/vsr-rs/issues/8` ("Notify client if primary changed") is related developer context. A maintainer comment says replies carry the view number and an in-flight request reaches the new primary because clients resend unanswered requests to every replica. This is not a report of permanent-minority non-progress.
- `https://github.com/penberg/vsr-rs/issues/9` and `https://github.com/penberg/vsr-rs/pull/10` concern kvstore example connection lifecycle/backoff and client connection cleanup. The target prompt separately excludes these exact duplicates. Their mechanism is not the core-library permanent-minority progress claim.

Local git history search over `lib.rs`, `README.md`, `tests/cluster.rs`, and `examples/kvstore/main.rs` found only related implementation intent:

- Commit `716c5bf` says the library owner steps `Replica` and `Client` with `on_message`, `on_idle`, and drains; normal operation, state transfer, view changes, and recovery are implemented.
- Commit `3ac0104` only renames view-change vocabulary to `DoViewChange`.
- Branch history contains backoff-related work (`0fe2a47` shown on remote branch history), but no local commit message reporting the exact CR-5 mechanism as a filed bug.

Comments/docs:

- `README.md:33-40` states VSR rotates primaries round-robin with each view.
- `README.md:50-56` states owners call `on_idle` at regular intervals to drive heartbeats, retransmission, and the view-change timer.
- `README.md:159` says stopping node 0 lets the others pick node 1 as the new primary within a second.
- `README.md:181-185` describes simulator checking replies/requests and stopping faults once requests are done, then leaving a random majority alive.
- Code comments at `lib.rs:355-357`, `lib.rs:661-667`, and `lib.rs:1254-1269` explicitly describe request retry, dropped requests on non-normal primaries, and timer/retransmission behavior.

Existing tests:

- `tests/cluster.rs:test_view_change_after_primary_crash` exercises a crashed primary with two healthy replicas, then verifies a later request completes through the new primary.
- `tests/cluster.rs:test_view_change_timeout_backs_off` exercises repeated view changes for an isolated backup and checks timeout backoff.
- `tests/cluster.rs:test_view_change_does_not_start_the_next` exercises delayed one-tick delivery and verifies the cluster eventually settles instead of rotating forever.
- The dirty worktree also contains `examples/kvstore/specula_scenarios.rs:271-326`, a Specula harness test named `specula_stable_minority` for a permanently down round-robin primary. It is treated as local coverage context, not upstream novelty evidence.

## Step 3: Known-Status / Precedent

Known-status search covered open and closed upstream issues/PRs, including recently closed PRs. No issue, PR, CVE, advisory, or local git-history entry found in the allowed sources reports the exact CR-5 mechanism at the same core-library site: continued client requests permanently fail because a minority replica or skipped round-robin primary is unavailable.

Known-status outcome for Phase 2: not already reported in the upstream tracker/PR history checked above; proceed to mandatory reproduction.
