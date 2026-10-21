# Validation changelog

## Phase 0
- Source revision `604948581512d83734377974d4c34adb4530f2d7`; instrumented-source manifest and harness artifact hashes verified. Inputs captured in `output/phase0-identity.json` and `output/input-spec/`.
- 111 Category B guest traces; `TraceMatched` and mandatory post-state checks are enabled. Phase 2.5 reports two ramfs collection mismatches and supplies a separate proposed patch.
- The MCP trace runner cannot find `java`; use the installed JRE with the same TLC jars and tool implementation. This is an infrastructure error, not a trace result.

## Round 1 - Trace Validation
- [fix] VmoCollectBegin: bound collection by native vector capacity; unaligned ramfs writes spanning three pages first collect two. Inconsistency Error, evidenced by baseline `vmo/mod.rs:581-584,780` and debugger level 8: segmentEnd 5 vs observed 4, collectEnd 3 vs observed 2 (`ramfs-3-3.ndjson`; also `ramfs-2-2.ndjson`). No trace comparison or outcome invariant changed.
- All 111 immutable guest traces match: 108 pass TraceMatched universally; three use the supplied TraceNotComplete witness mode with every final thread cursor checked against length + 1. Universal failures are dead-end candidate orderings, not incomplete accepted traces. Receipts: `output/trace-round1-results.json`.

## Round 1 - Model Checking
- Infrastructure: the detached launch exited before parsing when its shell tool session closed; no TLC result was produced. The foreground wrapper retains the session, resource admission and 30-minute watchdog. Original launch log remains `output/MC_round1.out`.
- `MC.cfg` completed without violations: 11,270 generated states, 8,131 distinct, depth 32, queue empty; exit 0. No spec or invariant changes during this phase. Log: `output/MC_round1_foreground.out`.

## Convergence
- Converged in one round: all 111 traces have full matching executions; the required `MC.cfg` exploration completed without violations.

## Bug hunting
- Run all 40 supplied hunting configurations unchanged. Each BFS has a 30-minute budget; completed runs with diameter at most 25 receive a 30-minute simulation with depth 100 and 999999999 requested traces.
- [bug] MC-1: Ramfs reads report a saved count that differs from delivered bytes (Case C; `MC_hunt_s1_ramfs.cfg`; evidence and qualifications in `bug-report.md`).
- [bug] MC-2: ExFAT reads copy beyond their reported prefix during write preparation (Case C; `MC_hunt_s1_growth_exfat.cfg`; evidence and qualifications in `bug-report.md`).
- [bug] MC-3: ExFAT stale write preparation permits false success and inconsistent extents (Case C; `MC_hunt_s2_exfat_extent.cfg`; evidence and qualifications in `bug-report.md`).
- [bug] MC-4: ExFAT successful ftruncate can retain the old logical size (Case C; `MC_hunt_s3_extend_zero_exfat.cfg`; evidence and qualifications in `bug-report.md`).
- [bug] MC-5: ExFAT regrown holes can read the subject's old backing bytes (Case C; `MC_hunt_s3_holes_exfat.cfg`; evidence and qualifications in `bug-report.md`).
- [bug] MC-6: Ramfs zero-count positional writes can enlarge the file (Case C; `MC_hunt_s4_empty_ramfs.cfg`; evidence and qualifications in `bug-report.md`).
- [bug] MC-7: ExFAT zero-count positional writes can enlarge the file (Case C; `MC_hunt_s4_empty_exfat.cfg`; evidence and qualifications in `bug-report.md`).
- [bug] MC-8: Ramfs zero-progress failed writes can publish the full requested extent (Case C; `MC_hunt_s4_fault_ramfs.cfg`; evidence and qualifications in `bug-report.md`).
- [docs] Updated `brief-coverage.md` for native batch capacity, validated traces, and per-configuration vacuity/liveness limits. Outcome predicates and hunting inputs remain unchanged.
- [cleanup] Ran `clean_traces`: removed 56 generated Trace_TTrace files. Preserved all 111 input traces and raw replay/model-checking outputs.
- Nine simulation follow-ups completed their 30-minute budgets without violations; observed wrapper exits were 124. Final per-config receipts: `output/simulation-final-summary.json`.

## Result
Converged in one round. Bug hunting: eight source-backed model findings from 18 violating configs; 22 BFS configs completed without violations. All nine required simulations finished. Existing guest receipts support ramfs growth under-reporting and exFAT resize; other runtime and fixture limits are in `bug-report.md`.
