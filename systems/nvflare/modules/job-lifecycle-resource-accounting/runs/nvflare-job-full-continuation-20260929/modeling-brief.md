# Modeling brief: NVFlare job lifecycle and resource accounting

BYOM Phase 2 continuation at source 53ba7ee567468ea7971dad4faccef13c6cb35dc2. This brief preserves the supplied model's scope and adds a focused Scenario supplement. It supersedes adoption/supplied-modeling-brief.md's acceptance claims; detailed historical evidence remains in analysis-report.md and evidence/. No behavior or invariant was changed during adoption.

## 1. System and contract basis

Category A: distributed server parent (SP), client parents (CP), server job processes (SJ) and client job processes (CJ), communicating through request/reply and best-effort CellNet messages. Inside each parent, Category B-style thread interleavings matter: runner, admin handlers, completion, process waiters, expiry, heartbeats and client sweeper use different locks and snapshots.

Scope is the default local-process launch path: reserve → deploy → acquire/start → stop/exit → free, including later-job admission and ordinary failures. Exclude training aggregation, model transfer, GPU computation, alternative launchers and HA recovery. GPU bookkeeping/binding, ordinary CP/SP restart effects and process bootstrap are related coverage gaps; excluding HA does not exclude all process restarts.

Reference lifecycle: SUBMITTED; scheduler selects a feasible subset and reserves client tokens; deployment writes DISPATCHED; SJ launch and client START consume tokens; JOB_STARTED takes an admission slot; runner inserts tracking then writes RUNNING; SJ exit and client outcomes permit final publication, followed by end events releasing the slot. CP returns allocation after waiting for the CJ leader. Reservations expire independently. This sequence is descriptive, not a guarded state-machine guarantee.

Contract sources and caveats:

- docs/user_guide/core_concepts/job.rst:263–345 describes scheduling, nonadmission cancellation and one-shot jobs. Its distinct-GPU example uses ListResourceManager, not the default memory-sharing GPUResourceManager.
- Terminal status and abort acknowledgment are grounded in job_cmds.py:1058–1080 and job_cli.py terminal handling. Actual status setters use blind writes and unlocked file RMW; intended precedence must be checked per counterexample.
- ResourceManagerSpec and AutoCleanResourceManager define reserve/allocate/cancel/free. Existing list-unit invariant does not verify default GPU floating-point arithmetic or environment binding.
- docs/programming_guide/timeouts.rst documents non-strict START timeout tolerance. Explicit error, missing target and timeout need not have identical policy.
- Default provisioned scheduler max_jobs=4 (class default 1), GPUResourceManager(0 GPUs, 0 memory, expiry 300 ticks), GPUResourceConsumer, and non-strict START replies. A positive-resource experiment must state its supported configuration.
- Outcome deadline defaults to 900 seconds and archive grace to 60 seconds. Model ticks/deadline actions and eventual properties do not prove these wall-clock bounds.

## 2. Supplied Scenarios and focused supplement

| Scenario | Mechanism / original targets | Adopted coverage and focused next check |
|---|---|---|
| S1 — status writes (high) | Stale status reads, blind writes and metadata RMW across abort/delete/start/completion. F1/F3/F16, RS-3, MC-A/B. | Runner/admin/store PCs and history are useful. Audit **V01** all scan/store read/write windows and **V05** concurrent same-job admin handlers; latter is currently serialized by one adm[j] PC. |
| S2 — admission and cleanup threads (high) | Deleted or poisoned candidate kills/stalls runner; publication retry/orphan slot; completion/sweeper death. F2/F4/F7/F12, RS-7/8, MC-C/D. | Slots, runner/completion PCs, generic poison and partial sweeper model. **V02** ordinary store/deploy/archive failures; **V06** full client-map/session/sweeper behavior. Boolean end-event history is not an exactly-once event count. |
| S3 — resource lifetime (high) | Reserve/expiry/cancel/allocate/start, late requests, cleanup and descendants; F6/F9/F10/F19. | Bags, reservation TTL, in-handler allocation, pending handle, leader/group state. **V07** read/reap/report/free gaps; **V08** real configured resource accounting/binding; **V09** post-allocation and post-spawn exception ownership. F9/F19 remain defensive without a supported caller. |
| S4 — outcome composition (high) | SJ status update/rc, client failures, stop marker, pending barrier and publication latch. F5/F17/F20, RS-5, MC-E. | Separate channels exist, but several handlers/latches are over-merged. **V03** launch/registration/fanout; **V04** accepted failure, abort and publication ordering. Recovered MC-U1 must be classified, not preemptively exempted. |
| S5 — partial deploy/start policy (medium) | Subset deployment, disconnect, explicit START error, timeout and late start. F15, CL-1. | Existing policy probe covers only min=1, no required sites and default non-strict behavior. **V02/V03** partial workspace/token ownership and strict/required-site variants are gaps. |

Supplement arising from pinned-code cross-check, not a new broad Phase 1 investigation:

| Interaction | Source mechanism and hypothesis | Phase ownership / coverage gap |
|---|---|---|
| Launch → registration → pending → report | SE:315–330, JR:304–364 and FS:906–957 are separate steps. Early SJ exit and accepted client failure may precede running insertion. | V03/V04; repair granularity in validation, test MC-U1 and F5 with supported process behavior. |
| Finalizer reads → latch → publish → removal | JR:444–541 and fail_run/stop_run use multiple critical sections. Shared object identity does not serialize all writers. | V04; audit residuals against each accepted-signal boundary, retain RS-7/MC-D and MC-E controls. |
| Client session replacement → old-job cleanup | ClientManager replaces token; job participants retain old token/name. Late SJ HEARTBEAT can mark a normally completed job aborted. | V06; recovered SE-3 and E7 are source-derived out-of-model leads. Confirm actual authentication and late-message path. |
| Parent death → CJ notify retry → later allocation | CP shutdown loses in-memory ownership; cooperative parent watchdog does not interrupt STARTED notification retry. | **V10**, out of model; F11/CL-4/6 require real worker/deployment evidence. Existing crash action assumes immediate descendant cleanup. |
| Overlapping resource consume → process spawn | CP-global environment may be changed by a later timed-out/overlapping START before the first spawn. GPU floats can prevent restoration of exact capacity. | V08/V09, out of model; F8/F13 numerical/binding checks, no GPU computation. |
| Ordinary local restart / control files | Persisted job status, restart/shutdown markers and newly empty process tables can disagree. | F18 and lower marker lead remain gaps. Determine public single-server/client behavior without modeling HA recovery. |
| Fast SJ engine thread → main status write | FS start_run writes STARTED after starting the engine thread; run_engine may already have written STOPPED. | E6/V03, out of model; historical forced-thread shim is not a real deployment proof. |

## 3. Adopted state and boundaries

Retain base.tla (55 variables), MC.tla, Trace.tla, 27 cfgs, instrumentation-spec.md, historical repair snapshots, harness and evidence as starting assets. Model includes finite pre-submitted jobs, homogeneous clients/units, blind persisted status, scheduler slots, runner/completion/admin PCs, resource bags/tokens, child states, outcomes, session set, message multiset and selected history.

Key preserved boundaries: status checks versus writes; refresh/deployment metadata read versus write; admin authorization versus execution; START allocate/register/launch; completion latch/publish/remove; leader exit versus free; stop versus mark. [adoption/model-audit.md](adoption/model-audit.md) audits every Next action family and identifies additional source interleavings currently merged.

Absent mechanisms must remain explicit: concrete deployment files/archival, all store RMW fields, real session generations, actual process return-code files/groups, retry/bootstrap loops, GPU arithmetic/binding, ordinary restart and full shutdown. They are not silently encoded as successful cleanup.

## 4. Failure assumptions and model controls

Cooperative participants and supported APIs/configurations. Timing controls may select legal thread/message order; fault injection must correspond to an ordinary default-path failure. Do not treat arbitrary plugin exceptions, fresh-token duplicate START, app removal or forged process outcome as automatically supported.

Messages may time out/later execute or be lost where actual transport/caller allows it. Retries/heartbeats/expiry have real caller semantics. Unconstrained instantaneous clean SJ completion requires a supported workflow before a candidate depending on it is accepted.

Safety cfgs use 1–2 jobs/clients, 0–2 units and bounded faults, heartbeats and CHECK attempts. These are search bounds, including bounds on normal operations. All current MC cfgs disable SJ-launch failure and backoff; all use min=1/no required sites. Liveness cfgs omit constraint/view/symmetry, but fairness on broad disjunctions and normal process/descendant exit assumptions need review. Cleanup currently exempts dead CPs. No bounded success implies unbounded correctness.

## 5. Invariants and contract questions

Actual cfg wiring is in [spec/brief-coverage.md](spec/brief-coverage.md). Keep strict contract properties and separately named hunting residuals; do not fix product logic or encode desired behavior as action guards.

| Property | Type / meaning | Acceptance limit |
|---|---|---|
| TerminalStable; AbortHonored; OneShot | Safety: terminal status stability, acknowledged pre-run abort, at most one SJ launch. | Terminal-to-terminal precedence and acknowledgment timing need source-specific decisions. |
| RunningIsTracked | Safety: RUNNING has runner or tracking owner. | Does not detect every untracked live child. |
| RunnerAliveInv; CompletionAlive; SweeperAlive | Safety: ordinary operations do not kill lifecycle services. | Source-reachable failures only; sweeper model covers one of three known paths. |
| SlotBalance; NoOrphanSlot | Safety: bounded slots with lifecycle owner. | Idempotent end-event effect, not exactly one end notification. |
| ResourceConservation; ExclusiveOwnership; NoFreeWhileGroupAlive | Safety: list-unit accounting and group lifetime. | Resource interpretation and descendant ownership must match deployment; no GPU arithmetic claim. |
| ReservationBounded | Safety: TTL stays in configured tick range. | Structural tick property, not real-time reclamation proof. |
| FinalMatchesOutcome | Safety: final outcome reflects applicable accepted/recorded signals. | Separate pending report acceptance, authoritative recording and late arrival after finality. |
| AdmissionProgress | Liveness: eligible non-poisoned job eventually leaves SUBMITTED. | Availability/fairness/fault bounds and poison head-of-line behavior matter. |
| BoundedFinalization; EventualCleanup | Liveness: eventual finalization/removal and cleanup. | No wall-clock bound; current parent-death and child-exit assumptions require V10. |
| PromptCancel; SjErrorNotMasked; StartFailureMatchesPolicy | Diagnostic probes. | Immediate cancellation, guaranteed best-effort delivery and uniform site policy are not established contracts. |

Residual audit: KnownOverwrite exempts writer families, AbortHonoredNovel can exempt a job forever, NoOrphanSlotNovel exempts every slot once runner/completion dies, and FinalMatchesOutcomeNovel suppresses more than a single accepted trace. The old “exactly the seed mechanism” claim is rejected. Validation must narrow these or explicitly bound the resulting claims; retain strict seeds.

## 6. Findings and verification routes

### 6.1 Model-checkable questions

| Question | Targeting cfg family | Required evidence |
|---|---|---|
| MC-1: other status/abort interleavings and duplicate launch | MC_hunt_s1_contracts/status | Strict properties plus cause-specific residual search after V01/V05. |
| MC-2: later-job admission after ordinary failure/deletion/thread death | MC_hunt_s2_contracts/slots/slots_c2/sweeper, live_admission | Later eligible-job control, no globally vacuous orphan exclusion; V02/V04/V06. |
| MC-3: concurrent resource transfer under timeout/abort/exit | MC_hunt_s3_resources/groups/promptcancel | Valid unit conservation and concrete ownership/lifetime; V07/V08/V09. |
| MC-4: applicable outcome precedence under cleanup races | MC_hunt_s4_outcome/unsafe/groundtruth | Accepted-signal definition, real rc semantics; classify MC-U1; V03/V04. |
| MC-5: finalization and cleanup progress | MC_hunt_live_finalize/cleanup, s5_policy | Audit fairness, parent-death assumptions and partial-start policy; V02/V06/V10. |

### 6.2 Seeds versus discoveries

F1, F2, F3, F5 and F16 are source-derived fidelity seeds; F9 is unsupported/defensive. F16 requires the dedicated refresh probe, not any TerminalStable violation. MC-A through MC-E are historical MC variants mapped in the changelog, several already seen in original Phase 2 smoke or source leads. MC-U1 is the last unclassified historical trace. No new TLC finding or runtime confirmation was produced during adoption.

### 6.3 Full candidate queue

[adoption/findings-reconciliation.md](adoption/findings-reconciliation.md) retains F1–F20, R1, every RS/CL/SE/process lead, lower archaeology leads, contract discrepancies, refuted cases and MC-A–E/U1. All eligible candidates, including source-only/out-of-model ones, go to the configured separate confirmation phase. Policy/unsupported/environment-limited outcomes need explicit disposition. Historical unit/stub/process probes are evidence to rerun and improve, not final verdicts.

## 7. Next phase and provenance

[Takeover review](takeover-review.md), [model audit](adoption/model-audit.md) and [harness audit](adoption/harness-audit.md) are mandatory reading for the next invocation. The harness phase adapts working-copy paths and reruns all 30 scenarios to produce fresh traces, overriding BYOM's reuse default. Validation then replays them, repairs semantics in normal phases, rechecks named seeds, and completes convergence/hunting and confirmation/classification through the launcher.

Original Claude run interrupted at credit exhaustion before confirmation; original spend $180.5573146 including preflight. This is an authorized mixed-model continuation: GPT-6 Astra max for reasoning/verification/repair/classification; configured GPT-5.5 xhigh for separate confirmation. New Codex subscription usage is accounted separately; API-equivalent estimates are not Claude charges.


## 8. Phase 3 handoff preservation: explicit source-review Scenarios

The launcher consolidator enumerates `Scenario N:` headings. The adopted brief's
S1–S5 table and linked reconciliation ledger alone did not create that enumerable
set. The following headings preserve the already-audited source candidates;
they are **not new model-checking discoveries or confirmation verdicts**. Read
`adoption/findings-reconciliation.md` for every historical alias, control,
unsupported variant and required source/deployment check. Merge a Scenario into
an MC finding only when its mechanism and affected source site are covered; a
common broad theme does not cover a distinct lower-priority consequence.

### Scenario 1: Acknowledged queued abort lost to lifecycle status writes

F1/I4/I5 and MC-A/B: JC:1058–1080 snapshots status; JR:670/674/711/720 and
completion :524 write without a shared status transaction. Confirm the public
abort acknowledgment and subsequent launch/status transition, including the
metadata-RMW and completion-writer variants, with a nonoverlap control. A launch
already underway differs from one begun after the acknowledgment.

### Scenario 2: Delete races kill the scheduler or strand admission capacity

F2/RS-1/RS-8, MC-C and R1's deletion case: JC:282–316/507–535 uses an authorization
snapshot, while JR:650/661/711/720 and completion :524 access the deleted store
object. Distinguish scan death, failure during startup, and repeated terminal
publication failure after RUNNING. Require a later resource-eligible job and
thread/slot evidence; do not call a finite wait permanent starvation without the
source loop or thread-death mechanism.

### Scenario 3: Completion precedes the runner's RUNNING write

F3: JR:709–711 inserts tracking and writes RUNNING separately; completion
JR:524–538 can publish/remove first. Confirm an actual early SJ exit, preferably
a supported error exit, then terminal-to-RUNNING and absent tracking. Preserve
a control with the RUNNING write preceding completion.

### Scenario 4: Accepted malformed public job metadata blocks later jobs

F4/RS-6: the validator checks an integer conversion without normalizing raw
min_clients; null/numeric-string values reach JS:166/229 and the whole-pass
exception handler. Confirm through a hand-written ZIP submitted by the public
API, not only an internal Job object. Distinguish pre-reservation string failure
from null's post-reservation failure and expiry accumulation; keep the valid-job
control. Internal schedule_* field misuse is a separate defensive observation.

### Scenario 5: A client failure during START removes an entry the runner indexes

F5/RS-4: JR:815–843 records an active client failure and pops pending outcomes;
JR:359–360 then indexes that entry and raises KeyError. Confirm both launches
succeeded, the report preceded reply collection, and FAILED_TO_RUN/stale exception
state differ from the after-insertion control. The source promises an authoritative
failure at JR:837; distinguish a genuine explicit START error from this KeyError.

### Scenario 6: Live dictionary iteration disrupts lifecycle services

F7/SE-1 A/B/C/RS-10: FS:309–330/1096–1113, SE.stop_all_runs and training shutdown
iterate mutable dictionaries. Confirm each owner/consequence separately: run-map
sweeper death, client-map mutation, stale logout token returning None, or an admin
command failing. A single modeled cardinality race does not cover all sites;
list(running_jobs.keys()) is a valid snapshot and is not this allegation.

### Scenario 7: Fractional GPU accounting fails to restore eligible capacity

F8: GPUResourceManager._reserve_resource/_deallocate subtract/add binary floats
and compare exact remaining memory for later admission. Confirm supported positive
memory requirements, public reserve/allocate/free order and a same-capacity
control; label ignore_host or hardware substitution. This concerns bookkeeping,
not GPU computation. AutoCleanResourceManager rejects noninteger/nonpositive
expiry; do not infer a separate fractional-expiry leak.

### Scenario 8: Leader exit releases resource units while descendants remain

F10/CL-5: CX:628–681 frees after the leader wait; ProcessAdapter uses
process_utils.py:293–316 getpgid on the leader PID, which can already be reaped.
Confirm a supported local job with cooperative same-group descendants, actual
OS identities, allocation/free, and later resource reuse. An in-tree trainer
using a separate session does not alone demonstrate this same-group trigger.

### Scenario 9: Parent death leaves a child in notification retry

F11/CL-4: client_runner.notify_job_status continues after its retry window and
stops sleeping; the parent monitor only invokes runner abort. The historical
real-CellNet process probe is useful but not a full worker deployment. Confirm
real CJ startup/notification, ordinary CP exit, surviving child/CPU behavior and
a successful-notification control; label kill/timing controls.

### Scenario 10: Disable leaves pending outcomes and slots until the grace expires

F12/SE-L4: SE:620–644 removes a session without notify_dead_client; JR:455–476
waits for pending outcomes. Distinguish disabled clients from removed clients
that can reappear on heartbeat. The default outcome grace is 900 seconds and the
provisioned max_jobs is 4; use actual configuration and a logout/control path.
This is a bounded-delay/contract question, not an assumed permanent leak.

### Scenario 11: Overlapping resource consumption changes another job's launch environment

F13/CL-3: GPUResourceConsumer.consume writes CP-global CUDA_VISIBLE_DEVICES;
the later local launcher copies the environment. Establish a supported overlap
(e.g. the first START exceeds its caller's deadline) despite the sequential
server runner. Confirm resource ownership versus inherited device IDs using real
spawn and passing serialization controls, without GPU computation.

### Scenario 12: Later empty-resource jobs inherit a stale device binding

F13/CL-2: a prior consume changes the parent environment and a later empty-resource
path may not reset it. Confirm any operational consequence and intended visibility
contract; a zero-GPU job was already unrestricted without a prior write. Do not
merge visibility alone into the overlapping-allocation defect in Scenario 11.

### Scenario 13: Scheduler metadata refresh restores an aborted job

F16/RS-2: JS:300–308 and FilesystemStorage:265–275 retain a SUBMITTED metadata
snapshot across public abort and overwrite ABORTED. Require refresh-read → abort
→ refresh-write → later launch plus a nonoverlap control. The dedicated refresh
MC probe is needed; the historical generic F16 cfg stopped at F1 instead.

### Scenario 14: Best-effort SJ status arrival loses an execution error

F17/E7 update-error: ServerAppRunner sends UPDATE_RUN_STATUS in finally;
SE:204–233 waits up to two seconds then pops; FS:594–604 ignores an absent record.
Confirm a supported error ending with normalized exit 0, actual delayed/lost
message, and the on-time control. Derive the delivery/status guarantee rather
than treating every late optional report as a defect.

### Scenario 15: Ordinary local restart leaves persisted lifecycle state inconsistent

F18: compare ordinary supported SP shutdown/restart and the persisted
RUNNING/DISPATCHED records against newly empty process tables and admission.
Reconciliation helpers without active callers do not establish recovery. Ordinary
local restart is in scope; HA recovery is excluded. Require a real restart and
later eligible-job consequence, not only an internal re-instantiated engine.

### Scenario 16: Cleanup pop races the waiter's return-code observation

F20: SE:204–233 reads after wait, may retain that exact record, then records/pop;
SE:402–409 terminates and pops separately. Confirm both read-before-pop and
pop-before-read with a real local process and normalized rc/rc file. The old
unconditional model stash was repaired. Fabricated PID reuse is not evidence of
an unrelated-process kill and remains defensive.

### Scenario 17: Unsafe client failure during startup does not mark the job aborted

RS-5: FS:952–956 calls stop_run for UNSAFE_COMPONENT; JR:798–811 only marks a
Job in running_jobs, which may not yet contain the starting job. Establish a
real preserved-102 rc-file path; raw 102 can normalize to 1 and STARTING remaps
to 104. Compare with the same report after running insertion and retain the
status/cleanup effect separately from F5.

### Scenario 18: Completion's blind deletion kills its service thread

RS-7/MC-D: completion JR:532 uses unguarded del after releasing its publication
window; runner JR:716–717 can remove the same job when the RUNNING write fails.
Preserve the historical injected transient-store-error experiment and the modeled
supported stale-delete trigger as distinct evidence. Confirm thread death and
later-job finalization/slot failure, with a passing nonoverlap control.

### Scenario 19: Empty participants alias the live registered-client dictionary

RS-11b: SE:318–324 substitutes client_manager.clients when job_clients is empty,
so later changes affect the retained PARTICIPANTS object. Establish a supported
all-clients-disappear preparation/launch ordering and a concrete iteration or
cleanup consequence. A mere possible alias without its caller sequence is not
confirmation; this remains outside the finite session-set projection.

### Scenario 20: Abort before client registration is dropped before a late start

CL-1: CE:390–404/CX:486–601 ignore an unregistered job; CX:299–307 registers only
later. Establish actual START timeout/abort ordering and whether normal heartbeat
compensates before an applicable lifetime contract is violated. The passing
pending-handle-first control is essential. Store-only abort of DISPATCHED is the
separate Scenario 1 mechanism.

### Scenario 21: Client shutdown and restart lose ownership before child cleanup

CL-6: CE:442–460 starts shutdown/restart while OS-child cleanup is cooperative;
new process ownership state is empty. Determine whether F11/CL-5 exceptions can
leave live workers at later allocation, and distinguish them from normal successful
watchdog termination. Require the supported control path and a real process
boundary; the fake CP-crash trace does not settle this.

### Scenario 22: Re-registration replaces tokens still used by running-job participants

SE-3: ClientManager.authenticate replaces the old token, but PARTICIPANTS retains
it; FS:1008–1113 heartbeat/dead-job and abort targeting use that membership. The
historical probe bypassed authentication and logged missing SSL/config errors.
Confirm actual same-site re-registration and cleanup; FS:1052–1055 can resolve
pending outcomes by name once SJ is gone, so permanent outcome starvation is not
established by token mismatch alone.

### Scenario 23: Typed process failures change meaning across normalization and status mapping

E1–E5: mpm.py rc-file handling, ProcessHandle.poll and CX:630–640 determine whether
101/102/103 survives or is mapped to generic 1/104. Historical real CJ bootstrap
used a fake parent/finalizer. Confirm actual local deployment reporting and
source-backed outcome precedence, with an rc-file/control matrix; do not claim
the unreachable raw -9 classification branch proves behavior of the default launcher.

### Scenario 24: Fast SJ engine completion is overwritten by STARTED

E6: FS:1145–1149 starts the engine thread then writes STARTED; run_engine at
:1200–1210 can already have set STOPPED. The historical forced Thread.start shim
ran the target synchronously, selecting an ordering but not proving a real worker
trigger. Confirm with real thread scheduling and a supported fast controller;
retain the corrected workspace/control and show main-loop survival/cleanup.

### Scenario 25: Delayed SJ heartbeat marks normal completion aborted

E7 heartbeat: FS:605–623 treats missing run_processes as an unexpected running SJ,
then checks persisted RUNNING and marks the runner Job aborted. Confirm actual
message delay after waiter pop and before terminal publication/pending release,
with timely-heartbeat control. A direct call to the handler with synthetic state
is only source-level evidence, not deployment confirmation.

### Scenario 26: Post-spawn setup or cleanup exceptions break resource ownership

Batch-3 L11/batch-4 L7: CX:309–334 can spawn before thread.start raises, while the
outer START exception path frees; CX:628–681 cleanup exceptions may skip later
registry removal. Find a concrete ordinary default-path failure and passing
control. Arbitrarily throwing custom event/resource-manager code is not sufficient;
component event exceptions are normally caught by event dispatch.

### Scenario 27: A pending restart or shutdown marker is removed by worker bootstrap

Batch-2 L8: CJ startup removes site restart.fl/shutdown.fl, overlapping public
parent control/scripts. Determine exact ownership and a supported lost-command
sequence affecting a later job. Historical code review alone has not established
a defect; keep this lower-priority lead through confirmation/disposition.

### Scenario 28: Partial deployment leaves workspace state relevant to later operations

Batch-4 L8/V02: failure can occur after site workspace creation, and _delete_run
has no demonstrated active failure-path caller. Derive the intended retention/
cleanup contract and test a later public operation, rather than treating every
residual directory as incorrect. Archive retry grace differs from deployment
cleanup and must not be conflated.

### Scenario 29: CAN_NOT_SCHEDULE overwrites an acknowledged abort

RS-3: JS:308 publishes CAN_NOT_SCHEDULE after queued failure-history work; a public
abort can write ABORTED before that final status update. Preserve N2a's low-priority
terminal-to-terminal discrepancy even if merged with a broader blind-status MC
candidate. No resource leak is established by that status change alone.

### Scenario 30: An ordinary cleanup exception escapes completion's narrow catch

RS-11a: completion's abort-client fanout catches RuntimeError but other exceptions
could escape. Establish a concrete ordinary exception in the default path; absent
that trigger this is defensive, not confirmed. Keep distinct from the observed
blind-del failure, whose source operation and trigger are already concrete.

### Scenario 31: Global machine status differs from concurrent job state

Batch-2 L3: one SJ waiter writes engine_info.status=STOPPED while another job may
run. Inspect consumers and confirm a lifecycle/admission consequence; a display
discrepancy alone is not proof of premature job termination. Retain a two-job
control and avoid applying a single-job status invariant to the aggregate blindly.

### Scenario 32: Lock/RPC ordering or late notifications affect cleanup progress

Batch-3 L8 and late client-status leads: engine.lock can be held across bounded
child RPCs while fail_run obtains runner/engine locks; STARTED/STOPPED notifications
and environment copies also have proposed races. Each needs a real cyclic wait,
applicable deadline violation or concrete late-delivery/first-insert sequence.
Existing 1–5-second blocking is not a proven deadlock. Preserve these as unresolved
source hypotheses, not model-checking findings.

Pure policy/defensive observations remain explicitly retained in the reconciliation
ledger: F6 expiry fallback; F9 app disappearance/fresh-token duplicate; F14 intended
GPU sharing; F15 documented non-strict policy; F19 direct duplicate free; arbitrary
permanent I/O outage (R1); internal schedule_* manipulation. They are not silently
promoted into ordinary defects. Confirmation should revisit a closed reachability
assumption if a supported sequence supplies new evidence.

### Scenario 33: Retained SJ status reference can replace a newer failure record

V04/F17 reference-lifetime supplement, identified during source validation, not a
TLC discovery: FS:597 retains run_process_info under FS.lock, while SE:219–233
can pop it under engine.lock. If a clean SJ exit leaves no exception entry and
JR:817–833 then creates a standalone authoritative client-failure record for the
still-tracked job, the retained UPDATE handler can later publish its older object
at FS:601 when execution_error is true. Verify whether this loses the recorded
INFRASTRUCTURE_ERROR precedence or otherwise affects the latch; a clean UPDATE
without execution_error does not replace the exception dictionary entry. Require
real rc semantics, shared-object identity and timing controls. The current model
keeps UPDATE atomic and its FinalMatchesOutcome groups failure categories, so it
does not establish this mechanism. This refines the existing V04 audit gap and
must not be counted as an independently confirmed or new MC bug.
