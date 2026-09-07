# Coverage assessment — validation round 1

Source: `3ac0104a567092139534c9022205d02281a2da41`.

Seven retained implementation traces (884 records) freshly pass the installed parallel validation handler with active TraceMatched and full normalized post-state equality. The 32 transition wrappers cover all 33 recorded event types including Init. This establishes conformance for these finite executions, not all branches, schedules, or implementations of the transport contract. No source/spec/harness repair was needed. Current input hashes are in initial-manifest.json.

| User question | Current implementation evidence | Limit |
|---|---|---|
| Peer frame completion | Real encoder/sender bytes, measured clean EOF dispatch, reset rejection, complete fragmented forwarding; successful original write, later cross-client Get of a prefix, and retained recovery state. Separate three-binary result and binary hashes verified. | Retained experiments re-audited, not re-executed in Phase 3. Composed byte-level and independent process experiments establish different parts of the mechanism. Other frame/reply variants not independently extended here. |
| DVC quorum excluding own state | Actual source and base permit two external DVCs selecting a new primary history without a self DVC. | Paper deviation alone is not loss. General safety requires the MC phase/hunts; no source-confirmed core counterexample. |
| Rolling recoveries | Actual trace recovers replicas 2, 0, then 1 with committed work and completions. Recovering counts unavailable. | MC.cfg allows one crash; S2/S3/S4 are separate broader configs and cannot inherit a pass from the trace. |
| Recovery during changing views | Trace retains authentic newer-to-older arrival overwrite, plus exact persisted floor and primary selection. | One schedule; seeing a response while Recovering does not create a new voting promise. |
| Cross-client real-time results | Four core traces complete Put/Get/Put/Get with results nil, AA, nil, B, and record six happens-before edges each (four cross-client). EOF trace instead returns A after successful Put(AA). | Bounded register workload, stable unique clients, one outstanding request per client. |
| Healthy majority / skipped primary | Actual trace uses healthy {0,2}, skips unavailable view-1 primary and serves continuing requests. | Liveness hunts use explicit synchronous drain/tick scheduling and three calls. Existing S5-minority cfg uses healthy {1,2}, so it does not cover skipping a future unavailable primary. |
| Partial publication after persistence | Rolling trace persists view 2, releases one SVC, crashes, loses unpublished remainder and retains the authentic envelope. | Finite schedule; broader combinations are reserved for S4. |
| Two replicas | Trace covers normal work, retries and view change with FailureBudget=0. | No one-crash availability claim; recovery requiring two external responses remains a contract/configuration question. |

The history-preservation observer checks selected/installed history, rather than directly proving recoverability from every combination of extant replica and in-flight state. The client-linearizability oracle uses original invocation arguments and real-time edges and remains separate from successful trace conformance. The seven supplied hunt configs and all original bounds are preserved. Current execution status belongs in validation-status.json and the final report; this assessment itself does not claim convergence or completed hunting.
