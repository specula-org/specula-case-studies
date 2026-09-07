# CR-2 Investigation

## Code Audit

Target checkout is `3ac0104a567092139534c9022205d02281a2da41`; the local dirty diff is limited to `specula-trace` observation hooks and kvstore harness probes, not changes to the CR-2 protocol branches.

Relevant entry points are public `Replica::on_message`, `Replica::on_idle`, `Replica::recover`, `Replica::drain_messages`, `Replica::drain_replies`, `Client::on_request`, `Client::on_reply`, and `Client::drain` (`lib.rs:545`, `lib.rs:1270`, `lib.rs:528`, `lib.rs:1513`, `lib.rs:1518`, `lib.rs:317`, `lib.rs:339`, `lib.rs:379`). The README describes the owner contract: call `on_message`/`on_idle`, then drain and deliver messages over a transport that may lose, duplicate, or reorder them, and persist `view_number()` before delivering produced output (`README.md:50-72`).

The cited view-change path is reachable during normal use. A backup times out in `on_idle`, calls `start_view_change`, sends `StartViewChange`, and after seeing `f` other `StartViewChange` messages sends `DoViewChange` (`lib.rs:1270-1321`, `lib.rs:987-1029`, `lib.rs:1032-1057`). The new primary accepts `DoViewChange` for its assigned view and may start that view after a quorum of `DoViewChange` messages (`lib.rs:943-960`, `lib.rs:1059-1108`). Because `on_do_view_change` calls `start_view_change` when the new primary is behind and then immediately records the received state, a quorum can be formed from other replicas without the new primary's own `DoViewChange` (`lib.rs:952-959`, `lib.rs:1072-1075`).

The history-selection code chooses the log with maximum `(last_normal_view, log.len())`, then independently takes the maximum reported `commit_number` and installs/commits that pair (`lib.rs:1076-1099`). `install_log` asserts only that the selected log contains the receiver's already committed prefix, rebuilds the client table, and preserves stored replies only for committed entries still matching the old prefix (`lib.rs:1358-1381`). `commit_up_to` commits sequentially and never decrements `commit_number` (`lib.rs:1384-1392`).

The recovery path is also reachable through the public API. `Replica::recover` starts a replica with empty volatile state, the persisted view number, and an initial `Recovery` broadcast (`lib.rs:523-541`, `lib.rs:1245-1251`). While recovering, the replica ignores all non-`RecoveryResponse` messages (`lib.rs:545-553`). A normal replica answers recovery; only the primary includes log and commit state (`lib.rs:1152-1177`). The recovering replica needs a quorum of responses, the latest view must be at least its persisted view, and the latest view's primary response must include state before it installs and commits that state (`lib.rs:1180-1242`).

Concrete reachable trigger used for Phase 2:

1. Commit client request A on replica 0 and backup 1 only; replica 2 misses the `Prepare`. Client 0 receives the successful reply from primary 0.
2. Reboot replica 1 with no memory through `Replica::recover`; deliver recovery responses from replicas 0 and 2. Replica 1 recovers A from current primary 0.
3. Force a view change to view 1 by timing out replica 2 and delivering only real `StartViewChange`/`DoViewChange` messages from replicas 0 and 2 to new primary 1. Do not deliver any `StartViewChange` to replica 1 before the two `DoViewChange` messages, so the installed quorum excludes primary 1's own state.
4. Deliver the resulting `StartView` to replicas 0 and 2, then reboot replicas 0 and 2 one at a time through normal recovery from primary 1.
5. Submit request B after client 0 learns view 1 from the duplicate reply emitted by the new primary, and verify all replicas commit A then B in order.

Safeguards / consistency arguments recorded for reproduction:

- A committed operation exists in the log of a quorum that acknowledged it; every later `DoViewChange` quorum intersects that quorum while the documented failure budget holds.
- A recovering replica does not participate until it has installed the latest primary's state from a quorum.
- A stale or non-primary recovery response without primary state cannot complete recovery.
- A `StartView` or catch-up `NewState` may replace only uncommitted suffixes; committed prefixes are guarded by `install_log` and by quorum intersection.

## Developer Knowledge Search

Local comments/docs state the intended behavior:

- `lib.rs:39-40`: indexes below `commit_number` are committed and never change.
- `lib.rs:1060-1061`: view-change selection relies on quorum intersection to hold every committed op.
- `lib.rs:1152-1186`: recovery requires current normal replicas and a latest-view primary state response before rejoining.
- `README.md:62-72`: the library calls the state machine in order for every committed operation and relies on persisting only `view_number`.
- `README.md:179-182`: the simulator checks committed prefix agreement, committed-operation survivability, reply/commit agreement, and duplicate execution.
- `simulator/properties.rs:51-105`: `Durability` checks that every committed op is held by enough non-recovering replicas to intersect every quorum.
- `simulator/properties.rs:207-246`: `CommittedPrefixAgreement` checks committed-prefix equality.
- `simulator/properties.rs:291-361`: `RepliesMatchCommits` checks that every reply corresponds to a committed request and expected result.

Local history on the cited paths shows three commits. The initial implementation describes the public state-machine API and view changes/recovery; the simulator commit states it injects loss, replay, reordering, crashes, restarts, and reboots through recovery and checks safety properties; the current target commit only renames view-change vocabulary from votes to `DoViewChange`.

## Known Status / Precedent

Public GitHub issue/PR search was performed against open and closed issues/PRs and recent commits for `penberg/vsr-rs`.

- `https://github.com/penberg/vsr-rs/issues/9` reports kvstore connection backoff, disconnect cleanup, and client ID reuse, explicitly not this core view-change/recovery history-selection mechanism.
- `https://github.com/penberg/vsr-rs/pull/10` was merged on 2026-09-06 and fixes issue #9 connection-lifecycle items, not CR-2.
- `https://github.com/penberg/vsr-rs/issues/4` concerns resending messages after timeout / state transfer retry.
- `https://github.com/penberg/vsr-rs/issues/8` concerns notifying clients of primary changes.
- `https://github.com/penberg/vsr-rs/pull/6` is the old view-change implementation PR, not a bug report for losing committed/client-completed operations across quorum-selected view changes and rolling recovery.
- Exact GitHub searches for `DoViewChange`, `"committed" "recovery"`, `"StartView" "log"`, and `"rolling" "recovery"` found no issue/PR reporting this mechanism at this site.

Known-status result for CR-2: no public issue, closed/merged PR, or local git-history report of this exact defect was found; proceed to Phase 2 as `Novelty: NEW`.
