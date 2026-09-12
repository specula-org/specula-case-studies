# Bug Report — temporal-reset

## Summary

- Revision: 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025.
- Convergence: **2 rounds**, all **8 real traces / 619 records** pass; MC.cfg completes **78,636 generated / 38,109 distinct states**, depth **54**, zero queued, no checked invariant violation.
- Trace coverage: **53/64 model actions**, with **42/42 independent durable-readback checkpoints**. This is not product-line or implementation-branch coverage.
- Scenarios examined: 5; configurations run: all 13 supplied hunting configurations by BFS, followed by simulation for 12 configurations.
- Model findings: **2 mechanisms** — one non-default scanner-age sensitivity and one reconfirmation of prior T-1. Prior T-2/CR-2 is separate code-analysis/test evidence, not another MC finding.
- Overall exploration: **INCOMPLETE**. Twelve BFS runs reach their 30-minute limits with nonzero queues. Simulation is bounded exploration, not an exhaustive pass or a liveness proof.

## Bug 1: A short scanner age can remove history before execution publication

- **Scenario**: 5, explicit non-default scanner-age sensitivity.
- **Severity**: Medium; configuration-dependent.
- **Invariant violated**: AcknowledgedResetExists.
- **Config**: MC_hunt_scenario5_short_age_sql.cfg.
- **Counterexample**: 13 states; [full output](output/validation-20260909/hunts-bfs-01/MC_hunt_scenario5_short_age_sql.out).

### Trace Summary

Start allocates a run and appends its history. While execution metadata is not visible, the branch crosses the configured scanner age and the scanner observes NotFound. Metadata then commits, the scanner removes the branch, and Start returns success naming a run whose required history is absent. The counterexample itself contains no Reset; the separate implementation probe checks the same publication boundary for Reset.

### Root Cause

The scanner's age filter and execution-absence lookup are separate from execution publication and branch deletion. Neither Start's transient context nor a Reset candidate holds a cache lease that protects the candidate against this explicit-RunID lookup. The deletion request does not condition removal on continued absence of execution metadata. Details, structured states/diffs and controls are in [scanner analysis](output/validation-20260909/scanner-analysis.md).

Four real file-SQLite probes run the public frontend APIs and the unchanged scanner age filter/deletion handler through a small test adapter:
- Age=0 Start: successful response, durable NextEventId=3, public history NotFound after shard reload. Exact Start retry returns the same unavailable run.
- Age=0 Reset: successful response, durable NextEventId=6, only 3 of 5 expected events returned and one exact Incomplete history assertion. Identical Reset retry with the schedule disabled returns a new run that reaches durable COMPLETED.
- Both default-60-day controls retain complete history and reach worker completion.

All four final probes satisfy their assertions; raw output is in [probe results](output/validation-20260909/scanner-probe/results.json). The test adapter selects an actually enumerated branch and invokes the real filter and handler, bypassing periodic worker scheduling only. No database editing or mocked persistence is used. Age zero is a deliberate sensitivity setting, not the production default; no default-age failure or novelty is claimed.

### Affected Code

- service/worker/scanner/history/scavenger.go:206-285: age filter, mutable-state lookup and subsequent deletion.
- service/history/api/create_workflow_util.go:135-162: transient Start context.
- service/history/ndc/workflow_resetter.go:378-425: separate history/metadata publication path.
- common/dynamicconfig/constants.go:3549-3552: default scanner minimum age is 60 days.

### Recommendation

Preserve the conservative age default. Any correctness repair should coordinate branch cleanup with execution publication or revalidate absence under suitable protection. Test both public Start and Reset, actual durable history, response receipt and eventual recovery. Positive-age timing thresholds and the full periodic worker schedule remain untested.

## Bug 2: Identical Reset requests can create another run instead of returning the first result

- **Scenario**: 1 plus 2, immediate replay/response-loss recovery; prior T-1/CR-1 reconfirmation.
- **Severity**: High, depending on workload consequences.
- **Invariant violated**: ImmediateRetryIdentity.
- **Configs**: MC_hunt_scenario1_2_replay_sql.cfg and MC_hunt_scenario1_2_replay_cassandra.cfg.
- **Counterexamples**: [SQL, 74 states](output/validation-20260909/hunts-sim-01/MC_hunt_scenario1_2_replay_sql.out); [Cassandra model, 78 states](output/validation-20260909/hunts-sim-01/MC_hunt_scenario1_2_replay_cassandra.out).

### Trace Summary

Both sequences reach missing current through supported Start/CAN/deletion actions, then successfully Reset from a surviving explicit base. SQL loses the first successful response; Cassandra's model replays a received response. The same request reads the first reset run as current, misses deduplication and commits a second run without intervening administrative replacement. The first run is already completed in these two model traces; termination of a still-running first run is established separately by the real SQLite traces.

### Root Cause

Invoke compares current CreateRequestId with the Reset API request ID. The resetter is not given that request ID and chooses the original Start ID for reconstruction. ApplyWorkflowExecutionStartedEvent/AttachRequestID stores it as the Start-map entry and CreateRequestId and passes it to callback construction. Retry reloads that value, so its public Reset ID does not match. The pinned API RequestId field explicitly documents deduplication.

[Structured analysis](output/validation-20260909/retry-analysis.md) records exact states, IDs, seeds and source assignments. Real same-replay and response-loss traces assert identical requests, different second UUIDs, the first run's terminated status, and the stored identity after durable readback. This is one prior defect reconfirmed, not two backend defects or a newness claim. Actual Cassandra execution and callback delivery are not claimed.

### Affected Code

- service/history/api/resetworkflow/api.go:140-157,195-241: comparison and resetter invocation.
- service/history/ndc/workflow_resetter.go:237-255: original Start identity selection.
- service/history/ndc/state_rebuilder.go:402-410: Start-map lookup.
- service/history/workflow/mutable_state_impl.go:2600-2612,3109-3131: persisted creation identity and callback source.

### Recommendation

Retain Reset deduplication identity independently from the original Start/callback source identity. Preserve both contracts and test identical retries after delivered and lost responses. Do not represent competing identities as indistinguishable Start-map entries.

## Not Reproduced / Exploration Coverage

Every non-violating timed run below is **INCOMPLETE**, not a pass. BFS numbers are the last recorded progress counts for time-limited runs; they are lower bounds. Simulation counts are sampled states/traces, not distinct states. The configured simulation horizon is 100, while many sampled paths end earlier.

| Config | BFS distinct | BFS depth | BFS result | Simulation states / traces | Result |
|---|---:|---:|---|---:|---|
| MC_hunt_scenario1_2_replay_cassandra.cfg | 358,433 | 51 | INCOMPLETE | 11831 / 776 | Prior identity finding MC-2 |
| MC_hunt_scenario1_2_replay_sql.cfg | 380,760 | 52 | INCOMPLETE | 9846 / 704 | Prior identity finding MC-2 |
| MC_hunt_scenario2_cassandra.cfg | 370,331 | 46 | INCOMPLETE | 30328651 / 3393306 | No additional violation observed; INCOMPLETE |
| MC_hunt_scenario2_liveness.cfg | 3,343,558 | 30 | INCOMPLETE | 9534728 / 964529 | No additional violation observed; INCOMPLETE |
| MC_hunt_scenario2_sql.cfg | 414,040 | 48 | INCOMPLETE | 30907751 / 3459715 | No additional violation observed; INCOMPLETE |
| MC_hunt_scenario3_cassandra.cfg | 169,394 | 23 | INCOMPLETE | 21137494 / 2226329 | No additional violation observed; INCOMPLETE |
| MC_hunt_scenario3_sql.cfg | 171,072 | 22 | INCOMPLETE | 20917230 / 2220322 | No additional violation observed; INCOMPLETE |
| MC_hunt_scenario3_sql_io1.cfg | 166,186 | 23 | INCOMPLETE | 20711122 / 2201709 | No additional violation observed; INCOMPLETE |
| MC_hunt_scenario4_cassandra.cfg | 340,597 | 17 | INCOMPLETE | 27166925 / 2467874 | No additional violation observed; INCOMPLETE |
| MC_hunt_scenario4_sql.cfg | 348,811 | 17 | INCOMPLETE | 26366965 / 2446725 | No additional violation observed; INCOMPLETE |
| MC_hunt_scenario5_cassandra.cfg | 296,810 | 19 | INCOMPLETE | 10432897 / 1094811 | No additional violation observed; INCOMPLETE |
| MC_hunt_scenario5_short_age_sql.cfg | 3,158 | 14 | VIOLATION | — | Conditional finding MC-1 |
| MC_hunt_scenario5_sql.cfg | 298,892 | 19 | INCOMPLETE | 11013868 / 1183100 | No additional violation observed; INCOMPLETE |


## Priority-question and handoff boundaries

| Question | Actual evidence/result | Unresolved boundary |
|---|---|---|
| Q1 persistence/recovery | Four SQL schedules cover definite rejection and committed-result uncertainty at both base and candidate writes; all reach healthy retry and worker completion. | OS process termination and remotely delayed completion are model-only; larger searches are unfinished. |
| Q2 identity | MC-2 plus real delivered/lost-response replay traces; callback source argument is checked. | Callback delivery and alternate database execution are untested. |
| Q3 ordering | Real competing Start between base and Create gets a conditional conflict; retried Reset performs ordered replacement and completes. | Different-base concurrent Reset schedules and SQL I/O=2 are not trace-validated; exploration remains bounded. |
| Q4 reapplication | Real CAN Signal trace passes independent provenance checks. Five existing Update-ID tests reconfirm same-ID rejection, including reload/missing current; distinct-ID and exclude-Update controls succeed. | Update producer batching, accepted-without-request, multipage reads and termination-time buffers are not validated by the current trace suite. No Update-enabled liveness proof is present. |
| Q5 cleanup | Public deletion and base-removal recovery preserve reachable Reset history in the ordinary tested schedules; MC-1 isolates the short-age sensitivity. | Default-age long-duration schedules and Cassandra physical visibility are not execution-tested. CR-3 child-completion redirection remains incomplete, not confirmed or closed. |

[CR-3 review](output/validation-20260909/child-completion-review.md) follows the public History handler's ResetRunId redirection and the transfer caller's NotFound handling. It still requires a supported pending-child scenario and recovery/compensation evidence. It is omitted from this model and from findings.json.

## Validation and provenance

The exact source revision, configuration, source/binary hashes, raw traces and independent checkpoints are retained in harness/evidence/manifest.json, harness/evidence/validation.json and the trace sidecars. The backend is file SQLite WAL/synchronous=normal, one shard and I/O=1, with an independent read-only observer connection. Reload means real shard/cache reload, not an OS process restart. Testcore removes temporary databases after tests; raw readbacks are retained.

All eight real scenarios pass. Five CAN Update controls, two existing history-cleanup cases and the upstream missing-current test also pass; [regression results](output/validation-20260909/existing-controls.json) retain commands and output. The final changed-code lint check reports zero issues. Original and final specs, layered debugger observations, classified model corrections and the isolated oracle sensitivity test are retained under output/validation-20260909.

The omission-oracle control completes 35 states; a copied mutant that omits the source range violates the monitor at state 34. It is a synthetic oracle test, not an implementation finding. AcknowledgedResetExists subsumes ReapplyProvenance's boolean monitor; these are not counted as independent checks.

Read-only upstream snapshots cover PR 10926 (intentional missing-current persistence), PR 10673 (replication context), issue 6375/PR 6513 (Update context), issue 6952 (excluded Activity behavior), and issue 11958 (callback identity context). No upstream writes or maintainer-confirmation claims are made.

Provider interruptions ended orchestration parents while independent TLC processes remained active. Existing jobs were observed through their original time limits using wait_for_pid; no phases or BFS jobs were restarted for those interruptions. Missing direct exit receipts are labeled in the run manifests. All trace-generator intermediates were archived before clean_traces removed redundant root copies.

Model changes and Case B corrections are recorded in [changelog.md](changelog.md). No Reset implementation repair was applied; source changes are instrumentation and focused validation probes.
