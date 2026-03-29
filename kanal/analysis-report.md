# Analysis Report: kanal — High-Performance MPMC Channel (Rust)

**Repository**: fereidani/kanal
**Language**: Rust, ~3465 LOC core logic (8 source files)
**Version analyzed**: 0.2.0-beta1 (commit 9a4b98d, HEAD of main)
**Date**: 2026-03-28

---

## 1. Codebase Structure

### 1.1 Core Files

| File | Lines | Role |
|------|-------|------|
| `src/lib.rs` | 1579 | Channel API: Sender, Receiver, send/recv/close, bounded/unbounded constructors |
| `src/future.rs` | 583 | Async futures: SendFuture, ReceiveFuture, SendManyFuture, ReceiveStream |
| `src/signal.rs` | 492 | Signal lifecycle: SyncSignal (thread park/unpark), AsyncSignal (waker), DynamicSignal (tagged pointer dispatch) |
| `src/internal.rs` | 307 | ChannelInternal: shared state, wait_list, ref counting, close protocol |
| `src/backoff.rs` | 249 | Spinning/backoff strategies: spin_cond, spin_rand, yield_os, sleep |
| `src/error.rs` | 112 | Error types |
| `src/pointer.rs` | 95 | KanalPtr: dual-mode data transfer (inline for small T, pointer for large T) |
| `src/mutex.rs` | 48 | Custom spinlock mutex (when not using std-mutex feature) |

### 1.2 Concurrency Model

- **Single shared mutex** protects all channel state (queue, wait_list, counts).
- **Wait_list** holds signals of ONE kind at a time (senders OR receivers), controlled by `recv_blocking` flag.
- **SyncSignal**: thread park/unpark for synchronous blocking. State machine: LOCKED → LOCKED_STARVATION → UNLOCKED/TERMINATED.
- **AsyncSignal**: waker-based notification for async. State machine: UNINIT → LOCKED(Pending) → UNLOCKED(Success)/TERMINATED(Failure).
- **KanalPtr**: zero-copy optimization. For `T ≤ pointer_size`, data is serialized inline into pointer storage. For `T > pointer_size`, data lives on sender's stack and pointer is shared.
- **DynamicSignal**: tagged pointer (LSB) dispatches between SyncSignal and AsyncSignal.

### 1.3 Channel Protocol

1. **Send (bounded, queue not full)**: acquire lock → check recv_count → check for waiting receiver → push to queue → release lock.
2. **Send (queue full or zero-cap)**: acquire lock → create SyncSignal on stack → push signal to wait_list → release lock → wait (park).
3. **Recv (buffered, queue non-empty)**: acquire lock → pop from queue → if waiting sender, pop sender signal and push its data to queue → release lock.
4. **Recv (queue empty)**: acquire lock → check for waiting sender → create SyncSignal → push signal to wait_list → release lock → wait.
5. **Close**: acquire lock → set send_count=recv_count=0 → terminate all signals → clear queue.
6. **Drop sender**: acquire lock → decrement send_count → if 0 and recv_count≠0, terminate signals → decrement ref_count → if 0, free allocation.
7. **Drop receiver**: acquire lock → decrement recv_count → if 0, terminate signals + clear queue → decrement ref_count → if 0, free allocation.

---

## 2. Bug Archaeology Summary

### 2.1 Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits | 251 |
| Bug-fix commits analyzed | 27 |
| GitHub issues collected | 44 |
| Issues deeply read | 33 |
| Confirmed bugs | 17 |
| Design defects | 3 |
| False positives excluded | 5 |

### 2.2 Historical Bug Classification

#### Critical (6 bugs)
1. **UB: double mutable reference** in SyncSignal (issue #2, commit 75960fb) — Stacked Borrows violation detected by Miri
2. **Race condition: drop/future lifecycle** (commit cb130b6) — Missing signal termination on last sender/receiver drop; ManuallyDrop UB in futures; use-after-free in AsyncSignal methods
3. **Double free: AsyncSignal::send** (commit be8e49b) — Assignment `*ptr = d` dropped uninitialized value
4. **Use-after-free: thread handle** (commit 773a4e7) — Thread cloned after state unlock, owner could destroy signal
5. **Soundness: missing Send bound** (issue #33, commits 8d92bd4, e55d07e) — `Sender<T>` was Send for non-Send T
6. **Soundness: unsound transmute** (issue #36, commits 9269095, b6aeab2) — Transmute between non-repr(C) structs

#### High (5 bugs)
7. **Data race: waker access** (issue #14) — Concurrent mutable access to waker in AsyncSignal
8. **Lost wake-ups** (issue #15) — Stale waker read during poll/send race
9. **Memory corruption: double free/SEGV** (issue #17, commit be8e49b) — Pointer bugs in async futures
10. **UB: uninitialized memory** (issue #19, commit f615c8c) — Race condition in send/recv future Drop
11. **Data loss on cancellation** (issue #47, #24, #50) — Documented design limitation with tokio::select!

#### Medium (5 bugs)
12. **Half-closed detection** (issue #13, commit 184be1e) — try_send/try_recv returned Ok on closed channel
13. **Miri: forget on Box** (issue #28, commit d3702c0) — UB in oneshot MaybeUninit handling
14. **Busy-wait in timeout** (issue #53, commit dc47624) — 100% CPU usage during wait_timeout
15. **Wrong search list** (commit 73befe0) — recv signal_exists searched send list
16. **Waker update missing** (commit ddb8452) — Re-poll with different Waker used stale waker

#### Low (4 bugs)
17-20. ZST handling, atomic ordering, DragonFly BSD target, benchmark iteration

### 2.3 Bug Hotspots

| File | Bug-fix commits | Historical severity |
|------|:---:|---|
| `src/signal.rs` | 14 | 6 critical, 3 high |
| `src/future.rs` | 9 | 2 critical, 4 high |
| `src/lib.rs` | 12 | 2 medium |
| `src/pointer.rs` | 5 | 2 medium |
| `src/internal.rs` | 5 | 1 critical |

---

## 3. Deep Analysis Findings

### 3.1 New Finding: `wait()` after `wait_timeout()` — LOCKED_STARVATION not handled (signal.rs:217-232)

**Severity**: HIGH — potential use-after-free / data race

**Scenario**:
1. `wait_timeout()` CAS succeeds: LOCKED → LOCKED_STARVATION (signal.rs:241)
2. Timeout expires, `wait_timeout()` returns `false` (state is LOCKED_STARVATION)
3. Caller's `cancel_*_signal()` fails (signal already popped by counterpart)
4. Caller calls `wait()` to wait for counterpart's response (lib.rs:809 / lib.rs:1155)
5. `wait()` spins for ~25μs, then CAS(LOCKED, LOCKED_STARVATION) **fails** because state is LOCKED_STARVATION (not LOCKED)
6. `wait()` returns `Err(v) => v == UNLOCKED` = `false` (signal.rs:232)
7. Caller reclaims data via `data.assume_init()` while counterpart may still be reading/writing

**Root cause**: `wait()`'s CAS failure path assumes the only failure values are UNLOCKED or TERMINATED, but LOCKED_STARVATION is also a valid failure value when `wait()` is called after `wait_timeout()` has already transitioned the state.

**Triggering condition**: Counterpart thread must be preempted for >25μs between popping the signal from the wait_list and completing write_data/read_data/terminate. While narrow, this is realistic under heavy system load.

### 3.2 New Finding: SendManyFuture silently drops error data (future.rs:487-495)

**Severity**: HIGH — data loss

When the inner `SendFuture` returns `Err(SendError(data))` (channel closed) but `elements` is not empty, the error value containing the unsent data is silently dropped (not returned to caller). The code continues the loop, rediscovers the closed channel, and returns a different element's error.

**Scenario**: Bounded channel with cap=1. Send `[A, B, C]` via `send_many`. A goes to queue. B goes to wait queue signal. All receivers drop. B's signal is terminated. Poll returns `Err(SendError(B))`. Since `elements = [C]` is non-empty, `res` is dropped, losing B. Loop detects `recv_count == 0`, returns `Err(SendError(C))`. Element B is lost.

### 3.3 New Finding: ReceiveFuture::drop push_front can exceed capacity (future.rs:246-249)

**Severity**: MEDIUM — capacity invariant violation

When a ReceiveFuture is dropped after a sender has written data (cancel-unsafety window), for bounded channels with capacity > 0, the data is pushed back to the queue via `push_front`. This can cause `queue.len() > capacity`, temporarily violating the stated capacity invariant. The next send will be blocked, so the excess is eventually consumed, but intermediate observers (via `len()`, `is_full()`) may see inconsistent values.

### 3.4 New Finding: AsyncSignal blocking_wait in async context (future.rs:184-185, signal.rs:461-491)

**Severity**: MEDIUM — executor thread blocking

When a signal's waker changes after the signal is dequeued (different executor), `blocking_wait` is called from within `poll`, blocking the executor thread for up to ~262μs (exponential backoff). This is documented as a rare path but can degrade async runtime performance under executor migration scenarios.

### 3.5 Confirmed Safe: All Other Patterns

| Pattern | Verdict | Rationale |
|---------|---------|-----------|
| KanalPtr inline optimization | Sound | Size/alignment guards correct, signal protocol ensures write-before-read |
| ref_count management | Safe | Protected by mutex, constructor pre-accounts for clone_unchecked |
| recv_blocking flag protocol | Safe | Always accessed under mutex |
| Signal-then-drop sequence | Safe | Terminate correctly swakes blocked threads |
| MaybeUninit lifetime in send | Safe | Sender blocks until data consumed |
| send_timeout cancel pattern | Safe | Three-step protocol handles all interleavings |
| close() vs concurrent operations | Safe | Mutex serialization |
| Custom mutex | Correct | TTAS with proper Acquire/Release ordering; unfair but not unsound |

---

## 4. Bug Families

### Family 1: Signal Lifecycle Races (HIGH)

**Mechanism**: SyncSignal and AsyncSignal have a complex lifecycle with multiple state transitions. The handoff protocol (push signal to wait_list under lock, counterpart pops it, writes data, signals completion) has multiple windows for races, especially around thread handle ownership, waker access, and state transitions.

**Evidence**:
- Historical: 7 race condition bugs (commits 75960fb, 773a4e7, cb130b6, 774a05f, 73befe0, ddb8452, f615c8c)
- Historical: Issues #2, #8, #11, #14, #15, #17, #19
- Code analysis: wait() after wait_timeout() LOCKED_STARVATION bug (signal.rs:217-232)

**Affected code paths**:
- `SyncSignal::write_data/read_data/terminate/cancel/wait/wait_timeout`
- `AsyncSignal::write_data/read_data/terminate/blocking_wait`
- `SendFuture::poll/drop`, `ReceiveFuture::poll/drop`

**Assessment**: 8+ historical bugs, 1 new potential bug. Most severe family — every memory corruption bug traced to this mechanism.

### Family 2: Async Future Cancellation / Drop (HIGH)

**Mechanism**: When an async future is dropped mid-operation (e.g., `tokio::select!`), data ownership is ambiguous. The drop handler must either cancel the signal (if still in wait_list) or wait for the counterpart to finish. For ReceiveFuture, data may be lost (rendezvous) or pushed back (buffered, exceeding capacity).

**Evidence**:
- Historical: Issues #24, #47, #50, #59; commits cb130b6, de2da0d, f615c8c
- Code analysis: ReceiveFuture::drop push_front capacity violation (future.rs:246-249)
- Code analysis: SendManyFuture error data loss (future.rs:487-495)

**Affected code paths**:
- `SendFuture::drop` (future.rs:67-93)
- `ReceiveFuture::drop` (future.rs:218-255)
- `SendManyFuture::poll` error handling (future.rs:486-495)

**Assessment**: 5+ historical bugs, 2 new findings. The cancel-unsafety is documented but the capacity violation and SendManyFuture data loss are new.

### Family 3: Close Protocol and Half-Close Detection (MEDIUM)

**Mechanism**: Channel close (via `close()` or last sender/receiver drop) must coordinate with in-progress operations. Signals in the wait_list must be terminated. Half-close detection (send_count=0 or recv_count=0) must be checked at the right point in each operation.

**Evidence**:
- Historical: Issue #13 (try_recv didn't detect closure), commit 184be1e
- Historical: Issue #59 (queue not cleared on receiver drop — open bug in 0.1.x)
- Code analysis: dec_ref_count protocol (internal.rs:288-306) — safe but complex
- Historical: commit cb130b6 (missing terminate_signals in Drop)

**Affected code paths**:
- `ChannelInternal::dec_ref_count` (internal.rs:288-306)
- `close()` (lib.rs:237-247)
- `terminate_signals()` (internal.rs:162-168)
- `try_send/try_recv` closed-channel checks

**Assessment**: 3+ historical bugs. The close protocol is now correct but was historically error-prone. Issue #59 (queue not cleared) was fixed in 0.2.0-beta1.

### Family 4: Unsafe Memory Operations (KanalPtr, transmute) (MEDIUM)

**Mechanism**: KanalPtr's dual-mode protocol (inline vs pointer) requires precise unsafe operations. The sync-to-async transmute between Sender/AsyncSender requires repr(C). ZST handling has special cases throughout.

**Evidence**:
- Historical: 5 pointer.rs bug-fix commits (ZST forget, MaybeUninit alignment, miri)
- Historical: Issues #36 (unsound transmute), #28 (forget UB)
- Historical: Commits 9269095, b6aeab2 (repr(C)), d3702c0, 5621e1f, 0b80158

**Affected code paths**:
- `KanalPtr::read/write/new_from/new_write_address_ptr` (pointer.rs)
- `store_as_kanal_ptr` (pointer.rs:89-95)
- `Sender::to_async/as_async` transmutes (lib.rs)

**Assessment**: All historical bugs in this family are fixed. Current code is sound. But the inline optimization is inherently fragile — any change to KanalPtr requires careful attention to size/alignment invariants.

### Family 5: Custom Mutex Fairness and Backoff (LOW)

**Mechanism**: The custom spinlock mutex has no fairness guarantee. Under sustained contention, threads can be starved. The backoff strategy skips the OS yield phase (OS_YIELD=0) and goes directly to sleep.

**Evidence**:
- Code analysis: mutex.rs uses unfair TTAS spinlock
- Code analysis: backoff.rs OS_YIELD=0 (phase disabled)
- Historical: commit 2708e3c (atomic RNG race in backoff)

**Assessment**: Not a correctness bug — fairness is a performance concern. The critical sections are short enough that starvation is unlikely in practice. Not suitable for TLA+ modeling.

---

## 5. Cross-Reference with Known Bugs

### No Loom Testing

Despite multiple community recommendations (notably from sbarral in issues #14, #15, #16), kanal does not use Loom for exhaustive concurrency testing. Miri is used for UB detection but cannot deterministically catch all data races. The wait()/wait_timeout() LOCKED_STARVATION bug (Finding 3.1) is the type of bug Loom would catch.

### Oneshot Removed

The oneshot channel was removed in v0.1.0 due to accumulated bugs (issues #28, #29, #33, #35, #47). All oneshot-related bugs are historical and do not affect the current codebase.

### Cancel Safety Documented

Cancel-unsafety (issues #24, #50) is explicitly documented in the API comments (lib.rs:1246-1258). The maintainer considers this a Rust language limitation, not a kanal bug. Our analysis confirms the technical details: ReceiveFuture on rendezvous channels loses data, while buffered channels push data back (potentially exceeding capacity).
