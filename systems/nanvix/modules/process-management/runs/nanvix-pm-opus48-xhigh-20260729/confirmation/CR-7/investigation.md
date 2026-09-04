# CR-7 Investigation — capctl performs no privilege check

## Finding
`capctl` kcall handler (`src/kernel/src/pm/kcall/capctl.rs:32`) has an explicit
`//FIXME: check if process has enough privileges to change capabilities.` and calls
`pm.capctl(pid, capability, value)` unconditionally. Any process can self-grant (or clear)
any capability, defeating the capability model that gates privileged operations.

## Step 1 — Code audit (facts)

### The unguarded handler
`src/kernel/src/pm/kcall/capctl.rs`:
```
24  fn do_capctl(pm, pid, capability, value) -> Result<(), Error> {
30      trace!(...);
32      //FIXME: check if process has enough privileges to change capabilities.
34      pm.capctl(pid, capability, value)     // <-- no gate
35  }
52  pub fn capctl(pid, arg0, arg1) -> KcallResult { ... do_capctl(pm, pid, capability, value) }
```
`do_capctl` performs NO capability/privilege check before mutating capabilities.

### `pid` is the kernel-derived caller PID (not user-supplied)
Dispatcher `src/kernel/src/kcall/dispatcher.rs:61,93`:
```
61  let pid = unsafe { ProcessManager::get() }.get_pid();
93  KcallNumber::CapCtl => pm::capctl(pid, arg0, arg1),
```
So `capctl` always operates on the **calling process's own** capability set. i.e. any process
can self-mutate its capabilities.

### The mutation is real and durable
`ProcessManager::capctl` (`process/manager/mod.rs:2345`) → `state.set_capability` /
`clear_capability` (`process/state/mod.rs:312-318`) → `Capabilities::set/clear`
(`process/capability.rs:22-28`), flipping a bit in the per-process capability bitmask. New
processes start with `Capabilities::default()` = `0` (no capabilities).

### The capability model gates real privileged operations (what escalation buys)
`Capability` (`libs/sys/.../pm/capability.rs:23`): ExceptionControl, InterruptControl,
IoManagement, MemoryManagement, ProcessManagement. `has_capability` is the gate for:
- `pm/kcall/terminate.rs:50` — terminate any process (ProcessManagement)
- `pm/process/manager/mod.rs:819` — post/kill signal to another process (ProcessManagement)
- `event/manager.rs:295,351,416` — interrupt / exception / process-management event control
- `io/kcall/{mmio,pmio}_*.rs` — direct hardware port / MMIO access (IoManagement)
- `pm/kcall/{mmap,munmap,mctrl,mcopy}.rs` — cross-process memory ops (MemoryManagement)

### Contrast with the sibling handler that IS gated
`pm/kcall/terminate.rs:42-57` `do_terminate` checks
`if !pm.has_capability(caller_pid, Capability::ProcessManagement)? { return PermissionDenied }`
before acting. `capctl` has the identical shape but omits the gate.

### Reachability
`capctl` is a public kernel call (`KcallNumber::CapCtl`), reachable by ANY user process via
`__kcall_capctl(capability, value)` (`libs/sys/src/sys/kcall/pm.rs:259`). Fully reachable at
Level 0 (black-box, public API). No caller-side safeguard exists: the dispatcher hands the
caller's own pid straight to the handler.

### Trigger scenario (concrete)
An unprivileged process P (capabilities = 0):
1. `__kcall_terminate(any_pid)` → `PermissionDenied` (proves gate active, P unprivileged).
2. `__kcall_capctl(ProcessManagement, true)` → `Ok` (BUG: self-grant, no check).
3. `__kcall_terminate(any_pid)` → gate now PASSES; P has escalated to a process killer.

## Step 2 — Developer-knowledge search (evidence, no classification)

- `capctl.rs:32` comment: `//FIXME: check if process has enough privileges to change
  capabilities.` — developer awareness that the check is MISSING (a suspicion, not a filed
  report).
- `git log`: commit `0cfd3537a "[kernel] B: Require capability on terminate kcall"` added the
  ProcessManagement gate to **terminate** and closed TODO #1434 *for terminate only*. Its
  message: "Previously, the terminate kernel call allowed any process to tear down any other
  process, with the privilege check left as a TODO (#1434)." The same class of gap in
  **capctl** was NOT addressed.
- Issue #1434 referenced only in `tests/integration/test-rust-testd/src/pm/terminate.rs:9`
  ("tracked by issue #1434") — about terminate, not capctl.
- Existing test `pm/capability.rs` asserts that the (unprivileged) test daemon can
  `__kcall_capctl(<every capability>, true)` and receive `Ok(())` — i.e. the current buggy
  self-grant behavior is encoded as "expected".
- Existing test `pm/terminate.rs:156,213` itself relies on the bug: the test process
  self-grants `MemoryManagement` and `ProcessManagement` via `capctl` to perform privileged
  mmap/terminate.

## Step 3 — Known-status / precedent

- No git remote configured in the worktree; issue tracker not directly queryable. Searched
  git history (`--all`) for capctl privilege / capability-check commits: none add a gate to
  `capctl` (only terminate got one, `0cfd3537a`).
- The terminate fix (#1434) is a **same-shape precedent at a DIFFERENT site** (terminate, not
  capctl). Per the skill this does NOT make capctl "known": the capctl gap is unreported. The
  FIXME is developer *suspicion*, not a filed report.
- Source = code-review (no MC counterexample). Not a code-review × known duplicate → proceed
  to Phase 2. Novelty = NEW (no report found for the capctl mechanism at this site).

## Reproduction plan (Level 0, public API only)
Add a testd integration test that, as an unprivileged process, observes the terminate gate
flip from `PermissionDenied` → `NoSuchProcess` on a fixed non-existent target pid solely
because it self-granted `ProcessManagement` via `capctl`. Non-destructive (target pid does not
exist). Real consumer observing the wrong outcome: `do_terminate` capability check
(`terminate.rs:50`).

## Phase 2 — Reproduction result (Level 0, pure black-box public kcall API)

Repro: repro/test_bugCR-7_capctl_selfgrant.{rs,sh}. Added an integration test to the
shipped test daemon `testd` (NO system logic altered). testd runs as an ordinary
unprivileged user process. Targets pid 1_000_000 (cannot exist) so nothing is killed.

Built the real system image (procd/memd/vfsd/testd), booted it under nanvixd/QEMU,
captured console (repro/test_bugCR-7_capctl_selfgrant.run.log):

  [ERROR][terminate] do_terminate(): process does not have process management capability
  [INFO ][pm::escalation] baseline: unprivileged terminate() -> PermissionDenied (gate active)
  [INFO ][pm::escalation] BUG: capctl(ProcessManagement, true) -> Ok (no privilege check)
  [ERROR][manager] find_process_mut(): process not found (pid=1000000)
  [ERROR][manager] terminate(): process not found
  [INFO ][pm::escalation] ESCALATED: terminate() -> NoSuchProcess (gate PASSED after self-grant)
  [INFO ][pm::escalation] passed test_capctl_self_grant_escalates_terminate

Kernel-side corroboration: the FIRST terminate is rejected by the capability gate
("process does not have process management capability"). After the self-capctl, the
SECOND terminate is NOT rejected by the gate — it proceeds to the target lookup
("find_process_mut(): process not found (pid=1000000)"). The only intervening action
was the self-grant. Driver exits 0 deterministically.

### Pre-REPRODUCED checklist
1. Level 0 alone triggered it (public kcalls only, no timing/injection/patch): YES.
2. N/A (Level 0 sufficed).
3. Real consumer observing wrong outcome: do_terminate capability gate
   (terminate.rs:50) — kernel logged the gate rejection pre-grant and did NOT post-grant.
   Same gate is relied on by cross-process signal post (manager/mod.rs:819) and event
   control (event/manager.rs:416; console also shows do_evctrl_scheduling gating on
   ProcessManagement at line 527).
4. Permanent: the capability bit persists in process state; no downstream mechanism
   revokes or masks a self-granted capability. No mask.

Source: Code Review (no MC counterexample). Novelty: NEW — git history (all branches)
and upstream default branch show capctl still ungated (FIXME present); the only related
fix (PR #2492 / issue #1434) hardened the DIFFERENT `terminate` site; no report exists
for the capctl gap. fix-status: unfixed.

VERDICT: REPRODUCED (Level 0).
