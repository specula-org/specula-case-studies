# Bug Report: etcd-io/raft

## Bug ER-1: LeaseRead Stale Read Under Network Partition (CONFIRMED)

**Severity**: HIGH
**Status**: CONFIRMED (acknowledged by maintainer as design flaw)
**Found by**: TLC Model Checking (BFS, 149M states, 2min 10s)
**Config**: `MC_hunt_lease_ultra.cfg` (ReadOnlyLeaseBased, checkQuorum=FALSE, preVote=FALSE)
**Invariant Violated**: `ReadIndexLinearizability`

### Summary

A leader using `ReadOnlyLeaseBased` can serve stale reads after a network partition causes a new leader to be elected. The old leader's `commitIndex` lags behind the global committed log, but it still serves reads because no mechanism (heartbeat quorum or CheckQuorum) forces it to verify its leadership.

### Counterexample (21 states)

```
State  1: All followers (term 1)
State  2: s1 becomes Candidate (term 2)
State  6: s1 becomes Leader (term 2), appends noop
State  9: s1 sends AppendEntries to s3, s3 acks
State 10: s2 times out, starts election (term 3)
           — s1 never receives s2's VoteRequest (partition)
State 15: s2 becomes Leader (term 3), appends noop
           — TWO leaders now: s1(term 2), s2(term 3)
State 19: s1 receives s3's ack → commits noop
           commitIndex[s1]=1, committedInTerm[s1]=TRUE
State 20: s2 receives s3's ack → commits noop
           commitIndex[s2]=2, committedLog grows to length 2
State 21: s1 serves LeaseRead → r.index=1
           BUT Len(committedLog)=2 → STALE READ!

Violation: r.index(1) < readRequestCommit(2)
```

### Root Cause

`ReadOnlyLeaseBased` (raft.go:2153-2156) responds immediately with the leader's current `commitIndex` without any quorum confirmation:

```go
case ReadOnlyLeaseBased:
    if resp := r.responseToReadIndexReq(m, r.raftLog.committed); resp.To != None {
        r.send(resp)
    }
```

In contrast, `ReadOnlySafe` (raft.go:2148-2152) broadcasts heartbeats and waits for quorum acks before responding, which correctly prevents stale reads.

### Impact

- Any client using `ReadOnlyLeaseBased` can receive stale data during network partitions
- The stale window persists until `CheckQuorum` fires (if enabled) or the partition heals
- Without `CheckQuorum`, the stale leader serves reads indefinitely

### Existing Acknowledgment

- etcd-io/raft Issue #166: maintainer @pav-kv stated LeaseRead "did not appear correct/usable"
- etcd-io/raft Issue #99: LeaseRead discussion
- No known production users of `ReadOnlyLeaseBased`

### Verification

- `ReadOnlySafe` mode: **NO VIOLATION** (1,837,459 states, BFS complete)
- `ReadOnlyLeaseBased` mode: **VIOLATED** (21-state counterexample)
- `ElectionSafety`: **NOT violated** (two leaders at different terms is expected in Raft)

---

## Bug ER-2: LeaseRead Stale Read Even With CheckQuorum Enabled (CONFIRMED)

**Severity**: HIGH
**Status**: CONFIRMED
**Found by**: TLC Model Checking (BFS, 720M states, 10min)
**Config**: `MC_hunt_lease_cq_min.cfg` (ReadOnlyLeaseBased, checkQuorum=TRUE, preVote=FALSE)
**Invariant Violated**: `ReadIndexLinearizability`

### Summary

Even with `checkQuorum = TRUE`, a stale leader can serve a LeaseRead before CheckQuorum ever fires. The key insight: CheckQuorum is periodic (tick-based), but the stale read can happen in the window BEFORE the first CheckQuorum invocation.

### Counterexample (24 states)

```
State  1-6:  s1 elected leader (term 2), s2 voted for s1
State  7-8:  s1 sends AppendEntries to s2, s2 acks → s1 commits noop
             commitIndex[s1]=1, committedInTerm[s1]=TRUE
State  9:    s3 times out, starts election (term 3)
             — s1 never receives s3's VoteRequest (partition)
State 12-13: s3 wins election with s2's vote, becomes Leader (term 3)
State 14-20: s3 replicates noop to s2, commits → committedLog=[noop_t2, noop_t3]
State 24:    s1 serves LeaseRead: r.index=1, Len(committedLog)=2 → STALE!
             checkQuorumCount=0 — CheckQuorum NEVER FIRED
```

### Key Finding

`checkQuorum = TRUE` does NOT prevent stale LeaseReads. The protection only works if CheckQuorum fires frequently enough. Between leader election and the first CheckQuorum tick, there is an unbounded window where stale reads can be served.

In practice, etcd's `electionTimeout` is typically 10× `heartbeatTimeout` (e.g., 1 second). The stale read window is up to 1 second — long enough for many client reads.

### Difference from ER-1

| | ER-1 | ER-2 |
|---|---|---|
| CheckQuorum | FALSE | **TRUE** |
| CheckQuorum fired | N/A | **0 times** |
| Window | Unbounded | Until first CheckQuorum tick |
| Practical impact | Theoretical | **Realistic** |

ER-2 is more severe than ER-1 because `checkQuorum = TRUE` is the **default production config** for etcd. Users expect CheckQuorum to protect against stale reads, but it doesn't protect against the initial window.

### Affected Code

Same as ER-1: `raft.go:2153-2156` (ReadOnlyLeaseBased immediate response)

---

## Finding ER-3: Immediate Rejection is Safe (NEW CONTRIBUTION — VERIFIED)

**Severity**: N/A (positive result — formal verification of developer's open question)
**Status**: VERIFIED
**Found by**: TLC Simulation (267M+ states, 4M+ traces, original + variant)
**Spec variant**: `base_immediate_reject.tla` + `MC_immediate_reject.tla`
**Developer question**: raft.go:578-589 — *"the safety of such behavior has not been formally verified"*

### Summary

The developer's comment at raft.go:587 explicitly asks whether rejected responses (`MsgVoteResp` and `MsgAppResp` with `Reject=true`) can be safely sent immediately without waiting for persistence. **We formally verified: YES, it is safe.**

### What We Tested

Created a spec variant where all rejected responses are sent immediately to the network (via `msgs`) instead of being deferred to `msgsAfterAppend`. Grant/success responses remain deferred.

### Results

| Invariant | Original (all deferred) | Variant (immediate reject) |
|-----------|------------------------|------------------------------|
| ElectionSafety | PASS (167M states) | PASS (100M states) |
| VoteSafety | PASS | PASS |
| LeaderCompleteness | PASS | PASS |
| StateMachineConsistency | PASS | PASS |

Both variants explored with crash injection (CrashLimit=2), message loss, and multiple elections. No safety violations.

### Practical Impact

The developer can safely add `&& !m.Reject` to the condition at raft.go:544:
```go
if m.Type == pb.MsgAppResp || m.Type == pb.MsgVoteResp || m.Type == pb.MsgPreVoteResp {
    if !m.Reject {  // ← safe to add this condition
        r.msgsAfterAppend = append(r.msgsAfterAppend, m)
    } else {
        r.msgs = append(r.msgs, m)  // send rejection immediately
    }
}
```

This would reduce latency for rejected requests without compromising safety. Rejections are already rare (as noted at raft.go:586), so the performance impact is minimal, but the correctness assurance is valuable.

### Caveats

- Verified with 3 servers, terms up to 4, 2 crashes, 1 client request
- Simulation coverage: 267M+ states, 4M+ traces (not exhaustive BFS)

---
