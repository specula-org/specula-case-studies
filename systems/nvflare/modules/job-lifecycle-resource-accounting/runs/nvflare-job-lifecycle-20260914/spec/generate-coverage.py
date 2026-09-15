from pathlib import Path
import re,json
P=Path(__file__).resolve().parent
cfgs={}
for p in sorted(P.glob('MC_hunt_*.cfg')):
 text=p.read_text(); active=[];mode=None
 for line in text.splitlines():
  s=line.strip()
  if not s or s.startswith('\\*'):continue
  if s in ['INVARIANTS','PROPERTIES']:mode=s;continue
  if s.startswith(('SYMMETRY','CONSTRAINT','CHECK_DEADLOCK')):mode=None
  if mode:active.append((mode,s))
 cfgs[p.name]=active
required=['ResourceConservation','ProcessBindingMatchesOwnership','NoFreeWhileInUse','CleanupOwnerOrCompleted','AcceptedPreRunAbortPersists','NoTerminalResurrection']
for inv in required:
 assert any(('INVARIANTS',inv) in vals for vals in cfgs.values()),inv
out='''# Brief coverage self-audit

Source: NVFlare `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Category A with explicit local concurrency boundaries. This audit reads the actual active INVARIANTS/PROPERTIES sections of the generated hunt configs; it is not an execution verdict.

The selected manager is ListResourceManager with gpu deque [0,1], one valid exclusive-unit demand per job/site and 30 cleanup ticks; consumer is ListResourceConsumer, launcher is the default local process launcher. Default admission is max_jobs=2, min_sites=1, required site-1; strict=False. Retry defaults remain 10, 10s and 600s. Configs also cover max_jobs=1, strict=True/min_sites=2, and three sites with two symmetric optional sites. Fresh token universe has 11 attempts per job; this is an explicit finite-workload boundary, distinct from the 10-attempt retry policy. No START retry for an already dispatched job is introduced.

## Brief section 2: scenarios

| Scenario | Target config(s) | Mechanism and limits |
|---|---|---|
| 1: shared process environment | MC_hunt_s1_environment.cfg; MC_hunt_s1_optional_symmetry.cfg | One start timeout leaves the first callback executing while the single server admission thread advances to the second job. Split allocate/consume/environment copy/spawn. Two disjoint allocations can be compared with actual bindings. |
| 2: cleanup ownership handoff | MC_hunt_s2_cleanup_handoff.cfg; MC_hunt_s2_partial_start_strict.cfg | One client waiter-installation exception after successful spawn follows processor rollback. The extra strict config covers partial deployment, prelaunch and spawn failure, and participant policy. CR-1 returned-error branch is represented but has no fabricated fresh-allocation trigger. |
| 3: status publication windows | MC_hunt_s3_abort_status.cfg; MC_hunt_s3_terminal_status.cfg | Explicit split into MC-3 and MC-4: saved status read versus later deployment/RUNNING write; running-map registration versus completion terminal publication/removal. |
| 4: logical termination versus physical cleanup | MC_hunt_s4_exit_cleanup.cfg; merged cleanup-handoff checks in Scenario 2 | Real stop/pending-handle/heartbeat routes, live STOPPED child, wait-before-free, report failures, finite outcome and archive delays, ABORTED then COMPLETED notifications. No universal live-process/scheduler-count equality. |
| 5: admission/completion service containment | MC_hunt_s5_scheduling_progress.cfg | Known admission-exception baseline, TTL backstop, deferred retry-history persistence, capped exponential backoff and a second job under max_jobs=1. Fair progress config assumes live services, successful failure-branch store operations, eventual normal child exit/delivery/cleanup ticks. TV-2 and TV-3 service-death extensions remain test-first as the brief requests. This is context coverage, not a rediscovery hunt for #5191. |

## Brief section 5: actual enabled safety properties

| Property | Definition / MC wiring | Hunt cfgs with the invariant enabled |
|---|---|---|
'''
for inv in required:
 enabled=', '.join('`'+n+'`' for n,v in cfgs.items() if ('INVARIANTS',inv) in v)
 out+=f'| {inv} | base.tla; inherited by MC EXTENDS base | {enabled} |\n'
out+='''
`MC.cfg` enables ResourceConservation and structural checks; all five extension invariants are listed but commented there. Each is actively enabled above. `CleanupOwnerOrCompleted` checks the safety ownership obligation; the optional `CleanupEventuallyReleased` covers waiter-owned allocation release under the separate fairness assumptions. Accepted pre-run abort persistence is a safety/history check; this suite does not claim a general abort liveness theorem.

## Brief section 6.1: reachable setups (source-based, not TLC results)

| Finding | Enabling setup | Observed property | Config |
|---|---|---|---|
| MC-1 | Two jobs, two units/site, max_jobs=2; first start callback delayed at consume/environment-copy; its waiter times out once; next admitted job changes environment | ProcessBindingMatchesOwnership; NoFreeWhileInUse | MC_hunt_s1_environment.cfg |
| MC-2 | One job; spawn succeeds, pending handle attaches and real AFTER_JOB_LAUNCH dispatch returns; Thread.start raises before cleanup waiter runs; processor rollback frees retained payload | NoFreeWhileInUse; CleanupOwnerOrCompleted | MC_hunt_s2_cleanup_handoff.cfg |
| MC-3 | One job; admin pre-run status read/write/successful reply interleave after a runner status check and before a later status write | AcceptedPreRunAbortPersists | MC_hunt_s3_abort_status.cfg |
| MC-4 | One job; server and clients may finish quickly, normal reports resolve outcome barrier, archival succeeds; completion interleaves after running-map publication but before RUNNING write | NoTerminalResurrection | MC_hunt_s3_terminal_status.cfg |

All required faults are enabled in those files: StartTimeoutLimit=1 for MC-1, WaiterErrorLimit=1 for MC-2, AdminAbortLimit=1 for MC-3. MC-4 needs no injected fault. Normal callback steps, process exit, resource cleanup, metadata success and completion are not counter-bounded. This table records source-based reachability; executed hunt results are in bug-report.md and output/run-coverage.json. Source reachability alone is not an implementation reproduction.

## Target priorities and evidence boundaries

1. **Q1 reservation/allocation:** atomic RM operations, deque multiplicity, token pop on allocation, missing-token rejection, TTL scans and idempotent cancellation are explicit. Unacknowledged cancellation is bounded reservation retention under fair ticks, not proof of a permanent allocation leak. Free uses retained payload with no invented token/idempotence guard.
2. **Q2 partial startup:** separate reserve/deploy/start response policies and actual child existence. Both raised startup exceptions and returned ClientEngine errors are represented; CR-1 lacks an established supported fresh-allocation trigger. Default non-strict mode counts received START replies for active metadata but does not re-enforce minimum/required-site policy after timeouts. Strict mode does; normal ERROR-prefixed replies fail either mode. Disconnected/structurally missing target snapshots and CR-5 header-only errors are not injected without producer evidence.
3. **Q3 termination:** logical STARTING/STARTED/STOPPED, stop command, pending abort, terminate request, OS exit, wait return, report, free, map pop and site event are distinct. The server terminate/pop ordering is represented without assuming permanently ineffective termination (CR-2). Normal client free follows wait. The no-waiter rollback is isolated by Scenario 2.
4. **Q4 identity:** messages carry job/site/attempt/operation; late replies only affect the matching waiting cell and closed waiters discard them. There is no fake wrong-job notification or duplicate fresh-token START. Real ABORTED/COMPLETED event pairs remove the same set membership idempotently. Site-local completion is not delivered to the server scheduler. Heartbeats derive aborts from actual server registry/outcome-key state and preserve the fixed outcome protection.
5. **Q5 progress:** candidate order is the submission order, with whole-pass exception containment preserved. Failed/blocked metadata writes occur after the candidate scan. Eventual progress is conditioned on finite faults and explicit fair service, transport, tick, process-exit and archive/retry actions. It does not promise success for permanently unavailable resources or beyond the finite fresh-token universe. TV-2/TV-3 remain production-test-first, so service death is not assumed impossible in NVFlare itself.

### Explicit abstraction/review boundaries

- Deadlines are untimed crossings with their actual durations retained in constants and enforced by Trace elapsed-time fields. Independent deadline crossings overapproximate time-consistent interleavings: a safety counterexample involving relative timing needs a real-time/source feasibility review. No timeout cancels an executing command. ReservationTTL=30 is not shrunk in hunt configs.
- RM cleanup tick and expired-token draining are separate *lock-held* internal actions; all other RM calls are disabled until draining finishes. The order of simultaneously expired tokens overapproximates dict insertion order. A queue-order-sensitive counterexample needs replay; multiplicity/ownership checks do not discard duplicates.
- Server outcome classes retain success, ABORTED and generic failure with stronger-code precedence; training and child-internal teardown are abstracted. Actual outcome producer/authentication and independent thread/service behavior need harness validation.
- The completion removal action requires the saved entry still exists. If failure cleanup removes it first, the Python KeyError/service-exit consequence is TV-3; `PendingCompletionRemoval` is a diagnostic, not an enabled claim or an invented repair. The suite must be extended after that local test before claiming completion-service conformance on that path.
- CR-3 invalid custom counts remains an input-contract finding; valid one-unit demands are the selected workload, not a claim that malformed counts are safe. CR-4 notification retry loop, CR-5 header-only error producers, and CR-6 disconnected empty target fallback remain code-review/test boundaries. Fixed historical guards and event identity are not reverted.

### Known issue status

[PR #5191](https://github.com/NVIDIA/NVFlare/pull/5191) was freshly retrieved on 2026-09-14 as **open, unmerged**, head `27ecde2ab85b38734072b90128dc5dc2e8390882`. The full PR body, issue discussion, reviews and inline review comments were read and saved as `pr5191-*.json`. The [expiry/tradeoff comment](https://github.com/NVIDIA/NVFlare/pull/5191#issuecomment-5432240101) concerns short-lived reservations and scheduling-pass/retry tradeoffs. Its proposed verify-and-log and cleanup changes are distinct from both the PR proposal and the pinned source. Overlap is known context, not classified as new.

## Execution status

This is the configuration/source coverage audit. Current execution coverage and limitations are recorded in `changelog.md`, `output/`, and the final `bug-report.md`; the initial generation-only receipt remains in `generation-validation.md`. Do not infer exhaustive completion or production confirmation from configuration wiring.
'''
(P/'brief-coverage.md').write_text(out)
(P/'coverage-enabled.json').write_text(json.dumps(cfgs,indent=2)+'\n')
print('coverage audit: 5 scenarios, 6 safety properties, 4 MC findings mapped; parsed',len(cfgs),'hunt configs')
