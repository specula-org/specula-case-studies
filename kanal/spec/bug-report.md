# kanal Bug Report

Bugs found via TLA+ model checking of the kanal MPMC channel library (Rust).

Spec: `case-studies/kanal/spec/base.tla`
Artifact: `case-studies/kanal/artifact/kanal/`
Source: https://github.com/fereidani/kanal

---

## Bug K-1: ReceiveFuture::drop push_front Exceeds Bounded Capacity (MEDIUM)

**Severity**: MEDIUM — queue exceeds declared capacity
**Family**: 2 (Async Future Cancellation / Drop)
**Found by**: MC_hunt_future_cancel.cfg, BFS, <1s, 5-state counterexample
**Finding ID**: F2-1 (from modeling brief)

### Summary

When an async `ReceiveFuture` is dropped after a sender has completed its half
of a direct handoff, the drop handler pushes data back to the channel queue via
`push_front`. This does NOT check if the queue is already at capacity, so on a
bounded channel, the queue can exceed its declared capacity.

### Root Cause

In `future.rs:246-249`, the `ReceiveFuture::drop` handler unconditionally pushes
data back into the queue when the channel is buffered (capacity > 0):

```rust
// future.rs:246-249
} else {
    // fallback: push it back to the channel queue
    acquire_internal(self.internal)
        .queue
        .push_front(self.sig.assume_init())
}
```

There is no `queue.len() < capacity` check before the push. If other senders
filled the queue between the handoff and the drop, this creates
`queue.len() > capacity`.

### Attack Trace (5 states, Capacity=1)

```
1. Init:              queue=<<>>, Capacity=1
2. RecvBlock(t1):     t1 blocks as receiver, signal in waitlist
3. SendDirectHandoff(t2): t2 sends d1 to t1's signal → signalState[t1]=UNLOCKED
4. SendToQueue(t3):   t3 sends d2 to queue → queue=<<d2>>, len=1 (at capacity)
5. DropRecvFutureBuffered(t1): t1's future dropped → push_front(d1)
                      → queue=<<d1, d2>>, len=2 > Capacity=1  *** VIOLATION ***
```

### Impact

- Queue exceeds bounded channel's advertised capacity
- Code that assumes `queue.len() <= capacity` may misbehave
- Affects any `select!` or cancellation scenario on bounded channels
- The VecDeque grows dynamically, so no memory corruption, but a semantic violation

### Affected Code

- `future.rs:246-249` — `ReceiveFuture::drop` push_front path
- Related: `future.rs:239-244` — the rendezvous (capacity=0) path drops data instead

### Status

Not previously reported. Distinct from the documented cancel-unsafety (which
concerns data loss, not capacity overflow).

---

## Bug K-2: ReceiveFuture::drop on Rendezvous Channel Loses Data (LOW)

**Severity**: LOW — documented design limitation
**Family**: 2 (Async Future Cancellation / Drop)
**Found by**: MC_hunt_future_rendezvous.cfg, BFS, <1s, 6-state counterexample
**Finding ID**: F2-3 (from modeling brief)

### Summary

When an async `ReceiveFuture` is dropped on a rendezvous channel (capacity=0)
after the sender completed the handoff, the data is silently discarded via
`drop_data()`. The sender has already returned `Ok(())`, so from its perspective
the send succeeded, but no receiver ever receives the value.

### Root Cause

In `future.rs:239-244`, when `capacity == 0`, there is no queue to push data
back to, so the handler drops it:

```rust
// future.rs:239-244
if self.internal.capacity() == 0 {
    #[cfg(debug_assertions)]
    println!(
        "warning: ReceiveFuture dropped while send operation is in progress"
    );
    self.sig.drop_data();
}
```

### Attack Trace (6 states, Capacity=0)

```
1. Init:              Capacity=0 (rendezvous)
2. SendBlock(t1):     t1 sends d1, blocks on waitlist
3. DropSendFutureCancel(t1): t1's send future cancelled, d1 returned
4. RecvBlock(t2):     t2 blocks as receiver
5. SendDirectHandoff(t3): t3 sends d2 to t2 → signalState[t2]=UNLOCKED
6. DropRecvFutureRendezvous(t2): t2's future dropped → d2 LOST  *** VIOLATION ***
```

### Impact

- Data loss on async cancellation (`select!`, timeouts)
- Sender gets `Ok(())` but no receiver processes the value
- Affects tokio::select!, async-std select, any cancel-on-drop pattern

### Affected Code

- `future.rs:239-244` — `ReceiveFuture::drop` rendezvous path

### Status

**Documented design limitation.** The kanal library explicitly documents that it is
not cancel-safe. This was a deliberate design choice prioritizing performance over
cancel safety. See: https://github.com/fereidani/kanal#cancel-safety

---

## Hunting Configs — No Violations

### Family 1: Signal Lifecycle Races (MC_hunt_signal_race)

- **BFS**: 27,263 states, 8,595 distinct, depth 20. No violations.
- **Simulation**: 1.35B states, 71M traces, 30 min. No violations.
- **Target invariants**: WaitCorrectness, NoDataRace, SignalSingleUse
- **Assessment**: The LOCKED_STARVATION gap (F1-1 from modeling brief) was not
  triggered. The current timeout/cancel protocol appears correct for the modeled
  scenarios (3 threads, 2 data values, Capacity=0, 3 timeouts, 3 preemptions).

### Family 3: Close Protocol (MC_hunt_close)

- **BFS**: 17,142 states, 4,208 distinct, depth 15. No violations.
- **Simulation**: 1.58B states, 219M traces, 30 min. No violations.
- **Target invariants**: NoDoubleFree, NoHangingSignals, CloseTerminatesAll,
  HalfCloseDetection, RefCountConsistency
- **Assessment**: Close protocol correctly terminates signals and manages ref counts
  for the modeled scenarios (3 threads, 2 data values, Capacity=1, 2 clones, 3 drops, 1 close).

---

## Convergence Summary

- **Spec convergence**: Round 1 — 3/4 traces pass, MC.cfg passes (695K states, 165K distinct)
- **Trace validation**: basic_send_recv (19 states), close_protocol (22 states), direct_handoff (67 states)
- **Abstraction gap**: trace_contention fails due to Category B timebox ambiguity (wide [8-54] timebox on t4.send_direct_handoff)
- **Bug hunting**: 2 bugs found across 4 configs, 2.93B+ simulation states explored
