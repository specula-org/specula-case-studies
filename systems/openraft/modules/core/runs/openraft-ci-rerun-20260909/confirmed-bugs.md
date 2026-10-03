# Confirmation Report — openraft

## Final Result

Reproduced bugs: 0 = 0 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 1
Dropped: 4
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 5
Dispositions: 5 total = 0 reproduced + 0 env-limited + 0 masked + 1 false-positive + 0 needs-more-info + 4 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | CR-1 | DROPPED | no |
| 2 | CR-2 | FALSE POSITIVE | no |
| 3 | CR-3 | DROPPED | no |
| 4 | CR-4 | DROPPED | no |
| 5 | CR-5 | DROPPED | no |

## Entry 1: Restored Leadership Before Application Recovery

- **Finding ID**: CR-1
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: [upstream issue #1511](https://github.com/databendlabs/openraft/issues/1511); fix-status: fixed)
- **Location**: openraft/src/engine/engine_impl.rs:145

## Description

Issue #1511 reports the same mechanism at the same site: a persisted self-leader vote restores leadership while an unpersisted committed pointer allows a transient state machine to restart behind, exposing reverted state to external readers.

## Trigger scenario

A leader applies a client write, persists its vote and logs but not `committed`, then restarts with a transient state machine before another leader is elected. It restores Leader state while application state may contain only the last snapshot.

## Developer intent

The supplied revision already warns applications not to serve reads before a new commit when `committed` is not persisted. [PR #1771](https://github.com/databendlabs/openraft/pull/1771) later fixed issue #1511 by adding an option to disable immediate leader restoration; it was merged as `f4b5f61d`.

## Reproduction result

The skill’s code-review × known pre-filter requires dropping before Phase 2, so no reproduction test was written or executed.

```text
issue 1511: state=closed, state_reason=completed, created_at=2025-11-18T06:08:45Z, closed_at=2026-06-12T06:59:55Z
PR 1771: state=closed, merged=true, merged_at=2026-06-12T06:59:54Z, merge_commit_sha=f4b5f61dea3a70c8bb5207e3b56b1013997ebe67
PR 1771 body: Fixes #1511
```

Full evidence is recorded in [investigation.md](/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-1/investigation.md).

## Recommendation

Do not report CR-1 as novel. For the supplied historical revision, persist `committed` or delay reads until recovery; newer upstream versions provide `enable_leader_restore` and `wait_for_recovery()` controls.

---

## Entry 2: Persistence-before-Ack in the Decoupled I/O Pipeline

- **Finding ID**: CR-2
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-2/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: openraft/src/core/raft_core.rs:1818

## Description

CR-2 was not confirmed. The decoupled pipeline permits submitted, flushed, committed, and applied positions to differ, but successful responses remain tied to the appropriate durability boundary:

- AppendEntries and Vote responses wait on `Condition::IOFlushed`.
- A leader’s client response follows quorum commit and state-machine application.
- Local application before local flush is intentionally allowed when the entry is already durable on a quorum.

Therefore, the observed intermediate states are intentional protocol states, not a persistence-before-ack defect.

## Trigger scenario

Using only public APIs and a contract-conforming storage wrapper:

1. Submit a single-node `client_write()` and retain its append callback.
2. Block `save_vote()` while invoking the public Vote RPC.
3. Send a legitimate committed AppendEntries RPC to a follower and retain its append callback.
4. Hold each operation at the submitted-but-not-flushed boundary.
5. Release the callback or shut down the node before releasing it.

The AppendEntries message was valid normal protocol traffic: `leader_commit` referenced the entry included in the request.

## Developer intent

The storage contract requires serialized vote/log writes, durable `save_vote()` before return, and callback delivery only after append persistence. The project documentation explicitly permits committed/applied state to exceed the local flushed position because the durability quorum need not contain the local node.

This intent is also stated in [issue #702](https://github.com/databendlabs/openraft/issues/702#issuecomment-1462053929) and the [transient-commit RFC closure](https://github.com/databendlabs/openraft/issues/284#issuecomment-3690782769). Searches covered open/closed issues and recently merged/closed PRs; no report of this exact core early-response mechanism was found. Related #1252, #1960, and PR #1999 concern different mechanisms or sites.

Full evidence is in [investigation.md](/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-2/investigation.md).

## Reproduction result

Reproduction: [test_bugCR-2_persistence_before_ack.rs](/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/repro/test_bugCR-2_persistence_before_ack.rs)

Command:

```text
timeout 5m cargo test -p tests --test cr2_persistence -- --nocapture
```

Actual output:

```text
running 1 test
LEVEL 0 PASS: public client_write completed normally at T1-N0.2 with stock callback timing
LEVEL 1 CLIENT WINDOW: callback_held=true response_before_flush=false applied_before_flush=false
LEVEL 1 CLIENT RELEASE: callback_released=true response_after_flush=true log_id=T1-N0.3
LEVEL 1 VOTE WINDOW: save_vote_blocked=true response_before_persist=false
LEVEL 1 VOTE RELEASE: save_vote_returned=true persisted_before_response=true vote=<T3-N7:->
LEVEL 1 RPC WINDOW: submitted=true applied=true callback_held=true response_before_flush=false
LEVEL 1 RPC RELEASE: callback_released=true response_after_flush=true success=true
LEVEL 1 SHUTDOWN WINDOW: callback_held=true successful_response_after_shutdown=false
LEVEL 2 NOT USED: no state injection; Level 1 already reached submitted-but-unflushed via real APIs
LEVEL 3 NOT USED: no source patch; the callback gate already held the exact window deterministically
CR-2 RESULT: no client, Vote, or AppendEntries success preceded its promised durability boundary
test repro::cr2_persistence_before_ack_public_api ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

Escalation stopped after Level 1 because it deterministically reached the exact reachable precondition. State injection or a source patch would add no legitimate execution.

Regressions also passed:

- OpenRaft library: 307 tests.
- Higher-term AppendEntries integration: 1 test.
- Client-write integration group: 4 tests.

Mandatory checklist:

1. Did Level 0 or Level 1 alone trigger the alleged defect? **no**.
2. Level 2/3 precondition requirement: **not applicable**; neither was used. The submitted-but-unflushed state was reached through real `client_write()`, `vote()`, and `append_entries()` calls at Level 1.
3. Which real consumer observes a wrong outcome? **None.** `ProtocolApi::append_entries()` (`openraft/src/raft/api/protocol.rs:412`) and `AppApi::client_write()` (`openraft/src/raft/api/app.rs:48`) both observed correct blocking behavior.
4. Permanent or later resolved/masked? **No bad state was established.** The transient local-flush gap is documented behavior. The callback releases the pending response; shutdown instead drops it without returning success.

## Recommendation

No core repair is warranted. Retain a timing regression resembling this reproduction and continue enforcing the documented storage serialization and callback contracts in storage implementations.

---

## Entry 3: Extended Membership Transactions and Session Fencing

- **Finding ID**: CR-3
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: [PR #2008](https://github.com/databendlabs/openraft/pull/2008); fix-status: fixed)
- **Location**: openraft/src/raft/api/management.rs:61
- **Severity**: High

## Description

Concurrent membership requests are not bound to the membership version observed by each caller. An intervening request can therefore replace that basis before the two-phase operation finishes.

This exact mechanism was already reported and fixed upstream by merged PR #2008, which adds `LastMembershipLogId` preconditions and fences the second proposal to the joint entry.

## Trigger scenario

Two callers derive changes from membership `M`. Their joint and flattening proposals interleave, allowing a later committed membership to supersede one caller’s observed basis.

Existing guards preserve quorum coherence: proposals require the prior effective membership to be committed, phase two flattens with an empty change, and replication notifications are fenced by leader vote plus membership log ID.

## Developer intent

The in-tree FAQ documents concurrent interleaving as supported but warns callers to validate the final configuration. PR #1351 previously fixed indefinite joint configurations, while PR #2008 subsequently added explicit compare-and-set semantics for callers requiring intent isolation.

## Reproduction result

No reproduction was created or executed because the required skill’s Phase-1 code-review × known pre-filter applies and explicitly ends processing before Phase 2.

Captured tracker evidence:

```text
2008  closed  merged=true  2026-08-21T07:19:02Z
bd6a9dab0ad1fc4da9db10a8878b48e657518da3
feat: membership: add change_membership_if() guarded by Precondition
```

Investigation record: [investigation.md](/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-3/investigation.md)

## Recommendation

Update to a revision containing PR #2008 and use `change_membership_if()` with `Precondition::LastMembershipLogId` when changes derive from an observed membership. Retain the existing replication-session and committed-membership guards.

---

## Entry 4: Snapshot, Membership, and Purge Lifecycle

- **Finding ID**: CR-4
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/databendlabs/openraft/issues/1808; fix-status: fixed)
- **Location**: openraft/src/raft_state/membership_state/mod.rs:97

## Description

CR-4 duplicates upstream [Issue #1808](https://github.com/databendlabs/openraft/issues/1808): snapshot installation can retain an effective membership whose backing log entry is subsequently purged. The supplied checkout predates the fix and contains the same index-only reconciliation.

## Trigger scenario

A node retains an uncommitted membership at index `i`, then installs a later-term snapshot whose committed membership is at `j < i` but whose `last_log_id >= i`. The cached membership survives while its backing entry is purged, permitting elections using a phantom configuration.

## Developer intent

Local comments require conflicting effective memberships to revert when logs are truncated. Merged [PR #1809](https://github.com/databendlabs/openraft/pull/1809) confirms this also applies when snapshot installation covers and purges the membership entry.

## Reproduction result

The required code-review × known pre-filter applied before Phase 2:

```text
Issue #1808: CLOSED
closed by: PR #1809
PR #1809: MERGED
mergedAt: 2026-06-27T16:41:32Z
mergeCommit: 275cce95b6c9ca87021757b821670b9e598f4d0b
```

Per the skill’s exact pre-filter, no reproduction test was created or executed. Investigation evidence is recorded in [investigation.md](/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-4/investigation.md).

## Recommendation

Upgrade to a release containing PR #1809 or backport its purge-boundary-aware membership reset.

---

## Entry 5: Independent Heartbeat, Replication, and Read Paths

- **Finding ID**: CR-5
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/databendlabs/openraft/pull/1993; fix-status: fixed)
- **Location**: openraft/src/core/raft_core.rs:305-444

## Description

The target revision’s ReadIndex path captures the leader vote and membership, then completes quorum confirmation in detached tasks without rechecking RaftCore’s current leadership. Heartbeat and replication feedback are session-fenced; the independently spawned read task is the unfenced path.

This exact mechanism was subsequently reported and fixed by merged [PR #1993](https://github.com/databendlabs/openraft/pull/1993), which replaces “independent per-read heartbeat probes” with a RaftCore queue and fails queued reads on leadership loss.

## Trigger scenario

In a three-voter cluster, start a ReadIndex request on leader `L`, delay voter `A`’s valid old-term success, let `L` accept a higher vote and become follower, then deliver `A`’s response. The detached task can combine captured self-vote `L` with `A` and return success without checking current leadership.

## Developer intent

The target code already contains a TODO to manage reads through RaftCore rather than spawning tasks. PR #1993 implements that design and explicitly adds leadership-loss failure handling.

## Reproduction result

The skill’s mandatory code-review × known pre-filter fired before Phase 2, so no reproduction file was written or executed.

```text
1993	closed	2026-08-18T11:24:16Z	https://github.com/databendlabs/openraft/pull/1993
  origin/HEAD -> origin/main
  origin/main
  origin/release-0.10
```

Investigation record: [investigation.md](/home/ubuntu/specula-ci-acceptance-20260906-Ccbuxg/ci/runs/20260907-022134-7ad4/openraft/.specula-output/confirmation/CR-5/investigation.md)

## Recommendation

Do not report CR-5 as novel. Upgrade to or cherry-pick the PR #1993 implementation.

---
