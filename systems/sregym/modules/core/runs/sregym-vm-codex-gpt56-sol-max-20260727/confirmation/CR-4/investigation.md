# CR-4 Investigation

## Scope and source provenance

- Finding source: code review; no model-checker counterexample is supplied.
- Canonical source revision: `d9a0663e3930d90bd98122e8a852cf8d27c410ec`
  (`HEAD`, `origin/main`, and the live `refs/heads/main` returned by
  `git ls-remote` all matched on 2026-07-27).
- The supplied worktree already contains Specula trace instrumentation in
  `manager.py` and `conductor.py`. `git diff` shows that it adds trace events,
  a boundary lock, and a configurable loop-sleep field, but retains the
  five-second join, cleanup ordering, unbounded apply, and post-apply record
  append at issue. Canonical line citations below refer to `HEAD`.

## Step 1: code audit

### Relevant code

- `sregym/generators/noise/manager.py:71-82`: public `start()` verifies Chaos
  Mesh, sets `running`, and starts the daemon worker.
- `sregym/generators/noise/manager.py:84-95`: public `stop()` clears `running`,
  joins the worker for at most five seconds, unconditionally clears
  `_background_thread`, then cleans the recorded list and performs the
  finalizer sweep.
- `sregym/generators/noise/manager.py:99-105`: the loop tests `running` only
  before entering `_maybe_inject`; it has no cancellation primitive for an
  operation already in progress.
- `sregym/generators/noise/manager.py:115-121`: one injection cycle applies
  two randomly selected templates serially and does not re-check `running`
  between them.
- `sregym/generators/noise/manager.py:125-156`: `_apply_experiment()` calls
  `kubectl apply` at line 150, waits for it to return, and only then appends
  the experiment to `active_experiments` at lines 154-155.
- `sregym/service/kubectl.py:714-724`: `exec_command()` uses
  `subprocess.run(...)` with no timeout, so a slow `kubectl apply` can outlive
  the five-second join.
- `sregym/generators/noise/manager.py:176-203`: cleanup holds `_lock`, iterates
  only experiments already in `active_experiments`, then clears that list.
- `sregym/generators/noise/manager.py:205-245`: the fallback enumerates Chaos
  CRs once and strips finalizers. It neither establishes worker quiescence nor
  issues deletion for an unrecorded CR; a CR created after its enumeration is
  not seen at all.
- `sregym/conductor/conductor.py:476-491`: the real evaluation path calls
  `nm.stop()` and immediately invokes the stage evaluation/oracle after it
  returns.
- `sregym/conductor/oracles/sustained_readiness.py:15-52`: a real mitigation
  consumer polls pod readiness and permanently returns `{"success": False}`
  when a pod becomes unhealthy during its observation window.
- `sregym/generators/noise/catalog.py:14-67`: normal noise includes
  `PodChaos/pod-failure` (45 seconds), `PodChaos/pod-kill`, 500 ms network
  delay, and 50% network loss, all aimed at the problem namespace.
- `sregym/service/cluster_state.py:19-45`: `chaos-mesh` and its infrastructure
  are deliberately protected during baseline reconciliation. The reconciler
  does not enumerate and delete namespaced Chaos custom resources, so it is
  not a safeguard for a late-created experiment.

### Call chain and reachability

Normal command-line use with `--noise` constructs
`ConductorConfig(enable_noise=True)`. `Conductor.start_problem()` deploys the
application, calls `get_noise_manager()`, supplies the application namespace,
and calls `NoiseManager.start()` (`conductor.py:464-474` in the supplied
instrumented worktree; canonical code has the same sequence). The daemon
immediately enters `_maybe_inject()` because `_last_injection_time` is initially
zero. A normal stage submission reaches
`Conductor.submit()` -> executor `_submit_evaluate_and_advance()` ->
`NoiseManager.stop()` -> the configured oracle.

The slow-apply precondition is reachable without internal state fabrication:

1. Start a problem with `--noise` against an installed Chaos Mesh cluster.
2. The worker issues a legitimate `kubectl apply -f <PodChaos-or-NetworkChaos>`.
3. The Kubernetes request takes longer than five seconds (for example, API
   server/admission/network delay) while the request is still accepted.
4. A normal agent submission calls `NoiseManager.stop()`.
5. The join times out; recorded cleanup and the one-shot fallback inspect the
   cluster before that apply completes; `stop()` returns.
6. The apply succeeds, the worker appends the experiment, and Chaos Mesh acts
   while the conductor's oracle is already evaluating.

### Safeguards observed

- `running = False` prevents a future outer-loop iteration, but does not cancel
  an in-flight subprocess or the remainder of the already-entered injection
  cycle.
- The five-second `join` is bounded but its timeout is ignored.
- `_lock` serializes list mutation and recorded cleanup; it cannot make an
  experiment visible before `kubectl apply` returns.
- Recorded cleanup deletes known experiments with `--wait=false` and may strip
  a stuck finalizer.
- `_force_remove_all_chaos_resources()` is a one-shot enumeration and only
  strips finalizers. It does not wait for the worker and does not delete a
  newly appearing CR.
- Chaos experiment durations eventually stop their injected effects
  (45 or 120 seconds), but the evaluation begins immediately after `stop()` and
  can record a failure during that interval.
- Baseline reconciliation protects Chaos Mesh and does not clean namespaced
  Chaos CRs.

## Step 2: developer-knowledge evidence

- PR #395 describes the lifecycle contract verbatim: the conductor keeps noise
  active during diagnosis/mitigation but has it “strictly cleaned up before
  the evaluation phase.” It also says CI/CD noise waits for rollouts during
  cleanup “to avoid interfering with evaluation”:
  https://github.com/SREGym/SREGym/pull/395
- Issue #647, implemented by PR #648 and commit
  `5627fff752fedbee4b88dd808996c22c5a003a72`, calls for “stage-aware lifecycle,
  context passing, start/stop around evaluations”:
  https://github.com/SREGym/SREGym/issues/647
  and https://github.com/SREGym/SREGym/pull/648
- The current conductor comment at `sregym/conductor/conductor.py:476` says
  “Stop noise before evaluation to ensure clean environment.”
- Issue #655 and PR #669 show that developers regard noise affecting oracle
  signals as undesirable. PR #669 specifically reports that `pod-failure` can
  trigger alerts and reduces its duration:
  https://github.com/SREGym/SREGym/issues/655
  and https://github.com/SREGym/SREGym/pull/669
- PR #732 addresses stuck finalizers for already recorded resources, and PR
  #752 preserves Chaos Mesh infrastructure across reconciliation. Neither
  discusses a worker surviving `stop()` or an apply completing after cleanup:
  https://github.com/SREGym/SREGym/pull/732
  and https://github.com/SREGym/SREGym/pull/752
- No existing test under `tests/` exercises `NoiseManager`, its five-second
  join, or stop/apply concurrency.

## Step 3: known-status and precedent evidence

Tracker searches covered issues and PRs (open and closed), including recently
closed/merged PRs:

- exact `join(timeout=5)`: 0 matches;
- exact `active_experiments`: 0 matches;
- `kubectl apply` + noise + stop: 0 matches;
- `NoiseManager`: five matches, none describing an apply that finishes after
  stop cleanup;
- noise + “before evaluation”: only PR #395, which states intent and does not
  report this defect.

The 100 most recently updated closed PRs and the preceding 100 closed PRs were
also scanned by title/body. PRs #732 and #752 concern finalizers/CRD
preservation, not this mechanism. Issue #674 and PR #679 are a same-shape
precedent at a different site: the conductor's whole cleanup thread could race
the next problem deployment. They do not report the `NoiseManager.stop()` /
in-flight-apply window:
https://github.com/SREGym/SREGym/issues/674 and
https://github.com/SREGym/SREGym/pull/679.

No issue, PR, CVE, or advisory found in the upstream tracker reports the same
mechanism at the same site. The code-review × known pre-filter therefore does
not apply, and Phase 2 is required.
