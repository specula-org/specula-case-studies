# MC-4 Investigation

## Scope and source

- Finding: MC-4, `FaultBeforeDiagnosis`.
- Source: model checking. The permitted counterexample
  `spec/output/MC_hunt_scenario4_bfs.out:34` reports
  `Invariant FaultBeforeDiagnosis is violated`.
- Counterexample transition: state 9 has run 1 in `diagnosis`,
  `waitingForAgent = TRUE`, `faultEffective[1] = TRUE`, and
  `podGen[1] = 0`; state 10 is `MCRestartPod`, after which the stage and
  agent readiness are unchanged while `podGen[1] = 1`,
  `faultEffective[1] = FALSE`, `workloadHealthy[1] = TRUE`, and
  `reattachPending = {1}` (`MC_hunt_scenario4_bfs.out:740-913`).

## Step 1 — code audit

### Cited sites and behavior

- `sregym/conductor/problems/khaos_faults.py:90-110` defines a daemon
  `_FaultReinjectionMonitor` whose only tracked generation identity is
  `pod_ref -> container_id`.
- `sregym/conductor/problems/khaos_faults.py:114-129` snapshots current
  container IDs and starts the daemon thread.
- `sregym/conductor/problems/khaos_faults.py:140-148` checks pods once and
  then waits up to five seconds before checking again.
- `sregym/conductor/problems/khaos_faults.py:150-196` detects a changed
  container ID, resolves the new host PID, and invokes Khaos for that PID.
  A non-running container is skipped; any other failure is logged. In both
  cases the unchanged cached ID causes a retry on a later polling pass.
- `sregym/conductor/problems/khaos_faults.py:262-264` states the intended
  mechanism directly: probes are pinned to host PIDs, a Kubernetes restart
  gives the container a new PID, and the fault disappears.
- `sregym/generators/fault/inject_hw.py:9-13`,
  `sregym/generators/fault/inject_hw.py:163-205`, and
  `sregym/generators/fault/inject_hw.py:310-331` confirm that injection
  resolves a container ID to a host PID and executes
  `/khaos/khaos <fault> <host_pid>`.
- `sregym/conductor/conductor.py:284-320` injects once before the first
  stage, then immediately sets `waiting_for_agent = True` and
  `submission_stage = stage_name`. It does not consult the monitor,
  container generation, or post-injection effectiveness.
- `sregym/conductor/conductor_api.py:119-159` accepts a public diagnosis
  submission whenever `submission_stage` is `diagnosis`; its only readiness
  protection concerns concurrent evaluation, not fault effectiveness.
  `sregym/conductor/conductor_api.py:162-169` likewise exposes the stage
  publicly through `GET /status`.

The worktree has pre-existing trace-only edits at the cited sites. Comparing
against `HEAD` shows that the operational monitor and conductor behavior
above is unchanged; the edits add `tla_trace` observations around those
operations.

### Normal call chain and reachability

1. The benchmark driver calls `await conductor.start_problem()` at
   `main.py:315-321`.
2. `Conductor.start_problem()` deploys the selected problem and calls
   `_advance_to_next_stage(start_index=0)` at
   `sregym/conductor/conductor.py:418-479`.
3. `_advance_to_next_stage(0)` calls `_inject_fault()`, then publishes the
   first configured stage as ready at
   `sregym/conductor/conductor.py:298-319`.
4. For a `KhaosFaultProblem`, `inject_fault()` performs the PID-scoped
   injection and starts the monitor at
   `sregym/conductor/problems/khaos_faults.py:243-273`.
5. A workload container can then restart normally after the injected syscall
   fault crashes it. This is also the exact admissible counterexample step
   from state 9 to state 10 (`MCRestartPod`).
6. Until the next monitor pass resolves the replacement PID and reattaches,
   `GET /status` continues to return `diagnosis`, and `POST /submit` remains
   eligible to accept the diagnosis.

### Concrete trigger scenario

Start a Khaos-backed benchmark problem through the normal driver. Let the
conductor inject the PID-scoped fault and publish the diagnosis stage. Just
after a monitor pass, let the fault crash/restart a targeted workload
container. The old process and its fault effect disappear, while the
replacement has a new container ID and host PID. During the monitor's
five-second wait plus PID resolution/retry time, the public diagnosis API
remains available.

### Safeguards and downstream mechanisms

- The daemon monitor eventually polls again and re-injects on a changed
  container ID (`khaos_faults.py:140-196`).
- If PID/container resolution or Khaos execution fails, the cached ID is not
  advanced, so a later poll retries.
- Recovery stops and joins the monitor before detaching the fault
  (`khaos_faults.py:275-280`).
- No caller-side gate pauses diagnosis while reattachment is pending, and no
  public API checks current fault effectiveness.

## Step 2 — developer-knowledge evidence

- The code comment at `khaos_faults.py:262-264` explicitly documents that a
  restarted container gets a new PID and the fault disappears.
- The comment at `khaos_faults.py:174-177` records that host-PID resolution
  can itself take several seconds.
- Git blame attributes the monitor and its five-second polling loop to merge
  commit `4bf9782681baaccc5a9588b862728a60d8db477d` (2026-02-25),
  “Reinject khaos after PID change (#569).”
- Upstream issue
  [#568, “Hardware faults injected by khaos is not persistent”](https://github.com/SREGym/SREGym/issues/568)
  reports this PID/restart persistence mechanism and links a developer
  observation that affected MongoDB pods returned to `Running` even at a
  100% injection rate.
- Merged upstream
  [PR #569, “Reinject khaos after PID change”](https://github.com/SREGym/SREGym/pull/569)
  closed #568 by introducing this monitor. Its asynchronous repair is evidence
  that reattachment was intended, but neither the issue nor implementation
  establishes a diagnosis-readiness barrier.
- No Python test outside the Specula trace harness references
  `_FaultReinjectionMonitor`, `reinjection-monitor`, or PID-change
  reattachment.

## Step 3 — known status and precedent

- Tracker result: the same mechanism at the same Khaos PID-reinjection site
  was already filed as upstream issue #568 and addressed incompletely by
  merged PR #569.
- Recent merged/closed history through checkout
  `d9a0663e3930d90bd98122e8a852cf8d27c410ec` was searched for Khaos,
  reinjection, reattachment, pod-restart, persistence, and
  fault-effectiveness changes. No later commit adds a generation/readiness
  gate or reports a completed fix for the remaining interval.
- Known-status record for the final report:
  `KNOWN (cite: https://github.com/SREGym/SREGym/issues/568; fix-status: unfixed)`.
- This is an MC finding with an actual violation trace, so known status does
  not trigger the code-review-only Phase-1 drop.
