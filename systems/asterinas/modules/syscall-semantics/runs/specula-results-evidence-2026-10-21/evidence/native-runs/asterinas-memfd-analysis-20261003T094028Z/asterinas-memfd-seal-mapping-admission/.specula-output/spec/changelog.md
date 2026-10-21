# Validation changelog

## Phase 0 - Initialization

- Verified all base, MC, trace, hunting, instrumentation and harness inputs. The source is pinned to `0c60537098f4c2949ad2d382aaf499de72263d76`. All 53 hashes in `harness/raw/run.json` match the current files, including the instrumented source and kernel artifacts. No prior TLC task remains active.
- The Category B corpus contains 90 traces. `Trace.cfg` enables `TraceMatched`, and every wrapper checks the complete action-specific post-state record. The default-seal control uses `harness/config/TraceNoSealing.cfg`.
- Retained the harness-stage `MmapFdMode` correspondence correction, which preserves MAY bits on early O_RDONLY WRITE rejection. It is recorded in `harness/patches/base-correspondence.patch` and does not change a compatibility oracle.
- Category B acceptance requires a complete matching ordering. Preserve universal replay failures and accept the existing `TraceSearch.cfg` fallback only when its `TraceNotComplete` witness consumes every event and no protocol invariant fails.

## Round 1 - Trace Validation

- All 90 traces (4,201 events) have complete matching executions. Eighty-two pass universal replay. Eight `seal-read-race` traces require the documented existential check, each ending at `l=10` after nine events. Results, trace hashes and both outputs are in `output/validation/`.
- [abstraction-gap] Layered debugging of `seal-read-race-04.ndjson` at TLC level 4 found `pc=[t1 |-> 3,t2 |-> 2]`, `ViablePIDs={t2}` and `s.sealLock=t1`. A speculative lock acquisition blocks the earlier captured read. `memfd.rs:47,73-74` confirms both operations use the same mutex. Every affected trace has the complete alternative ordering. No base action, state comparison, invariant or trace was changed.
- The trace tool reports the newer TLC temporal/invariant messages as generic `error`. Syntax checking passed. Classification uses the retained TLC output: only `TraceMatched` fails in universal replay, and only `TraceNotComplete` fails in each complete witness.

## Round 1 - Model Checking

- Started `MC.cfg` with a 30-minute budget, 2 GiB heap, 1 GiB off-heap and deadlock checking enabled. The original bounds and workload are unchanged.
- `MC.cfg` completed with no errors: 64,042 generated states, 40,745 distinct states, depth 157 and an empty queue. The run finished naturally in two seconds. `output/validation/MC_round1.out` retains the complete log.

## Round 1 - Convergence

- Trace correspondence and `MC.cfg` both pass on the same unchanged model. Converged in one round. Known Linux compatibility predicates remain enabled in their separate hunting configurations.

## Bug Hunting

- Running every supplied `MC_hunt_*.cfg` with the original bounds and a 30-minute BFS budget per run. Follow-up simulation is required only for a violation-free run whose achieved diameter is at most 25.
- [bug] `MemfdCheckWritable` / `MappedVmoNew`: TV-1a fails `ReadOnlyAdmissionAfterWrite` in 14 states, and TV-1b fails `ReadOnlyAdmissionNoFalseBusy` in 22 states. The broad scenario-1 hunt also reaches TV-1a. Case C: post-check MAY_WRITE is cleared while tracking remains true (`map.rs:337-349`, `memfd.rs:80-89`, `vmo/mod.rs:1199-1220` at the pinned commit). These are two manifestations of known TV-1 / AST-73, reported once as MC-1.
- [bug] `VmarRemoveNext` / `MemfdCheckWritable`: TV-2 fails `SealRejectedReplacement` in a 31-state counterexample. Case C: full replacement removes the old mapping before rejecting the sealed incoming WRITE request (`map.rs:289-298,337-349`, `vmar_impls/mod.rs:377-414`). This is known TV-2 / AST-75, reported as MC-2. The matching harness also covers partial replacement.
- All five protocol hunts completed with empty queues and no enabled invariant violation or deadlock. Their depths are 58, 88, 84, 157 and 68. No simulation condition applies. All nine hunts and the convergence run are recorded in `output/validation/mc-results.json`.
- The persistent-findings lookup returned no reusable records. Known attribution is retained from the brief. No new finding is inferred from a shared identifier or from the earlier harness's successful assertion totals.
- The structured TLC parser did not recognize the current JSON trace schema. For TV-1a and TV-1b, `.text.out` copies omit only the JSON-redirection line so the tools can parse the original text states. Original `.out` and `.json` files remain intact. All four failing configurations were summarized and their final states inspected. The distinct TV-1a, TV-1b and TV-2 transitions were compared.

## Cleanup

- Archived 100 generated `Trace_TTrace_*` and `MC_TTrace_*` files in `output/validation/trace-exploration.zip` with a SHA-256 index, then ran `clean_traces` for both modules. Twelve older exploration modules listed in the harness manifest are now in that archive. Source, model, configuration, kernel and trace inputs remain unchanged.

## Result

Converged in one round without model or invariant edits. Bug hunting found two distinct known bugs and no additional bug within the supplied bounds. `bug-report.md` and `findings.json` report the same MC-1 and MC-2 findings. The existing kernel traces were revalidated. Kernel execution and repair verification were not repeated in this phase.
