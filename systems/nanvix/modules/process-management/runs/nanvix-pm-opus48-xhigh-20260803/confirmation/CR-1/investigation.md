# CR-1 Investigation — Location & state-machine integrity (residual gaps)

Source: **Code Review** (MC exercised ExactlyOneLocation / NestedStateConsistent /
NoRunAfterZombie / NoStoppedDispatch and found **no violation** → not MC-sourced).
Two residual code-review concerns to adjudicate:

- **A.** Deferred self-stop: a process that stops itself can run up to one extra
  quantum before deschedule (`stop_process`, mod.rs:951-966; skipped later by
  `take_earliest_ready`, 2674-2697).
- **B.** `take_earliest_ready` ends with `.expect(...)` (mod.rs:2691-2693) that would
  panic "if every ready process were stopped", said to rely on an *unenforced*
  "kernel process is never stopped" invariant.

## Step 1 — Code audit (facts)

### Concern B: is the `.expect` reachable?
`take_earliest_ready` (mod.rs:2674-2697) scans `self.ready`, **skips** stopped
processes, selects the earliest-admission non-stopped one, and
`.expect("there should always be a non-stopped process ready to run")`. The panic
fires **iff every process on the ready list is stopped**.

The comment claims the kernel process is "never stopped and is always runnable, so a
non-stopped candidate always exists." Audit shows this invariant is **enforced**, not
merely assumed, by a ring of guards:

1. `stop_process` (mod.rs:955-959) — **rejects** `pid == KERNEL` (`InvalidArgument`)
   before ever calling `set_stopped(true)`.
2. `set_stopped(true)` has exactly **one** caller in real kernel code: mod.rs:963
   inside `stop_process` (grep of `src/kernel/src` — the only other `set_stopped`
   calls are `false` in `continue_process`/`terminate`; the `true` at
   `process/state/tla_world.rs:1068` is the TLA harness, not a kernel path).
3. `do_sleep` (mod.rs:1772-1774) — **panics** if the kernel tries to sleep, so the
   kernel can never enter `suspended`.
4. Because the kernel is never suspended, `interrupt_signal_candidate`
   (mod.rs:1009-1018) — which only scans `self.suspended` — can never move the kernel
   to `interrupted`.
5. `do_exit` / `do_exit_thread` (mod.rs:2124-2126, 2214-2216) — **panic** if the
   kernel tries to exit, so the kernel never becomes a `zombie`.
6. `terminate` (mod.rs:2270-2274) — **rejects** terminating the kernel.

Consequence: the kernel process is, at every `take_earliest_ready` call site,
**either the running process or on the ready list, and it is never stopped**:
- `schedule()` (1671-1685): takes the running process and **pushes it back to `ready`**
  (1674), then drains `interrupted` into `ready` (1679-1682), then calls
  `take_earliest_ready`. Whether the previous runner was the kernel or a user process,
  the (non-stopped) kernel is on `ready`.
- `do_sleep`/`do_exit`/`do_exit_thread` (1791, 2147, 2251): the running process is a
  **user** process (kernel can't sleep/exit — guards 3/5 above), so the kernel is not
  running and, by the ring above, must be on `ready`.

Therefore a non-stopped candidate (at minimum the kernel) always exists →
**`.expect` is unreachable through the real API.** To make it fire you must inject a
state ("every ready process stopped, kernel included") that `stop_process` refuses to
produce.

### Concern A: deferred self-stop
`kill(self, self, SIGSTOP)` resolves to `PostAction::Stop` → `stop_process(self)`
(mod.rs:895, 951-966), which sets the caller's own `stopped` flag while it is the
**running** process (not on any queue). It is descheduled only at the next scheduling
opportunity, when `schedule()` pushes it to `ready` (1674) and `take_earliest_ready`
then skips it (2681-2683). So the self-stopper finishes its current quantum but is
**never re-dispatched** while stopped. The developer documents exactly this at
mod.rs:942-945: "A process that stops *itself* … is descheduled and skipped at the
next scheduling opportunity (its next blocking call or preemption)."
`NoStoppedDispatch` (no *new* scheduler dispatch of a stopped process) is preserved;
the state self-resolves at the next `schedule()`.

## Step 2 — Developer-knowledge search (evidence)

- Commit `787aa7534` / PR **nanvix/nanvix#2766** ("[kernel] Add SIGCHLD and Stop/Cont
  job control", merged 2026-06-28) introduced both sites. Message states the intent
  verbatim: "skip stopped processes in `take_earliest_ready()`" and "**Reject stopping
  the kernel process** and clear the stopped flag on `terminate()` so a doomed process
  can run its own exit." — i.e., the kernel-never-stopped invariant was a deliberate,
  enforced design decision, not an oversight.
- In-code docs: mod.rs:942-945 documents the deferred self-stop as intended;
  mod.rs:952-954 and 2675-2678 document the "kernel always selectable" rationale.
- No `FIXME`/`TODO`/"known bug" near either site flags them as defects.

## Step 3 — Known-status / precedent

Searched `nanvix/nanvix` issues + PRs (GitHub API): `take_earliest_ready`,
"non-stopped", "stopped process", SIGSTOP, scheduler, self-stop, deferred. Matches:
PR #2766 (the feature itself), issue #2697 (the feature request, closed/implemented),
issue #663 (a scheduler *enhancement* — binary heap). **No filed issue/PR/CVE reports
either the `take_earliest_ready` `.expect` panic or the deferred self-stop as a bug.**
→ Novelty: **NEW** (searched open + recently-closed/merged; nothing reports THIS
mechanism at THIS site). Code-review × known drop does **not** apply.

## Assessment (to be finalized after Phase 2)
- B: enforced invariant, `.expect` unreachable via real API → not a defect.
- A: documented, intended, self-resolving, `NoStoppedDispatch` preserved → not a defect.
Both point to **FALSE POSITIVE**. Phase 2 attempts the trigger via a faithful port.
