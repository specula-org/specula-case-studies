# Generation validation

Generated against source commit `3ac0104a567092139534c9022205d02281a2da41` on 2026-09-05. The tracked Rust source was not modified. The pre-existing untracked `source/.codex/` remains untouched.

All requested files are present. Base, MC, and Trace modules passed SANY parsing and semantic analysis (also performed by the successful TLC runs). A separate read-only source audit checked guard ordering, timer/backoff updates, client-table reconstruction, DVC overwrite/ties, suffix transfer, recovery filtering, and the trace/config handoff.

| Check | Result | Scope / evidence |
|---|---|---|
| `MC_smoke.cfg`, exhaustive BFS | **PASS**; 5,180 generated, 1,677 distinct states; queue empty, depth 13 | One request, one replica idle, no faults/retries; [log](validation/MC-smoke.log) |
| `MC.cfg`, random TLC simulation | **PASS**; 200 generated traces, 20,911 states checked; seed `20260905`, aril 0, depth cap 100 | Non-exhaustive generation sanity check with bounded callbacks/crash/loss/duplication; [log](validation/MC-simulation.log). This is **TLC simulation**, not the Rust simulator. |
| Synthetic trace replay | **PASS**; all 37 tagged events consumed | Normal replication, duplicate ack, retry/cached reply, explicit loss, suffix transfer, fresh recovery, and view change; [log](validation/Trace-positive.log), [fixture](validation/trace-positive.ndjson) |
| Mutated application snapshot | **Correctly rejected**; exit 13, `TraceMatched` violation | Event 6 sets actual captured `app` to 999; [log](validation/Trace-negative-state.log) |
| Mutated emitted request payload | **Correctly rejected**; exit 13, `TraceMatched` violation | Event 3 changes a Prepare operation in `outputs`; [log](validation/Trace-negative-output.log) |
| Missing Prepare event | **Correctly rejected**; exit 13, `TraceMatched` violation | Removes the first backup Prepare handler while retaining subsequent snapshots; [log](validation/Trace-negative-missing-event.log) |
| Brief/config self-audit | **PASS with explicit exclusions** | [brief-coverage.md](brief-coverage.md); every implemented brief safety property is enabled in the actual baseline cfg; non-modeling routes are individually preserved |

The synthetic traces were authored for testing the generated replay machinery, not captured from Rust. They establish that full snapshots and outputs are enforced and that a blocked trace does not pass vacuously. They do **not** establish implementation/spec convergence. The instrumentation handoff must still be implemented and checked against actual Rust traces in the next phase.

No exhaustive run of the larger `MC.cfg` or `MC_hunt_baseline.cfg` is claimed. No targeted protocol finding was selected by the brief; no integration defect or production bug was confirmed in this phase. No finite/unbounded client-liveness theorem was checked. Message/view constraints and finite injection budgets limit baseline exploration. The actual integer-accumulator application is a specialization, not a refinement of arbitrary kvstore results. `TraceMatched` checks the supplied trace, not independent trace-capture completeness; omitted no-op calls and terminal truncation require separate capture-integrity evidence.

## Reproduction

Tools used:

- TLC `2026.08.11.125311`, revision `0894c34`.
- `/home/ubuntu/Specula-incremental-dataset-100-20260819/tools/tla2tools.jar`
- `/home/ubuntu/Specula-incremental-dataset-100-20260819/tools/CommunityModules-deps.jar`
- Java 21.0.11; one TLC worker, 2 GiB heap for final checks.

From `spec/`, set `TLA_TOOLS_JAR` and `COMMUNITY_MODULES_JAR` to those files (or equivalent compatible distributions), then:

```sh
java -XX:+UseParallelGC -Xmx2g -cp "$TLA_TOOLS_JAR" tlc2.TLC -workers 1 -seed 20260905 -config MC_smoke.cfg MC.tla
java -XX:+UseParallelGC -Xmx2g -cp "$TLA_TOOLS_JAR" tlc2.TLC -workers 1 -config MC.cfg -simulate num=200 -depth 100 -seed 20260905 MC.tla
python3 validation/make_trace_fixtures.py
JSON=validation/trace-positive.ndjson java -XX:+UseParallelGC -Xmx2g -cp "$TLA_TOOLS_JAR:$COMMUNITY_MODULES_JAR" tlc2.TLC -workers 1 -config Trace.cfg Trace.tla
```

For each negative check, replace the JSON path with `validation/trace-negative-state.ndjson`, `validation/trace-negative-output.ndjson`, or `validation/trace-negative-missing-event.ndjson`. Expected outcome is exit 13 with a `TraceMatched` violation, not a parser/type error. Use separate working/metastate directories or disable automatic trace exploration when running negative checks concurrently, as TLC's generated diagnostic filenames can collide within a second. Full independent per-check logs above are retained.

`artifact-manifest.json` records hashes of generated artifacts and the source/tool inputs. It excludes itself.
