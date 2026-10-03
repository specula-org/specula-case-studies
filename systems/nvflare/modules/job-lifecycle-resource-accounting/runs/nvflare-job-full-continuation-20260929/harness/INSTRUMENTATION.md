# nvflare-job instrumentation guide for Phase 3

Phase 3 C5 regenerated all 32 scenarios after adding the waiter read hook and repairing the fake CJ sync prerequisite: **2,286 events, 65 event types, and 32 successful C5 replays**. Earlier Phase 2.5 (2,244 events) and Phase 3 read-hook (2,288 events) batches remain frozen. This is finite trace compatibility under the controls below, not independent product confirmation. See [phase2_5-report.md](phase2_5-report.md) for earlier results and provenance, [HOOKS.md](HOOKS.md) for capture points, and [the continuation audit](../spec/continuation-audit.md) for current projection limits.

## Run and inspect

From this `.specula-output` directory:

```bash
bash harness/run.sh
VALIDATE=1 bash harness/run.sh
SCENARIOS="normal_two_jobs start_failures" bash harness/run.sh
bash harness/validate.sh traces/normal_two_jobs.ndjson
bash harness/validate.sh traces/*.ndjson --results harness/build/replay-results.json
source harness/paths.sh
"$NVF_PYTHON" harness/src/trace_inspect.py traces/normal_two_jobs.ndjson --tlc-log <tlc.log>
```

`paths.sh` selects this continuation's source, framework and prepared Python runtime. `apply.sh` checks source HEAD is `53ba7ee567468ea7971dad4faccef13c6cb35dc2`, archives its `nvflare/` package into `harness/build/nvflare_src`, copies the hook module, applies the supplied patch and compiles the affected modules. The product checkout is untouched. `run_scenario.py` rejects imports outside that build. To relocate, override `NVF_SOURCE`, `NVF_PYTHON` and `SPECULA_ROOT` with paths to the same pins/runtime; a different source HEAD is rejected.

Each scenario has a 180-second shell timeout. Its report, stdout, stderr, exit code and integrity result go to `build/reports/`. `run.sh` exits nonzero for scenario, integrity or requested replay failure. A timeout requires diagnosis; it is not automatically a product deadlock.

`validate.sh` calls the pinned Specula durable TLC task API (the same resource wrapper used by the TLC service), never bare Java. Runs are sequential, each with 2 GiB heap, 1 GiB offheap, one worker and a five-minute limit, under aggregate 64 GiB/16-worker limits. The JSON trace, spec hashes, task ID, final exit status, log paths and TLC statistics are retained. PASS requires both exit code 0 and TLC's success result. Scratch spec copies and trace-explorer outputs stay in `build/replay/`; durable logs are in `../.tlc-tasks/`. A time-limited run without completion is not PASS.

`stress.sh N` is an optional schedule-variation runner (up to four scenario processes, serial TLC); it was adapted and syntax checked but **not rerun in this phase**. Historical stress logs are not fresh results. `clean.sh` removes `build/`. Fresh delivered traces/reports and runtime versions are also frozen outside it in [evidence/continuation/fresh-suite](evidence/continuation/fresh-suite).

## What executes

This is a Category A message-passing harness. Actual pinned server/client lifecycle code runs in one Python process: `FederatedServer`, `ServerEngine`, `RunManager`, `ClientManager`, `JobRunner`, `DefaultJobScheduler`, `SimpleJobDefManager`, `FilesystemStorage`, `JobCommandModule`, `ClientEngine`, `JobExecutor`, `ListResourceManager` and the request/status processors. The real `ProcessHandle` wraps `FakeProc`.

`nvf_env.py` supplies CellNet/admin transport, launcher, SJ/CJ process and authenticated-session setup substitutes. It creates the relevant real objects and temporary workspaces; it does not run a full local deployment, worker bootstrap or actual OS process groups. `FakeSJ` omits `HANDLE_DEAD_JOB` effects. Heartbeat calls the real sync/cleanup methods directly, bypassing transport/authentication and delayed snapshot delivery. The list-unit resource manager is supported, but does not exercise the default GPU memory accounting or device binding. These boundaries are material for confirmation.

## Files and instrumentation changes

| File | Purpose |
|---|---|
| `patches/instrumentation.patch` | Supplied patch plus Phase 3 SpWaitRead capture: 11 product files, 83 trace markers. Applied only in the build. |
| `src/tla_hooks.py` | Hook API, inactive until a tracer is installed. Object arguments avoid attribute reads when disabled. |
| `src/nvf_tracer.py` | Event sections, ordering lock, post-state projection, token mapping and frozen NDJSON writer. |
| `src/nvf_env.py`, `src/nvf_scenarios.py` | Real-object wiring, explicit process/network substitutes, timing gates, 30 supplied plus two deadline scenarios. |
| `src/resource_observer.py` | Separately records actual allocation/free calls and compares their outstanding units to event-driven ownership projections. |
| `src/run_scenario.py` | Import guard, execution, expected-error assertions, admission stop/network drain, report/hash and process exit. |
| `src/trace_contract.py`, `src/validate_traces.py` | Strict trace/report input guard and budgeted TLC replay. |
| `src/check_scenario_evidence.py`, `src/negative_controls.py` | Seed-mechanism/control assertions and labeled corruptions of a fresh trace. |
| `src/run_unit_controls.py`, `src/pytest_import_control.py` | Scoped existing unit tests on pristine, patched-disabled and patched-no-op code with import-origin checks. |
| `src/audit_phase2_5.py` | Read-only verification of frozen evidence, original hashes, coverage and syntax; writes the audit result. |

To edit a hook, edit the isolated build file and run `bash harness/make_patch.sh` **before** rebuilding. `apply.sh` replaces the build. Add an event by following a nearby `_tla.section` or `_tla.begin`/`_tla.end` pair, passing local variables/objects. Resolve attributes in `Tracer._normalize`, not in product hook arguments. A new action also requires a corresponding Trace wrapper and inclusion in `TraceNext` during the validation/repair phase.

Add a captured field in `Tracer.snapshot()`, update `trace_contract.py`, and add the actual comparison to the appropriate Trace validator. Document its source and absence behavior. Move a capture point by moving the section boundary; check source locks and observable intervening operations before treating the region as atomic. Every logged event wrapper reaches `ValidatePostState` and advances the trace cursor. Phase 3 adds next-event-constrained silent preparatory microsteps for the finer source model; these do not validate their newly possible interleavings. This says nothing about implementation operations omitted by the model.

## Scheduling controls and fault injection

The tracer's process-wide lock `T` is acquired before a traced section's mutations and held until its post-state event is written. Snapshots take no additional product locks. Nested sections are absorbed, and explicit `emit` calls can publish intermediate events. Exception handlers close open sections; unexpected thread death fails a scenario report. This imposes atomic regions beyond the source's synchronization. No-op unit tests do not demonstrate transparency with `T` active.

Requests sent while `T` is held are queued until release; the sender sees an injected timeout where applicable. REPORT and SJ ABORT therefore have selected deferred schedules with immediate stub TIMEOUT results. The real synchronous waits (up to five seconds for REPORT, one for SJ ABORT) and report-before-free windows are not represented faithfully by these steps. Audit records expose the requested timeout, result and deferral, rather than hiding them.

CHECK/START admin requests now honor the actual caller's deadline (15/20 seconds); late replies are discarded. `delay:N` delays handler admission without holding `T`, so the two new scenarios actually wait out those deadlines. Explicit `hold` and `drop` policies still inject an immediate timeout; `drop` emits `LoseMsg`, `fail` supplies a DEPLOY error reply. Policy, elapsed wait, reply retention and dispatch are in `network_observation` in each report. The delay is a timing control in the stub transport, not an actual congested network.

Other controls: gates pause at the locations listed in [HOOKS.md](HOOKS.md); gates are ignored inside `T` to avoid a harness deadlock. `GatedTime` makes the real reservation expiry thread take one tick per `Env.tick`. Outcome grace is configured explicitly. A CP crash freezes its waiter and forcibly exits fake children/descendants; it **assumes** cleanup and does not establish parent-death liveness. Cooperative `stop_only` children acknowledge STOPPED but exit slowly, permitting overlapping termination threads. Seeded random scenarios are timing dependent.

At the end, the runner stop flag prevents new admissions, active network handlers are drained, and the writer is closed under `T` before hashing. Sleeping product threads/fake crash waiters end at `os._exit`. Reports identify this as a finite prefix after scenario assertions, not whole-system shutdown. Two deletion scenarios require an exact expected runner exception and a still-SUBMITTED later job; all other runner/thread failures are rejected.

## State validation coverage (L2)

All emitted event-state fields are mapped by `ValidateServer`/`ValidateClients`, subject to the presence conditions below. These validators contain real equations, not `TRUE`. Timestamp/thread/error metadata are diagnostics, not model state. The config line is separate from event lines; all subsequent rows must have `tag=trace`.

| Captured state | Implementation observation | Trace comparison and limits |
|---|---|---|
| `tagged`, `scheduled_jobs`, `running_jobs`, `sessions` | Tag/store cache, scheduler slots, runner map, session membership | Sets compared on every event. Deleted tags retain a ghost value; session generations are absent. |
| job `status`, `schedule_count` | Stored job metadata; cached counter after deletion | Compared to `status`/`pCount`; `DELETED` denotes absence. Cached values are not reads from a deleted object. |
| job `run_aborted` | Current or cached `Job` object | Compared to `runAborted`; sticky after removal, contrary to the old mapping's “else false” prose. |
| job `pending`, `latched` | Runner pending set and finalizer latch | `PendingMatches`, `latched` equation. Absent-record empty members are schema padding. |
| job `run_process`, `exception_process` | Actual engine records | `RecMatches`: presence, then finished/error/rc/participants. Absent-record false/zero/empty values are padding, not observations. |
| job `sj`, client job `cj` | Fake leader/process state | Compared to `sj`/`cjProc`; not an OS/group observation. |
| client `alive`, `free`, `reserved` | Harness CP liveness; real list pool/reservation table | `cpAlive`, multiplicity-preserving `BagOf`, `ResvOf` (token→attempt/job mapping). Reservation units are sets, with uniqueness required by the input guard. |
| client job `registration` | Real executor registration | `RegMatches`: presence, then status/attached/abort intent. Absent-record values are padding. |
| client job `starting`, `allocated` | Tracer event-driven side tables | `StartingMatches`/`alloc` equation. Independently cross-checked against actual successful allocate/free calls at each live-client snapshot, sharing token identity mapping. This checks the projection, not all resource contracts. |

For a dead CP only `alive=false` is emitted, because Trace intentionally stops checking that client's local state. Its old frozen pool/registration fields were removed and the affected scenario rerun. No live allocation claim is made for dead clients. The observer's 79 allocate calls include one expected expired-token error; 78 succeed, and 77 frees return. The remaining call belongs to the intentionally frozen dead CP, whose cleanup is not measured.

Hidden/model-inferred state includes the full message multiset, termination counters, waiter retained references, service-thread PCs, SJ/CJ bootstrap and sync, client registry generations and OS descendant use. Those require source audit and separate scenarios/reproduction; 65 event names do not establish all branch/interleaving coverage.

Before replay, `trace_contract.py` checks one initial config, every retained row, contiguous sequence, recognized names, domains, required fields, real ordered timestamps, successful report/exit, exact frozen hash/event counts and drained network. It rejects malformed/filtered records and post-collection truncation. It cannot prove the tracer observed every implementation change. A valid truncated prefix passes raw TLC when the report check is deliberately bypassed; preserve this limitation.

## Current scenarios and next phase

The 30 supplied defaults (including `wfc_stale_read_after_pop`) and the new `check_deadline_backoff_expiry`/`start_deadline_late_start` all generated successfully and replayed successfully against the adopted, unchanged spec. Per-scenario counts, hashes, errors/controls and TLC logs are linked in [final-audit.json](evidence/continuation/final-audit.json). The only uncovered event is `CpStartAllocateAppMissing`: its opt-in scenario is outside the ordinary `EnableUnsupported=FALSE` envelope and was not rerun or counted as a supported defect.

The old guide's 29-scenario/26-PASS/3-FAIL result predates supplied model repairs (message bags, termination counters and waiter handling). It is historical, not a fresh failure or proof that those repairs are faithful. The guide and old build are preserved under `history/pre-continuation-phase2_5/`.

All [V01–V10](../adoption/model-audit.md) obligations remain for normal validation/repair: scan/store; partial deployment/I/O; startup/fanout; outcome/abort/latch/report/free; same-job admin concurrency; sessions/sweeper/heartbeat; wait/reap/groups; configured resource accounting; allocation/spawn ownership; parent-death/notification liveness. In particular the global sweep section still blocks the live-map mutation race, and the forced CP cleanup still excludes F11/CL-4/CL-6. Fresh replay does not discharge these gaps, residual/hunt exclusions, named MC seed fidelity, MC-U1 classification or the confirmation queue in [findings-reconciliation.md](../adoption/findings-reconciliation.md).

## Phase 3 repair evidence

`SpWaitRead` records SE:205 after process.wait, including the independently observed `record_present` Boolean. Its Trace wrapper checks the Boolean against the model read and validates the post-state. The stale-read scenario now shows the actual read before pop. The updated patch, 32 traces/reports and hashes are frozen in `evidence/continuation/phase3-fresh-suite/`. `phase3-read-hook-unit-tests/results.json` records identical 32-test controls in three modes; `phase3-negative-controls/results.json` records five rejected semantic corruptions. See `../spec/continuation-audit.md` for source repairs and retained projection gaps. The earlier Phase 2.5 evidence is unchanged.

C5 found that random_mix_s1/s5 could request clean exits from fake CJs whose first STARTED notification came after SJ exit. Real ClientRunner.init_run requires a successful SYNC_RUNNER first on the flat topology modeled here. `nvf_env.py` now selects an immediate simulated sync only while the SJ is alive and registered; an unsynced fake CJ cannot report STOPPED or cleanly exit. A requested clean exit in that condition is explicitly logged and emitted as a controlled generic nonzero process exit. This does not execute SYNC_RUNNER, reproduce its concrete timeout, or establish a typed rc-file path. These remain process-edge substitutes, not product fixes.

Trace's hidden sync witness is selected before the SJ's last exit opportunity when a later logged clean CJ return requires it. The lookahead constrains only unobserved step placement, does not advance the cursor, and does not bypass any logged post-state check. It prevents a feasible trace from failing solely because an optional hidden step was skipped. The old two impossible random traces still fail this model; all 32 regenerated traces pass. Exact scripts, traces, reports, run log and hashes are under `evidence/continuation/phase3-C5-fresh-suite/`; 11 mechanism/control assertions pass in `phase3-C5-scenario-assertions.json`. Successful CJ status delivery while the CP is alive is a selected schedule, not coverage of STARTED timeout or infinite STOPPED retries.
