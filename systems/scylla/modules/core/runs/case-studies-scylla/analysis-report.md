# Analysis Report: scylladb/scylla Raft Library

## 1. Codebase Reconnaissance

### 1.1 Core Modules

| Component | File | LOC | Purpose |
|-----------|------|-----|---------|
| State machine (FSM) | `raft/fsm.cc` + `fsm.hh` | 1847 | Core Raft protocol logic: elections, replication, commit, snapshots |
| Server wrapper | `raft/server.cc` + `server.hh` | 2274 | Async I/O, persistence orchestration, client API |
| Follower tracking | `raft/tracker.cc` + `tracker.hh` | 513 | Match/next index management, quorum calculation, vote tallying |
| Log management | `raft/log.cc` + `log.hh` | 515 | In-memory log, truncation, snapshot application, config tracking |
| Types & interfaces | `raft/raft.hh` + `raft.cc` | 886 | RPC types, persistence/RPC/SM interfaces, configuration |
| Logical clock | `raft/logical_clock.hh` | 56 | Tick-based logical time for election timeouts |
| **Total** | | **~6100** | |

### 1.2 Architecture

ScyllaDB's Raft is a **pure in-memory state machine** with a `step(message)` / `get_output()` API. The FSM is deterministic; all I/O is pushed to the `server_impl` wrapper.

**Two-fiber design:**
- `io_fiber`: polls `fsm::get_output()`, persists term/vote/entries/snapshots, sends messages, notifies commit waiters
- `applier_fiber`: applies committed entries to the state machine, takes snapshots

**Shared failure detector:** Instead of per-group heartbeats, ScyllaDB uses an external `failure_detector::is_alive()` call (raft.hh:808-815). Leaders check follower liveness via the FD during `tick_leader()` for activity tracking, and followers suppress elections when `has_stable_leader()` returns true based on FD state.

### 1.3 Concurrency Model

Seastar-based: single-threaded per core, cooperative scheduling. No locks or mutexes. Interleaving only at `co_await` yield points. The FSM itself (`fsm.cc`) is fully synchronous — no yield points within any FSM method. All async operations happen in `server.cc` (`io_fiber`, `applier_fiber`).

### 1.4 Key Raft Extensions

- **PreVote** (configurable via `enable_prevoting`)
- **Joint consensus** for configuration changes (C_old + C_new → C_new two-phase)
- **Read barriers** via `read_quorum` messages (quorum-based read index)
- **Leadership transfer** via `timeout_now` message
- **Shared failure detector** (replaces per-group heartbeats)
- **Entry forwarding** from followers to leader (configurable via `enable_forwarding`)

## 2. Bug Archaeology

### 2.1 Coverage Statistics

- **Git commits analyzed**: 43 significant bug-fix commits touching `raft/`
- **GitHub issues deeply read**: 20 issues with full comment threads
- **GitHub PRs reviewed**: 10+ PRs with fix intent
- **Confirmed bugs**: 40+
- **Excluded as false positive / non-raft-core**: ~15 issues (topology coordinator, schema management, persistence layer)

### 2.2 Bug-Fix Commits by Severity

| Severity | Count | Examples |
|----------|-------|---------|
| Critical | 8 | Commit index over-advancement, election deadlocks, persistence corruption |
| High | 20 | Use-after-free, race conditions, config change hangs, assertion failures |
| Medium | 11 | Snapshot leaks, retry loops, abort handling, crash on unexpected input |
| Low | 4 | Off-by-one timeout, unnecessary packets, dead code |

### 2.3 Bug-Fix Commits by Component

| Component | Bug Count | Key Issues |
|-----------|-----------|-----------|
| Election | 8 | Timer reset, disruptive candidate, prevote, sticky leadership, voters(), empty log term |
| Replication | 8 | Commit index advancement (×2), log matching, use-after-free (×2), stray rejects |
| Snapshot | 8 | Persistence truncation, race with commits, transfer condition, local detection, leak |
| Configuration | 7 | can_vote joint, RPC setup, config entries in output, modify_config variants |
| Server lifecycle | 5 | Shutdown deadlock, waiter race, applier abort, new waiters after abort |
| Read barrier | 3 | Commit_idx safety, abort handling, commit_idx optimization |

### 2.4 Complete Bug-Fix Commit List

#### Critical Severity

1. **`bce8cb11a7`** — Missing election timer reset on vote grant. Server granting vote could immediately become candidate, disrupting the newly elected leader. Permanent unavailability.
2. **`5c8092cf42`** — Election deadlock with disruptive candidate. Without prevote, a rejoining node disrupts the leader, but followers reject both candidates' votes. 4+ node clusters stuck permanently.
3. **`a59779155f`** (#9552) — Leader re-sends entries inside follower's snapshot, follower rejects them, reply lost → replication stuck forever.
4. **`bdf7d1a411`** (#9551) — Remote snapshots used non-zero trailing for persistence truncation. Stale entries corrupt state after restart.
5. **`1216f39977`** (#9965) — Follower advances commit index beyond matched entries. Safety violation: inconsistent state machines.
6. **`1eb849c3d7`** (#10578) — Same commit-index over-advancement via read_quorum messages. Safety violation.
7. **`f31f73b1e8`** (#10618) — `voters()` set construction with duplicates → undefined behavior → voter excluded → cluster unavailable.
8. **`bf823e34a4`** — Sticky leadership rule + shared FD → removed servers block elections → cluster unavailable.

#### High Severity (selected)

9. **`532343f09e`** — Missing leader identity tracking when AppendEntries arrives with matching term but no known leader.
10. **`dfcd56736b`** — Stale semaphore units after leader term change across yield point in `add_entry_on_leader`.
11. **`88a6e2446d`** (#9550) — Race between snapshot application and commit notification across fibers.
12. **`bd168d57ff`** — PreVote reply registered as real vote.
13. **`8f64a6d2d2`** — `can_vote()` returned from `current` config without checking `previous` config in joint config.
14. **`b3cb4f3966`** — Quorum check for joint config ignored voter status and dual-majority.
15. **`888b52dea1`** — Leader not replicating when it's removed from current config.
16. **`32d386d0d8`** / **`adc87aa278`** — Use-after-free in `append_entries_reply()` after config change.
17. **`4c95277619`** — Stray reject assertion failure on slow networks.
18. **`db2a3deda1`** (#11235) — io_fiber and applier_fiber racing to resolve waiters.
19. **`c8237d405e`** — Deadlock on shutdown: RPC abort waited for read barriers, read barriers waited for RPC.
20. **`28b5792481`** (#9981) — Follower forwarding config change that removes itself waits forever.

### 2.5 Developer Signals (TODO/FIXME/HACK)

1. `tracker.cc:82` — `FIXME: make it smarter` — Pipeline flow control is simplistic.
2. `server.cc:581` — `FIXME: replace this with a different exception type` — `commit_status_unknown` used when entry is actually committed.
3. `fsm.cc:344` — `TODO: avoid copies by making sure log truncate is copy-on-write` — Log entries copied before persistence to avoid race with truncation.
4. `fsm.cc:757` — `FIXME: make it more efficient` — Reject handling backoff could be smarter.

### 2.6 Open Issues

- **#26189** (HIGH) — `add_entry` can span multiple terms. Between memory permit and actual add, leadership can change. Breaks linearizability for conditional writes.
- **#9956** (LOW) — Snapshot application after snapshot dropped. Currently benign by lucky ordering.
- **#16817** (LOW) — `store_snapshot_descriptor` doesn't account for `max_trailing_bytes`.
- **#23816** (MEDIUM) — Use-after-free in `applier_fiber` / `handle_background_error`.

## 3. Deep Analysis Findings

### 3.1 Election and Voting

**PreVote vs Real Vote consistency**: Both paths use identical `is_up_to_date` checks (log.cc:47-54). PreVote doesn't update term/vote/election timer. Transition from prevote win to real vote is safe. The `state.is_prevote != reply.is_prevote` guard (fsm.cc:840) prevents cross-counting.

**Term management**: `update_current_term()` atomically clears `_voted_for` (fsm.cc:147). A server cannot vote for two different candidates in the same term.

**`ignore_term` for prevotes**: Correctly handles all edge cases:
- Prevote request with higher term → ignore (don't advance term on prevote)
- Granted prevote reply with higher term → ignore (it's our own future term echoed back)
- Rejected prevote reply with higher term → don't ignore (step down, the rejector's term is genuine)

**Dead `force` flag**: `vote_request::force` (raft.hh:408) is set during leadership transfer but never read by the receiver's `request_vote()` handler. The disruptive server check it was designed to bypass was removed. This is dead code, not a bug.

**Leader stepdown via failure detector**: `tick_leader()` counts alive followers via `failure_detector.is_alive()` rather than actual AppendEntries responses. A stale FD could delay stepdown but cannot cause safety violations — commit still requires actual message exchange.

### 3.2 Replication and Commit

**AppendEntries follower handling**: Correctly clamps commit advancement to `min(leader_commit_idx, last_new_idx)` (fsm.cc:667). For heartbeats, `last_new_idx = prev_log_idx`, which is conservative and correct.

**Out-of-order reply handling**: `follower_progress::accepted()` uses `std::max` (tracker.hh:67-73), safe for out-of-order replies. In PIPELINE mode, `next_idx` is optimistically advanced; late replies don't regress it.

**Rejected next_idx below snapshot**: Can happen but is handled: `replicate_to()` enters SNAPSHOT mode when `_log.term_for(prev_idx)` returns nullopt (fsm.cc:897).

**"Commit from current term only" rule**: Correctly implemented at fsm.cc:435. New leader's dummy entry (fsm.cc:184) ensures current-term entries are quickly available for commit.

**Pre-persistence stable index advance**: `get_output()` calls `advance_stable_idx` → `maybe_commit()` before entries hit disk. Safe because: (1) committed entries are externalized only in `process_fsm_output()` after `store_log_entries()`; (2) if persistence fails, `io_fiber` stops the server. Relies on crash-stop model.

### 3.3 Configuration Changes

**Overlapping config change guard**: `add_entry<configuration>()` at fsm.cc:74-88 checks `_log.last_conf_idx() > _commit_idx || _log.get_configuration().is_joint()`. Sufficient — covers both uncommitted non-joint and active joint phases. No yield points between joint commit and non-joint append (fsm.cc:455-466).

**Joint quorum calculation**: `tracker::committed()` (tracker.cc:188-202) correctly computes dual-majority and returns `std::min`. Commit index cannot move backwards (guaranteed by `_count` threshold logic).

**New finding — Read barrier stall during voter demotion**: `broadcast_read_quorum()` at fsm.cc:1055 filters by `p.can_vote`, which only reflects the `current` config's voter status. A server being demoted (voter in `previous` but not `current`) won't receive read_quorum requests, yet `tracker::committed<read_id>()` counts it in `_previous_voters`. Read barriers stall until joint config resolves. This is a **liveness bug**, not a safety bug.

**Leader self-removal**: `transfer_leadership(duration(0))` is called from `maybe_commit()` (fsm.cc:498). If the leader is not in the new config, stepdown is not cancelled (fsm.cc:566-568 skips timeout check for non-voters). The leader keeps replicating until a follower catches up and receives `timeout_now`.

### 3.4 Snapshots and Persistence

**Term+vote atomicity**: Single `store_term_and_vote()` call. Persisted first in `process_fsm_output()` (server.cc:1110), before log entries and messages.

**Remote snapshot rejection**: Correctly rejects if `snp.idx <= _commit_idx` (fsm.cc:995). Advancing `_commit_idx` to `snp.idx` is safe because install_snapshot only arrives from a valid leader.

**Trailing entries**: No off-by-one in `log::apply_snapshot()`. The byte-budget loop breaks before including over-budget entries.

**Snapshot + replication**: SNAPSHOT state blocks `can_send_to()` (tracker.cc:87-88). No duplicate entries during snapshot transfer. After transfer, probe/ack self-corrects `next_idx`.

**`process_fsm_output` ordering**: Safe: (1) term+vote, (2) snapshot, (3) log entries, (4) RPC config, (5) messages, (6) committed entries + commit_idx. Crash before commit_idx persistence is handled: commit index is recovered through normal Raft operation (documented as optional at raft.hh:738).

**Applier fiber snapshot lifecycle**: `_applied_idx` captured before `co_await take_snapshot()`. No concurrent modification possible (single fiber). Stale local snapshots rejected by `fsm::apply_snapshot` if a newer remote snapshot arrived.

## 4. Bug Family Synthesis

### Family 1: Commit Index Over-Advancement
- **Mechanism**: Unclamped leader-provided commit index values
- **Historical bugs**: 2 critical (both fixed)
- **New findings**: 0 — both paths now correctly clamped
- **Model priority**: HIGH — the pattern could recur in any new message type carrying commit info

### Family 2: Joint Consensus Quorum Miscalculation
- **Mechanism**: Incorrect voter identification during config transitions
- **Historical bugs**: 3 (critical + high severity)
- **New findings**: 1 — read barrier `can_vote` mismatch (liveness)
- **Model priority**: HIGH — complex state space, error-prone, unfixed liveness issue

### Family 3: Snapshot Lifecycle & Persistence
- **Mechanism**: Complex ordering between snapshot/log/persistence operations
- **Historical bugs**: 6+ (high severity)
- **New findings**: 0 — existing implementation is careful
- **Model priority**: HIGH — crash recovery is classic TLA+ target

### Family 4: Configuration Change Liveness
- **Mechanism**: Self-removal operations hang
- **Historical bugs**: 4 (high severity, all fixed)
- **New findings**: 0
- **Model priority**: MEDIUM — all fixed, good for liveness verification

### Family 5: Election Disruption & FD Dependence
- **Mechanism**: FD staleness affects election/leader liveness
- **Historical bugs**: 3 (critical severity)
- **New findings**: 1 — dead `force` flag (cosmetic)
- **Model priority**: MEDIUM — safety holds regardless of FD accuracy; FD is architectural choice

## 5. Reference Deviations from Raft Paper

| Area | Paper Says | ScyllaDB Does | Risk |
|------|-----------|--------------|------|
| Heartbeats | Leader sends periodic empty AppendEntries | Shared failure detector + targeted heartbeats | FD staleness delays leader detection (liveness only) |
| Disruptive server (§4.2.3) | Don't grant vote if heard from leader recently | Removed — uses PreVote + FD instead | PreVote OFF + FD issues could cause disruption |
| Leader lease | Heartbeat-based contact tracking | FD-based activity tracking | Same as above — FD accuracy matters |
| Vote response | `{term, voteGranted}` | `{term, voteGranted, is_prevote}` | Extension for PreVote; safe |
| Append reply | `{term, success}` | `{term, commit_idx, accepted/rejected{details}}` | Extensions for commit tracking and fast log matching; safe |
| Read semantics | ReadIndex protocol | Read barrier via `read_quorum` messages | Read_quorum is equivalent; commit_idx clamping critical |
