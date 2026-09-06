# CR-3 Investigation

## Finding

- Source: Code Review. The supplied finding has no model-checking counterexample or invariant violation.
- Claimed mechanism: service and recovery progress under stable timing, including client retry, view-change retry/backoff, recovery response collection, and simulator liveness convergence.
- Primary location: `lib.rs:1166`, `lib.rs:1203`, `lib.rs:1233`, `lib.rs:1302`, `simulator/lib.rs:786`, `simulator/lib.rs:891`, `simulator/lib.rs:944`.

## Step 1: Code Audit

Relevant code facts:

- Public contract: callers step `Replica` and `Client` with `on_message`, `on_reply`, and `on_idle`, then deliver drained messages/replies. `README.md:52-58` and `lib.rs:6-12` state that the library does no I/O, clocks, or threads.
- Timer/persistence contract: callers must call `on_idle` at a fixed period and persist `view_number()` after each step before delivering produced output, then pass it to `Replica::recover` after reboot. See `README.md:67-72` and `lib.rs:14-20`.
- Client retry: `Client::on_idle` re-sends the pending request to every replica, because the client may not know the current primary (`lib.rs:359-379`).
- Backups ignore client requests unless they are the primary and in normal status. A primary in non-normal status also drops requests; the client retry is the intended recovery path (`lib.rs:666-675`).
- Recovery constructor: `Replica::recover` creates a recovering replica in the caller-persisted view, stores the fresh nonce, and immediately sends `Recovery` (`lib.rs:527-546`).
- Recovering replicas ignore all non-`RecoveryResponse` protocol messages until recovered (`lib.rs:549-558`).
- `on_recovery` responds only from normal replicas. If the recovering replica's persisted view is ahead, the receiver starts that view change and returns instead of letting the recovering replica rejoin an older view (`lib.rs:1146-1172`).
- `on_recovery_response` requires a quorum of responses, rejects a latest response view older than the persisted view, and requires the primary for the latest view to provide state before installing that state and entering normal status (`lib.rs:1174-1228`).
- `Replica::on_idle` has explicit retry/progress arms: primary commits/re-sends uncommitted `Prepare`s, recovering replicas resend `Recovery`, state-transfer replicas retry `GetState`, and view-change replicas retry `StartViewChange`/`DoViewChange`; view-change waits use capped exponential backoff (`lib.rs:1239-1308`, `lib.rs:1320-1328`).
- Simulator liveness mode disables network faults, clears partitions, and chooses a liveness core containing a quorum of non-recovering replicas before filling the remaining core slots (`simulator/lib.rs:723-781`).
- Simulator `pending()` distinguishes unreplied requests, pending network messages, replica convergence, pending commit, and final property failures (`simulator/lib.rs:783-809`).
- Simulator heartbeat ticks all up replicas and all clients with `on_idle`, so client retries continue even after new request generation stops in liveness mode (`simulator/lib.rs:891-900`).
- Simulator `flush()` persists each replica's view before publishing its drained messages and delivers replies into the owning client, incrementing `requests_replied` only for the current inflight request (`simulator/lib.rs:929-963`).

Reachability:

- All cited library paths are reachable through public APIs only: `Client::on_request`, `Client::on_idle`, `Replica::on_message`, `Replica::on_idle`, `Replica::drain_messages`, `Replica::drain_replies`, and `Replica::recover`.
- A natural trigger sequence is: a client request or recovery message is lost during faults; after the network stabilizes, the caller keeps ticking clients and replicas with `on_idle`; retries should move the cluster through view changes, recovery response collection, and final request reply.
- A specific higher-view recovery sequence is also reachable: a backup times out and enters a higher view, the owner persists that view, then the backup crashes before its view-change messages are delivered. On reboot, `Replica::recover` is called with the persisted higher view. Other normal replicas must not answer in an older view; instead they advance through view changes until a non-recovering primary can answer recovery.

Safeguards/progress mechanisms encountered:

- Client resend to all replicas via `Client::on_idle`.
- Recovery resend via `Replica::on_idle` while `Status::Recovering`.
- View-change resend and exponential backoff via `Replica::on_idle`.
- Simulator liveness core selection excludes the case where the core lacks a non-recovering quorum.
- Simulator heartbeat calls client `on_idle`, so pending client requests are not silently abandoned during liveness convergence.

## Step 2: Developer-Knowledge Search

Tracker and PR search covered open and closed issues and PRs in `penberg/vsr-rs` using `gh issue list`, `gh pr list`, and `gh search issues --include-prs` for recovery, liveness, `RecoveryResponse`, `on_idle`, view-change backoff, pending request, and progress terms.

Relevant tracker evidence:

- Issue #4, "Resend messages after timeout", reported an older stall where a lost `GetState` could prevent progress. The maintainer closed it with a comment saying idle periods now resend unanswered protocol messages: `GetState`, uncommitted `Prepare`, client requests, view-change messages, and `Recovery`. URL: https://github.com/penberg/vsr-rs/issues/4#issuecomment-5523020336.
- Issue #7, "Remove `on_idle()` from Replica", records the intended caller-driven clock model. The maintainer comment says `on_idle` is the tick, replicas count idle periods, detect a silent primary after `Config::primary_timeout`, use exponential backoff between incomplete view changes, and there is no other clock. URL: https://github.com/penberg/vsr-rs/issues/7#issuecomment-5523021102.
- PR #6 is the older closed view-change protocol PR. It is not a report of the current CR-3 defect.
- Issue #9 and PR #10 are about kvstore example connection lifecycle, disconnect cleanup, and client identity reuse. They do not report this library-level recovery/view-change/simulator progress mechanism.

Commit/blame evidence:

- `git log -- lib.rs simulator/lib.rs tests/cluster.rs` has three commits at this checkout: initial commit, deterministic simulator, and view-change vocabulary cleanup.
- `git blame` shows the recovery response and `Replica::on_idle` progress arms originate in the initial commit, and simulator liveness/pending/heartbeat/flush originate in the deterministic simulator commit.

Existing tests:

- `tests/cluster.rs` already has focused regression tests for lost `GetState` retry, lost `PrepareOk` retry, lost `Prepare` retry, client request retry, view change after primary crash, recovery after reboot, view-change timeout backoff, and synchronized-delivery view-change convergence.
- `simulator/simulator_tests.rs` checks perfect-network request replies and a fault script with crash, restart, reboot, partition, and heal-all.

## Step 3: Known Status / Precedent

Novelty determination: NEW for the current CR-3 mechanism.

Rationale:

- The prior-report search did find related historical intent and one old missing-retransmission report (#4), but not an already-filed report for a current defect in the combined CR-3 mechanism at `on_recovery`, `on_recovery_response`, `on_idle`, and simulator liveness/flush.
- The old #4 mechanism was reported as fixed by the idle-period retransmission paths that CR-3 now asks to check. It is precedent and developer-intent evidence, not an exact duplicate of a current report.
- The kvstore example reports (#9/#10) concern integration-level connection and client-identity issues, not this fixed-membership library progress path.
