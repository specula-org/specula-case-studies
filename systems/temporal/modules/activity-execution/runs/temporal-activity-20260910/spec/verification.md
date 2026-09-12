# Specification-generation verification

**Current validation:** 21/21 complete real replays and the completed bounded safety baseline pass. The generation-stage material below is historical; current evidence, coverage and limitations are in [validation-report.md](validation-report.md).

**Generation complete; implementation fidelity and full hunt convergence INCOMPLETE.** No Temporal protocol bug is claimed. This directory contains all eight requested artifacts, seven scenario hunt configs, a progress config, a small exhaustive config, and explicitly synthetic specification controls.

The source checkout was rechecked clean at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Category A. The selected storage contract is modern nonzero DBRecordVersion SQL execution/task atomicity; intended real-trace backend is the analysis baseline's SQLite/WAL/synchronous=NORMAL. This phase ran no Temporal functional tests, actual storage injections or restarts. Stamp increment defaults false in the model; companion hunts enable it. Non-eager ordinary token requests, valid payloads, single Run/cluster and no administrative/routing/time-skipping extensions are required.

## Checks on the final artifacts

| Check | Result and boundary |
|---|---|
| SANY | `base.tla`, `MC.tla`, `Trace.tla` parse and semantically resolve with the recorded tool jars. |
| `MC_smoke.cfg`, exhaustive BFS | **PASS**: 2,393,231 generated / **322,501 distinct** / 0 queued states; depth 53; 30.537 seconds wall time including Java startup. Checks core safety, structural and all scenario safety operators. |
| Seven hunt configs, simulation | **PASS for sampled model executions only**: 500 simulations per config, depth cap 150, seed 9102026. No invariant violations; not exhaustive hunt convergence and not implementation traces. |
| Synthetic full replay controls | **5/5 matched completely**, with unchanged base actions/post-state checks and final endpoint. These are generated specification controls, not independently recorded Temporal executions. |
| Corruption / prefix controls | **4/4 rejected** by TraceMatched: wrong request attempt, wrong durable buffer, missing watermark field, missing final endpoint. |
| Production provenance control | `Trace.cfg` rejects a synthetic evidence label (exit 151: CompleteTraceUsesIndependentEvidence is FALSE). The separate test module accepts only the explicitly synthetic label for replay plumbing checks. |
| `MC.cfg`, larger two-attempt BFS | **INCOMPLETE**: stopped after its 120-second generation-phase budget. Last periodic report below is a lower bound, not a final state count or pass. |
| `MC_progress.cfg` | Temporal property/fairness configuration generated and SANY-resolved. An earlier specification revision's exploratory run was INCOMPLETE after 180 seconds. No final-revision liveness result is claimed. |
| Real complete trace validation | **0**. Harness hooks, independent backend/ActivityInfo/task evidence and end-to-end recovery executions remain the next phase. |

Last reported larger-search progress:

```text
Progress(39) at 2026-09-10 14:08:50: 4,392,422 states generated (4,194,602 s/min), 824,623 distinct states found (780,139 ds/min), 225,618 states left on queue.
```

`evidence/final-bounded-results.json` binds both final safety runs to SHA-256 hashes of their exact model/config files. `evidence/final-check-results.json` records SANY/simulation commands and exits. `evidence/control-results.json` records every control command and expected exit. The memory/runtime requirements of liveness and larger hunts were not treated as proof of success. Previous development logs have explicit `before-*`/`incomplete` names; their counts are not added to final coverage.

## Bounds and reductions

The completed exhaustive check uses one Activity, two interchangeable workers, **one attempt**, logical time 1..3, STS=1 ms, STC=1 ms, SCT=2 ms, HB=1 ms, one ordinary result request (including late duplicate/invalid-cancel cases), no separate heartbeat input, no injected storage/cache/shard/response faults, and a buffer bound of 3. It explores dispatch, accepted start versus delivered token, completion/failure/cancellation rejection, all applicable timeout branches, transient Started History materialization and terminal WFT responsibility. It is a small calibration check, not retry/recovery coverage by itself.

`MC.cfg` enlarges to two attempts, time 1..4, SCT=3 ms, STS/STC/HB=1 ms, one ordinary result and buffer bound 3. The hunt configurations preserve their specific fault setups. S2 uses two Activities, STC=4 ms, SCT=6 ms, HB=1 ms, TimeLimit=7, one heartbeat, one cache loss, one storage uncertainty and one redelivery. STC must be later than the extended HB deadline so the intended HB-regeneration/watermark path remains reachable; equal STC/HB deadlines select STC first by the real comparator. Both stamp settings have companion hunts.

MC bounds environmental input, time advance, loss, cache/shard loss, storage faults, and duplicates. Deterministic/reactive handlers, retry decisions, timeout scans, store completion/rejection, reload, WFT processing and queue retirement are not counter-bounded. Workers are symmetric; Activity ScheduledEventID order is not. `MCSafetyView` projects only four diagnostic ledgers (`observed`, `historyAppends`, `notifyPending`, `notified`) that neither enable protocol transitions nor affect checked properties. Fault counters remain in the fingerprint because they affect future enablement. The message constraint is explicit. Trace replay compares all fields, including those omitted only by this MC view.

Progress is conditional on fair time, persistence, timer service, restored ownership/cache and WFT start/completion, with finite policy/deadline and an eventually healthy suffix. It permits terminal failure or legal Workflow closure, not guaranteed Activity success. Real Matching internals and WFT transport are interface abstractions; actual task/response evidence remains necessary for fidelity. Task deletion projects a successful category/range batch atomically, including all affected scheduled time buckets; an in-memory executable Ack is not a durable deletion observation.

## Synthetic mechanism controls

`SpecControls.tla` drives full base transitions and serializes their snapshots. `SyntheticTraceControls.tla` changes only the expected provenance label, by duplicating the production provenance predicate with `basis="synthetic-specification-control"`; it does not replace any protocol action, post-state check or endpoint rule. Production `Trace.cfg` continues to require implementation evidence. These fixtures must never be copied into the real `../traces/` evidence set or counted as real execution validation.

| Control | Events including Bootstrap/FinishTrace | Mechanism exercised |
|---|---:|---|
| `Healthy` | 106 | Two attempts, heartbeat checkpoint, failure/retry, four stale-token rejections, successful terminal acknowledgement, buffered result, cache reload and final WFT consumption. |
| `Unknown` | 106 | Same lifecycle, actual modeled terminal commit followed by unknown response, RangeID reacquisition/reload and result consumption. |
| `Condition` | 107 | Same logical terminal request commits, internal backend retry fails its stale DBVersion CAS, final response is Condition, independently reloaded terminal survives. |
| `RejectedClose` | 108 | Previously acknowledged terminal is buffered; close rejection explicitly clears/reloads cache, fails/renews WFT and preserves result consumption. |
| `SharedTimers` | 144 | Two Activities running; one heartbeat extends; shared cue retries the other; reload produces watermark=0; redelivery creates a second covering HB cue; both attempts terminate and WFT consumes both results. |

The complete synthetic controls use their own explicit driver configs; they are not claimed as exhaustive paths enumerated under a hunt's input limits. The S2 trigger prefix has the matching policy/timer constants and requires no result input; its full endpoint control later sends two completions, while the tightly bounded hunt permits one result input and can terminate the other Activity by deadline.

The mandatory audit is `brief-coverage.md`; its active-invariant map is mechanically checked in `evidence/final-audit.json`. All five scenarios, six named safety operators and both section 6.1 finding mechanisms are mapped. Exactly 56 primed base transition operators have 56 full Trace wrappers and 56 instrumentation entries; pure in-lease helpers are not counted as separate transitions.

## Remaining verification work

Implement the immutable observation hooks and real positive/negative controls from `instrumentation-spec.md`; collect complete healthy and Timeout/ExecuteAndTimeout/cache/shard recovery scenarios through independent terminal readback and WFT consumption. Establish exact backend/configuration/ordering evidence. Finish exhaustive larger safety/hunt and conditional liveness runs after real trace calibration; MC-1 and MC-2 remain unresolved hypotheses. Distinguish cache reload, shard reacquisition, process restart and database restart by actual execution. No process/database restart or power-loss experiment has occurred here.

Pause/unpause, ResetActivity and ByID remain separate, unvalidated extensions. Legacy DBRecordVersion=0 CAS, legacy missing FirstScheduledTime, multiple checkpoint values/custom application retry-delay arithmetic, workflow retry/cron/cross-run behavior, replication and worker routing require distinct extensions/configuration. The model's one-checkpoint payload quotient and modern SQL conditions are explicit; neither a proof for all backend configurations nor external exactly-once effects is claimed.

## Reproduction

Run from this `spec/` directory. Exact commands and local tool identities are also preserved under `evidence/`.

```bash
TLA_JAR=/home/ubuntu/.cache/sci-20260904/1fad5b05ff373973f69b1054d96f58f1/lib/tla2tools.jar
COMMUNITY_JAR=/home/ubuntu/.cache/sci-20260904/1fad5b05ff373973f69b1054d96f58f1/lib/CommunityModules-deps.jar
java -cp "$TLA_JAR:$COMMUNITY_JAR" tla2sany.SANY Trace.tla
java -Xmx2g -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -workers 2 -config MC_smoke.cfg MC
java -Xmx2g -XX:+UseParallelGC -cp "$TLA_JAR" tlc2.TLC -workers 2 -config MC.cfg MC
python3 evidence/run-controls.py
# Next phase, only after an actual complete implementation trace exists:
JSON=../traces/trace.ndjson java -Xmx2g -cp "$TLA_JAR:$COMMUNITY_JAR" tlc2.TLC -workers 1 -config Trace.cfg Trace
```

The available tools jar reports a development TLC 2.20 version string with a placeholder revision. Use the recorded jar SHA-256 identities, not that string alone, to reproduce these counts. No toolchain installation or Temporal source modification was performed.
