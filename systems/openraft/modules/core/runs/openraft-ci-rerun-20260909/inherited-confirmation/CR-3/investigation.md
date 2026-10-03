# CR-3 Phase 1 Investigation

- Source kind: Code Review. The finding provides no model-checking counterexample or violation trace.
- Audited checkout: `d5da3a0f168c532fa348edda44427649b422139e` (`v0.10.0-alpha.11-81-gd5da3a0f`).
- Scope: CR-3 only. No specification, bug-report, other-finding, or shared repair-request artifact was read.

## Step 1: Code audit

### Relevant code and call chain

1. The public `Raft::change_membership()` API delegates directly to `ManagementApi::change_membership()` (`openraft/src/raft/impl_raft_blocking_write.rs:66-71`).
2. The management API submits the caller's change as a `RaftMsg::ChangeMembership` and awaits completion of the first proposal (`openraft/src/raft/api/management.rs:61-100`). If the resulting membership is joint, it later submits an empty `AddVoterIds({})` operation to flatten whichever effective joint membership is current (`openraft/src/raft/api/management.rs:102-124`). There is no caller-supplied membership-version precondition in this checkout.
3. The core dispatches each message to `RaftCore::change_membership()` (`openraft/src/core/raft_core.rs:1360-1369`). That function builds the next coherent membership from the current effective membership and appends it through the normal replicated-log write path (`openraft/src/core/raft_core.rs:447-482`).
4. `ChangeHandler::apply()` first calls `ensure_committed()`, which rejects a proposal while the effective membership log differs from the committed membership log (`openraft/src/raft_state/membership_state/change_handler.rs:31-58`). Thus the core permits at most one uncommitted membership entry; it does not, however, bind the next proposal to the membership version originally observed by an API caller.
5. Membership construction deliberately applies a requested change to the last constituent of the currently effective config and computes a coherent successor (`openraft/src/membership/membership.rs:271-330`). `MembershipState::append()` advances `committed` to the prior effective membership and installs the new effective membership (`openraft/src/raft_state/membership_state/mod.rs:129-149`).
6. An effective membership change rebuilds quorum progress and replication streams before initiating replication (`openraft/src/engine/handler/replication_handler/mod.rs:56-112`). A replication session ID includes both the committed leader vote and effective membership log ID (`openraft/src/replication/replication_session_id.rs:10-52`); delayed replication progress is accepted only when both still match (`openraft/src/core/raft_core.rs:1561-1569,1742-1763`). Rebuilding streams also closes prior streams and creates streams against the new effective membership (`openraft/src/core/raft_core.rs:1937-1952`). These are concrete safeguards against stale progress crossing a leader or membership boundary.

### Reachable trigger scenario

The public path is reachable in normal use:

1. A client reads effective membership version `M` and derives change A.
2. Another client concurrently derives change B from the same or a later observation.
3. A's joint proposal commits and A's management future resumes; before A's second proposal is processed, B's first proposal may be processed against the now-current effective membership.
4. Each second phase is an empty change that flattens the latest coherent membership, not an operation cryptographically or logically owned by the initiating request.
5. Without a last-membership-log precondition, an intervening committed membership can therefore replace a caller's observed basis; the unguarded API response/final state must be checked by the application.

The current checkout's safeguards preserve protocol coherence during that interleaving: only a committed effective membership can be succeeded, joint quorum progress is rebuilt from the effective membership, the empty second phase forces a uniform successor, and vote-plus-membership session checks discard stale replication progress. Those safeguards do not provide compare-and-set semantics for distinct callers' intent.

## Step 2: Developer-knowledge evidence

- The in-tree FAQ explicitly documents concurrent two-phase interleaving, warns that the final configuration may not reflect either request's full intent, tells callers to validate the final config, and says this is by design (`openraft/src/docs/faq/faq.md:396-438`). That text originated in commit `c09290fab315a619d5443c945b9a203640d63ccb`, whose subject is `docs: Add FAQ explaining the interleaved change-membership in parallel`, and was merged as [PR #1350](https://github.com/databendlabs/openraft/pull/1350).
- [PR #1351](https://github.com/databendlabs/openraft/pull/1351), merged 2025-07-24, reported and fixed an older same-area defect in which replaying the original operation during phase two could leave the cluster joint. The checkout contains that fix: phase two uses empty `AddVoterIds({})` (`openraft/src/raft/api/management.rs:111-113`; commit `37d69439b61cf7f2e2890811869372b97816b029`). The PR states that applications must still verify the result of concurrent requests.
- [PR #1558](https://github.com/databendlabs/openraft/pull/1558), merged 2025-12-16, later replaced membership-wide replication-session invalidation with per-stream IDs because the old fencing discarded still-valid notifications after membership changes. It describes fake message loss/spurious failures, not acceptance of stale progress or a quorum-safety violation.
- [PR #2051](https://github.com/databendlabs/openraft/pull/2051), merged 2026-08-28, added a separate direct-append membership API and a leader-term commit barrier for that API. Its safety analysis expressly says existing `RaftCore::change_membership()` keeps its behavior because its two proposals share an exact constituent voter set.

## Step 3: Known-status / precedent

The tracker search covered open and closed issues and merged/closed PRs for `change_membership`, parallel/concurrent membership changes, interleaving, `membership_log_id`, stale replication, replication sessions, preconditions, and recently merged membership work.

[PR #2008](https://github.com/databendlabs/openraft/pull/2008), merged 2026-08-21 as `bd6a9dab0ad1fc4da9db10a8878b48e657518da3`, reports CR-3's request-intent mechanism at the same management API site and fixes it upstream. Its stated mechanism is exact: `Precondition::LastMembershipLogId` makes concurrent membership changes safe to serialize, so a change committed after a caller's observation is rejected instead of being silently overwritten. It also changes `ManagementApi::change_membership()` to rebuild the precondition set after the joint proposal and bind the flattening proposal to that joint entry's log ID, preventing another membership proposal from taking ownership of phase two. The PR adds public integration coverage in `tests/tests/membership/t22_change_membership_if.rs`.

The target checkout predates that merged fix, but the defect is already reported and fixed upstream. Under the bug-confirmation guide's only Phase-1 pre-filter, a Code Review finding that duplicates an existing issue/PR for the same mechanism and site is not reproduced again.

Status: DROPPED (code-review x known, cite: https://github.com/databendlabs/openraft/pull/2008; fix-status: fixed)
