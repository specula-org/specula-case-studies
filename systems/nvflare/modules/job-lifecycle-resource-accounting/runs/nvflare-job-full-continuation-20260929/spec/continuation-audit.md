# Phase 3 continuation audit

Source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. This extends the Phase 2
[takeover review](../takeover-review.md) and [action-by-action audit](../adoption/model-audit.md).
The original Claude run was interrupted by credit exhaustion during hunting,
before independent confirmation. Its labels and no-counterexample runs are
historical evidence. This phase uses the configured GPT-6 Astra/max; separate
GPT-5.5/xhigh confirmation, repair dispatch, classification and final reporting
belong to the launcher. No product logic has been changed.

## Records independently inspected in this phase

Read handoff `conversations/README.md` and `index.json`, the four main transcript
decision navigations in `adoption/conversation-navigation`, and original chunks:

- `01-analysis.md:9700–9850`: lifecycle controls, runner-removal harness correction.
- `02-specification.md:13040–13115`: synthetic TLC-derived replay, negative
  controls, F16 cfg actually stopping at F1. These are not implementation traces.
- `03-harness.md:16720–16835`: seven instrumentation-induced unit failures and
  the hook-argument repair. Disabled-hook equivalence is necessary but does not
  establish transparency of the active tracing lock.
- `04-validation-and-hunting.md:13875–14038`: MC-E residual addition, three-trace
  sanity replay, next 27-state failure, and the final credit-exhaustion message.
- `analysis-agent-aa05006549b97b289.md:8850–8953`: N5 injected status-write
  failure; K2v supported stale-delete ordering; N3/F5, N4/unsafe, N6 poison probes.
- `analysis-agent-a9b2b77d6bf662997.md:9810–9875`: real CellNet parent-process
  death causing continued notify retries. This was not a full local deployment.
- `analysis-agent-ab99a5ff5dbe12529.md:7350–7445`: SE-3 re-registration probe,
  including the missing SSL/config errors and substituted authentication edges.
- `analysis-agent-ac097fcff7aa25dcb.md:9800–9820,10110–10160`: forced-thread E6
  status race and late UPDATE/heartbeat E7 controls, followed by interruption.

The Phase 2 audit's complete transcript/asset hash manifest is retained. The
chunks above supplement it with direct inspection of the decisions relevant to
current repairs and counterexamples. No newer source, external answer, other
experiment or home-directory memory was consulted.

## Independent source checks and semantic changes

Abbreviations follow the adoption audit: JR job_runner.py, SE server_engine.py,
FS fed_server.py, JC job_cmds.py, JD job_def_manager.py, CX client_executor.py.
The generator `repair_continuation.py` starts from `history/continuation-r0` and
reproducibly writes the working base/MC/Trace modules. Individual run snapshots
and their hashes are frozen under `output/continuation-*/`.

| Obligation | Current treatment and remaining boundary |
|---|---|
| V01 scan/store | Per-object scan reads replace the all-job atomic read. Listing/read deletion, blind status writes and refresh/deployment RMW retain their source windows (JD:524–531; JR:650/661/670/674/697/711; storage:265–275). Tag creation failure and non-status metadata fields are unmodeled. No claim covers all filesystem transactions. |
| V02 deployment/I/O | Partial target success and threshold failure, reservations surviving failed deployment, stale-delete storage absence and repeated publication failure remain modeled. Concrete workspace files, arbitrary transient I/O, archival cleanup, and callbacks remain source-only. JR:493–522 bounds archival retries; :524–530 retries status publication without that bound. RS-7's injected transient error is retained separately from the delete-triggered MC-D path. |
| V03 startup | Separate launch, parent process registration/waiter availability, pending initialization and per-site START send (JR:304–310; SE:315–329/1073–1083). Normal SJ finish requires parent participant-list bootstrap (server_app_runner.py:82; SE:828–846). It does not require CJ startup: ServerRunner:185–237 invokes a controller without a universal child-start barrier. START reply validation, pending intersection and JOB_STARTED remain a coarse serialized projection; strict-mode/site-threshold variation, post-spawn thread-start failure and E6 are outside it. |
| V04 outcome/latch | Separate initial server classification, pending barrier, abort marker read, exception lookup/abort fanout, and latch. Separate REPORT pending acceptance, authoritative active fail_run, cleanup RPC, unsafe-stop marker, and resolve. JR:817–835 explicitly rejects an inactive job and does not create an exception entry; old contract T5 was wrong. A source-level pending report can still be accepted before running insertion, which is MC-U1's question. UPDATE_RUN_STATUS's own retained-reference read/write and dictionary identity replacement are still coarse. Individual critical sections do not serialize the whole finalization operation. |
| V05 admin concurrency | One delete context independent of one abort context per job; source status snapshots are preserved. Multiple simultaneously in-flight aborts or deletes of the same job remain a finite input bound. Delete storage effects are one projected removal, not every file operation. |
| V06 sessions/heartbeat | Current session membership, disable, heartbeat cleanup and one live-run-map sweeper race remain. Session generations, re-registration, live client-map iteration, stale logout token, delayed heartbeat snapshots, SJ heartbeat and full shutdown/restart remain absent. These are user-scope gaps, not silently categorized as HA. SE-1 A/C, SE-3, E7 heartbeat and F18 remain in the confirmation queue. |
| V07 waiter/group | SpWaitRead occurs only after process exit; only a real prior read retains a removed record. Termination and process-table pop are separate. CP reap/report precedes free/pop; getpgid after reaping cannot kill the remaining same-group descendants. SE:204–233/402–409; CX:628–681; process_utils.py:293–316. The live source uses rc files and launcher normalization; typed codes must be established in confirmation, not supplied directly as an unexplained report. |
| V08 resources | Atomic reserve/cancel/allocate/expiry follow the RM lock, and list-unit conservation remains meaningful. AutoCleanResourceManager:41–44 rejects noninteger/nonpositive expiry even though the GPU subclass annotation is broader; no fractional-expiry leak is inferred. The discrete list-unit projection does not model GPU float subtraction/addition or CP-global CUDA environment binding (F8/F13). List-unit exclusivity is not a default-GPU sharing contract (F14). |
| V09 ownership transfer | Token allocation, pending-handle registration, launch/exception cleanup and normal waiter free are represented. Real spawn/attach/event/thread-start are still coarse; same-token duplicate START is rejected by allocation, not the unsupported fresh-token app-missing leak. Public cooperative reachability is required for F9/F19. Post-spawn setup/cleanup failures remain source-only candidates, not invented plugin exceptions. |
| V10 parent death | CP death no longer forces OS child/group death or makes EventualCleanup true by definition. A cooperative child exit is possible without assuming fairness through a stuck notification loop. The trace harness still forcibly cleans fake children on CP death and suppresses dead-CP local-state comparisons; it cannot validate F11/CL-4/CL-6 or ordinary restart. |

The finalizer's pending wait is a selected serialized schedule in this finite
projection; it does not model every pass over other jobs while one job waits.
The model does not assert that a no-counterexample result covers these omitted
interleavings. Deadlines/expiry are nondeterministic/tick transitions, not proofs
of 20-, 60- or 900-second bounds. Server launch errors and ordinary client exits
are abstract outcome choices; a reported bug must have a concrete supported
source trigger and passing control.

## Trace evidence and non-vacuity

The inherited fresh Phase 2.5 batch passed 32/32 against the received suite.
After source repairs, 31/32 passed; the stale-waiter case exposed a missing
read-point event. The isolated patch now logs the actual SE:205 read under its
own trace section and captures `record_present`; Trace checks that argument and
the full post-state. All 32 scenarios were regenerated, their input/report
integrity checked, and all 32 replayed successfully on C2 and C3. The new hook's
32 existing server-engine tests pass identically on pristine, patched-disabled
and patched-noop copies. Logs are in `harness/evidence/continuation/phase3-*`.

Every logged wrapper validates the emitted state and advances the cursor.
`TraceMatched` remains configured. Finer model steps are allowed silently only
immediately before the matching coarse event, with matching job/client/message;
they are not arbitrary cursor-independent activity. This is compatible with
the selected trace schedule, not evidence for newly exposed interleavings.
The SJ bootstrap is inferred from the real prerequisite, since fake SJ bodies
do not execute it. Snapshot checks retain presence guards for absent records.

Five synthetic semantic corruptions fail TraceMatched: status, free pool,
pending set, publication order and waiter-read argument. Five malformed inputs
are rejected before replay. A syntactically valid truncated prefix can pass raw
TLC; the frozen report hash/count rejects accidental post-collection truncation.
Neither mechanism proves whole-system observation completeness. Synthetic
negative controls and old TLC-generated traces are not implementation evidence.

The harness's process-wide trace lock is stronger than product locks, and its
process/transport/authentication stubs and queued synchronous reports select
particular schedules. The resource observer independently records actual
allocate/free calls but shares token identity mapping. No trace establishes real
OS descendant cleanup, default GPU arithmetic, actual authentication or an
end-to-end deployment. Those limitations follow the evidence into confirmation.

## Invariants, residuals and fairness

Strict TerminalStable still fails: C1 depth 11 and repaired C2 depth 13 reproduce
F1. To continue Case C checking in the required MC.cfg, it uses the explicitly
named NoNovelTerminalOverwrite residual. Its writer/from/to categories are
tightened, but it still excludes categories, not just one witnessed execution.
It is not a proof of TerminalStable. Strict seed/writer probes and historical
strict configs retain the failing contract.

The other inherited residuals are not independent contracts:
AbortHonoredNovel can exempt a job forever; NoOrphanSlotNovel is globally
weakened by either dead lifecycle thread; FinalMatchesOutcomeNovel tolerates
start errors/KeyError and a historical stop window. Each is tracked as such in
the hunt coverage, with strict counterpart runs. A residual PASS cannot certify
an excluded thread-death effect on a later eligible job. Source-only checks and
the strict slot/outcome probes are retained rather than dropping those effects.

FinalMatchesOutcome and SjErrorNotMasked require per-counterexample contract
analysis. Tests `test_fail_run_ignores_job_already_finalized` and
`test_process_job_failure_fails_run_for_reported_client_failures` distinguish
finalized jobs from still-pending reports; an ever-recorded history flag alone
cannot establish a guarantee of retroactive finality. Late optional status
delivery and expiry/timeout policy are not automatically defects. PromptCancel
and StartFailureMatchesPolicy are diagnostic probes; documented non-strict START
timeouts do not enforce min/required sites (timeouts.rst:2432–2468).

Normal heartbeats, backoff choices and CHECK attempts are no longer cut off by
MC fault counts/state constraints. Original fault/input limits are not reduced.
S5 no longer uses a safety view/symmetry for its temporal property. Safety views
retain all behavior variables, the new `micro` state, fault counters and the
history used by the corresponding checks; client/unit permutations preserve
uniform configuration and do not permute ordered jobs. Liveness configurations
have no view/symmetry/state constraint. Weak fairness is an assumption on
modeled reactive actions; grouped-message fairness and normal child/group exit
do not prove progress under arbitrary real scheduling, unbounded failures or
worker hangs. No unbounded correctness claim follows from these searches.

## C5 synchronization and policy-oracle follow-up

The first group-resource hunt exposed a Case B precursor: a clean CJ exit before
the server runner existed. ClientAppRunner:71–80 notifies STARTED before
ClientRunner.init_run:743–778 synchronizes; ServerRunner:113–128 handles that
sync after its creation. C5 adds CjSyncRunner history while both processes are
alive, and requires it for clean CJ return and the projected STOPPED notification.
An early abort acknowledgment need not mean that init_run has returned. This is
a flat client topology projection. CJ notification loss/timeouts, hierarchical
sync and its concrete 60-second timer remain source-only obligations.

All 32 scenarios were regenerated again (2,286 events, 65 event types, 46 waiter
reads). The two randomized fake-process paths that previously returned cleanly
without a possible sync now take an explicitly logged nonzero process-edge
outcome. No real child bootstrap or networking is claimed. Trace lookahead forces
necessary hidden sync witnesses before the final SJ exit opportunity; it cannot
invent a sync after exit, advance the cursor, or skip logged state comparisons.
The old impossible traces fail, and the new 32/32 batch and 11 mechanism/control
assertions pass. Frozen evidence is in `phase3-C5-fresh-suite/` and the C5 replay
record. The earlier 25-failure replay included avoidable nondeterministic dead
branches; debugger evidence at normal_two_jobs cursor 71 identifies that wrapper
issue separately from the two actual stub-order defects.

PromptCancel's eight-state late-CHECK failure is Case A: automatic expiry is
documented; instantaneous cancellation is not. Its cfg keeps its original bounds
and now checks ReservationDrain for the finite batch under fair cleanup ticks,
without VIEW or symmetry, plus conservation and the TTL range. The temporal drain
oracle is falsifiable by persistent reservations and is not implied by TypeOK;
the safety range is existing coverage, not an additional independent guarantee.

NoDeletedTrackedSlot was also narrowed before its first run: the post-publication
completion Remove state can legitimately overlap deletion. An independent runner
exception removing the same map entry can still kill completion there (historical
MC-D), and the strict CompletionAlive hunt independently reproduced that path in
38 states. Final-model run coverage and counterexample dispositions are recorded
in `hunt-ledger.json` and the final report.

## Provenance and downstream ownership

### Additional pre-hunt source checks on C5

The active-file rebuild from the preserved r0 baseline reproduces base/MC/Trace
byte for byte (`output/continuation-C5-rebuild-check.json`). A fresh preservation
check matches all 4,301 original artifacts and 20 raw conversations, confirms the
exact source pin and finds no tracked product diff
(`output/continuation-C5-preservation.json`).

Typed client UNSAFE evidence remains conditional: ProcessHandle.poll maps raw
102 to generic execution error; ClientExecutor then maps generic STARTING errors
to 104. MPM.run:178–199 writes a typed rc file only when non-daemon threads remain
after its cleanup grace (or preserves a component-written authoritative file).
The model's RC_UNSAFE input explicitly selects that preserved-102 path. A later
UNSAFE counterexample must retain that precondition and cannot be confirmed by
injecting a bare OS exit 102 or a direct handler payload. The ordinary generic
STARTING error path used by F5 does not need this typed-file assumption.

START policy was rechecked in admin.py:85–139 and JobRunner:309–364. Explicit
error bodies fail even in non-strict mode; missing-target reply count also fails.
Timeout exclusion in default non-strict mode is documented in timeouts.rst and
does not enforce min/required sites. The S5 oracle is therefore a diagnostic
pending Case A disposition, not evidence of a promised cross-phase tolerance.

All F1–F20, R1, RS/CL/SE/E leads, lower-priority archaeology, refutations and
contract discrepancies remain in [findings-reconciliation.md](../adoption/findings-reconciliation.md).
That file is mandatory for consolidation. Do not omit source-only candidates
because Phase 3's findings.json is correctly restricted to MC findings.
MC-A–E are historical variants/seeds, including mechanisms already seen before
the interrupted hunt; they are not new GPT discoveries. MC-U1 is retained for
explicit source/contract classification, not accepted merely on its old failure.

Original supplied assets are immutable. Product source remains at the pin;
instrumentation runs only in the disposable copy. Original Claude spend is
$180.5573146 including preflight. Codex subscription usage must be reported
separately by the pipeline; API-equivalent estimates are not new Claude charges.

Per-run outcomes, repairs and final phase status are recorded in changelog.md
and the final bug-report/coverage artifacts. This audit is not a confirmation or
classification verdict and does not preempt the configured reproduction model.

## C6 source ordering and diagnostic dispositions

C5's new per-site START step conflated request construction with delivery.
SE:1070–1083 resolves all names into the request dictionary before invoking
_send_admin_requests. C6 retains per-site lookup/disable interleavings but sends
only after construction finishes. This removes impossible early client execution
before a later lookup, without reducing any input/fault bound. All 32 fresh traces
replay; VAV reports zero assignment issues. The exact replay inputs/model hashes
are frozen in output/continuation-C6-trace-manifest.json. C5 is historical evidence;
C6 requires its own MC.cfg and full seed/hunting results.

H2 independently found historical MC-E with AdminMarkAborted between completion's
marker read and its latch. The residual now also tolerates runAborted for this
known class; NoStoppedSuccess remains the strict falsifiable probe. This is not a
repair of product behavior or a strict-outcome PASS. The ground-truth probe's
undelivered fire-and-forget UPDATE is Case A for an unconditional reliable-signal
claim; the cfg now checks recorded execution errors. F17/F20 remains a source-only
candidate requiring end-to-end failure/contract confirmation. Recorded-error
history can become TRUE and COMPLETED is reachable, so the replacement is not
TRUE, a type predicate or an unreachable-antecedent trick.

S5's 25-state missing-target failure matches admin.py:102–105, even with one good
reply meeting min_sites. Cross-phase START tolerance is removed as not applicable.
The same fault/topology bounds now check tracking, publication and slot ownership,
which have reachable started/held/latch states. They are structural lifecycle
coverage, not an independent min/required-site policy claim. Neither Case A row
is promoted into Phase 3's MC findings; the source-only policy review is retained.

The repaired C5 group-resource witness includes CJ sync and is retained as F10.
A missing STOPPED observation does not invalidate clean exit: unlike STARTED,
ClientAppRunner.notify_job_status receives retry_timeout=None and returns after
one send regardless of reply (:196–197). Source/model evidence of release while a
same-group descendant survives still needs a cooperative supported subprocess,
real local OS behavior and allocation control in the separate confirmation phase.

## C7 failed-sync deadline projection

ClientRunner.init_run:739–778 raises after its configured deadline when its SJ cannot answer SYNC_RUNNER; run:689–690 leaves that exception outside its training-loop catch, and worker_process:123–130 propagates it through ordinary shutdown. CjSyncTimeout selects this path when STARTED was observed, synchronization never succeeded, and the SJ has exited. The transition is reactive and therefore is not disabled by MaxCjError=0. It assumes the ordinary non-stuck exception cleanup already used for process-exit progress. Arbitrary cleanup hangs, typed rc-file outcomes and timeout while an SJ is merely delayed are still outside this specific transition. It adds no numeric time guarantee. All original fault bounds and generic error/descendant choices remain unchanged.

This action is MC/source-derived only: the fresh harness does not execute the real SYNC_RUNNER deadline. Its generic CjExit projection remains the recorded process-edge event; trace replay does not establish the new timer or fairness assumption. C7 replays the same 32 fresh observations with TraceMatched and zero VAV issues. See output/continuation-C7-trace-manifest.json.

## C7 resumed-session evidence integrity

On the explicit continuation, source HEAD and tracked diff were rechecked, the interrupted 46-second C7 task was preserved rather than counted as a result, and the unchanged model was relaunched with its full budget. The byte-identical rebuild, current trace/report hashes, TraceMatched wiring and corruption controls pass (`output/continuation-C7-rebuild-check.json`, `continuation-C7-artifact-preflight.json`). A new preservation check matches all 4,301 supplied artifacts and 20 raw conversation hashes (`continuation-C7-preservation.json`). All 33 source-review Scenario headings remain enumerable for the launcher. No completed adoption or harness analysis was restarted.

The resumed pre-hunt check also followed ServerRunner.run:185–237 through participant hierarchy setup and workflow execution/teardown, and ClientRunner.run:689–702 through its uncaught init_run deadline. The SJ bootstrap prerequisite is a parent membership handshake, not proof that all CJs have started. A fast cooperative Controller implementation remains a supported-API hypothesis for MC-U1; actual local-deployment timing and successful-start controls remain mandatory in confirmation. No process stub establishes that end-to-end schedule.

TBI.check_end_run_readiness (`nvflare/private/fed/tbi.py:59–90`) asks configured components whether teardown can finish, with a five-second default bound; it does not add a universal CJ-start barrier. Controller.control_flow is the public run-duration interface (`nvflare/apis/controller_spec.py:266–276`). These source checks preserve MC-U1 as an eligible timing/contract question without assuming that arbitrary instant success is observed in the harness.

## C8 dead-parent request deadline

The final timeout/fairness audit found that retaining cst across CP death (C1) accidentally kept StartRepliesLost false for an in-flight allocate/register handler. With MaxStartTimeout=0, MC would then require an impossible remote reply rather than allowing the ordinary local request deadline. This is a model omission, not a product hang. SE:1082 passes timeout_secs=20; admin.py:307-337 returns after all replies or timeout and has no dependence on the vanished remote handler's local state. New requests already target LiveOf clients, and ClientCrash drops queued client-bound messages; CheckRepliesLost therefore needs no analogous change.

C8 changes only StartRepliesLost: each missing reply is unavailable if its CP is dead, or if the old no-request/no-handler condition holds. Existing replies remain in StartReps and are excluded from the missing set. The unreachable-dead-parent guard in MaxClientCrash=0 configurations explains why those prior C7 witnesses remain useful, but all final evidence is nevertheless being rechecked under C8 rather than relabeling old runs. Source, traces, fault limits, action variables and invariant definitions are unchanged.

## Final C8 validation and launcher handoff — 2026-09-27

The Phase 3 verification work is complete under the authorized bounded-search
interpretation. All 32 fresh trace projections replay on C8, including the actual
waiter-read hook and corrected process prerequisites. The frozen suite contains
2,286 events, 65 event types and 46 waiter-read observations. Five semantic
corruptions fail TraceMatched, five malformed inputs reject, and a valid finite
prefix is distinguished from a complete scenario by report hash/count validation.
VAV reports zero assignment issues across 228 operators and 56 variables; this is
assignment coverage, not full conformance. The byte-identical C8 generator rebuild
and trace-debug cleanup are retained in their existing evidence files.

The unchanged MC.cfg completed its 30-minute budget at depth 39 with 74,561,992
distinct states and 32,570,191 still queued. All 25 hunting configurations, eight
seed checks and the optional depth-100 simulation were executed on the final
model and reviewed. Fifteen hunts reached Case C candidates; ten exhausted their
budgets without a reported violation. The optional CANT_SCHEDULE simulation
completed 780,167 traces without rediscovery, preserving RS-3 as a source-only
confirmation obligation. Every no-violation BFS exceeded depth 25. Finalization's
last temporal check was in progress at cutoff; no complete temporal verdict or
unbounded correctness claim follows. No model/configuration changed after this
convergence round, and no search bound was reduced for depth.

[bug-report.md](bug-report.md) and [findings.json](findings.json) contain 13 matching
MC candidate entries. [brief-coverage.md](brief-coverage.md) states all residual,
policy and out-of-model limits. `output/continuation-final-matrix.json` identifies
the selected frozen runs; `hunt-ledger.json` retains every classified witness,
interruption and source disposition. `output/continuation-C8-execution.json` has
no active or queued work. Final hash/report/source checks are recorded in
`output/continuation-C8-artifact-final.json`; the original-evidence preservation
check is `output/continuation-final-preservation.json`.

This completes validation, not independent implementation confirmation. The
launcher must consolidate the MC entries with all 33 source-review Scenarios and
the complete [findings reconciliation](../adoption/findings-reconciliation.md),
including Q/D and lower-priority rows. Use the configured serial GPT-5.5/xhigh
confirmation with public APIs, real local deployment where feasible, labeled
timing/fault controls and passing controls. Feed model/harness mismatches through
normal GPT-6 Astra/max repair/evolution before classification and final reporting.
Historical source seeds and MC-A–E/MC-U1 are rediscoveries; the V04 active-failure
trace is new concrete model evidence for a reopened source concern. No old
CONFIRMED label is treated as a completed continuation confirmation.

The original Claude run ended during hunting because of credit exhaustion. This
is a mixed-model continuation, with original Claude spend fixed at $180.5573146
including preflight. New Codex subscription usage and API-equivalent estimates
remain separate and are finalized by the launcher after the worker returns;
cumulative resumed-session usage exports must not be added together. Product
source remains pinned and unchanged. Publication, product fixes, pushes and
tracker writes were not performed.
