# Modeling Brief: kanal — High-Performance MPMC Channel (Rust)

## 1. System Overview

- **System**: kanal — Rust MPMC channel library with sync and async API
- **Language**: Rust, ~3465 LOC core logic across 8 source files
- **Protocol**: Concurrent bounded/unbounded MPMC channel with mutex-based synchronization and signal-based rendezvous
- **Key architectural choices**:
  - **Single shared mutex** protects all channel state (queue, wait_list, ref counts)
  - **Unified wait_list** holds either send OR recv signals (toggled by `recv_blocking` flag)
  - **KanalPtr inline optimization**: for `T ≤ ptr_size`, data is serialized into pointer storage (zero-copy)
  - **SyncSignal/AsyncSignal**: separate signal types for sync (thread park/unpark) and async (waker) blocking, dispatched via tagged pointer in DynamicSignal
  - **Not cancel-safe**: dropping a ReceiveFuture mid-operation can lose data (documented)
- **Concurrency model**: All state mutations under a single mutex. Blocking happens OUTSIDE the lock via signal wait. Signals are stack-pinned (sync) or future-owned (async).

## 2. Bug Families

### Family 1: Signal Lifecycle Races (HIGH)

**Mechanism**: The signal handoff protocol (push to wait_list under lock → counterpart pops → writes/reads data → signals completion) has tight timing windows. Historical bugs centered on thread handle ownership, waker access ordering, and state transition visibility.

**Evidence**:
- Historical: 7 race condition commits (75960fb, 773a4e7, cb130b6, 774a05f, 73befe0, ddb8452, f615c8c); Issues #2, #8, #11, #14, #15, #17, #19
- Code analysis: `wait()` CAS failure path doesn't handle LOCKED_STARVATION after `wait_timeout()` (signal.rs:217-232). If counterpart is preempted >25μs after popping signal, `wait()` returns `false` prematurely → caller reclaims data → use-after-free / data race

**Affected code paths**: `SyncSignal::write_data/read_data/terminate/wait/wait_timeout` (signal.rs:161-261), `SendFuture::poll/drop`, `ReceiveFuture::poll/drop` (future.rs)

**Suggested modeling approach**:
- Variables: `signalState[Signal]` ∈ {Locked, LockedStarvation, Unlocked, Terminated}, `signalOwner[Signal]` ∈ {WaitList, Sender, Receiver, None}, `dataLocation[Signal]` ∈ {SenderStack, Inline, ReceiverStack, Consumed}
- Actions: `PushSignal` (under lock), `PopSignal` (under lock), `WriteData` (outside lock, changes state), `ReadData` (outside lock), `Terminate`, `Wait`, `WaitTimeout` (CAS to Starvation), `WaitAfterTimeout` (re-enters wait with existing LOCKED_STARVATION)
- Granularity: `WriteData` must be split into two steps: (1) copy data, (2) swap state to Unlocked. The interleaving between steps is where the race window exists.
- Fault injection: `Preempt` action delays the counterpart between PopSignal and WriteData/ReadData

**Priority**: High
**Rationale**: 8+ historical bugs, 1 new potential bug. Root cause of all memory corruption bugs in kanal's history. The LOCKED_STARVATION gap is model-checkable.

---

### Family 2: Async Future Cancellation / Drop (HIGH)

**Mechanism**: When an async future is dropped mid-operation, data ownership is ambiguous between sender, receiver, and channel queue. The drop handler must either cancel (signal still in wait_list) or wait for counterpart. For ReceiveFuture, data may be lost (rendezvous) or pushed back to queue (buffered, potentially exceeding capacity).

**Evidence**:
- Historical: Issues #24, #47, #50, #59; commits cb130b6, de2da0d, f615c8c
- Code analysis: ReceiveFuture::drop push_front can exceed capacity (future.rs:246-249)
- Code analysis: SendManyFuture silently drops error data when elements remain (future.rs:487-495)

**Affected code paths**: `SendFuture::drop` (future.rs:67-93), `ReceiveFuture::drop` (future.rs:218-255), `SendManyFuture::poll` (future.rs:470-583)

**Suggested modeling approach**:
- Variables: `futureState[Future]` ∈ {Unregistered, Pending, Success, Failure, Done}, `dataOwnership[Data]` ∈ {Sender, Channel, Receiver, Lost}
- Actions: `PollSend`, `PollRecv`, `DropSendFuture`, `DropRecvFuture` (non-deterministic cancellation), `CancelSignal` (under lock), `BlockingWait`
- Model `DropRecvFuture` with both rendezvous (data lost) and buffered (push_front) paths
- Invariant: `NoDataLoss` — every sent datum is either received or returned to sender. Check if capacity violation (queue.len > cap) is reachable.

**Priority**: High
**Rationale**: Documented design limitation with real user impact (select! data loss). The capacity violation and SendManyFuture data loss are new findings. Model checking can quantify the data-loss windows.

---

### Family 3: Close Protocol and Half-Close Detection (MEDIUM)

**Mechanism**: Channel close (via `close()` or last sender/receiver drop) must terminate all pending signals and coordinate with in-progress operations. The ref_count protocol (send_count, recv_count, ref_count) manages both half-close detection and memory reclamation.

**Evidence**:
- Historical: Issue #13 (try_recv didn't detect closure), Issue #59 (queue not cleared on recv drop)
- Historical: Commit cb130b6 (missing terminate_signals in Drop), commit 184be1e
- Code analysis: dec_ref_count interleaving with concurrent send/recv (internal.rs:288-306)

**Affected code paths**: `dec_ref_count` (internal.rs:288-306), `close()` (lib.rs:237-247), `terminate_signals()` (internal.rs:162-168)

**Suggested modeling approach**:
- Variables: `sendCount`, `recvCount`, `refCount`, `channelOpen`
- Actions: `CloneSender`, `CloneReceiver`, `DropSender`, `DropReceiver`, `Close`
- `DropSender` when send_count→0: terminate signals, but ONLY if recv_count≠0
- `DropReceiver` when recv_count→0: terminate signals AND clear queue
- Invariant: `NoDoubleFree` — allocation freed exactly once when ref_count→0
- Invariant: `NoHangingSignals` — all signals terminated before allocation freed

**Priority**: Medium
**Rationale**: 3+ historical bugs. The protocol is now correct but complex. TLA+ can verify the ref_count interleaving exhaustively.

---

### Family 4: Unsafe Memory Operations (KanalPtr, transmute) (LOW)

**Mechanism**: KanalPtr's dual-mode protocol requires precise unsafe operations for different T sizes. All historical bugs in this family are fixed.

**Evidence**: 5 historical pointer.rs commits, issues #36, #28. Current code is sound (verified in deep analysis).

**Priority**: Low
**Rationale**: All fixed. Not suitable for TLA+ — these are implementation-level memory safety issues, not protocol logic.

---

### Family 5: Waitlist Mode Switching (LOW)

**Mechanism**: The unified wait_list toggles between send and recv modes via `recv_blocking` flag. Mode switches happen when the list empties. `send_many` manually sets this flag.

**Evidence**: No historical bugs in this specific mechanism. send_many's manual `recv_blocking = false` (lib.rs:736) is redundant but correct.

**Priority**: Low
**Rationale**: Simple protocol, always under mutex. Could be included as part of the base spec for completeness.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Signal lifecycle state machine | Family 1: root cause of 8+ bugs, 1 new finding | State variable per signal, split WriteData into data-copy + state-swap steps |
| Timeout → Cancel → Wait protocol | Family 1: LOCKED_STARVATION gap is the key new bug | Model wait_timeout setting LOCKED_STARVATION, then wait() re-entering with that state |
| Async future drop/cancel | Family 2: data loss on cancellation | Non-deterministic DropFuture action at any point after first poll |
| Push-front capacity violation | Family 2: new finding in ReceiveFuture::drop | Track queue.len vs capacity as invariant |
| Close / half-close protocol | Family 3: ref_count coordination | Model send_count/recv_count decrements with signal termination |
| Waitlist mode switching | Family 5: base spec completeness | recv_blocking flag + unified wait_list |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| KanalPtr inline optimization | Family 4: memory layout issue, not protocol logic. All bugs fixed. |
| Custom spinlock mutex | Family 5: fairness is a performance concern, not safety |
| Backoff/spinning strategies | Performance optimization, no correctness implications |
| ZST special handling | Implementation detail, size=0 case doesn't affect protocol logic |
| Async waker mechanics | Too low-level; model signal state transitions, not waker clone/wake |
| Stream (ReceiveStream) | Thin wrapper over ReceiveFuture, no independent protocol |
| repr(C) / transmute safety | Compile-time issue, not runtime protocol |
| send_many sync version | Same protocol as repeated send() — no independent bugs |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Signal state machine | `signalState`, `signalOwner`, `dataLocation` | Model the handoff protocol between sender/receiver via signals | Family 1 |
| Timeout + starvation | `timedOut[Thread]`, `starvation[Signal]` | Model wait_timeout → LOCKED_STARVATION → wait() re-entry | Family 1 |
| Future lifecycle | `futureState`, `futureDropped` | Model async poll/drop/cancel with data ownership tracking | Family 2 |
| Queue capacity tracking | `queueLen`, `capacity` | Detect push_front capacity violations | Family 2 |
| Ref counting | `sendCount`, `recvCount`, `refCount` | Model close/half-close coordination | Family 3 |
| Preemption fault injection | `preempted[Thread]` | Delay counterpart between PopSignal and WriteData | Family 1 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoDataRace | Safety | Data is not accessed concurrently by sender and receiver | Family 1 |
| SignalSingleUse | Safety | Each signal's write_data/read_data/terminate is called exactly once | Family 1 |
| WaitCorrectness | Safety | wait() returns true iff data was successfully transferred; false iff terminated | Family 1 (LOCKED_STARVATION bug) |
| NoDataLoss | Safety | Every datum sent is either received, returned to sender, or in the queue | Family 2 |
| CapacityBound | Safety | queue.len ≤ capacity (for bounded channels) | Family 2 |
| NoDoubleFree | Safety | Channel allocation freed exactly once | Family 3 |
| NoHangingSignals | Safety | When channel is fully closed, no signals remain pending | Family 3 |
| CloseTerminatesAll | Safety | close() terminates all pending signals | Family 3 |
| FIFO | Safety | Messages are received in send order (within a single sender) | Correctness |
| HalfCloseDetection | Safety | send returns error iff recv_count=0; recv returns error iff send_count=0 and queue empty | Family 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| F1-1 | wait() after wait_timeout() returns false when state is LOCKED_STARVATION — counterpart still processing | WaitCorrectness, NoDataRace | Family 1 |
| F2-1 | ReceiveFuture::drop push_front exceeds bounded capacity | CapacityBound | Family 2 |
| F2-2 | SendManyFuture error path drops data without returning to caller | NoDataLoss | Family 2 |
| F2-3 | ReceiveFuture cancellation on rendezvous channel loses data | NoDataLoss | Family 2 |
| F3-1 | Interleaving of DropSender + DropReceiver + Close with pending signals | NoHangingSignals, NoDoubleFree | Family 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | wait() after wait_timeout() with preempted counterpart | Inject delay between pop_signal and write_data, check for data corruption |
| T2 | SendManyFuture with partial failure | Close channel after partial send_many, verify all data accounted for |
| T3 | High-contention close() during active send/recv | Stress test: many senders + receivers + close() simultaneously |
| T4 | ReceiveFuture cancellation on bounded channel | Use tokio::select! to cancel receive, verify queue.len ≤ capacity |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C1 | SendFuture::drop redundant `need_drop = true` at line 81 | Remove dead code |
| C2 | AsyncSignal::cancel is no-op with misleading comment "Drops waker without waking" | Fix comment |
| C3 | drain_into returns `required_cap` (pre-drain count) as "number received" | Rename variable |
| C4 | `unsafe impl<T> Sync for Internal<T>` has no `T: Send` bound | Add `T: Send` bound |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/kanal/analysis-report.md`
- **Key source files**:
  - `artifact/kanal/src/signal.rs` (signal lifecycle, 492 lines) — highest bug density
  - `artifact/kanal/src/future.rs` (async futures, 583 lines) — cancel-unsafety
  - `artifact/kanal/src/lib.rs` (channel API, 1579 lines) — send/recv protocol
  - `artifact/kanal/src/internal.rs` (shared state, 307 lines) — ref counting, close
  - `artifact/kanal/src/pointer.rs` (KanalPtr, 95 lines) — inline optimization
- **GitHub issues**: #2, #14, #15, #17, #19 (Family 1); #24, #47, #50, #59 (Family 2); #13, #59 (Family 3); #33, #36 (Family 4)
- **GitHub repository**: https://github.com/fereidani/kanal
- **Category**: B (concurrent/lock-free) — use timebox trace approach for trace validation
