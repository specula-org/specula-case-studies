# Confirmed Bug Report — rabbitmq/ra

## Summary

- Total findings reviewed: 16
- Confirmed: 8 (7 reproduced, 1 code-audit only)
- False positives: 6
- Not applicable (defensive/style): 2

### Reproduction Environment

- Test file: `test/ra_bug_confirmation_SUITE.erl` (new bugs), `test/ra_bug_repro_SUITE.erl` (prior bugs)
- All reproduced bugs pass deterministically (5/5 runs)

---

## Bug 1: Follower Crash on Cluster Change Overwrite (badkey:previous_cluster)

- **Source**: Code Review (TV-1)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `ra_server.erl:3577-3579` (`pre_append_log_follower/2`, first clause, non-cluster-change branch)
- **Description**: When a follower has processed an uncommitted cluster change entry at index I from leader L1 (term T1), and a new leader L2 (term T2) overwrites index I with a regular (non-cluster-change) entry, the follower's `pre_append_log_follower` function crashes with `{badkey, previous_cluster}`. The crash occurs because the follower path (`handle_follower -> pre_append_log_follower`) never sets `previous_cluster` in the state map — only the leader path (`append_cluster_change`, line 3615) does.
- **Trigger scenario**:
  1. 3-node cluster {N1, N2, N3}. N1 is leader at term 5.
  2. N1 proposes adding N4 via `$ra_cluster_change` at log index 4, sends AER to N2.
  3. N2 (follower) processes the cluster change: `cluster_index_term` -> `{4, 5}`. No `previous_cluster` key is set.
  4. N1 crashes. N3 becomes leader at term 6.
  5. N3 does not have the cluster change entry. N3 writes a regular command at index 4, term 6, and sends AER to N2.
  6. N2's `pre_append_log_follower` matches the first clause (index 4, term 6 != 5), enters the non-cluster-change branch, calls `maps:get(previous_cluster, State)` -> **crash**.
- **Reproduction**: `ra_bug_confirmation_SUITE:tv1_badkey_previous_cluster/1` and `ra_bug_repro_SUITE:bug42_pre_append_log_follower_badkey_crash/1`. Constructs a valid follower state, sends two legitimate AERs through `ra_server:handle_follower/2`. The first AER carries a cluster change at index 4 (term 5), the second overwrites index 4 with a regular entry (term 6). The second call crashes with `{badkey, previous_cluster}`.
- **Impact**: Follower gen_statem process terminates. Requires automatic restart by supervisor. Cluster temporarily loses one member's participation. Triggered whenever a leader proposes a membership change that is not committed before a leader change, and the new leader overwrites the entry.
- **Recommendation**: In `pre_append_log_follower/2` second clause (line 3586-3592), save `previous_cluster` the same way `append_cluster_change/5` does:
  ```erlang
  pre_append_log_follower({Idx, Term, {'$ra_cluster_change', _, Cluster, _}},
                          State = #{cluster := OldCluster,
                                    cluster_index_term := {PrevIdx, PrevTerm}}) ->
      State#{cluster => Cluster,
             membership => get_membership(Cluster, State),
             cluster_index_term => {Idx, Term},
             previous_cluster => {PrevIdx, PrevTerm, OldCluster}};
  ```

---

## Bug 2: Pre-vote voted_for Blocks Real Vote

- **Source**: Code Review (MC-9)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `ra_server.erl:2960`, `ra_server.erl:1491`
- **Description**: When a follower grants a pre-vote, `process_pre_vote` (line 2960) sets `voted_for => Cand` in the in-memory state. This is not persisted (unlike real votes), but it IS checked by the real vote handler at line 1491: `VotedFor /= undefined andalso VotedFor /= Cand`. If the pre-vote advances the follower's term (via `update_term` at line 2942), a subsequent real vote request at the SAME term from a DIFFERENT candidate is rejected because `voted_for` is already set from the non-binding pre-vote.

  Per the Raft thesis (Section 9.6), pre-votes are "speculative" and should not prevent real votes. Ra's implementation conflates pre-vote and real vote state by sharing the `voted_for` field.

- **Trigger scenario**:
  1. Follower F at term 3
  2. Node A at term 5 sends `pre_vote_rpc{term=5}` to F
  3. F grants pre-vote: `update_term(5)` advances F to term 5 (clears voted_for), then sets `voted_for => A`
  4. Node B starts real election at term 5, sends `request_vote_rpc{term=5}` to F
  5. F checks: term 5 == CurTerm 5, voted_for = A, Cand = B, A != B -> **REJECT**
  6. B's legitimate vote request is blocked by A's non-binding pre-vote

- **Reproduction**: `ra_bug_confirmation_SUITE:mc9_prevote_blocks_real_vote/1`
  - Sends pre_vote_rpc from N1 at term 5 to follower at term 3
  - Verifies pre-vote granted and voted_for = N1
  - Sends request_vote_rpc from N3 at term 5
  - Asserts `vote_granted = false`
  - Result: **vote rejection confirmed deterministically**

- **Impact**: Not a safety violation (at most one leader per term still holds), but a liveness issue. The rejected candidate must retry at a higher term, causing unnecessary term inflation and election delay. In pathological cases with multiple concurrent pre-votes and real elections at similar terms, this could contribute to election livelock.

- **Recommendation**: Do not set `voted_for` when granting a pre-vote. Use a separate `pre_voted_for` field or simply omit the `voted_for => Cand` assignment in `process_pre_vote`:
  ```erlang
  %% Line 2960: remove voted_for assignment for pre-votes
  {FsmState, State, [{reply, pre_vote_result(Term, Token, true, Id)}]});
  ```

---

## Bug 3: Pre-vote Causes Term Inflation on Receiver

- **Source**: Code Review (MC-10)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `ra_server.erl:2942`
- **Description**: `process_pre_vote` calls `update_term(Term, State0)` at line 2942, which advances the receiver's term when the pre-vote RPC carries a higher term. Per the Raft thesis (Section 9.6): "This [pre-vote] does not change the receiver's term." The whole purpose of pre-vote is to prevent a partitioned node's failed elections from disrupting the cluster via term inflation. By updating the receiver's term on pre-vote, Ra partially defeats this purpose.

- **Trigger scenario**:
  1. Node A is partitioned, runs failed elections, reaches term 10
  2. A reconnects and sends `pre_vote_rpc{term=10}` to follower F at term 3
  3. F calls `update_term(10, State)` -> F's term jumps from 3 to 10
  4. F now rejects AppendEntries from the current leader (who is at term <= 3)
  5. This triggers an unnecessary election -- exactly what pre-vote should prevent

- **Reproduction**: `ra_bug_confirmation_SUITE:mc10_prevote_term_inflation/1`
  - Follower at term 3 receives pre_vote_rpc at term 10
  - Verifies term advances to 10
  - Result: **term inflation confirmed deterministically**

- **Impact**: A partitioned node can disrupt a healthy cluster by sending pre-vote RPCs with inflated terms. The current leader loses its followers, triggering unnecessary re-elections. This undermines pre-vote's core design goal.

- **Recommendation**: Remove `update_term` from `process_pre_vote`. The receiver should respond to pre-vote RPCs at its current term without adopting the candidate's term:
  ```erlang
  process_pre_vote(FsmState, #pre_vote_rpc{term = Term, ...}, State0)
    when Term >= CurTerm ->
      %% Do NOT update term for pre-vote (Raft thesis Section 9.6)
      %% State = update_term(Term, State0),  %% REMOVE THIS
      LastIdxTerm = last_idx_term(State0),
      ...
  ```
  Note: This fix interacts with Bug 2 (MC-9). If `update_term` is removed, the pre-vote will not advance the receiver's term, which also eliminates the scenario where pre-vote's `voted_for` conflicts with a real vote at the same (now-not-advanced) term. Both bugs share the root cause of pre-vote having too many side effects.

---

## Bug 4: Candidate Ignores install_snapshot_rpc

- **Source**: Code Review / Spec Generation
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `ra_server.erl:1173-1175` (`handle_candidate/2`, catch-all clause)
- **Description**: The `handle_candidate` function has no clause for `#install_snapshot_rpc{}`. When a lagging node enters candidate state (election timeout) and the leader sends an InstallSnapshot RPC (because the node is too far behind for AppendEntries), the message falls through to the catch-all handler, which returns `{error, {unsupported_call, Msg}}` and stays in candidate state. Compare with `handle_pre_vote` (line 1212-1215) which correctly handles ISR by stepping down to follower.
- **Trigger scenario**:
  1. Node N1 falls far behind (e.g., network partition).
  2. N1's election timer fires -> enters candidate state.
  3. Leader sends InstallSnapshot RPC to N1 (N1's log is too far behind for AER).
  4. N1 rejects the ISR, stays candidate, election times out -> restarts election.
  5. Loop repeats indefinitely: N1 can never rejoin via snapshot.
- **Reproduction**: `ra_bug_repro_SUITE:bug39_candidate_ignores_install_snapshot/1`. Calls `ra_server:handle_candidate/2` with a valid ISR at the same term. Returns `{candidate, _, [{reply, {error, {unsupported_call, _}}}]}` instead of stepping down.
- **Impact**: A lagging node that can only rejoin via snapshot installation is permanently stuck in election loops. The node consumes network bandwidth with repeated election attempts but never catches up. Only affects nodes where the log gap exceeds the leader's retained log window.
- **Recommendation**: Add an ISR handler to `handle_candidate/2`, mirroring the `handle_pre_vote` pattern:
  ```erlang
  handle_candidate(#install_snapshot_rpc{term = Term} = ISR,
                   #{current_term := CurTerm} = State0)
    when Term >= CurTerm ->
      {follower, State0#{votes => 0}, [{next_event, ISR}]};
  ```

---

## Bug 5: Permanent Error During Snapshot Reception

- **Source**: Code Review (TV-2)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `ra_server.erl:1901-1905` (`handle_receive_snapshot/2`, catch-all clause)
- **Description**: During snapshot reception (`receive_snapshot` state), client commands and consistent queries fall through to the catch-all handler which returns `{error, {unsupported_call, Msg}}`. This is a permanent, non-retryable error. The node knows the leader ID (stored in `leader_id` field) but does not redirect the client. Snapshot transfers can last seconds to minutes for large snapshots, during which all client requests to this node fail permanently.
- **Trigger scenario**:
  1. Node N2 is receiving a snapshot from leader N1 (in `receive_snapshot` state).
  2. Client sends a write command or consistent query to N2.
  3. N2 returns `{error, {unsupported_call, ...}}` -- a permanent error.
  4. Client interprets this as a fatal failure rather than a temporary unavailability.
- **Reproduction**: `ra_bug_repro_SUITE:bug43_receive_snapshot_permanent_error/1`.
- **Impact**: Client-visible permanent failures during snapshot transfer. In RabbitMQ quorum queues, this could cause publishers/consumers connected to a node undergoing snapshot reception to see permanent errors instead of being redirected to the leader.
- **Recommendation**: Add explicit handlers for client commands and queries in `handle_receive_snapshot` that return `{redirect, LeaderId}`.

---

## Bug 6: Stale Membership After Cluster Change Overwrite

- **Source**: Code Review (MC-6)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `ra_server.erl:3572-3576` (`pre_append_log_follower/2`, first clause, cluster-change branch)
- **Description**: When a cluster change entry at index I (term T1) is overwritten by another cluster change entry at the same index (term T2), the first clause of `pre_append_log_follower` updates `cluster` and `cluster_index_term` but does NOT update the `membership` field. Compare with the second clause (line 3590-3592) which correctly calls `get_membership(Cluster, State)`. This leaves the follower's `membership` field stale, potentially causing incorrect election participation decisions.
- **Trigger scenario**:
  1. Leader L1 (term 5) appends cluster change at index 4 that demotes N2 to `non_voter`.
  2. Follower N2 receives it -- second clause fires, membership updated to `non_voter`.
  3. L1 loses leadership before commit.
  4. New leader L2 (term 6) appends a DIFFERENT cluster change at index 4 that re-promotes N2 to `voter`.
  5. N2 receives it -- first clause fires (same index, different term, IS cluster change). Updates cluster (N2 is voter) but membership stays `non_voter`.
  6. N2 thinks it's a non-voter, won't participate in elections.
- **Reproduction**: `ra_bug_confirmation_SUITE:mc6_membership_not_updated_on_overwrite/1`
  - Sends AER with demote cluster change, verifies membership = non_voter
  - Sends AER overwriting with promote cluster change at different term
  - Asserts membership is still non_voter (stale)
  - Result: **stale membership confirmed deterministically**
- **Impact**: Transient. The stale membership persists until the entry is committed and applied by `apply_with($ra_cluster_change)`, which correctly updates membership. The trigger conditions (two leaders proposing cluster changes at the exact same log index) are rare.
- **Recommendation**: Add `membership => get_membership(Cluster, State)` to the state update in the first clause's cluster-change branch (line 3575-3576).

---

## Bug 7: Silent Request Drop During Leadership Transfer

- **Source**: Code Review (TV-3)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `ra_server.erl:1959-1968` (`handle_await_condition/2`, catch-all clause)
- **Description**: When a leader initiates leadership transfer via `transfer_leadership`, it enters `await_condition` state with `transfer_leadership_condition/2` as the predicate (line 1024-1029). This condition only returns `{true, State}` for AppendEntries or InstallSnapshot RPCs with a higher term (lines 2245-2254). All other messages -- including client commands, queries, and heartbeat replies -- return `{false, State}`, causing the catch-all handler at line 1965-1967 to silently drop them with no effects generated. No error reply is sent to the client.
- **Trigger scenario**:
  1. Leader L receives `transfer_leadership(N2)` -> transitions to `await_condition`
  2. Client C sends a pipeline_command to L
  3. `transfer_leadership_condition(CommandMsg, State)` returns `{false, State}`
  4. Command is dropped silently -- no reply to C
  5. C hangs until client-side timeout
- **Reproduction**: `ra_bug_confirmation_SUITE:tv3_silent_request_drop_during_transfer/1`
  - Leader initiates transfer_leadership -> enters await_condition
  - Client command sent to await_condition handler
  - Asserts: state stays await_condition, no reply effects generated
  - Result: **silent drop confirmed deterministically**
- **Impact**: During the leadership transfer window, all client operations are silently lost. While typically short (until the new leader is elected), it can be longer if the target node is slow or partitioned.
- **Recommendation**: Add explicit rejection handlers in `handle_await_condition` for client commands:
  ```erlang
  handle_await_condition({command, _} = _Cmd, State) ->
      {await_condition, State, [{reply, {error, leader_transfer_in_progress}}]};
  ```

---

## Bug 8: Commit Index Monotonicity Violation (Known Design Choice)

- **Source**: MC (Finding 1, MC_hunt_family1.cfg)
- **Status**: CONFIRMED (code audit + MC counterexample)
- **Severity**: Low (known design choice, not a safety bug)
- **Location**: `ra_server.erl:1322-1323` and `ra_server.erl:1359-1361`
- **Description**: The follower sets `commit_index` directly from `LeaderCommit` in the AER without a `max(oldCI, newCI)` guard. If a stale AER arrives after a newer AER due to message reordering (after TCP reconnection), the follower's commit_index can regress.
- **MC Counterexample**: 44 states (MC_hunt_family1.cfg simulation). State 42: follower's commitIndex becomes 1 from a newer AER. State 43: stale AER with mcommitIndex=0 arrives -> commitIndex regresses to 0.
- **Safeguards**: `evaluate_commit_index_follower` (line 2269) bounds apply operations: `ApplyTo = min(Idx, CommitIndex)`. Since `lastApplied` only advances monotonically, a regressed commitIndex simply pauses further applies until a newer AER restores it. All 7 safety invariants hold.
- **Impact**: Temporary pause in follower apply progress after TCP reconnection. No safety violation. Self-healing when the next AER arrives.
- **Recommendation**: Adding `max(OldCI, LeaderCommit)` would match the Raft paper but is not strictly necessary. Documented design choice (PR #508).

---

## False Positives

### FP-1: Vote Deduplication Gap (MC-1)
- **Claimed**: Integer vote counter can double-count if `request_vote_result` is network-duplicated.
- **Why false positive**: Erlang distribution uses TCP, which does not duplicate messages. Ra uses spawned processes for vote requests (`ra_server_proc.erl:1712-1717`): each process does exactly one `gen_statem:call` + one `gen_statem:cast`. No mechanism exists for a single peer to deliver multiple vote replies. Term matching prevents stale votes from counting. Pre-vote token matching prevents stale pre-vote results.

### FP-2: Vote Quorum Exact Equality (MC-2)
- **Claimed**: Pattern match `NewVotes ->` (exact equality) misses case where votes exceed quorum.
- **Why false positive**: Votes are initialized to 0 and increment by 1 per response. The cluster map doesn't change during an election. Therefore `NewVotes` always passes through the exact quorum value. The `>` case is unreachable in practice.

### FP-3: voted_for Clearing on Same-Term AER (MC-3)
- **Claimed**: Candidate receiving same-term AER clears `voted_for`, allowing double voting -> Election Safety violation.
- **Why false positive**: If a leader exists for term T, it already holds quorum Q. The remaining N-Q nodes is strictly less than Q (since Q > N/2). Even if all N-Q nodes cleared their voted_for and voted for a new candidate, the new candidate could get at most N-Q < Q votes -- below quorum. Two leaders in the same term is impossible.

### FP-4: Missing update_term in Pre-Vote ISR Handler (MC-4)
- **Claimed**: `handle_pre_vote(#install_snapshot_rpc{...})` doesn't call `update_term` when Term > CurTerm.
- **Why false positive**: The handler transitions to follower with `{next_event, ISR}`. The ISR is immediately reprocessed by `handle_follower` which calls `update_term`. In OTP gen_statem, state change and next_event processing happen atomically.

### FP-5: Leadership Transfer + Non-Voter Interaction (MC-7)
- **Claimed**: Non-voter could participate in elections during leadership transfer.
- **Why false positive**: MC simulation (114M states, 219K traces) found no violation. Follower and await_condition election_timeout handlers both have non-voter guards. Pre-vote result handler has `membership := voter` guard. Non-voter cannot enter election pipeline.

### FP-6: Candidate/Pre-Vote Missing Non-Voter Guard on election_timeout
- **Claimed**: Lines 1148 and 1246 lack `membership := voter` guard.
- **Why false positive**: Candidate and pre_vote states are only reachable by voters. Entry guards exist at follower election_timeout and pre_vote win. Membership cannot change while in candidate/pre_vote state. Defense-in-depth only.

---

## Not Assessed (Out of Scope)

| ID | Description | Reason |
|----|-------------|--------|
| CR-1 | handle_pre_vote missing rejection for lower-term RVR | Catch-all returns error, not safety-relevant |
| CR-2 | Orphaned snapshot sender when leader steps down | Resource leak, not protocol logic |
| CR-3 | No reply for already_member join attempts | Quality-of-service TODO, not safety |
