# SREGym Code Analysis Report

## Audit Metadata

| Field | Value |
|---|---|
| Repository | `SREGym/SREGym` |
| Local path | `/users/Pial/targets/sregym-codex-gpt56-sol-max-20260727` |
| Revision | `d9a0663e3930d90bd98122e8a852cf8d27c410ec` |
| Analysis date | 2026-07-27 |
| Language | Python |
| Reference | [SREGym paper, arXiv:2605.07161v2](https://arxiv.org/html/2605.07161v2) |
| Category | **Category A — Distributed / Message-Passing** |
| BFT overlay | Not applicable |
| Primary handoff | `modeling-brief.md` |

## Executive Summary

The most valuable formal model is not a Kubernetes implementation model. It is a small benchmark-protocol model with five actors: driver, submission API, evaluator, noise manager, and Kubernetes environment. Four mechanisms should be modeled:

1. evaluation versus timeout/exit/teardown;
2. untagged submissions versus mutable run/stage state;
3. crash/restart with stale or partial persisted baselines;
4. noise/fault-effect quiescence versus temporal oracle observation.

The strongest current model-checkable defect is the timeout path: it tears the environment down without waiting for an accepted evaluation. The evaluator can later reopen mitigation, mutate results after publication begins, or restart noise (`main.py:393-404,428-463`; `sregym/conductor/conductor.py:468-514`).

The strongest directly confirmed non-model findings are:

- evaluated agents receive an unproxied host kubeconfig alongside the filtered one (`sregym/service/container_runner.py:253-263`);
- proxy checks for label-hidden resources happen after an upstream mutation is forwarded (`sregym/service/k8s_proxy.py:299-349,372-385`);
- `MitigationOracle` records but does not enforce original replica counts (`sregym/conductor/oracles/mitigation.py:23-32,69-84`);
- `DeploymentReadinessOracle` accepts `desired=ready=0` (`sregym/conductor/oracles/deployment_readiness.py:27-46,59-73`);
- `NoiseManager.stop()` does not establish that an in-flight apply has stopped (`sregym/generators/noise/manager.py:84-95,125-157`);
- the global command helper turns nonzero exits into ordinary strings, allowing false “applied/cleaned” state (`sregym/service/kubectl.py:714-724`);
- abnormal shutdown does not invoke conductor teardown (`main.py:537-563,630-652`);
- `fix_kubernetes()` unconditionally restores kube-proxy to a hard-coded version (`sregym/conductor/conductor.py:702-709`).

## Method and Coverage

The required `code-analysis` methodology was followed in four phases. Category A references were used; BFT and Category B overlays were not applicable.

| Coverage item | Result |
|---|---:|
| Repository commits across all refs | 2,534 |
| Local/remote refs examined | 43 |
| Commits touching broad core paths | 535 |
| Keyword-selected candidate commit diffs inspected | 142 / 142 |
| Candidates retained as core-mechanism significant | 54 |
| Candidates explicitly excluded | 88 |
| GitHub issues collected | 485 / 485 |
| Issue comments collected | 2,529 |
| Bug-labeled issues collected | 78 |
| Open issues at audit time | 24 |
| Issues deeply read, including every comment | 42 |
| Comments in those deep threads | 165 |
| Confirmed bugs/design defects among deep reads | 39 |
| Excluded as unverified/environmental false positives | 3 |
| Open PRs reviewed for intent | 16 / 16 |
| Open PRs with bug/security-fix intent fully reviewed | 3 / 3 |

The `gh` client was unavailable, so public GitHub REST data was used. The issue search corpus and all repository issue comments were collected before selecting threads. Issue bodies, all matching comments, local commits, current code, and compensating mechanisms were then cross-checked in parallel batches.

## Phase 1 — Reconnaissance

### Scale

Line counts include physical Python lines at the audited revision.

| Area | Python files | Lines |
|---|---:|---:|
| Whole repository | 450 | 79,397 |
| `sregym/conductor` | 169 | 25,178 |
| `sregym/generators` | 27 | 8,676 |
| `sregym/service` | 26 | 5,277 |
| `sregym/observer` | 7 | 307 |
| `mcp_server` | 24 | 2,159 |
| `clients` | 62 | 8,626 |
| Selected lifecycle/control core | 16 | 5,897 |

The selected core comprises `main.py`, conductor/API/problem/oracle bases, fault/noise control, Kubernetes command/state/proxy services, and agent/container lifecycle.

### Structural map

| Component | Responsibility | Important state/effects |
|---|---|---|
| `main.py` | Batch/attempt driver, agent timeout/exit handling, result publication | Driver daemon thread, `results`, agent process, timeout |
| `sregym/conductor/conductor.py` | Run state machine and environment lifecycle | `submission_stage`, `current_stage_index`, `_evaluating`, `_submit_future`, `problem`, baseline |
| `sregym/conductor/conductor_api.py` | HTTP/MCP submission and status boundary | Global conductor reference; asynchronous acknowledgment |
| `sregym/conductor/problems/*`, `sregym/conductor/oracles/*` | Fault-specific setup, diagnosis, and mitigation judgment | Kubernetes state and temporal observations |
| `sregym/service/kubectl.py` | Python-client and shell Kubernetes operations | Remote side effects, command exit semantics |
| `sregym/service/cluster_state.py` | Persisted baseline and cleanup reconciliation | Resource-name sets, node state, CoreDNS |
| `sregym/generators/noise/manager.py` | Background Chaos Mesh experiments | Worker thread, `running`, active experiment list |
| `sregym/service/k8s_proxy.py` | Hides fault-plane namespaces/resources | HTTP proxy thread, upstream credentials, response filtering |
| `sregym/agent_launcher.py`, `sregym/service/container_runner.py` | Agent process/container isolation and cleanup | PIDs/process groups, Docker container, mounted credentials |

### Execution actors and atomicity boundaries

The implementation has multiple independently progressing actors:

- Uvicorn/FastMCP runs in the main thread (`main.py:613-632`; `sregym/conductor/conductor_api.py:185-215`).
- The benchmark driver runs in a daemon thread (`main.py:613-628`).
- Every accepted submission gets a one-worker `ThreadPoolExecutor` (`sregym/conductor/conductor.py:550-566`).
- Noise runs in another daemon thread (`sregym/generators/noise/manager.py:71-105`).
- The evaluated agent is a separate process or Docker container (`sregym/agent_launcher.py:58-101,113-161`).
- Kubernetes, Helm, Docker, HTTP, and MCP operations cross process/network boundaries.

Operations that look like one Python call but must be modeled as begin/complete effects include:

| Apparent call | Non-atomic reality |
|---|---|
| `submit()` | Receive → accept → executor start → oracle work → stage advance → cleanup |
| `_finish_problem()` | guard → mark tearing down → stop noise → recover → undeploy → reconcile → done |
| `exec_command()` | issue shell process → remote request(s) → exit/output |
| `capture_baseline()` | eleven sequential API listings with independent failure |
| `reconcile_to_baseline()` | observe current state → issue many deletes/patches → eventual Kubernetes effects |
| `NoiseManager.stop()` | set flag → bounded join → clean recorded set, not necessarily all in-flight effects |
| proxy request | authorize namespace path → forward upstream → inspect response → filter client-visible result |

### Intended lifecycle

The normal final-submission path has meaningful compensation:

1. `submit()` marks the stage accepted and stores a loop-independent future (`sregym/conductor/conductor.py:550-566`).
2. Evaluation and final teardown execute in that worker (`sregym/conductor/conductor.py:468-514`).
3. `done` is published after recovery, app cleanup, and attempted reconciliation (`sregym/conductor/conductor.py:319-365`).
4. A following `start_problem()` awaits a still-running prior future (`sregym/conductor/conductor.py:399-407`).

This normal path matters: the analysis does **not** report the already-fixed #674 cross-problem race as current. Current failures occur in alternate timeout, bounded-wait, exception, crash, retry, and background-noise paths.

## Phase 2 — Bug Archaeology

### Git history mining

The scan covered all 535 commits touching `main.py`, conductor, generators, service, agent lifecycle, clients, and MCP paths across all refs. Keyword filtering (`fix`, `bug`, `race`, `panic`, `deadlock`, `correctness`, `crash`, `corrupt`, `leak`, `inconsistent`, `wrong`, `stale`, `cleanup`, `hang`, `timeout`, `failure`, `error`) produced 142 candidate patches.

Every candidate diff was inspected. Fifty-four were retained because they changed a core lifecycle, cleanup, transport, command-completion, isolation, or state-observation mechanism. Eighty-eight were excluded as merge-only duplicates, abandoned branch variants, cosmetic changes, problem-local content, ground-truth edits, application manifests, or agent-only behavior.

#### Significant commit groups

| Mechanism | Representative significant commits | What history established |
|---|---|---|
| Evaluation/lifecycle barriers | `b56d743b`, `172d0512`, `562acb79`, `f2276f3e`, `1e1afc38` | Publishing `done`, asynchronous acknowledgment, cleanup ownership, duplicate submits, and timeout results repeatedly changed together |
| Agent/process cleanup | `87b95c9a`, `a87aaf9e`, `2c3a914b`, `fc15a27c`, `2938a8fa` | Process exit and child-process ownership are recurring contamination sources |
| Baseline/resource cleanup | `8181d966`, `74f9fef4`, `37c1874a`, `543cbfd9`, `fed99969`, `2f5fd1c7` | Cleanup expanded from app-local heuristics to persisted cluster snapshots and special-case preservation |
| Command completion | `42efe88a`, `70afff60`, `55433a6b`, `6f841351`, `0bf47ea2` | Silent shell failures and timeout interpretation have repeatedly produced false success or hangs |
| Proxy/transport | `2e6313a0`, `4a4d6eec`, `4f69a331`, `32d51bfe`, `8f1099fc`, `98de7af1` | Authentication, concurrent requests, host/container addressing, and port forwarding are platform-sensitive |
| Trust boundary | `a99e0cc6`, `ddb071b7`, `4c994252`, `fc15a27c` | Ground-truth responses and problem/process leakage were removed, but the privileged workload-oracle credential was added to the agent container |
| Oracle soundness | `f782c17f`, `93ab29b7`, `7344b01c`, `b39ce848`, `ee6f5180`, `a3cacad5` | Freshness, semantic specificity, reward hacking, and capture timing are recurring scoring defects |
| Noise/finalizers | `64ace89c`, `7b506088`, `457241c1`, `ecdded374`, `2f5fd1c7` | Noise cleanup and Kubernetes finalizers have repeatedly blocked or contaminated later work |

#### Accounting for the 142 candidate diffs

- Rows 1–47: 20 retained, 27 excluded.
- Rows 48–94: 21 retained, 26 excluded.
- Rows 95–142: 13 retained, 35 excluded.

Retained candidate IDs by scan range:

- 1–47: `7344b01c`, `978a80b8`, `011acd26`, `f2276f3e`, `2938a8fa`, `fc15a27c`, `37c1874a`, `7f36a0e8`, `1e1afc38`, `562acb79`, `74f9fef4`, `98de7af1`, `4a4d6eec`, `6605a766`, `15c8f1c8`, `7297cf96`, `ddb071b7`, `b3a5d981`, `478a897a`, `0bf47ea2`.
- 48–94: `2e6313a0`, `2c3a914b`, `82cf5450`, `a87aaf9e`, `172d0512`, `42efe88a`, `4f69a331`, `32d51bfe`, `8f1099fc`, `e49f5a19`, `a99e0cc6`, `97cdb21a`, `543cbfd9`, `fed99969`, `70afff60`, `ce10c759`, `7b1b7b55`, `87b95c9a`, `5cfc0efa`, `b56d743b`, `64ace89c`.
- 95–142: `6f841351`, `7b9a3f24`, `55433a6b`, `0d8512d9`, `648068d2`, `7b506088`, `457241c1`, `c225c43b`, `401ac145`, `57ceca1e`, `66035bfb`, `19685ff9`, `a7b73851`.

Additional non-keyword historical anchors were inspected when linked from issues or later fixes, including `8181d966`, `2f5fd1c7`, `ecdded374`, `4a49936a`, `3e2343b3`, `93ab29b7`, and `4c994252`.

Notable exclusion traps:

- branch-only and merge duplicates were not double-counted as independent mechanisms;
- `e3889e72` was an incomplete precursor to the applicable #679 race fix;
- `94995393` and `ddb071b7` carry the same stable workload-oracle bypass change; the applicable ancestry was tracked once;
- large problem additions with “failure”, “bug”, or “leak” in their benchmark name were excluded unless the diff also changed core control behavior;
- cosmetic shutdown `CancelledError` suppression was retained as historical confirmation but not as a modeling mechanism;
- old `srearena`/legacy-noise changes were used only when their mechanism survives in current architecture.

### Issue verification

All 42 referenced issues below were read in full, including all 165 comments. “Active” means current HEAD still contains the exact or a directly equivalent mechanism; “partial” means the reported bug was addressed but current code retains a narrower gap.

| Issue | Verified disposition | Current/modeling relevance |
|---|---|---|
| [#64](https://github.com/SREGym/SREGym/issues/64) | Confirmed exit-cleanup bug; historical handler later removed intentionally | Active abnormal-exit cleanup gap |
| [#101](https://github.com/SREGym/SREGym/issues/101) | Confirmed cleanup regression, fixed | Historical abnormal-exit evidence |
| [#210](https://github.com/SREGym/SREGym/issues/210) | Confirmed stale PV selector, fixed | Resource-scope evidence |
| [#230](https://github.com/SREGym/SREGym/issues/230) | Confirmed workload Job ownership defect, fixed | Cleanup-ownership evidence |
| [#266](https://github.com/SREGym/SREGym/issues/266) | Missing noise cleanup/finalizer design confirmed; exact intermittent exception unproven | Historical noise mechanism; exact report not replayed |
| [#337](https://github.com/SREGym/SREGym/issues/337) | Confirmed cluster-global CoreDNS residue, fixed later than closure | Cross-run state evidence |
| [#408](https://github.com/SREGym/SREGym/issues/408) | Confirmed premature `done`, fixed | Lifecycle ordering evidence only |
| [#410](https://github.com/SREGym/SREGym/issues/410) | Confirmed cleanup deleting next app, fixed with #408 | Lifecycle ordering evidence only |
| [#411](https://github.com/SREGym/SREGym/issues/411) | Confirmed deterministic hostPort collision, fixed | Excluded from “port exhaustion” claims |
| [#460](https://github.com/SREGym/SREGym/issues/460) | Confirmed recovery asymmetry; reconciliation only partially resolves it | Active baseline/restart scenario |
| [#235](https://github.com/SREGym/SREGym/issues/235) | Confirmed cleanup exception prevented terminal transition, fixed | Cleanup phase-ledger evidence |
| [#261](https://github.com/SREGym/SREGym/issues/261) | Confirmed gameable extra-round design, later superseded | Historical liveness/fairness evidence |
| [#286](https://github.com/SREGym/SREGym/issues/286) | Synchronous submit timeout design confirmed; later asynchronous fix | Asynchronous acknowledgment evidence |
| [#290](https://github.com/SREGym/SREGym/issues/290) | No reproduction, root cause, or direct fix | **Excluded** as unverified |
| [#351](https://github.com/SREGym/SREGym/issues/351) | Cold image download on slow network | **Excluded** as environment/performance issue |
| [#374](https://github.com/SREGym/SREGym/issues/374) | Confirmed nested event-loop bug, fixed | Runtime-local, not TLA+ |
| [#576](https://github.com/SREGym/SREGym/issues/576) | Confirmed cosmetic shutdown logging, fixed | No semantic impact |
| [#593](https://github.com/SREGym/SREGym/issues/593) | Confirmed force-submit loop, fixed | Historical terminal-state evidence |
| [#650](https://github.com/SREGym/SREGym/issues/650) | Confirmed double submission/retry loop, fixed | Submission-ownership evidence |
| [#674](https://github.com/SREGym/SREGym/issues/674) | Confirmed cleanup/start race, fixed by `562acb79` | Closed bug is reference, not MC target |
| [#95](https://github.com/SREGym/SREGym/issues/95) | Confirmed in-flight workload batch freshness bug, fixed | Oracle freshness evidence |
| [#359](https://github.com/SREGym/SREGym/issues/359) | Confirmed Stratus initialization bug, fixed | Indefinite-wait theory explicitly excluded |
| [#483](https://github.com/SREGym/SREGym/issues/483) | Pod-only mitigation oracle design defect; later regressed | Active for Mongo auth/user faults |
| [#494](https://github.com/SREGym/SREGym/issues/494) | Host/source isolation defect fixed for stock agents | Related cluster-credential bypass is active |
| [#507](https://github.com/SREGym/SREGym/issues/507) | Diagnosis/mitigation semantic inconsistency, fixed for report | Oracle-specific historical evidence |
| [#552](https://github.com/SREGym/SREGym/issues/552) | Ground-truth response leak confirmed, fixed | Trust-boundary evidence |
| [#556](https://github.com/SREGym/SREGym/issues/556) | Problem-ID capability leak confirmed and later fixed | Trust-boundary evidence |
| [#559](https://github.com/SREGym/SREGym/issues/559) | One transient `IncompleteRead`, no recurrence or targeted fix | **Excluded** as unconfirmed; failure class still tested in baseline design |
| [#579](https://github.com/SREGym/SREGym/issues/579) | Proxy auth bug fixed locally; later real-kubeconfig mount bypasses it | Active end-to-end isolation defect |
| [#704](https://github.com/SREGym/SREGym/issues/704) | Agent continued acting during teardown, fixed in Stratus | Completion-ownership evidence |
| [#558](https://github.com/SREGym/SREGym/issues/558) | Train-ticket tracing remains nonfunctional | Active observability defect |
| [#617](https://github.com/SREGym/SREGym/issues/617) | Transient healthy window confirmed, fixed for reported oracle | Temporal-oracle evidence |
| [#688](https://github.com/SREGym/SREGym/issues/688) | Stage-sampling race confirmed, fixed by polling | Submission/stage evidence |
| [#691](https://github.com/SREGym/SREGym/issues/691) | Timeout result omission confirmed, fixed | Timeout publication evidence |
| [#745](https://github.com/SREGym/SREGym/issues/745) | Chronic unrelated alert causes false failures | Active; draft fix reviewed below |
| [#753](https://github.com/SREGym/SREGym/issues/753) | Khaos reattachment reward hack confirmed | Open but affected new problems are disabled |
| [#808](https://github.com/SREGym/SREGym/issues/808) | Hard-coded kube-proxy downgrade confirmed directly | Active code-review defect |
| [#853](https://github.com/SREGym/SREGym/issues/853) | Default-oracle reward hacking confirmed | Partially fixed; downscale/readiness gaps remain |
| [#857](https://github.com/SREGym/SREGym/issues/857) | Orphaned child processes confirmed, fixed | Historical stale-submission evidence |
| [#905](https://github.com/SREGym/SREGym/issues/905) | Runtime problem-ID leak confirmed, fixed | Trust-boundary evidence |
| [#911](https://github.com/SREGym/SREGym/issues/911) | Unrestricted egress used to query benchmark source | Active; draft fix is bypassable |
| [#941](https://github.com/SREGym/SREGym/issues/941) | Empty pre-deploy replica baseline confirmed, fixed | Capture timing fixed; replica equality still missing |

The three explicit exclusions are #290, #351, and #559. Narrow uncertainty inside #266 was also preserved: omission/finalizer design is confirmed, but its precise “third experiment” failure was not.

### Scenario grouping from history

| Historical mechanism | Issues/commits | Current use |
|---|---|---|
| Premature lifecycle publication and missing completion barriers | #408, #410, #650, #674, #704; `b56d743b`, `562acb79` | Guides Scenario 1 without reverting fixed code |
| Abnormal exit and cleanup ownership | #64, #101, #230, #266, #857 | Guides crash/restart and phase-ledger analysis |
| Cross-run/global residue | #210, #337, #460; `8181d966`, `74f9fef4` | Guides baseline provenance Scenario 3 |
| Untagged/repeated stage submissions | #261, #286, #593, #650, #688 | Guides Scenario 2 |
| Temporal oracle windows | #95, #617, #745, #753, #853, #941 | Guides Scenario 4 and unit-test targets |
| Trust-boundary leakage | #494, #552, #556, #579, #905, #911 | Direct code review, not core TLA+ state |
| Silent command/cleanup failure | #235, #359, #674 and command-fix commits | Test and cleanup phase-ledger targets |

### Open PR review

All 16 open PRs were classified for intent. The three with bug/security-fix intent were fully reviewed, including body, changed-file patches, issue comments, reviews, and review state.

| PR | Intent | Audit disposition |
|---|---|---|
| [#663](https://github.com/SREGym/SREGym/pull/663) | Jaeger bug fix | Draft; changes requested. ExternalName wiring does not solve absent application instrumentation; maintainers confirmed current images emit no traces. |
| [#754](https://github.com/SREGym/SREGym/pull/754) | Problem/oracle feature bundle | Excluded from bug-fix PR set |
| [#845](https://github.com/SREGym/SREGym/pull/845) | New oversized-config problem | Excluded |
| [#848](https://github.com/SREGym/SREGym/pull/848) | New connection-pool problem | Excluded |
| [#855](https://github.com/SREGym/SREGym/pull/855) | New GitOps-deletion problem | Excluded |
| [#856](https://github.com/SREGym/SREGym/pull/856) | New readiness-probe problem | Excluded |
| [#865](https://github.com/SREGym/SREGym/pull/865) | New CoreDNS saturation problem | Excluded |
| [#866](https://github.com/SREGym/SREGym/pull/866) | New page-cache problem | Excluded |
| [#883](https://github.com/SREGym/SREGym/pull/883) | New image-pull-secret problem | Excluded |
| [#885](https://github.com/SREGym/SREGym/pull/885) | New AURA client | Excluded |
| [#902](https://github.com/SREGym/SREGym/pull/902) | New proxy-webhook fault | Excluded |
| [#914](https://github.com/SREGym/SREGym/pull/914) | Internet-integrity/security fix | Draft, no reviews. It injects HTTP(S) proxy environment variables; a shell-capable evaluated agent can unset them or make a direct connection. Tests cover proxy matching/env injection, not adversarial bypass. |
| [#927](https://github.com/SREGym/SREGym/pull/927) | New Postgres-lock problem | Excluded |
| [#932](https://github.com/SREGym/SREGym/pull/932) | New ProcessOracle | Excluded |
| [#933](https://github.com/SREGym/SREGym/pull/933) | AlertOracle bug fix | Open, no reviews. Baseline filtering uses only `alertname`; a preexisting alert can suppress a newly affected instance or recurrence with the same name. Tests do not vary other labels or recurrence. |
| [#944](https://github.com/SREGym/SREGym/pull/944) | New hostAliases problem | Excluded |

### Reference comparison

The paper defines each problem as environment, injected issue, fault, and oracle, and expects exactly two submissions: diagnosis and mitigation. It also says the fault plane is hidden from evaluated agents and describes noise as a separate loop coordinated by the benchmark.

| Reference-level expectation | Implementation deviation | Consequence |
|---|---|---|
| Exactly one diagnosis and mitigation response | Request contains only solution text; asynchronous success does not identify run/stage/request | Delay/duplicate/retry ambiguity |
| Coordinated run lifecycle | Driver, API, evaluator, agent, and noise progress independently | Completion barriers become correctness-critical |
| Hidden injection plane | Real kubeconfig is mounted into the evaluated container | Direct fault-plane visibility/bypass |
| State-based mitigation oracle | Predicates vary by problem and often see only current pod/deployment state | False success/failure and temporal reward hacks |
| Noise stopped for grading | Bounded join does not cancel or await apply completion | Oracle may observe non-quiescent state |
| Fresh problem environment | Persisted, unversioned, asymmetric baseline reconciliation | Crash/restart and cross-cluster provenance risk |

## Phase 3 — Deep Analysis

### F1. Timeout/exit can tear down an environment under evaluation

**Status**: Confirmed current concurrency defect.  
**Severity**: High.  
**Model suitability**: High.

Execution:

1. API accepts diagnosis and starts `_submit_evaluate_and_advance` (`sregym/conductor/conductor.py:516-568`).
2. Oracle evaluation remains in flight (`sregym/conductor/conductor.py:468-500`).
3. Driver timeout kills the agent and immediately calls `_finish_problem` without awaiting/cancelling the future (`main.py:393-404`).
4. Cleanup can undeploy the app while the oracle reads it (`sregym/conductor/conductor.py:319-365`).
5. The worker later clears `_evaluating`, computes the next index, reopens mitigation, and can restart noise (`sregym/conductor/conductor.py:500-514`).
6. Main can concurrently flatten `conductor.results` for permanent publication (`main.py:428-463`).

Agent-exit has a partial barrier, but it is bounded at 300 seconds and proceeds after timeout (`main.py:412-424`). `start_problem()` protects only the normal following-start path by awaiting a still-pending future (`sregym/conductor/conductor.py:399-407`).

### F2. Submission identity is implicit and mutable

**Status**: Confirmed protocol gap.  
**Severity**: Medium to High for generic HTTP/MCP clients.  
**Model suitability**: High.

- HTTP `SubmitRequest` has only `solution` (`sregym/conductor/conductor_api.py:110-115`).
- MCP has only `ans` (`sregym/conductor/conductor_api.py:23-53`).
- There is no attempt, problem, stage, generation, or idempotency key.
- The endpoint retries `RuntimeError` for 60 seconds without pinning the originally observed stage (`sregym/conductor/conductor_api.py:114-148`).
- `_evaluating` is cleared before stage advance, creating a retry-crossing seam (`sregym/conductor/conductor.py:500-505`).
- A duplicate during evaluation is discarded but acknowledged by the conductor (`sregym/conductor/conductor.py:537-543`); the endpoint then returns a generic accepted response.

Stock TierZero and Stratus drivers explicitly poll for mitigation/done (`clients/tierzero/driver.py:307-323`; `clients/stratus/stratus_agent/driver/driver.py:807-817`). That is a compensating client convention, not an API invariant.

### F3. Cleanup is not a durable phase ledger

**Status**: Confirmed current failure seam.  
**Severity**: High.  
**Model suitability**: Medium; tests and code review are also appropriate.

`_cleanup_sync` catches noise-stop and reconciliation errors, but does not protect `problem.recover_fault()` or `problem.app.cleanup()` with `try/finally` (`sregym/conductor/conductor.py:331-361`). If either raises:

- stage remains `tearing_down`;
- the stage-only idempotence guard rejects retry (`sregym/conductor/conductor.py:378-382`);
- an already-exceptional future is cleared without observing its exception because `start_problem()` awaits only a not-done future (`sregym/conductor/conductor.py:399-407`);
- a retry/next deploy can cross partially completed cleanup.

There is a second stale-stage seam: `start_problem()` replaces problem/results before `deploy_app()` sets stage to `setup`; failures in dependency/fix/stage/leftover cleanup can occur while the prior `done` value remains, causing main's cleanup safety call to no-op (`sregym/conductor/conductor.py:409-438,782-796`; `main.py:314-361`).

### F4. Persisted baseline has no provenance or completeness contract

**Status**: Confirmed design defect/risk.  
**Severity**: High on cluster reuse or partial API failure.  
**Model suitability**: High.

- Cache path is fixed at `~/cache_dir/cluster_baseline_state.json` (`sregym/paths.py:11-16`).
- Serialized data has no schema version, cluster UID/context, capture timestamp, or field-success bitmap (`sregym/service/cluster_state.py:48-96`).
- `from_json` turns every missing field into an empty set/dict (`sregym/service/cluster_state.py:98-113`).
- Capture performs sequential listings (`sregym/service/cluster_state.py:130-149`); each helper converts `ApiException` into an empty value (`sregym/service/cluster_state.py:352-395,451-511`).
- The result is written directly, not through an atomic temporary-file replace (`sregym/service/cluster_state.py:153-163`).
- The conductor loads/reuses it once per process and sets `_baseline_captured=True` (`sregym/conductor/conductor.py:787-796`).

Reconciliation deletes current-minus-baseline namespaces, RBAC, PVs, storage classes, CRDs, and webhooks (`sregym/service/cluster_state.py:184-350`). It does not recreate deleted baseline objects or restore arbitrary edits. Node labels, taints, and CoreDNS are the only value-level restorations (`sregym/service/cluster_state.py:337-347,539-624`).

`delete_namespace()` logs non-404 errors without raising (`sregym/service/kubectl.py:498-509`), yet reconciliation appends the namespace to its “deleted” report (`sregym/service/cluster_state.py:208-217`). Thus even the cleanup summary is an issued-operation summary, not a verified postcondition.

### F5. Abnormal shutdown leaves recovery to ad-hoc next-run repair

**Status**: Confirmed current lifecycle gap.  
**Severity**: High.  
**Model suitability**: Fold into crash/restart baseline model.

- Driver crash performs agent cleanup and API shutdown only (`main.py:537-563`).
- KeyboardInterrupt/finally performs agent cleanup, optional noise stop, and a five-second driver join (`main.py:630-652`).
- Neither invokes `_finish_problem`, app cleanup, baseline reconciliation, or proxy stop.
- A next run performs many ad-hoc `fix_kubernetes()` repairs and cleans only the newly selected app before deploy (`sregym/conductor/conductor.py:429-438,702-780,873-876`).

External-harness mode intentionally exits with the injected fault active (`main.py:368-372`) and is excluded from this defect.

### F6. Noise stop is not a quiescence barrier

**Status**: Confirmed current race.  
**Severity**: High when noise is enabled.  
**Model suitability**: High.

`stop()` sets `running=False`, joins five seconds, discards the thread reference, cleans the recorded list, strips finalizers, and returns (`sregym/generators/noise/manager.py:84-95`). `_apply_experiment()`:

1. builds a manifest;
2. runs an unbounded shell command;
3. appends to `active_experiments` only after the command returns (`sregym/generators/noise/manager.py:125-157`).

If apply takes longer than five seconds, stop can clean/clear first; the late apply then appends a resource that was never deleted. A new `start()` can create a second worker because the old thread reference was discarded (`sregym/generators/noise/manager.py:71-82`). The fallback sweep strips finalizers but does not delete a late resource (`sregym/generators/noise/manager.py:205-245`). Evaluation starts after `stop()` returns (`sregym/conductor/conductor.py:476-505`).

### F7. Command failure often means “successful method return”

**Status**: Confirmed outcome-semantics defect.  
**Severity**: Medium to High across inject/cleanup paths.  
**Model suitability**: Prefer parameterized tests.

`KubeCtl.exec_command` uses `check=True` but catches `CalledProcessError` and returns stderr (`sregym/service/kubectl.py:714-724`). A checked variant exists (`sregym/service/kubectl.py:726-748`) but is used rarely: the audited source has 371 general calls versus 12 checked calls across generators/problems/apps.

Consequences include:

- Noise apply logs “Applied” and records an experiment after a failed command (`sregym/generators/noise/manager.py:150-155`).
- Noise cleanup logs cleaned and clears tracking without verified delete/patch outcomes (`sregym/generators/noise/manager.py:176-203`).
- Many fault injectors return normally, after which the conductor sets `fault_injected=True` (`sregym/conductor/conductor.py:219-231`).
- The `mark_fault_injected` decorator treats absence of an exception as success (`sregym/utils/decorators.py:1-14`).

History contains multiple fixes for the same semantic mismatch (`42efe88a`, `70afff60`, `55433a6b`), which increases confidence this is not merely stylistic.

### F8. Mitigation predicates permit degraded or unrelated states

**Status**: Multiple confirmed current predicate defects.  
**Severity**: High for benchmark score integrity.  
**Model suitability**: Local tests; model only abstract oracle soundness.

1. `MitigationOracle` captures `{deployment: replicas}` but later iterates only keys and requires current desired merely be nonzero/ready (`sregym/conductor/oracles/mitigation.py:23-32,66-84`). Baseline 3 → current 1/1 passes.
2. It has no `observedGeneration` check, so stale Deployment status is not explicitly ruled out.
3. `DeploymentReadinessOracle` treats zero as one while waiting, then treats zero as zero while grading and accepts `ready == desired` (`sregym/conductor/oracles/deployment_readiness.py:27-46,59-73`). Scale-to-zero passes after the settle timeout if other pods are healthy.
4. That oracle is used by `sregym/conductor/problems/admission_webhook_tls_mismatch.py:90` and `sregym/conductor/problems/psa_restricted_blocks_recreation.py:98`, with no direct tests.
5. Generic readiness cannot detect logical Mongo authorization/user faults even when pods are healthy (`sregym/conductor/problems/revoke_auth.py:33-53`; `sregym/conductor/problems/storage_user_unregistered.py:33-56`; issue #483).
6. `AlertOracle` fails immediately for any firing namespace alert (`sregym/conductor/oracles/alert_oracle.py:135-168`), including chronic unrelated #745. Draft PR #933's name-only baseline can overcorrect and hide a new same-name alert instance.

Existing `tests/oracles/test_mitigation_oracle_baseline.py:101-250` tests capture timing, deletion, zero scale, and under-readiness. It does not test baseline N→smaller nonzero, generation freshness, or functional workload health.

### F9. The evaluated agent receives the bypass credential

**Status**: Confirmed current benchmark-integrity defect.  
**Severity**: High.  
**Model suitability**: Code review only.

The conductor starts a proxy and gives AgentLauncher a generated filtered kubeconfig (`sregym/conductor/conductor.py:101-122`; `main.py:222-225`). `ContainerRunner` mounts that file at `/root/.kube/config`, but also mounts host `~/.kube/config` at `/root/.kube/real-config` and exports `SREGYM_REAL_KUBECONFIG` (`sregym/service/container_runner.py:253-263`).

The mount was introduced so Stratus workload oracles could bypass filtering (`clients/stratus/weak_oracles/workload_oracle.py:20-43`). The workload oracle and untrusted evaluated agent share the same container and filesystem, so there is no privilege separation. Read-only mounting prevents credential edits, not direct cluster use.

### F10. Proxy filtering is post-effect and incomplete

**Status**: Confirmed mediation defects.  
**Severity**: High independently of F9.  
**Model suitability**: Code review/integration tests.

- Direct hidden namespace paths are correctly blocked before forwarding (`sregym/service/k8s_proxy.py:211-222,303-306`).
- Cluster-wide response filtering recognizes a fixed built-in list only; custom resources and discovery paths are not covered (`sregym/service/k8s_proxy.py:265-297`).
- Individual hidden-label checks occur only after the request is forwarded and a response is read (`sregym/service/k8s_proxy.py:299-349`).
- PUT/PATCH can mutate before the proxy returns 403; DELETE commonly returns a Status without the deleted object's label.
- All HTTP verbs use the same forward-first path (`sregym/service/k8s_proxy.py:372-391`).

Conditional gaps, kept below the primary claim:

- in-cluster bearer token is read once and not refreshed (`sregym/service/k8s_proxy.py:71-81,180-188`);
- out-of-cluster parsing handles client cert/key but not every token/exec/auth-provider kubeconfig form (`sregym/service/k8s_proxy.py:92-154`);
- generated kubeconfig always uses loopback, while macOS containers deliberately do not use host networking (`sregym/service/k8s_proxy.py:415-467`; `sregym/service/container_runner.py:240-250`).

### F11. `fix_kubernetes` can downgrade the cluster

**Status**: Confirmed current defect and open #808.  
**Severity**: High operationally; direct, not formal.

Every `start_problem()` calls `fix_kubernetes()` before deployment (`sregym/conductor/conductor.py:421-438`). It invokes:

```text
recover_daemon_set_image_replacement(
    daemon_set_name="kube-proxy",
    original_image="registry.k8s.io/kube-proxy:v1.31.13"
)
```

at `sregym/conductor/conductor.py:702-709`. Recovery rewrites any different image and restarts the DaemonSet (`sregym/generators/fault/inject_virtual.py:2376-2392`). There is no check that this run injected the fault and no capture of the actual pre-fault image.

### F12. Container cleanup can mistake a nonzero Docker result for success

**Status**: Confirmed implementation gap.  
**Severity**: Medium.  
**Model suitability**: Test/code review.

`ContainerRunner.stop_container()` calls `docker stop` without `check=True` or return-code inspection; force remove runs only if `subprocess.run` raises (`sregym/service/container_runner.py:401-425`). A normal nonzero result does not raise. `AgentLauncher.cleanup_agent()` then reaps/kills the Docker client process and removes tracking (`sregym/agent_launcher.py:168-198`), potentially leaving the container.

Shell-launched agents have a stronger process-group path (`sregym/agent_launcher.py:212-256`), so this finding is container-specific.

### F13. Lower-priority current/conditional findings

| Finding | Evidence | Disposition |
|---|---|---|
| Train-ticket Jaeger emits no traces | #558 and PR #663 discussion; special wiring at `sregym/conductor/conductor.py:847-868` | Direct integration fix |
| Unrestricted internet allows benchmark-source lookup | #911; host networking at `sregym/service/container_runner.py:45-54,240-251` | Direct isolation fix; PR #914 env-only proxy is bypassable |
| Partial resume duplicates attempts | counts loaded at `main.py:255-280`, loop restarts at `main.py:307` | Unit/integration test |
| Proxy token refresh and auth-type coverage | `sregym/service/k8s_proxy.py:71-154,180-188` | Conditional platform/auth tests |
| Docker Desktop loopback kubeconfig | `sregym/service/k8s_proxy.py:415-467`; `sregym/service/container_runner.py:216-225,240-250` | Conditional macOS integration test |

## Compensating Mechanisms and Explicit False-Positive Exclusions

1. **Normal final-submit cleanup is ordered.** Synchronous cleanup in the evaluator and the pending-future wait prevent the exact fixed #674 race on the ordinary path (`sregym/conductor/conductor.py:319-407,468-568`).
2. **Reconciliation failure is not silently ignored in logs.** It is caught/logged and `done` is still published (`sregym/conductor/conductor.py:353-365`). The remaining problem is that “done” means attempted, not verified.
3. **Stock clients reduce stage ambiguity.** TierZero and Stratus poll exact next stages. The API remains uncorrelated for other clients and delayed messages.
4. **Hidden namespace paths are preblocked.** Proxy findings are restricted to alternate credentials, custom/discovery listing, label-hidden resources, and mutation ordering.
5. **Real kubeconfig exposure is intentional for a workload oracle.** The defect is the lack of a separate privilege domain, not accidental file creation.
6. **Many problems use custom or compound oracles.** Generic-oracle claims are restricted to problems actually using it and to its local predicate.
7. **Affected new Khaos reward-hack problems are disabled.** #753 is mechanism evidence; the formal question targets generic late noise/fault effects, not re-enabling a closed configuration.
8. **Dedicated stable clusters reduce stale-baseline probability.** They do not supply cluster identity, capture completeness, atomic persistence, or crash restoration guarantees in code.
9. **`exec_command_checked` exists.** The defect is broad use of the unchecked method where success state is subsequently recorded.
10. **External harness intentionally leaves the fault active.** It is excluded from abnormal-exit cleanup expectations.
11. **#290 is unverified, #351 is environmental, and #559 is a one-off transport failure.** None is presented as a confirmed model target.
12. **Closed historical bugs are not MC targets.** #408/#410/#650/#674/#704 appear only as evidence that the mechanisms are error-prone.

## Scenario Prioritization

| Scenario | Severity | Evidence density | TLA+ leverage | Priority |
|---|---|---|---|---|
| Evaluation versus timeout/teardown | High | High, including current exact path | High | High |
| Crash/restart baseline provenance | High | High, historical and current | High | High |
| Noise/fault quiescence versus oracle | High | High, open issue plus current race | High | High |
| Submission run/stage correlation | Medium–High | High; stock-client compensation | High | Medium |
| Cleanup phase exceptions | High | Current exact path | Medium | Test/code review plus lifecycle extension |
| Proxy/credential isolation | High | Direct proof | Low | Code review/integration |
| Local oracle predicates | High for scores | Direct proof | Low | Unit/integration tests |
| Hard-coded kube-proxy recovery | High operationally | Direct proof/open issue | None | Code fix/review |

## Verification Classification

### Model-checkable

- timeout/exit interleavings with accepted evaluator work;
- stale/delayed/retried submissions across stage/run transitions;
- crash/restart, partial baseline, and reconciliation ownership;
- late noise apply or fault reattachment across stop/evaluation/next run.

### Test-verifiable

- baseline replica 3 → current healthy 1 must fail;
- `DeploymentReadinessOracle` desired=ready=0 must fail immediately;
- logical Mongo faults require functional workload/auth probes;
- AlertOracle baseline identity and recurrence behavior;
- unchecked command nonzero propagation;
- blocking noise apply followed by stop;
- partial/missing/stale baseline validation;
- cleanup exception retry/phase behavior;
- Docker stop nonzero handling;
- partial resume attempt numbering.

### Code-review-only

- remove/separate the real kubeconfig;
- authorize proxy mutations before forwarding;
- enforce egress below the evaluated agent privilege boundary;
- capture actual kube-proxy image instead of hard-coding it;
- define shutdown ownership and cleanup ledger;
- instrument train-ticket and require nonempty traces.

## Validation Performed

- Re-read exact current code for every reported finding and traced callers.
- Checked local history and issue/PR discussions for fixes, reverts, superseding designs, and branch duplicates.
- Searched tests for lifecycle, noise, proxy, baseline, container, and oracle coverage.
- Parsed 11 selected core files successfully with Python 3.10's AST parser.
- Confirmed the target repository remained clean; no source files were modified.

Runtime tests were attempted with:

```text
uv run pytest -q tests/oracles/test_mitigation_oracle_baseline.py \
  tests/generators/test_checked_kubectl.py \
  tests/conductor/test_calico_route_reflector_cleanup.py
```

The command could not run because `uv` is not installed. The host has Python 3.10 and no `pytest`, while `pyproject.toml:3,119` requires Python 3.12+ and declares pytest. This is an environment limitation, not a passing or failing test result.

## Phase 4 — Modeling Brief Handoff

The model should abstract Kubernetes effects to fallible, delayed messages and retain only resource identity/origin/value. It should not model Kubernetes schedulers, Helm, CRD schemas, LLM semantics, or individual fault scripts.

The exact variables, split actions, invariants, forward-looking MC questions, test candidates, direct review findings, and source pointers are in `modeling-brief.md`.
