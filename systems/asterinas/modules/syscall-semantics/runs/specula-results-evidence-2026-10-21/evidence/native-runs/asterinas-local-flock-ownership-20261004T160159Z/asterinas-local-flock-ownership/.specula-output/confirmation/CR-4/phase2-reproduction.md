# CR-4 Phase 2 reproduction record

Test: `repro/test_bugCR-4_drop_drain.c` + driver `repro/test_bugCR-4_drop_drain.sh`
Run: `repro/test_bugCR-4_drop_drain-run-20261006T021117/` (Linux smoke + 3 instrumented guest boots)

## Escalation ladder

- **Level 0 — pure black-box public API: MECHANISM TRIGGERED.**
  Linux smoke control on the same flock workload (uninstrumented Linux 7.2.8
  container): `CR4_WORKLOAD complete=true`, `CR4_FIXTURE_SMOKE_OK` — fixture
  sound. Guest runs (real Asterinas pin 0c6053709 + reviewed trace
  instrumentation, KVM, 2 vCPUs, 2G, ramfs fs_type 0x858458f6): 3 boots ×
  31 rounds (14 grant-race, 14 SH→EX conversion, 3 EX→SH downgrade control),
  every flock returned 0, every round completed, zero dropped trace events.
  Results per boot (`clone_drops` = successful-request clone drops):
  - boot1: 93 drops, drain_fired=1, futile_cycles=1 (reenq 16+13 vs baseline 28)
  - boot2: 93 drops, drain_fired=2, futile_cycles=2 (reenq 15+15 vs 28)
  - boot3: 93 drops, drain_fired=2, futile_cycles=2 (reenq 16+14 vs 28)
  Total: 279 clone drops → **5 drains fired (~1.8%)**, each popping exactly one
  queued waiter (`FlockItemDropRequest → WaitQueuePop → WakerWakeUp accepted →
  SchedulerUnpark`), and each popped waiter performing exactly one extra futile
  wake-retry-re-enqueue cycle (per-boot futile_cycles == drain_fired; the
  waiter-side count comes from same-request-id double `TrySetLockRegister`
  events with no grant between). Direct trace evidence in the run logs
  (CR4_SIGNATURE/CR4_EVENT lines), e.g. boot2 tid2 grant of request 2002
  popping waker 3002 (tid3) at TSC 25795736241..25795797860.
- **Level 1 — timing assistance: not escalated.** Level 0 already triggered the
  mechanism; the open question was impact magnitude. Note the reviewed
  instrumentation itself is de-facto timing assistance on the granting thread's
  return path (three trace emits widen Mutex-release→clone-drop to min ~1.5µs,
  avg ~8-9µs, max ~116µs), so the 1.8% firing rate is an upper bound; the
  uninstrumented production path (return + `clear_signalled_waker` + drop glue)
  is sub-µs and fires less often still.
- **Level 2 — state injection: not applicable.** The pre-condition (a waiter
  re-enqueued on a just-granted item's queue inside the granting thread's return
  window) is reachable through the real `flock(2)` API — Level 0 demonstrated it.
- **Level 3 — source patch: not needed.** A forced window widening would only
  inflate the already-measured firing rate; it could not change the harm
  assessment.

## Impact measurement (the finding's actual claim)

- Firing rate under purpose-built maximal churn (every grant raced by a parked
  contender re-enqueueing on a second vCPU): 5/279 ≈ 1.8% of grants.
- Cost per firing: one queue pop + one unpark + one futile list scan + one
  re-park for one waiter (a single absorbed retry cycle). Winner-side drain
  sequence measured 61-756µs on the instrumented kernel — dominated by trace
  string formatting; uninstrumented cost is single-digit µs.
- Amortized overhead vs. round wall time (~100ms/round): ≈0.001%. The
  CR-4-extra cycles (5) are ~5.6x rarer than the legitimate lost-race
  re-enqueues the same protocol produces in the same run (28), which the fixed
  Linux oracle also produces ("A wake means retry, not reservation").
- No correctness effect: all syscalls returned 0, no lost wakeups, all rounds
  completed — consistent with the C09 hunt exhausting without safety violations.
- The EX→SH downgrade control (convdown) confirmed the sibling replacement
  Drop-wake is load-bearing: the SH waiter is granted on its retry only because
  the replaced item's Drop wakes it (queue otherwise orphaned).

## Verdict derivation

- Mechanism: real, reachable via public API (Level 0). Wrong outcome for a real
  consumer: none — the popped waiter's blocking flock still returns exactly on
  acquisition; no fairness/latency/throughput contract is promised (campaign
  scope and contracts explicitly exclude them). The transient awake-while-held
  state is resolved within microseconds by the designed `pause_until` retry
  closure — a transient snapshot the system's own protocol absorbs is not a
  reproduced bug.
- Not MASKED: no defect exists for a safeguard to mask; the retry loop IS the
  specified algorithm (wake-retry protocol, Linux-parity), not a bolted-on
  safeguard, and the uniform Drop-wake policy is documented and load-bearing on
  the dead-owner-removal and replacement paths.
- Not ENV_LIMITED: this environment triggered the mechanism and measured its
  impact — negatively.

**Verdict: FALSE POSITIVE** — documented, intended protocol behavior; the only
claimed harm (excessive scheduling impact) is empirically negligible and the
finding's own framing concedes no correctness violation. Novelty NEW (tracker
and recent-PR search found no prior report of this mechanism at this site).
