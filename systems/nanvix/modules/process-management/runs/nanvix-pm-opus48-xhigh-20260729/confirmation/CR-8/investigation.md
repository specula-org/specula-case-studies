# CR-8 Investigation — fork/duplicate child receives Capabilities::default()

## Step 1: Code audit (facts)

Cited site: `src/kernel/src/pm/process/state/mod.rs:253` — `ProcessState::new` unconditionally sets
`capabilities: Capabilities::default()` (empty; `Capabilities(u8)` = 0, see
`process/capability.rs:14`).

Fork path (`duplicate()` kcall → `ProcessManager::duplicate_process`, `manager/mod.rs:1485`):
- Child built by `RunnableProcess::new(child_pid, pid, thread, vmem)` (`manager/mod.rs:1628`),
  which delegates to `ProcessState::new` (`runnable.rs:73`) → capabilities defaulted (empty).
- Signal state IS inherited: `inherited_signals = self.get_running().state().signals().inherited_for_fork()`
  (`manager/mod.rs:1606-1607`) then `process.set_signals(inherited_signals)` (`manager/mod.rs:1629`);
  the calling thread's blocked mask is inherited too (`manager/mod.rs:1608-1619`). POSIX cited for
  signals. Capabilities are NOT mentioned/inherited.

Spawn path (`create_process`, `manager/mod.rs:1129`): the brand-new process is ALSO built via
`RunnableProcess::new` → `ProcessState::new` → `Capabilities::default()` (`manager/mod.rs:1208`).
=> Every process-creation path assigns an empty capability set; capabilities are never inherited.

Capability model:
- Granted per-process only via the `capctl()` kcall (`kcall/capctl.rs` → `ProcessManager::capctl`,
  `manager/mod.rs:2345` → `set_capability`/`clear_capability`). `do_capctl` has **no** privilege
  check (`kcall/capctl.rs:32` FIXME: "check if process has enough privileges to change capabilities").
- Real consumers of `has_capability`: mmap/munmap/mcopy/mctrl (MemoryManagement), IO kcalls
  (IoManagement), terminate + inter-process signal post (ProcessManagement), event manager
  (Interrupt/Exception/ProcessManagement). All read `ProcessManager::has_capability`
  (`manager/mod.rs:3074`) which delegates to `ProcessState::has_capability`.

Reachability: a process can hold a capability (public `capctl` kcall) and then `fork()` (public
`duplicate` kcall). Fully reachable. But the resulting "child has no capability" state is the
system's uniform design, not an anomalous state.

## Step 2: Developer-knowledge search (evidence)

- Git: signal inheritance on fork was added deliberately in `787aa7534` ("[kernel] F: Add SIGCHLD and
  Stop/Cont job control", Part of #2690, Closes #2697): "Inherit ... the parent's dispositions/
  restorer on fork via SignalControl inheritance". Capabilities are not mentioned — no commit adds or
  discusses capability inheritance on fork/duplicate.
- `src/libs/proc/src/daemon/mod.rs:214-215`: the process daemon **explicitly acquires**
  `Capability::ProcessManagement` at init via `capctl`. `daemons/memd` acquires ExceptionControl +
  ProcessManagement; `daemons/vfsd` acquires IoManagement. None rely on inheritance.
- Userspace `fork()` (`libs/sys/src/sys/kcall/fork.rs`, `libs/syscall/src/unistd/fork/mod.rs`): the
  child path does NOT re-acquire capabilities and nothing assumes inherited caps. No userspace code
  forks then uses a capability in the child without acquiring it.
- Integration tests (`test-rust-kernel/duplicate.rs`, `test-rust-testd/pm/capability.rs`,
  `duplicate_burst.rs`, `terminate.rs`): the parent acquires ProcessManagement via `capctl` to
  terminate children; none assert the child inherits capabilities.
- No comment/doc anywhere states fork should (or should not) inherit capabilities.

## Step 3: Known-status / precedent

- Issue-tracker search (GitHub `nanvix/nanvix`, open + recently merged/closed PRs): searched
  "capability fork", "capabilities inherit". Hits are unrelated mechanisms (getpid cache #2577,
  socket refcount across fork #2609, dup2 #354). No issue/PR/CVE reports child-capability
  non-inheritance on fork/duplicate. => Novelty: NEW.
- Not code-review × known → not the pre-filter drop. Proceed to Phase 2.

## Phase 2: Reproduction

The behavior is deterministic (a value fixed at construction time, no timing
component), so booting the full Nanvix OS under the UserVM/nanvixd harness
(sysroot + cross toolchain + QEMU) is disproportionate. Reproduction is
Level 2 (state injection): a self-contained host program
(`repro/test_bugCR-8_fork_default_capabilities.rs`) that compiles the REAL,
unmodified capability primitives and transcribes the exact creation-path logic
with file:line citations:
  * `Capability` enum + `TryFrom` VERBATIM from `libs/sys/.../pm/capability.rs`;
  * `Capabilities` bitset VERBATIM from `pm/process/capability.rs`;
  * `ProcessState::new` default-caps init (state/mod.rs:253);
  * fork inheritance step (manager/mod.rs:1606-1630: signals inherited, caps not);
  * spawn construction (manager/mod.rs:1208: same default-caps path);
  * capctl self-grant with no privilege check (capctl.rs:32, manager/mod.rs:2361).

Built: `rustc --edition 2021 -O test_bugCR-8_fork_default_capabilities.rs`.
Executed output (`repro/test_bugCR-8_fork_default_capabilities.run.log`):
```
[CR-8] parent.has(IoManagement)=true child.has(IoManagement)=false child.signals_inherited=true
[CR-8] spawned.has(IoManagement)=false (spawn uses the SAME default-caps path)
[CR-8] after child self-capctl: child.has(IoManagement)=true (mask fires)
[CR-8] RESULT: confirmed — fork child does NOT inherit parent capabilities ...
```

Independent verification of the "uniform policy" claim: ALL construction sites
use `RunnableProcess::new` -> `ProcessState::new` -> `Capabilities::default()` —
kernel bootstrap (manager/mod.rs:265), spawn/create_process (mod.rs:1208), and
fork/duplicate_process (mod.rs:1628). No path anywhere inherits capabilities.

## Consequence analysis / verdict basis

- The non-inheritance BEHAVIOR is real and reproduced. But it is a **uniform,
  intended policy**: spawn AND fork (and kernel bootstrap) all assign
  `Capabilities::default()`; the only way to obtain a capability is explicit
  `capctl`. A forked child is in the identical position as a freshly-spawned
  process. This is a self-acquire / least-privilege model, not a fork-specific
  oversight.
- **No real consumer/caller observes a wrong outcome:** every privileged process
  (daemons: memd, vfsd, proc daemon) acquires its own capabilities via `capctl`;
  nothing in the tree relies on fork-inherited capabilities. The
  signal/capability asymmetry is explained — signals are POSIX-mandated state
  with an inheritance contract; the 5 Nanvix capabilities are a bespoke privilege
  model with no inheritance contract, self-acquired uniformly.
- Even the theoretical functional impact is nil: `capctl` has no privilege check,
  so a child can self-grant any capability (demonstrated: `child.has=true` after
  self-capctl). The child gets FEWER privileges (fail-safe; no escalation).

Verdict: **FALSE POSITIVE** (Code Review). Intended, uniform self-acquire policy;
nothing reads an inherited capability; no wrong outcome for any real consumer.
NOT MASKED — removing the self-grant "mask" would still harm no caller, because
no consumer expects inheritance in the first place (the whole system self-
acquires), so there is no underlying real defect being masked; it is simply the
intended behavior. NOT REPRODUCED — no live harm and no real consumer observes a
wrong outcome.

## Phase 2 (executed) — REAL Level-0 in-guest reproduction  [supersedes the earlier host transcription]

The earlier note reproduced only a host transcription of the logic (Level 2). This pass runs the
actual mechanism end-to-end through the public kcall API on the booted OS (QEMU), matching the CR-7
harness pattern. Test: `repro/test_bugCR-8_fork_cap_inherit.rs` (+ `.sh`), added to `testd`, wired
FIRST in `pm::test()`. Built with `make image`; booted with `make run LOG_LEVEL=info`.

Console evidence (`repro/test_bugCR-8_fork_cap_inherit.run.log`):
```
136 [ERROR][terminate] do_terminate(): process does not have process management capability
137 [CR-8][parent] baseline terminate() -> PermissionDenied (unprivileged)
140 [CR-8][parent] privileged terminate() -> NoSuchProcess (gate PASSED for parent)
141 [CR-8][parent] duplicated child pid=5
142 [ERROR][terminate] do_terminate(): process does not have process management capability
143 [CR-8][child] terminate() -> PermissionDenied (capability NOT inherited from parent)
146 [CR-8][child] after self-capctl: terminate() -> NoSuchProcess (MASK fires: child recovered)
148 [proc::daemon] process created (child=5, parent=4, role=User)
158 [CR-8][parent] reaped child pid=5
159 passed test_fork_child_does_not_inherit_capabilities
```

Mechanism CONFIRMED at Level 0: the forked child (pid 5, parent 4) does NOT inherit the parent's
ProcessManagement capability — the kernel `terminate()` gate (terminate.rs:50) denies the child
(line 142/143) exactly as it denied the unprivileged parent baseline (line 136/137), even though it
authorized the parent after its self-grant (line 140).

## Final verdict — MASKED (revised from the earlier FALSE POSITIVE)

- Real anomaly (not a clean FALSE POSITIVE): the reset contradicts the documented libc `fork()`
  "exact copy of the calling process" contract (unistd/bindings/fork.rs:18-19) and is inconsistent
  with the *deliberate* signal inheritance on the same path (manager/mod.rs:1629). The capability
  value IS read — the gate denies the child — so "nothing reads it" is false, and it is undocumented
  (so not "intended"). FALSE POSITIVE's own criteria are therefore not met.
- Live harm is MASKED, and the mask is PROVEN to fire: (a) the ungated self-service `capctl`
  (separate bug CR-7) lets the child re-establish the capability on demand — demonstrated at line 146
  (child self-grants, gate then passes); and (b) every real privileged component self-acquires its
  capabilities in `init()` (no in-tree caller relies on fork-inherited capabilities; children in
  `duplicate_burst` do nothing privileged). The reset is fail-closed (child is LESS privileged — no
  escalation).
- Latent risk this finding surfaces: if CR-7 is fixed (capctl properly gated), mask (a) is removed;
  a POSIX-style "acquire privilege, fork, child uses it" program would then be permanently denied →
  live harm. That is why this is a *finding* (MASKED), not a discardable false positive.

Verdict: MASKED. Novelty: NEW (no issue/PR/CVE reports child-capability non-inheritance on fork;
CR-7 is a different mechanism/site). Source: Code Review (never model-checked).
