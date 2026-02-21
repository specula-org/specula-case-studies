# hashicorp/raft Code Analysis Report

## 1. Scope and Methodology

### 1.1 Objective

Static code analysis of the hashicorp/raft library to identify potential protocol safety issues
and code defects, guiding subsequent TLA+ modeling and bug discovery.

### 1.2 Analyzed Code

Code located at `case-studies/hashicorp-raft/artifact/raft/`, primary files analyzed:

| File | Size | Responsibility |
|------|------|----------------|
| `raft.go` | ~2200 lines | Core state machine: runFollower/runCandidate/runLeader, RPC handling, elections, snapshots |
| `replication.go` | ~660 lines | Log replication: replicate, heartbeat, pipelineReplicate |
| `configuration.go` | ~370 lines | Cluster membership configuration change logic |
| `commitment.go` | ~105 lines | Commit index advancement and quorum calculation |
| `snapshot.go` | ~279 lines | Snapshot management |
| `api.go` | Public API |

### 1.3 Methodology

1. **Parallel static code analysis** — Independent line-by-line analysis of raft.go, replication.go, configuration.go
2. **Git history bug pattern analysis** — Analysis of bug fix patterns in historical commits
3. **GitHub open issues analysis** — Review of current unresolved issues and confirmed bugs
4. **PreVote implementation audit** — Focused analysis of PreVote extension implementation quality
5. **Deep verification** — Thorough verification of each suspicious finding, distinguishing real bugs from false positives

---

## 2. Code Analysis Findings

### 2.1 raft.go Core Logic

#### Finding 1: Heartbeat goroutine does not check resp.Term

**Location**: `replication.go:412-437`

**Description**: In the `heartbeat()` function, after successfully receiving an AppendEntries response,
the code completely ignores `resp.Term`. In contrast, `replicateTo()` (line 239-241) and
`pipelineDecode()` (line 548-550) both check `resp.Term > req.Term` and call `handleStaleTerm(s)`
to trigger leader step-down.

```go
// replication.go:412-437 (heartbeat - missing term check)
if err := r.trans.AppendEntries(peer.ID, peer.Address, &req, &resp); err != nil {
    // ... error handling
} else {
    s.setLastContact()
    failures = 0
    // NOTE: No check for resp.Term > req.Term here
    s.notifyAll(resp.Success)
}

// Compare with replication.go:238-242 (replicateTo - has term check)
if resp.Term > req.Term {
    r.handleStaleTerm(s)
    return true
}
```

**Analysis**: This is the only code path among three that lacks the term check. When the cluster is
idle (no new writes), only the heartbeat goroutine is active and `replicateTo` is not called.
If another node wins election with a higher term, the old leader's heartbeat goroutine will not
detect the higher term; leader step-down must rely on other mechanisms (lease timeout, receiving
RequestVote, etc.).

**Verification status**: **Code inconsistency confirmed**. Whether this leads to a protocol
violation requires TLA+ modeling or constructing a specific trigger scenario.
The leader will eventually step down via lease timeout or other mechanisms, so this may only
delay step-down rather than cause a safety violation.

**Assessment**: Code inconsistency (Medium)

---

#### Finding 2: timeoutNow has no state guard

**Location**: `raft.go:2210-2215`

```go
func (r *Raft) timeoutNow(rpc RPC, req *TimeoutNowRequest) {
    r.setLeader("", "")
    r.setState(Candidate)
    r.candidateFromLeadershipTransfer.Store(true)
    rpc.Respond(&TimeoutNowResponse{}, nil)
}
```

**Description**: `processRPC` is called in all three state loops: `runFollower` (line 172),
`runCandidate` (line 326), `runLeader` (line 686). `timeoutNow` does not check the current
node's state.

**Scenario analysis**:

| Current State | Effect of Receiving TimeoutNow |
|---------------|-------------------------------|
| Follower | Normal: sets Candidate, exits runFollower (`for r.getState() == Follower`), enters election |
| Candidate | Sets `candidateFromLeadershipTransfer=true`, granting privileged election status (skips PreVote, other nodes vote even with existing leader) |
| Leader | Forced step-down: leaderLoop exits (`for r.getState() == Leader`), stops replication, enters election |

**Analysis**: Under normal operation, TimeoutNow is only sent by the leader to the target follower
and would not be sent to a candidate or the leader itself. However, there is no protocol-level
protection. If an abnormal node in the cluster sends TimeoutNow to the leader, it can force
leader step-down.

**Verification status**: **Code behavior confirmed**. Does not trigger under normal operation;
represents a defensive programming gap.

**Assessment**: Robustness issue (Low-Medium)

---

#### Finding 3: requestVote bumps term before rejecting non-voter requests

**Location**: `raft.go:1665-1684`

```go
// Bump term first (line 1665-1672)
if req.Term > r.getCurrentTerm() {
    r.setState(Follower)
    r.setCurrentTerm(req.Term)
    resp.Term = req.Term
}

// Then check if non-voter (line 1679-1684)
if len(req.ID) > 0 {
    candidateID := ServerID(req.ID)
    if len(r.configurations.latest.Servers) > 0 && !hasVote(r.configurations.latest, candidateID) {
        r.logger.Warn("rejecting vote request since node is not a voter", "from", candidate)
        return  // Rejects vote, but term has already been bumped!
    }
}
```

**Description**: When a non-voter (NonVoter) sends a RequestVote with a higher term, the
receiving node first bumps its own term (potentially causing the current leader to step down),
then checks whether the requester has voting rights. Even though the vote is ultimately
rejected, the term bump side effect has already occurred.

**Analysis**: This was discussed in hashicorp/raft PR #526, and code comments (line 1674-1678)
explain this is an intentional design choice:

> "if we get a request for vote from a nonVoter and the request term is higher,
> step down and update term, but reject the vote request.
> This could happen when a node, previously voter, is converted to non-voter.
> The reason we need to step in is to permit to the cluster to make progress in such a scenario."

**Verification status**: **Design decision, not a bug**. However, a demoted node can repeatedly
disrupt the cluster by sending high-term RequestVotes (causing leader step-down). PreVote
can mitigate this.

**Assessment**: Known design trade-off (Low)

---

#### Finding 4: Vote/PreVote uses uncommitted latest config for membership checks

**Location**: `raft.go:1645, 1681, 1758, 1785`

```go
// requestVote (line 1645) - uses latest config
if len(r.configurations.latest.Servers) > 0 && !inConfiguration(r.configurations.latest, candidateID) {
    // reject vote
}

// requestPreVote (line 1758) - also uses latest config
if len(r.configurations.latest.Servers) > 0 && !inConfiguration(r.configurations.latest, candidateID) {
    // reject prevote
}
```

**Description**: Both `requestVote` and `requestPreVote` use `r.configurations.latest` to
determine whether the candidate is in the cluster and has voting rights. `latest` may include
uncommitted configuration changes.

**Analysis**: This is common practice in Raft implementations. Using committed config would
prevent newly added voters from participating in elections before the config is committed.
However, using latest config means different followers may have different judgments about the
same candidate's eligibility (because they may have different latest configs).

hashicorp/raft mitigates this by restricting to one uncommitted config change at a time
(`configurationChangeChIfStable`, line 659).

**Verification status**: **Code behavior confirmed, debatable whether it's a bug**. Most Raft
implementations use latest config. The single uncommitted config change constraint limits impact.

**Assessment**: Known design trade-off (Low)

---

#### Finding 5: processConfigurationLogEntry committed semantics on followers

**Location**: `raft.go:1586-1601`

```go
func (r *Raft) processConfigurationLogEntry(entry *Log) error {
    switch entry.Type {
    case LogConfiguration:
        r.setCommittedConfiguration(r.configurations.latest, r.configurations.latestIndex)
        r.setLatestConfiguration(DecodeConfiguration(entry.Data), entry.Index)
    }
    return nil
}
```

**Description**: When a follower receives a config change log entry, it promotes the current
`latest` to `committed`, then sets a new `latest`. However, the current `latest` itself may
not yet be committed.

**Compare with leader's approach** (line 795-797):
```go
// Leader only updates committed when commit index advances
if r.configurations.latestIndex > oldCommitIndex &&
    r.configurations.latestIndex <= commitIndex {
    r.setCommittedConfiguration(r.configurations.latest, r.configurations.latestIndex)
}
```

**Analysis**: Since hashicorp/raft restricts to one uncommitted config change at a time,
when processing a new config entry, the previous `latest` is typically already committed.
So in practice this behavior is likely correct.

Additionally, the follower has correct committed update logic in `appendEntries` (line 1571-1572):
```go
if r.configurations.latestIndex <= idx {
    r.setCommittedConfiguration(r.configurations.latest, r.configurations.latestIndex)
}
```

**Verification status**: **Code inconsistency confirmed**. Due to the single uncommitted config
change constraint, this likely does not cause issues in practice.

**Assessment**: Code inconsistency (Low)

---

#### Finding 6: installSnapshot does not verify snapshot is newer than current state

**Location**: `raft.go:1815-1953`

**Description**: `installSnapshot` does not explicitly check whether the snapshot's index/term
is newer than the current state when receiving and applying a snapshot. This could theoretically
lead to state regression.

**Analysis**: Under normal operation, the leader only sends snapshots when a follower is too
far behind. The snapshot's index should be higher than the follower's current lastApplied.
However, the code does not explicitly check this.

**Verification status**: **Needs further verification**. Need to confirm whether other
mechanisms (e.g., term check) implicitly prevent this.

**Assessment**: Needs further verification (Low-Medium)

---

#### Finding 7: dispatchLogs inflight list cleanup issue on failure

**Location**: `raft.go:1256-1273`

```go
// Logs already added to inflight list
for idx, applyLog := range applyLogs {
    r.leaderState.inflight.PushBack(applyLog)
}

// StoreLogs fails
if err := r.logs.StoreLogs(logs); err != nil {
    for _, applyLog := range applyLogs {
        applyLog.respond(err)  // respond with error
    }
    r.setState(Follower)  // But inflight list entries not removed!
    return
}
```

**Description**: When `StoreLogs` fails, the code responds to all applyLogs with an error
and transitions to Follower. But these logFutures remain in the `inflight` list. When
`runLeader`'s deferred cleanup function executes, it iterates the inflight list and calls
`respond(ErrLeadershipLost)` on each entry, meaning these futures get responded to twice.

**Analysis**: Need to check whether `respond()` has idempotency protection (respond only once).

**Verification status**: **Need to check respond() implementation**

**Assessment**: Needs further verification (Medium)

---

#### Finding 8: lastLog cache incorrect after truncation + StoreLogs failure

**Location**: `raft.go:1540-1543`

```go
if err := r.logs.StoreLogs(newEntries); err != nil {
    r.logger.Error("failed to append to logs", "error", err)
    // TODO: leaving r.getLastLog() in the wrong
    // state if there was a truncation above
    return
}
```

**Description**: This is a developer-acknowledged TODO. In `appendEntries`, if log truncation
(`DeleteRange`, line 1526) executes first and then `StoreLogs` fails, the `lastLog` cache
is left in an incorrect state: it still points to the pre-truncation value, but the actual
log has already been truncated.

**Analysis**: This can cause subsequent operations (e.g., `getLastEntry`) to return incorrect
values, affecting the Log Matching property.

**Verification status**: **Known issue acknowledged by developers**

**Assessment**: Known issue (Medium-High)

---

### 2.2 replication.go Replication Logic

#### Finding 9: Non-atomic read-write of nextIndex

**Location**: `replication.go:256`

```go
atomic.StoreUint64(&s.nextIndex, max(min(s.nextIndex-1, resp.LastLog+1), 1))
```

**Description**: `atomic.StoreUint64` reads `s.nextIndex` internally without using
`atomic.LoadUint64`. `s.nextIndex` is concurrently accessed by the heartbeat goroutine
and the replication goroutine.

**Verification status**: **Code issue confirmed**, this is a data race.

**Assessment**: Data race (Medium)

---

#### Finding 10: s.peer.ID accessed without lock

**Location**: `replication.go:521, 647, 660`

```go
// line 660 - commitment.match uses unlocked s.peer.ID
s.commitment.match(s.peer.ID, last.Index)
```

**Description**: `s.peer` can be modified by `startStopReplication` via `peerLock` (updating
address, etc.), but some access points lack locking.

**Analysis**: Line 660 in `updateLastAppended` passes `s.peer.ID` to `commitment.match`.
If `s.peer` is concurrently modified (torn read), an incorrect server ID may be passed.
However, `peerLock` only protects address updates; the ID does not change in practice.

**Verification status**: **Code issue confirmed**, but actual impact is likely minimal
(ID doesn't change, only Address changes).

**Assessment**: Code issue (Low)

---

#### Finding 11: Closed stopCh affects best-effort replication

**Location**: `replication.go:147, 272`

**Description**: At the `CHECK_MORE` label in `replicate`, there is a select checking `stopCh`.
When `stopCh` is closed, select immediately picks the `stopCh` branch, bypassing the
best-effort replication logic.

**Verification status**: **Code behavior confirmed**

**Assessment**: Minor issue (Low)

---

### 2.3 configuration.go Configuration Change Logic

#### Finding 12: AddNonvoter suffrage handling logic

**Location**: `configuration.go:252-272`

```go
case AddNonvoter:
    for i, server := range configuration.Servers {
        if server.ID == change.serverID {
            if server.Suffrage != Nonvoter {
                // If already Voter/Staging, only update address, don't change suffrage
                configuration.Servers[i].Address = change.serverAddress
            } else {
                configuration.Servers[i] = newServer
            }
        }
    }
```

**Description**: Calling `AddNonvoter` on an existing Voter node does not demote it to
Nonvoter; it only updates the address.

**Analysis**: Per API documentation (`api.go:959-963`), this is by design:
> "If the server is already in the cluster, this updates the server's address."

Demotion requires using `DemoteVoter`.

**Verification status**: **Not a bug, matches design intent**

**Assessment**: By design (not an issue)

---

#### Finding 13: EncodeConfiguration/DecodeConfiguration panic on error

**Location**: `configuration.go:352-368`

**Description**: These two public functions call `panic` instead of returning an error
on serialization/deserialization failure. If a corrupted log entry is received, the node crashes.

**Verification status**: **Code behavior confirmed**

**Assessment**: Robustness issue (Low-Medium)

---

#### Finding 14: Inconsistent use of committed vs latest configuration

**Location**: Multiple locations

| Function | Config Used | Location |
|----------|-------------|----------|
| Leader step-down check | `committed` | raft.go:798 |
| `quorumSize()` | `latest` | raft.go:1089 |
| `checkLeaderLease()` | `latest` | raft.go:1049 |
| `setupLeaderState` commitment | `latest` | raft.go:458 |
| Vote eligibility check | `latest` | raft.go:1645 |

**Description**: Different functions use different versions of configuration. This is usually
not an issue (since latest and committed are typically identical), but during configuration
changes it can lead to inconsistent decisions.

**Verification status**: **Code inconsistency confirmed**

**Assessment**: Code inconsistency (Low-Medium)

---

### 2.4 PreVote Implementation

#### Finding 15: Metrics label copy-paste error

**Location**: `raft.go:1738`

```go
func (r *Raft) requestPreVote(rpc RPC, req *RequestPreVoteRequest) {
    defer metrics.MeasureSince([]string{"raft", "rpc", "requestVote"}, time.Now())
    //                                                    ^^^^^^^^^^^ should be "requestPreVote"
```

**Verification status**: **Confirmed bug** (copy-paste error)

**Assessment**: Confirmed bug (Low, only affects metrics)

---

#### Finding 16: requestPreVote missing len(req.ID) > 0 guard

**Location**: `raft.go:1758`

**Description**: `requestVote` has an `if len(req.ID) > 0` guard before checking candidateID
(backward compatibility with old protocol), but `requestPreVote` does not. Since PreVote only
exists in the new protocol version, this has no practical impact.

**Verification status**: **Code inconsistency confirmed, no practical impact**

**Assessment**: Code inconsistency (Very Low)

---

#### Finding 17: Nodes not supporting PreVote treated as granted

**Location**: `raft.go:2083-2091`

```go
if err != nil && strings.Contains(err.Error(), rpcUnexpectedCommandError) {
    resp.Term = req.Term
    resp.Granted = true
}
```

**Description**: Uses `strings.Contains` for error matching, which is fragile. However, this
is for mixed-version cluster compatibility.

**Verification status**: **Design decision**

**Assessment**: Robustness issue (Low)

---

## 3. Git History Bug Pattern Analysis

### 3.1 Bug Hotspot Files

| File | Change Count | Primary Bug Types |
|------|-------------|-------------------|
| `raft.go` | 36 | State transitions, race conditions, election safety |
| `api.go` | 28 | API interface, Leadership Transfer |
| `replication.go` | 18 | Race conditions, peer state management |
| `configuration.go` | 12 | Configuration change safety |

### 3.2 Historical Bug Classification

| Category | Count | Severity |
|----------|-------|----------|
| Race conditions | 5+ | High |
| Leadership Transfer logic errors | 4 | High |
| Election/voting safety violations | 3 | Critical |
| PreVote implementation bugs | 2 | High |
| Unhandled errors causing panic | 2+ | High |
| Channel notification failures | 2 | Medium |

### 3.3 Notable Historical Bug Fixes

| Commit | Description | Lesson |
|--------|-------------|--------|
| `49bd61b` | `candidateFromLeadershipTransfer` non-atomic access | Leadership Transfer is a race condition hotspot |
| `1a62103` | Peer access races with heartbeat | replication.go concurrency model is complex |
| `d68b78b` | Leadership Transfer flag set timing error | Flag set after goroutine starts |
| `38cb186` | Removed node can still vote | Config change and election interaction is a bug breeding ground |
| `656e6c0` | NonVoter can transition to Candidate | Suffrage concepts expand the state space |
| `6b4e320` | NonVoter high term causes leader step-down | Same as above |
| `497108f` | Leader's own PreVote rejected | Address comparison may fail in certain network environments |
| `42d3446` | Granting PreVote incorrectly updates leader last-contact | PreVote and heartbeat timeout interaction |

---

## 4. GitHub Open Issues and PRs Analysis (individually verified)

### 4.1 Issues Labeled as Bug

| Issue | Description | Open Since | Verification Result |
|-------|-------------|------------|---------------------|
| #275 | Race between `shutdownCh` and `consumerCh` in `inmemPipeline` | 2018 | **Confirmed bug** (only affects test infrastructure, has full reproduction program) |
| #503 | Leader LogStore hang causes entire cluster hang, unable to re-elect | 2022 | **Confirmed bug** (severe, has production reproduction; heartbeat goroutine runs independently of leader main loop, preventing follower timeout elections) |
| #522 | Leader cannot load snapshot, cluster cannot recover | 2022 | **Confirmed bug** (severe, leader cannot send snapshots but does not step down, has production log evidence) |
| #85 | Panic after restoring from old snapshot | 2016 | **Confirmed bug** (snapshot rollback causes log gap, has Gist reproduction test, open nearly 10 years unfixed) |
| #86 | `TrailingLogs=0` crashes after snapshot | 2016 | **Confirmed bug** (boundary condition, confirmed still reproducible in 2024, open 8 years unfixed) |
| #66 | Peer/configuration changes not atomic with log operations | 2015 | **Design issue/uncertain** (minimal description, no reproduction, no comments, may have been mitigated by new config model) |

### 4.2 Unlabeled Issues (individually verified)

| Issue | Description | Verification Result |
|-------|-------------|---------------------|
| #614 | Storage-corrupted node keeps winning elections | **Confirmed bug** — no election penalty after self-demotion, node retains term advantage and wins repeatedly, real production event (lasted 10 minutes) |
| #612 | Replication to follower silently stops (detailed report) | **Confirmed bug** (severe) — pipeline replication path may swallow follower-side StoreLogs failure, no error log on leader side, has production logs and metrics screenshots |
| #611 | Replication stops (brief report) | **Uncertain** — report too brief, no logs/reproduction, may share root cause with #612 |
| #498 | `Apply()` permanently deadlocks when quorum lost | **Confirmed bug** (severe) — `deferError` future's `errCh` is never signaled, independently confirmed by multiple people, still reproducible as of Feb 2025, open 3+ years |
| #634 | LeaderLeaseTimeout may cause unnecessary leader step-down | **Design discussion** — theoretical concern, safe under default config, no concrete reproduction |
| #652 | Impact of LeaderLeaseTimeout shorter than HeartbeatTimeout | **Not a bug** — user misunderstanding of heartbeat mechanism, HashiCorp member explained heartbeat interval is HeartbeatTimeout/10 |
| #472 | Config divergence causes election stuck in Candidate state | **Confirmed bug** (severe) — config divergence between 2 surviving nodes in a 3-node cluster causes permanent inability to elect, confirmed by multiple independent production systems |
| #586 | `max(uint64)` term causes extremely slow elections | **Out of design scope** — requires manual fault injection, non-Byzantine protocol does not handle this scenario, maintainers explicitly stated not a priority |
| #643 | Node identity conflict across clusters | **User error** — two independent clusters sharing the same transport address, Raft does not support this by design |
| #621 | Linearizable read optimization cannot be safely implemented | **Confirmed design deficiency** — library does not expose leader's initial noop commit status, PR #625 proposes fix |
| #549 | Commit index not persisted | **Confirmed design deficiency** — after restart, node cannot replay committed logs, HashiCorp contributor proposed `CommitTrackingLogStore` interface |

### 4.3 Open PRs (individually verified)

| PR | Description | Verification Result |
|----|-------------|---------------------|
| #665 | Fix requestPreVote metrics label | **Our submitted bug fix** |
| #651 | Snapshot RPC error fix | **Real bug fix** (severe) — snapshot transfer size change corrupts connection protocol, subsequent RPC parsing fails |
| #638 | Lower "nothing new to snapshot" log level | **Real bug fix** (log noise) — normal behavior logged as error |
| #625 | Support leadership assertion checks | **Important enhancement** — implements linearizable read precondition per Raft paper Section 8, fixes #621 |
| #613 | Persist commit index in LogStore | **Enhancement** — fixes #549, accelerates restart recovery |
| #588 | Allow shutdown during snapshot transfer | **Real bug fix** — Shutdown() blocks permanently during large snapshot transfers |
| #579 | WIP: Async log writes (leader disk parallel replication) | **Enhancement (WIP)** — Ongaro thesis Section 10.2.1 optimization |
| #571 | Upgrade golang.org/x/sys (CVE) | **Outdated** — superseded by subsequent dependency updates |
| #538 | gRPC transport implementation | **Enhancement (draft)** — 3 years inactive, extremely outdated |
| #518 | Export SkipStartup + add Start() | **Enhancement** — 3.5 years inactive |
| #427 | Make LeaderCh() return new channel each time | **Enhancement** — 5 years inactive |

---

## 5. Deep Verification Results

Thorough verification of high-priority findings from initial analysis:

### 5.1 Eliminated False Positives

| Original Finding | Reason for Elimination |
|-----------------|----------------------|
| "Leadership Transfer candidate receiving same-term AppendEntries without stepping down could lead to two leaders" | `runFollower` loop condition is `for r.getState() == Follower`; after timeoutNow sets state=Candidate, the next loop iteration immediately exits, entering runCandidate. It does not get stuck in runFollower. |
| "AddNonvoter reverses suffrage logic" | By design: AddNonvoter is only for adding new nonvoters or updating existing node addresses. Demotion uses DemoteVoter. API documentation explicitly describes this behavior. |
| "checkLeaderLease may panic due to missing voter in replState" | All configuration updates and replState updates execute synchronously on the main thread (`setLatestConfiguration` and `startStopReplication` called sequentially in `appendConfigurationEntry`), so no inconsistency window exists. |
| "dispatchLogs inflight list double respond" (raft.go:1256) | `respond()` has idempotency protection via `d.responded` at `future.go:125-126`; the second call is a no-op. Even if inflight cleanup calls respond again after StoreLogs failure, no side effects occur. |
| "processConfigurationLogEntry committed semantics" (raft.go:1586) | `configurationChangeChIfStable()` (line 659) restricts to one uncommitted config change at a time. When processing a new config entry, the previous latest is already committed, so promoting it to committed is correct. |

### 5.2 Confirmed Findings (after secondary deep verification, ranked by confidence)

| # | Finding | Confidence | Severity | Detailed Verification Conclusion |
|---|---------|------------|----------|--------------------------------|
| 1 | Metrics label copy-paste error (raft.go:1738) | **Confirmed bug** | Low | "requestVote" should be "requestPreVote". Submitted PR #665 to fix. |
| 2 | lastLog cache incorrect after truncation+StoreLogs failure (raft.go:1540) | **Confirmed (developer TODO)** | Medium-High | `DeleteRange` succeeds then `StoreLogs` fails, lastLog cache points to truncated position. Can cause subsequent PrevLog check errors, inflated commit index. Requires disk failure to trigger. |
| 3 | Heartbeat does not check resp.Term (replication.go:412) | **Confirmed real issue** | Low | `replicateTo` (line 239) and `pipelineDecode` (line 548) both check resp.Term; only heartbeat does not. When cluster is idle, only heartbeat runs, and leader cannot detect higher term via this path. But heartbeat carries no log entries, cannot cause incorrect commit; LeaderLeaseTimeout provides eventual fallback. |
| 4 | timeoutNow has no state guard (raft.go:2210) | **Confirmed real issue** | Moderate | Any node capable of sending RPCs can send TimeoutNow: forces leader step-down, or grants candidate privileged election status (skips PreVote, other nodes vote even with existing leader). Does not trigger under normal operation; defensive programming gap. |
| 5 | nextIndex non-atomic read-write (replication.go:256) | **Confirmed data race** | Medium | `atomic.StoreUint64` reads `s.nextIndex` internally without `atomic.LoadUint64`; data race exists. |
| 6 | EncodeConfiguration panic (configuration.go:352) | **Code behavior confirmed** | Low-Medium | Robustness issue; receiving a corrupted log entry causes node panic. |

---

## 6. Bug Family Analysis and TLA+ Modeling Strategy

By analyzing historical bug fixes, confirmed open issues, and static analysis findings,
we identified **5 bug families**. Each family shares a common root cause pattern and
is associated with historical bugs and newly discovered potential issues.

### 6.1 Family 1: Race Conditions

**Common root cause**: Multiple goroutines concurrently accessing shared state without proper
synchronization.

**Historical bugs**:
- `candidateFromLeadershipTransfer` non-atomic access (commit `49bd61b`) — Leadership Transfer flag readable by other goroutines before being set
- Peer access races with heartbeat (commit `1a62103`) — peer address update concurrent with heartbeat goroutine
- `inmemPipeline` shutdownCh race (#275) — channel operations lack synchronization protection

**New potential issues**:
- **P1-C**: `nextIndex` non-atomic read-write (`replication.go:256`) — `atomic.StoreUint64` reads `s.nextIndex` internally without `atomic.LoadUint64`

**TLA+ modeling insight**: Model shared variable read and write as independent atomic steps in the spec, checking whether interleaving causes nextIndex to regress or skip.

---

### 6.2 Family 2: Leader Cannot Self-Detect Failure (Most Critical)

**Common root cause**: Leader fails to timely detect its own abnormality (storage hang, snapshot
failure, superseded by higher term) and step down, causing cluster unavailability. **This is the
most severe bug root cause pattern in hashicorp/raft production environments.**

**Historical bugs**:
- #503: LogStore hangs -> heartbeat runs independently -> followers don't timeout -> **entire cluster stuck**
- #522: Leader cannot load snapshot but doesn't step down -> **cluster cannot recover**
- #614: Storage-corrupted node self-demotes but has no election penalty, retains term advantage -> **wins elections repeatedly for 10 minutes**

**New potential issues**:
| ID | Description | Code Location | Risk |
|----|-------------|---------------|------|
| P2-A | Heartbeat does not check resp.Term | `replication.go:412` | Delayed leader step-down in idle clusters |
| P2-C | `checkLeaderLease` uses latest config | `raft.go:1049` | May miscalculate lease during config changes |
| P2-D | No stable store health check | Overall design | Leader unaware of its own disk failure |
| P2-E | Snapshot errors silently swallowed | Snapshot-related code | Snapshot failure only logged, no recovery action |

**TLA+ modeling recommendations**:
- Model leader's "liveness obligation": leader must detect its own abnormality and step down within finite steps
- Model heartbeat as **independent from log replication** path (this is the root cause of #503)
- Model LeaderLeaseTimeout as the ultimate step-down mechanism
- Property: `LeaderHealthProperty == [](isLeader(s) /\ ~canReachQuorum(s) => <>~isLeader(s))`

---

### 6.3 Family 3: Configuration Change Safety (Most Complex)

**Common root cause**: Inconsistent use of `committed` and `latest` configurations across
different code paths, combined with interactions between config changes and elections/replication,
creates difficult-to-predict state combinations.

**Historical bugs**:
- Removed node can still vote (commit `38cb186`)
- NonVoter can transition to Candidate (commit `656e6c0`)
- Config divergence causes permanent election deadlock (#472) — config divergence between 2 surviving nodes in 3-node cluster, **permanently unable to elect**
- Peer/configuration changes not atomic with log operations (#66)

**committed vs latest usage inconsistency summary**:

| Function | Config Used | Code Location |
|----------|-------------|---------------|
| Leader step-down check | `committed` | raft.go:798 |
| `quorumSize()` | `latest` | raft.go:1089 |
| `checkLeaderLease()` | `latest` | raft.go:1049 |
| `setupLeaderState` commitment | `latest` | raft.go:458 |
| Vote eligibility check | `latest` | raft.go:1645 |
| `electSelf` vote request scope | `latest` | raft.go:1096 |
| `startStopReplication` | `latest` | raft.go:459 |

**New potential issues**:
| ID | Description | Code Location | Risk |
|----|-------------|---------------|------|
| P3-A | `quorumSize()` uses latest | `raft.go:1089` | Incorrect quorum size during config changes |
| P3-B | `electSelf` uses latest | `raft.go:1096` | Requests votes from uncommitted members |
| P3-C | Follower config commit after truncation | `raft.go:1586` | Truncation may remove config entry but committed config doesn't revert |
| P3-E | `startStopReplication` uses latest | `raft.go:459` | Leader may replicate to uncommitted new members |

**TLA+ modeling recommendations**:
- **Distinguish between `committed` and `latest` configurations** (this is the key differentiator)
- Allow at most one uncommitted config change at a time
- Trigger leader crash during in-progress config changes and re-election
- Cover Voter/NonVoter/Staging suffrage types
- Property: `ElectionSafety == [](\A s1,s2 \in Servers: isLeader(s1) /\ isLeader(s2) /\ sameTerm(s1,s2) => s1 = s2)`
- Property: `ConfigSafety == [](committedConfig # latestConfig => AtMostOneUncommittedChange)`

---

### 6.4 Family 4: Copy-Paste / Incomplete Implementation

**Common root cause**: PreVote functionality implemented by copying RequestVote code, with some
paths missing necessary modifications.

**Historical bugs**:
- Metrics label copy-paste error (submitted PR #665 to fix)
- Granting PreVote incorrectly updates leader last-contact (commit `42d3446`)

**New potential issues**:
| ID | Description | Code Location | Risk |
|----|-------------|---------------|------|
| P4-E | `requestPreVote` address decoding differs from `requestVote` | `raft.go:1736` | Address resolution inconsistency |
| P4-F | `requestPreVote` missing `len(req.ID) > 0` guard | `raft.go:1758` | No practical impact (PreVote only in new protocol) |
| P4-G | `preElectSelf` log message says "requestVote" | Log code | Debugging confusion |

**Analysis**: This family is better suited for code review than formal verification. Can be
found by systematically comparing every line of RequestVote and RequestPreVote.

---

### 6.5 Family 5: Error Handling Gaps

**Common root cause**: Incomplete recovery paths after disk write/read failures, leaving
intermediate state inconsistent.

**Historical bugs**:
- Panic after restoring from old snapshot (#85) — open nearly 10 years unfixed
- `TrailingLogs=0` crashes after snapshot (#86) — open 8 years unfixed

**New potential issues**:
| ID | Description | Code Location | Risk |
|----|-------------|---------------|------|
| P5-B | `persistVote` non-atomic | `raft.go:1135-1141` | Writes term then candidate; crash between leaves inconsistent state |
| P5-D | `installSnapshot` doesn't update lastLog cache | `raft.go:1815+` | lastLog points to old value after snapshot install |
| P5-E | Truncation + StoreLogs failure | `raft.go:1540` | Confirmed (developer TODO), lastLog cache stale |
| P5-F | Configuration decode failure causes panic | `configuration.go:352` | Corrupted log -> node crash |

**TLA+ modeling recommendations**:
- Model crash-recovery scenarios (crash after partial write)
- Insert crashes between the two writes of `persistVote` and between `DeleteRange` and `StoreLogs`
- Property: `CrashRecovery == [](crashed(s) /\ recovered(s) => consistentState(s))`

---

## 7. TLA+ Modeling Priorities

### 7.1 Top Priority: Configuration Change + Election Interaction

**Rationale**: Highest historical bug density (4+ critical bugs), has confirmed unfixed issue (#472),
inconsistent committed vs latest config usage is the most systematic suspicious pattern in the code,
and TLA+ excels at finding this type of state space interaction issue.

**Potential new bugs to discover**: P3-A, P3-B, P3-C, P3-E

### 7.2 Second Priority: Leader Health Detection and Step-Down

**Rationale**: 3 confirmed severe production bugs (#503, #522, #614) share the same root cause
pattern. Heartbeat running independently of log replication is an architectural design choice
whose side effects may have undiscovered issues.

**Potential new bugs to discover**: P2-A, P2-C, P2-D

### 7.3 Third Priority: Crash-Recovery Consistency

**Rationale**: 2 long-standing unfixed bugs (#85, #86), developer-acknowledged lastLog cache
issue (with TODO comment). Crash recovery is a classic application of formal verification.

**Potential new bugs to discover**: P5-B, P5-D, P5-E

---

## 8. Summary

### 8.1 Code Analysis Findings

1. **1 confirmed bug**: Metrics label copy-paste error (submitted PR #665)
2. **1 developer-acknowledged issue**: lastLog cache state error (has TODO comment)
3. **3 real code issues**: Heartbeat term check missing, timeoutNow without state guard, nextIndex data race
4. **5 eliminated false positives**: Ruled out seemingly suspicious but actually safe code paths through deep code verification
5. **14 new potential bug instances**: New suspicious code paths derived from historical bug patterns via bug family analysis

### 8.2 Issue/PR Verification Conclusions

All issues and open PRs mentioned in the report have been individually verified:

- **Confirmed real bug issues**: #275, #503, #522, #85, #86, #614, #612, #498, #472 (9 total)
- **Confirmed design deficiency issues**: #621, #549 (2 total)
- **Ruled out as non-bug issues**: #652 (user misunderstanding), #586 (out of design scope), #643 (user error)
- **Uncertain issues**: #66 (too old), #611 (insufficient report, may share root cause with #612), #634 (theoretical discussion)
- **Noteworthy open PRs**: #651 (snapshot RPC corruption fix), #625 (linearizable read API), #588 (shutdown blocking fix)

### 8.3 Bug Families and TLA+ Strategy

| Family | Historical Bug Count | New Potential Instances | TLA+ Priority | Key Modeling Differentiator |
|--------|---------------------|----------------------|---------------|---------------------------|
| Race conditions | 3 | 1 | Low | Requires modeling fine-grained concurrent steps |
| Leader self-detection failure | 3 | 4 | **High** | Requires modeling independent heartbeat path |
| Configuration change safety | 4 | 4 | **Highest** | Requires distinguishing committed/latest config |
| Copy-paste | 2 | 3 | Low | Better suited for code review |
| Error handling gaps | 2 | 4 | **High** | Requires modeling crash-recovery |

### 8.4 Recommended Next Steps

**TLA+ modeling**: Start with "configuration change + election interaction", distinguishing
between committed and latest configurations, triggering leader failure during in-progress config
changes and re-election, focusing on Election Safety and Log Matching properties.

**Code fix PR targets**:
1. `Apply()` deadlock (#498) — long-standing unresolved, confirmed by multiple people, severe impact
2. Heartbeat resp.Term check missing — one-line code fix, clear impact
3. `preElectSelf` log message copy-paste error — same category as PR #665
