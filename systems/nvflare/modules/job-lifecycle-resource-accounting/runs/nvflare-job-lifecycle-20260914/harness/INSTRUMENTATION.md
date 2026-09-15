# NVFlare lifecycle harness

Run from `.specula-output/` with `bash harness/run.sh`. The script applies
pin-checked probes, compiles Python, executes four pytest POC scenarios, writes
normalized NDJSON and provenance, replays every trace using the experiment-local
`run_trace_validation` implementation, and audits event/state coverage. Nonzero
exit preserves test, projection, or conformance failures for Phase 3.

Source revision: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. This is Category A.
Every site uses the real `ListResourceManager(gpu=[0], expiration_period=30)`,
`ListResourceConsumer`, `ClientProcessJobLauncher`, and `JobExecutor`. The server
uses the real scheduler, runner, file job store, deployment, secure Cell transport,
and `ServerProcessJobLauncher`. The launcher subclasses use
`ProcessJobLauncher.launch_job`. No simulator, mock RM, mock response, synthetic
process handle, replacement dispatcher, or scripted model transition is used.
The job payload simply waits cooperatively; no GPU hardware or aggregation runs.

The fixture follows the repository's `tests/integration_test/src/poc_site_launcher.py`
provision-and-launch pattern. Existing scheduler/deploy/executor unit tests mock
the adjacent chain and cannot supply this evidence. All parents, workspaces and
process groups belong to this experiment. Scratch workspaces are retained.
An initial test gate holds the scheduling thread while real parent services
connect and the finite workload is submitted. It is released before the first
scheduling pass, satisfying the supplied TraceInit bootstrap contract. It adds
no lock or gate to any subsequent lifecycle transition.

## Configuration and scenarios

All cases retain max_jobs=2, retry limit=10, backoff=10..600 seconds, 30 actual
one-second reservation scans, 900-second outcome grace, 60-second archive grace,
default non-strict start replies, and mandatory site-1. `mandatory_clients` is
the pinned implementation's required-site metadata key. Manifest values are
read from the executed workload's receipt; resource/config files remain under
the receipt's workspace path.

| Scenario | Workload and ordinary faults |
|---|---|
| competition | Two jobs, min_sites=1; later admission retries against occupied capacity. A site-2 AFTER_JOB_LAUNCH component throws; production dispatch catches it and waiter cleanup still runs. |
| delayed_start | Two jobs, min_sites=2; site-2 START execution waits 32 real seconds, exceeding its reservation TTL and 20-second start waiter. One site-1 cancellation acknowledgement waits 12 seconds after actual cancellation, exceeding the 10-second waiter. No timer acceleration. |
| admission_exception | Two jobs, min_sites=1; one exception after the first job's real resource-check replies, then a site-2 preparation OSError for job 2 after allocation. The real processor rolls back, while a successful site's process follows its actual stop/exit path. |
| abort_completion | Three jobs, min_sites=1; wait for real child STARTED notifications, abort one running job twice and one submitted job twice, allow the other job to complete. |

Tests check saved terminal status, actual final RM deque/reservation snapshots,
empty executor process maps, and one observed free per observed allocation.
These assertions do not establish model conformance or cover every fault branch.

## Editing probes

`src/apply_instrumentation.py` is the patch source. Its `before`/`after` helpers
insert calls into pinned NVFlare files using exact anchors and reject unrelated
source edits. `patches/instrumentation.patch` is the resulting reviewable diff.
`hook-locations.json` lists every **file:line after apply**. `src/probe.py` is
copied to `nvflare/_lifecycle_probe.py`; `src/workload.py` supplies the cooperative
job and the ordinary throwing event handler.

- Add a field to the whitelist/extractor in `probe.py`, then decode its actual
  value in `normalize.py`. Add it to `post` only with a corresponding non-vacuous
  Trace validator. Additional raw provenance is not a validated state field.
- Add an event at an actual source boundary, update the model/Trace contract if
  necessary, regenerate `event-schema.json` with names/args/post-field names only,
  and add its observation projection. Never import or execute model updates in
  the observer.
- Move a capture by changing its exact anchor and `before`/`after` placement.
  Preserve the existing RM lock for deque/token mutations, and preserve distinct
  consume, environment-copy, spawn, attachment, dispatch and waiter boundaries.
- Re-run `bash harness/run.sh`. It does not reset the checkout or remove unrelated
  files. Each execution gets new raw logs and scratch workspaces; latest receipts
  select the traces. Tests/builds have outer `timeout` bounds; TLC uses 2 GiB heap,
  1 GiB maximum direct memory and one worker, sequentially.

## Capture and validation boundaries

The writer uses a process-local mutex plus `flock` for a single local-host raw
NDJSON stream. Each record includes the real monotonic timestamp, capture-entry
timestamp, PID, TID, sequence and source stack. Writers flush/close on every emit.
Do not use these timestamps to merge traces from different hosts. The raw stream
records a causally ordered observation on this host; it is not a global atomic
snapshot. Retain overlapping capture intervals rather than claiming they prove
one physical interleaving.

RM mutations are captured under their existing lock. At the final expiry tick,
the map still contains TTL=1 while the local `tokens_to_remove` represents the
decremented zero; the projection uses that directly observed scan-local zero.
Allocation payloads and release counts come from actual allocate returns/free
calls, independent of the built-in RM's reservation map. Environment assignment
and copied child environment are captured separately. Actual spawn PIDs and
wait returns establish ownership/exit; STOPPED, abort acknowledgement and registry
removal do not establish process exit.

Capture is specialized at asynchronous boundaries: process registration probes
are inside their existing locks; attachment probes follow the handle's return, while notification
status is read in the notifying thread (the pinned notifier itself has no lock).
The observer carries forward other components' last observations. These probes
do not take a new lock across startup or abort windows. A conflicting concurrent
mutation requires a more precise capture/partial-order replay, not an invented
snapshot.

The independent observer maps real job UUIDs and real reservation UUIDs to
job/attempt aliases. Admin request IDs and CoreCell waiter IDs are retained; late
reply disposal is correlated to the original waiter. Empty scheduling passes and
RM scans with no reservations are omitted because they do not change the selected
state. All raw hooks remain available. `post` has exactly the action-specific
field set, and every captured post field is checked by `ValidatePostState`.
`TraceMatched` and the supplied invariants remain enabled; no silent actions or
vacuous validators were added.

The contract format edits use `tag: "trace"` for events and `tag: "config"` for the manifest, required by the selected skill,
in `Trace.tla` and its generator/instrumentation documentation. The configuration record keeps its target-specific fields. Flat event/args/post fields are
unchanged. `artifact-hashes.json` here records the executed artifacts; the spec
generation receipt describes its earlier pre-harness snapshot.

## Phase 3 handoff

Read `coverage.json`, the per-scenario `logs/*.validation.json`, and
`../traces/*.provenance.json`. A passing pytest means the controlled production
workload and cleanup assertions passed. A passing replay means that finite
observed trace conforms. Neither establishes exhaustive correctness.

Phase 3 repaired the observed boundaries. Client stop sends and blocking returns
are separate; client abort ownership is captured under the existing executor
lock before teardown waits. Explicit start errors preserve the initialized
participant list. Heartbeat missing-outcome resolution is a distinct action;
late untracked reports have an actual receiver ignore hook. Server cleanup
records full-grace, early-exit, zero-grace and repeated termination/pop paths.
Original raw traces and failed replays remain under `spec/validation/initial/`,
`spec/validation/before-r2/` and `spec/output/`.

The latest full replay passed all four scenarios and all 1,353 semantic events
(`spec/output/traces-r5/`). This is finite trace conformance; standard model
checking and scenario search have separate receipts. Accepted ABORTED outcome
codes have a distinct model class, but the receiver path for that class has no
dedicated passing trace in these four workloads. Delayed heartbeat snapshots,
service-death paths and the other limits below remain untested.

`coverage.json` enumerates all 125 spec actions and uncovered branches. In
particular, full retry exhaustion, 900-second outcome expiry, archival/store
outages, heartbeat orphan cleanup, waiter-install failure, and every alternate
startup failure are not covered by four finite workloads. Input-deferred CR/TV
reachability boundaries remain deferred; no custom invalid counts, duplicate
fresh-token starts, or deployed-directory removal is introduced.
The one-unit pool exercises contention, expiry and ownership transfer. It does
not establish correctness of simultaneous bindings to two different units in
one parent process; that requires a separate multi-unit workload.

| Priority question | Evidence in these workloads |
|---|---|
| 1: expiry/cancellation versus allocation | Real 30-tick expiry, rejected delayed START, acknowledged and timed-out cancellation, allocation/free ledgers and final capacity. |
| 2: partial deployment/start | Real deployment at both sites; partial startup OSError and default non-strict timeout behavior. Explicit deployment-failure replies remain untested. |
| 3: abort/completion/exit | Normal exit, repeated running and submitted aborts, completion events, actual waiter free and executor-map removal. |
| 4: identity and delayed/repeated events | Original job/attempt/request/CoreCell waiter mapping, late reply disposal, repeated abort and lifecycle event removal, heartbeat outcome boundary. |
| 5: later scheduling/retry progress | Finite one-shot admission exception and resource contention with default backoff/TTL; later jobs reach saved terminal states and release capacity. No progress claim under permanent outage. |

PR [#5191](https://github.com/NVIDIA/NVFlare/pull/5191) was refreshed on 2026-09-14:
open, unmerged, head `27ecde2ab85b38734072b90128dc5dc2e8390882`. All discussion,
review and review-comment pages are saved in `logs/pr5191-*.json`. Its
[expiry/cancellation discussion](https://github.com/NVIDIA/NVFlare/pull/5191#issuecomment-5432240101)
distinguishes expiring reservations from allocations owned by running jobs.
The admission-exception case overlaps that known context; proposed changes were
not applied to the pinned implementation.
