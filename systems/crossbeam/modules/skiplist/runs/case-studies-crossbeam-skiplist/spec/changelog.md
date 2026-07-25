# Changelog: crossbeam-skiplist Spec Validation

## Round 1 - Trace Validation
- [fix] TraceNext: Changed stuttering clause from `ThreadsWithEvents = {} /\ UNCHANGED` to unconditional `UNCHANGED allTraceVars` — dead-end interleavings in Category B (concurrent) cause deadlocks without unrestricted stuttering
- [fix] TraceMatched: Replaced temporal property with inverted invariant `TraceIncomplete` (violation = success) — temporal properties require fairness and still fail for dead-end interleavings in Category B
- [fix] ValidateBuildLevel: Pass `tid` parameter instead of accessing nonexistent `logline.tid` field — thread ID comes from the outer JSON key, not from event records
- [fix] StringToNat: Extract last character before digit matching — multi-digit node IDs like "10" were parsed incorrectly (matched entire string against single-digit patterns, returning -1)
- Validated traces: basic_ops (17 states), concurrent_insert_remove (25 states), interleaved_ops (71 states)

## Round 1 - Model Checking
- [fix-spec] InsertBegin/RemoveBegin: Added `tEntry[t] = Nil` precondition — Rust ownership prevents starting new operations while holding an entry handle; without this, entry handles leak and refCount diverges (Case B)
- [fix-inv] RefCountCorrect: Changed from exact equality to two-sided bound (LivePhysicalLinks <= refCount <= AllPhysicalLinks + EntryHandles) — marking a predecessor reduces live links before HelpUnlink decrements refCount, so exact equality doesn't hold in intermediate states (Case A)
- [fix-inv] PhysicalLinks: Split into LivePhysicalLinks (non-marked predecessors only) and AllPhysicalLinks (all predecessors) — stale outgoing pointers from marked nodes are not reference-counted in the implementation (Case A)
- MC result: 1.5B states, 360M distinct, depth 21, 30 min BFS — all 8 invariants pass

## Round 2 - Trace Validation (regression check)
- All 3 traces pass: basic_ops (17), concurrent_insert_remove (25), interleaved_ops (71)
- No regressions from Round 1 spec changes

## Bug Hunting
- F1 (Ref Count Lifecycle): BFS 750M states depth 22, sim 1.39B states 13.5M traces — no violation
- F2 (Linearizability, MarkBeforeCAS=TRUE): BFS 742M states depth 21, sim 2.84B states 26.8M traces — no violation
- F4 (Tower Marking Protocol): BFS 691M states depth 20, sim 2.16B states 20.4M traces — no violation

## Result
Converged in 2 rounds. Bug hunting: 0 bugs found across 3 configs, 7.4B+ states explored.
