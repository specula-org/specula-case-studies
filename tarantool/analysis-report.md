# Code Analysis Report: tarantool/tarantool Raft Consensus

## 1. Coverage Statistics

| Metric | Count |
|--------|-------|
| Total raft-related commits | 102 |
| Bug-fix commits analyzed | 34 |
| Critical severity | 7 |
| High severity | 17 |
| Medium severity | 8 |
| Low severity | 2 |
| GitHub issues found (unique) | 98 |
| Issues deeply read (full thread) | 15 |
| Confirmed bugs | 12 |
| Design defects | 2 |
| User error / false positive | 1 |
| Open raft bugs | ~18 |
| Core files deeply analyzed | 4 (raft.c, raft.h, box/raft.c, box/raft.h) |
| Code-level findings | 21 |

---

## 2. System Architecture

### 2.1 Overview

Tarantool's Raft implementation is an **election-only** Raft engine (~2200 LOC core). Log replication is handled separately by Tarantool's native replication subsystem. The system uses **vclocks** (vector clocks) instead of a single log index for vote eligibility comparison.

### 2.2 Core Files

| File | Lines | Purpose |
|------|-------|---------|
| `src/lib/raft/raft.c` | 1431 | Core state machine, election logic |
| `src/lib/raft/raft.h` | 454 | Struct definitions, public API |
| `src/box/raft.c` | 746 | Tarantool integration (fencing, worker fiber, WAL) |
| `src/box/raft.h` | 176 | Box-layer public API |

### 2.3 Key Architectural Decisions

1. **Election-only**: Core Raft handles leader election only; log replication is orthogonal.
2. **Vclock-based**: Full vector clock comparison for vote eligibility (not single log index).
3. **Dual state tracking**: Volatile state (`volatile_term`, `volatile_vote`) separated from persisted state (`term`, `vote`). Volatile state used for decisions; persisted state used for broadcasts.
4. **Leader witness map**: Bitmap tracking which peers see the current leader (implicit pre-vote).
5. **Cooperative fibers**: Single-threaded state machine + separate worker fiber for async I/O.
6. **WAL write blocking**: State machine is "frozen" as FOLLOWER during WAL writes.

### 2.4 Concurrency Model

- **Main fiber**: All state machine logic runs synchronously (no yields), enforced by `csw` assertions.
- **Worker fiber** (`box_raft_worker_f`): Handles WAL writes and broadcasts. Can yield during I/O.
- **Coordination**: State machine sets flags (`is_write_in_progress`, `is_broadcast_scheduled`); worker processes them.
- **No locks**: Cooperative fiber model eliminates need for mutexes. Yield points are the concurrency boundaries.

---

## 3. Bug-Fix Commit Analysis

### 3.1 Complete Bug-Fix Commit Table

| # | Commit | Summary | Root Cause | Component | Severity | Issue |
|---|--------|---------|------------|-----------|----------|-------|
| 1 | `6b43f1031` | New candidate should wait for leader death | Candidate configured via election_mode didn't monitor leader health | box/raft.c | High | #5339 |
| 2 | `f85e886e9` | Crash when leader resigned | Voter/disabled nodes tried to start election on leader resign | box/raft.c | Critical | #5426 |
| 3 | `d4de0ed17` | Assertion on transition to voter | Death timer not stopped when transitioning candidate→voter | box/raft.c | High | #5426 |
| 4 | `03512e53b` | Crash in worker fiber | Yield between checking for work and sleeping caused assertion | box/raft.c | Critical | — |
| 5 | `b4c4387d5` | Crash on restart during WAL write | Re-enabling raft during pending WAL write hit assertion | box/raft.c | High | #5506 |
| 6 | `9a8688fad` | Crash on candidate cfg during WAL write | Wrong if-condition ordering: WAL write checked last instead of first | box/raft.c | High | #5506 |
| 7 | `2f5522ddb` | Crash on term=0 message | assert(req->term != 0) hit in debug builds | raft.c | Medium | #5303 |
| 8 | `3fe5367c8` | Bad state not fully validated | Invalid state value could still bump term | raft.c | Medium | #5303 |
| 9 | `ad7133994` | Crash on election timeout decrease | Negative timeout passed to libev | raft.c | High | #5303 |
| 10 | `4042b5c09` | Crash on death timeout decrease | Same as above for death timeout | raft.c | High | #5303 |
| 11 | `e51c61ae1` | ev_timer.at incorrect usage | Used as original value, but becomes deadline after start | raft.c | High | — |
| 12 | `82757e55e` | Crash on election_timeout reconfig during WAL write | Missing `!is_write_in_progress` guard for timer | raft.c | High | — |
| 13 | `3a1c7b782` | Timer active check wrong for 0-timeout | libev makes 0-timeout+0-repeat timer inactive but pending | raft.c | High | #6847 |
| 14 | `2afde5b1d` | **Spurious split-vote detection** | **Typo**: `raft_add_vote(raft, self, self)` instead of `(raft, self, candidate)` | raft.c | High | #8698 |
| 15 | `5765fdc4e` | Manual nodes bump term excessively | Used `is_candidate` where `is_cfg_candidate` was needed | raft.c | Medium | #8168 |
| 16 | `df6cf5ec6` | Assertion in raft_stop_candidate | Timer not always running when leader seen (WAL write in progress) | raft.c | Medium | #8169 |
| 17 | `352fe0c7d` | promote() hang without quorum | Manual nodes didn't transition back to follower on timeout | raft.c + box/raft.c | High | #8217 |
| 18 | `dd89c57e7` | **Infinite elections with multi-promote** | Retry loop in promote caused infinite term bumps | box/raft.c | Critical | — |
| 19 | `ab08dad95` | Promote hang when node becomes non-candidate | Wait trigger checked `is_enabled` not `is_candidate` | box/raft.c | High | — |
| 20 | `c9155ac86` | **Split-brain: foreign term+vote with pending txns** | Vote applied before pending writes updated vclock | raft.c | Critical | #7253 |
| 21 | `8a124e502` | Self-vote split from term increases split-vote | Broadcasting new term without vote caused others to self-vote | raft.c | Medium | #8497 |
| 22 | `17371215c` | Promote didn't vote for self immediately | Node didn't appear as candidate after promote | raft.c | Medium | #8497 |
| 23 | `ebe4cd9bd` | Assertion in box_promote_qsync | Concurrent promote hit false `!is_in_box_promote` assertion | box/raft.c | High | #9263 |
| 24 | `05d03a1c5` | Demoted leader re-elects itself | After demote, saw no votes, voted for self, won immediately | box/raft.c | High | #9855 |
| 25 | `02920c041` | Promote hang (leader-seen from follower) | Follower's is_leader_seen blocked candidate with no leader connection | box/raft.c | High | #10836 |
| 26 | `d4f9c9c99` | Promote crash (quorum loss+regain) | Error checks failed after is_candidate toggled during promote | box/raft.c | Critical | #10836 |
| 27 | `214b54ce7` | **Election deadlock with election_mode=off** | Disabled nodes reported stale is_leader_seen=true | raft.c | Critical | #12018 |
| 28 | `b59284539` | Concurrent promote crash | Racing promote calls corrupted diag state | box/raft.c | Critical | #11703 |
| 29 | `08a836b17` | Leader resign during WAL write | Candidate saw leader=0 after WAL, started futile election | box/raft.c | Medium | #6129 |
| 30 | `7b8357674` | Panic on invalid state field | unreachable() only active in debug; changed to panic() | raft.c | Medium | #6067 |
| 31 | `0e71be2e6` | **Leader doesn't step off on WAL IO error** | Heartbeats continued despite disk failure | box/raft.c | High | #9399 |
| 32 | `6e6b17208` | Format string mismatch in logging | %u for uint64_t | raft.c | Low | #5846 |
| 33 | `d25ecab48` | Compilation warning | Missing cast | box/raft.c | Low | — |

### 3.2 Bug Hotspot Analysis

| Component | Bug Count | Critical+High |
|-----------|-----------|---------------|
| WAL write interactions | 8 | 6 |
| Promote/demote | 8 | 7 |
| Timer management | 4 | 3 |
| Leader witness map | 3 | 3 |
| Term/vote persistence | 4 | 2 |
| Message validation | 3 | 0 |

---

## 4. GitHub Issue Analysis

### 4.1 Critical Issues Deeply Read

| Issue | Title | State | Classification | Component |
|-------|-------|-------|---------------|-----------|
| #7253 | Old leader confirms data not on new leader | CLOSED | **Confirmed bug** (Critical safety) | Election + Synchro |
| #8497 | Write term and vote atomically during promote | CLOSED | **Confirmed bug** | WAL persistence |
| #12018 | Elections never start with election_mode=off member | CLOSED | **Confirmed bug** (Critical liveness) | Witness map |
| #7512 | Followers don't notice leader hang | CLOSED | **Design defect** | Fencing |
| #10836 | Hang/crash in box.ctl.promote() | CLOSED | **Confirmed bug** | Promote |
| #12292 | Leader doesn't detect read-only disk | **OPEN** | **Confirmed bug** | Fencing |
| #12076 | Promote stuck when synchro queue empties | **OPEN** | **Confirmed bug** | Promote |
| #8095 | PROMOTE not guaranteed on new leader | **OPEN** | **Design defect** | Promote + Repl. |
| #9376 | Premature limbo flush during promote | **OPEN** | **Confirmed bug** | Limbo |
| #6245 | Infinite election (network partition) | CLOSED | **Confirmed bug** | Election |
| #8168 | promote() bumps term twice | CLOSED | **Confirmed bug** | Promote |
| #11938 | Assertion after anon→normal transition | CLOSED | **Confirmed bug** | Raft config |
| #11598 | Crash in box_raft_worker_f | CLOSED | **Confirmed bug** | Worker fiber |
| #5229 | Dirty reads of uncommitted sync txns | CLOSED | **Design defect** (fixed via MVCC) | Synchro |
| #9935 | Data inconsistency (split brain report) | CLOSED | **User error** | — |

### 4.2 Open Issues of Note

- **#12292**: Leader doesn't detect read-only disk → phantom writes lost on restart
- **#12076**: Promote stuck when synchro queue empties → indefinite hang
- **#8095**: PROMOTE not guaranteed on new leader → split-brain window
- **#9376**: Premature limbo flush during promote
- **#11423**: Raft timer assertion found via simulation testing

---

## 5. Deep Code Analysis Findings

### Finding 1: Stale witness bits survive term bumps (raft.c:527-531)

**Severity**: High | **Model-checkable**: Yes

In `raft_process_msg`, `raft_process_term` (line 528) is called before `raft_notify_is_leader_seen` (line 531). If the incoming message has a higher term, `raft_sm_schedule_new_term` clears `leader_witness_map = 0` (line 909). Then `raft_notify_is_leader_seen` immediately re-sets the source's witness bit if `req->is_leader_seen == true` — but this refers to the OLD term's leader. The new term has `leader == 0`, yet `leader_witness_map != 0`, blocking elections at line 346.

The stale bit persists until the remote node sends an updated message with `is_leader_seen=false` (requires the remote to also process the term bump and clear its own leader state). Delay: up to one `death_timeout` period. If the remote is unreachable, this is a permanent election deadlock.

**Fixed case**: #12018 fixed the specific case of `election_mode=off` nodes. The general ordering issue for enabled nodes remains.

### Finding 2: Leader resignation only clears self witness bit (raft.c:605-627)

**Severity**: Medium | **Model-checkable**: Yes

When a leader resigns (sends `state != RAFT_STATE_LEADER`), the handler at line 615 only clears the self bit: `bit_clear(&raft->leader_witness_map, raft->self)`. Remote peers' witness bits persist. For `is_cfg_candidate` nodes, `raft_sm_schedule_new_election` is called (line 625), which bumps the term and clears all bits. But for non-cfg-candidate nodes, stale remote bits survive and there's no path to clear them within the current term.

### Finding 3: Conflicting leader detection is a no-op (raft.c:633-642)

**Severity**: Critical (latent) | **Code-review-only**

When two leaders are detected in the same term, the node logs a warning and does nothing:
```c
/* XXX: A message from a conflicting leader. Split brain, basically.
 * Need to decide what to do. Current solution is to do nothing. */
```

### Finding 4: Heartbeat during WAL write extends effective death timeout (raft.c:678-680)

**Severity**: Medium | **Model-checkable**: Yes

`raft_process_heartbeat` updates `leader_last_seen` but returns early during WAL writes without resetting the timer. When the WAL write completes, `raft_sm_wait_leader_dead` starts a fresh `death_timeout` from that point. Effective death timeout = `death_timeout + WAL_write_duration`.

### Finding 5: `raft_sm_follow_leader` doesn't revoke pending volatile vote (raft.c:854-868)

**Severity**: Medium | **Model-checkable**: Yes

When a leader is discovered, `raft_sm_follow_leader` does not revoke a pending `volatile_vote` for a different candidate. The vote will still be persisted when the WAL write completes. The `raft_worker_handle_io` completion logic (line 715) handles this by checking for a known leader first, but the unnecessary vote write wastes WAL bandwidth and creates a window where the node has voted for a candidate while following a leader.

### Finding 6: `raft_cfg_election_quorum` can trigger become_leader during WAL write (raft.c:1258-1269)

**Severity**: High | **Model-checkable**: Yes

`raft_cfg_election_quorum` checks `state == RAFT_STATE_CANDIDATE` and calls `raft_sm_become_leader` if votes suffice. But it does NOT check `is_write_in_progress`. `raft_sm_become_leader` asserts `!is_write_in_progress` (line 846). If a quorum config change happens during a WAL write when the node has already transitioned to CANDIDATE state, this assertion fails. In practice, the node should be FOLLOWER during WAL writes (asserted at line 704), but the transition to CANDIDATE happens inside `raft_worker_handle_io` at line 724 after the WAL write completes — before `is_write_in_progress` is cleared (it's cleared at line 709 via `goto end_dump`). So the assertion should hold. However, if `raft_cfg_election_quorum` is called re-entrantly during the `raft_schedule_broadcast` call at line 884 (inside `raft_sm_become_candidate`), it could fire before the timer is set up.

### Finding 7: Recovery doesn't validate term/vote consistency (raft.c:422-453)

**Severity**: Medium | **Code-review-only**

`raft_process_recovery` applies term and vote independently. Out-of-order or corrupted WAL entries could set `vote = X` with `term = T+1` where X was voted for in term T.

### Finding 8: Multi-pass WAL write pattern (raft.c:737-795)

**Severity**: Medium | **Model-checkable**: Yes

The WAL write logic at `raft_worker_handle_io` deliberately splits term and vote persistence. When `volatile_term > term` and a foreign vote is pending, the term is written first (line 771-772) without the vote (goto `do_dump` at line 760). Only after the term is persisted does the vote eligibility get re-checked against the now-updated vclock. This is the fix for #7253 (split-brain). If the vclock comparison fails, `raft_revoke_vote` is called. Correct but intricate — the multi-pass pattern is the core mechanism preventing the historical split-brain bug.

### Finding 9: WAL write failure is fatal (box/raft.c:443-449)

**Severity**: Medium | **Code-review-only**

Any WAL write failure panics the process. The XXX comment acknowledges this is a stub.

### Finding 10: SOFT vs STRICT fencing not differentiated (box/raft.c:297-308)

**Severity**: Low | **Code-review-only**

Both `ELECTION_FENCING_MODE_SOFT` and `ELECTION_FENCING_MODE_STRICT` call `raft_resign()` identically. The timing differentiation relies entirely on the health monitoring layer.

### Finding 11: `box_raft_update_synchro_queue` silently drops non-retriable errors (box/raft.c:133-147)

**Severity**: Medium | **Code-review-only**

Errors from `box_promote_qsync` other than `ER_QUORUM_WAIT` or `ER_IN_ANOTHER_PROMOTE` are logged but not retried. The new leader becomes elected but unable to process synchronous transactions.

---

## 6. Bug Family Analysis

### Family 1: Leader Witness Map Election Blocking

**Mechanism**: Stale `is_leader_seen` witness bits in the `leader_witness_map` prevent elections by blocking `raft_sm_election_update` (line 346: `if (raft->leader_witness_map != 0) return`).

**Evidence**:
- Historical: #12018 (Critical, FIXED) — disabled nodes report stale is_leader_seen=true
- Historical: #7512 (High, FIXED) — relay heartbeats continue when TX thread hung
- Code: raft.c:527-531 — witness bits set AFTER term bump clears them (ordering issue)
- Code: raft.c:605-627 — leader resignation only clears self bit, remote bits survive
- Code: raft.c:489-501 — `raft_leader_resign` doesn't clear remote witness bits

**Affected code paths**:
- `raft_process_msg` → `raft_process_term` → `raft_notify_is_leader_seen` (lines 527-531)
- `raft_sm_election_update_cb` (line 978: only clears self bit)
- `raft_sm_election_update` (line 346: blocks on any non-zero bit)
- Leader resignation handler (line 615: only clears self bit)

**Assessment**: 3+ historical bugs, 1 remaining code-level concern (ordering). The witness map is the gate for all elections — any stale bit causes liveness failure. **High priority for TLA+ modeling**.

---

### Family 2: WAL Write In-Progress State Machine Fragility

**Mechanism**: During WAL writes, the state machine is "frozen" as FOLLOWER, but external events (heartbeats, configuration changes, leader announcements, messages) are partially processed, leaving state inconsistent or hitting assertions.

**Evidence**:
- Historical: #5506 (2 crashes) — candidate cfg and restart during WAL write
- Historical: commit 03512e53b (Critical) — worker fiber yield race
- Historical: commit 82757e55e (High) — election_timeout reconfig during WAL write
- Historical: commit df6cf5ec6 (Medium) — assertion in raft_stop_candidate during WAL write
- Historical: commit 08a836b17 (Medium) — leader resign during WAL write
- Code: raft.c:678-680 — heartbeat during WAL write extends effective death timeout
- Code: raft.c:854-868 — follow_leader doesn't revoke pending volatile vote
- Code: raft.c:1258-1269 — quorum config change during WAL write

**Affected code paths**:
- `raft_worker_handle_io` (lines 700-796) — multi-pass WAL write with state transitions
- `raft_process_heartbeat` (lines 678-680) — partial processing during write
- `raft_sm_follow_leader` (lines 862-865) — conditional timer management during write
- `raft_cfg_election_quorum` (lines 1264-1266) — no is_write_in_progress guard

**Assessment**: 6+ historical bugs (4 Critical/High). The WAL write "freeze" is the source of the most complex state machine interactions. The dual volatile/persisted state pattern is unique and error-prone. **High priority for TLA+ modeling** — the split between volatile and persisted state is a natural TLA+ modeling target.

---

### Family 3: Non-Atomic Term/Vote Persistence

**Mechanism**: Term and vote are persisted as separate WAL entries. A crash between them, or stale vclock during persistence, can violate Raft's one-vote-per-term invariant.

**Evidence**:
- Historical: #7253 (Critical) — old leader confirms data not on new leader (vclock stale during vote)
- Historical: #8497 (Fixed) — term+vote non-atomic, crash could cause double vote
- Historical: commit c9155ac86 — split-brain via persisting foreign term+vote with pending txns
- Historical: commit 8a124e502 — self-vote split from term increases split-vote probability
- Code: raft.c:759-760 — vote deliberately deferred when volatile_term > term
- Code: raft.c:422-453 — recovery doesn't validate term/vote consistency
- Open: #8095 — PROMOTE not guaranteed on new leader

**Affected code paths**:
- `raft_worker_handle_io` (lines 737-795) — multi-pass WAL write
- `raft_process_recovery` (lines 422-453) — independent term/vote application
- `raft_sm_schedule_new_term` + `raft_sm_schedule_new_vote` (separate calls)

**Assessment**: 4 historical bugs including a Critical split-brain (#7253). The current multi-pass WAL write pattern is the FIX for #7253, making it load-bearing code that must be modeled precisely. **High priority for TLA+ modeling** — crash recovery with split persistence is a classic TLA+ strength.

---

### Family 4: Promote/Demote Race Conditions

**Mechanism**: `box.ctl.promote()` interacts unsafely with concurrent elections, quorum changes, worker fiber state, and repeated invocations.

**Evidence**:
- Historical: 8 bug-fix commits (7 Critical/High)
- Historical: #10836, #8168, #8217, #9855, #9263, #11703 — all fixed
- Open: #12076 — promote stuck when synchro queue empties
- Open: #8095 — PROMOTE not guaranteed on new leader
- Code: raft.c:1212-1220 — promote doesn't guard against is_write_in_progress

**Assessment**: The most bug-dense area (8 historical bugs), but most are fixed. The remaining open issues (#12076, #8095) involve the synchro queue interaction, which is outside core Raft election scope. **Medium priority** — model the promote-as-election-trigger, but the synchro queue interaction is out of scope.

---

### Family 5: Fencing / Leader Health Detection

**Mechanism**: Leader fails to detect its own abnormality (disk failure, TX thread hang) and continues appearing alive to followers.

**Evidence**:
- Historical: #7512 (Fixed) — relay heartbeats mask TX thread hang
- Historical: #9399 (Fixed) — leader doesn't step off on WAL IO error
- Open: #12292 — leader doesn't detect read-only disk (page cache masks failure)
- Code: box/raft.c:297-308 — SOFT vs STRICT fencing not differentiated in implementation

**Assessment**: Important for production safety but mostly outside core Raft protocol scope. The relay/TX thread separation is architectural. **Low priority for TLA+ modeling** of core election protocol.

---

## 7. Existing TLA+ Spec Gap Analysis

The Tarantool team has a WIP TLA+ specification at `proofs/tla/wip/raft.tla` (350 lines). Key gaps:

| Feature | In Spec? | Notes |
|---------|----------|-------|
| Election (term bump, vote, leader) | Yes | Core election modeled |
| Volatile vs persisted state | Yes | `volatileTerm`/`volatileVote` vs `term`/`vote` |
| WAL write async pattern | Partial | `RaftWorkerHandleIo` exists but blocking not modeled |
| Leader witness map | **No** | Comment says "not needed in TLA" — contradicted by #12018 |
| Crash recovery | **No** | Listed as follow-up |
| Message loss / partition | **No** | Reliable ordered queues only |
| Election safety invariant | **No** | No invariants defined on raft module |
| Leader completeness | **No** | No invariants |
| Fencing | **No** | Not modeled |
| Promote/demote | Partial | `LimboPromoteQsync` exists |
| Heartbeat handling | **No** | No heartbeat action |
| Configuration changes | **No** | Listed as follow-up |

**Critical gap**: The existing spec has **zero invariants** checked on the Raft module. The WIP top-level composition (`tarantool.tla`) has syntax errors that prevent it from running.

---

## 8. Cross-Reference Summary

| Bug Family | Historical Bugs | Open Issues | Code Findings | TLA+ Coverage | Priority |
|-----------|-----------------|-------------|---------------|---------------|----------|
| 1. Witness map blocking | 3 | 0 | 3 | None | **High** |
| 2. WAL write fragility | 6 | 0 | 3 | Partial | **High** |
| 3. Non-atomic persistence | 4 | 2 | 3 | Partial | **High** |
| 4. Promote/demote races | 8 | 2 | 1 | Partial | Medium |
| 5. Fencing / leader health | 3 | 1 | 1 | None | Low |
