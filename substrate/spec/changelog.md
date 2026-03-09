# Substrate GRANDPA Spec Changelog

## Round 1 - Trace Validation
- [fix] TraceInit: Changed blockTree initialization from `IF b=1 THEN 0 ELSE NilBlock` to all NilBlock. Implementation starts with only genesis (block 0); blocks are produced by test. bestBlock initialized to 0 instead of 1.
- [fix] Trace.cfg: Changed Server/InitAuthorities from model values `{s1, s2, s3}` to strings `{"s1", "s2", "s3"}` to match JSON trace deserialization. Adjusted Block={1..5}, MaxBlock=5 for test scenario.
- [fix] NilBlock: Changed from 0 to 99 in all config files. NilBlock=0 conflicts with genesis parent (also 0). TLC config parser also doesn't support negative literals.
- [fix] ProduceBlock: Changed guard from `parent = 0 \/ blockTree[parent] /= NilBlock` to `IF parent = 0 THEN TRUE ELSE blockTree[parent] /= NilBlock`. TLC doesn't short-circuit `\/` in guards, causing out-of-domain error when parent=0.
- [fix] FinalizedBlockExists: Same IF-THEN-ELSE fix for `finalizedBlock[s] = 0` guard.
- [fix] SilentProduceBlock: Added guard `logline.event /= "ProduceBlock"` to prevent silent block production from stealing blocks traced by ProduceBlock events.
- [fix] ComputeVoteLimit: Renamed to ComputeVoteLimitOf(ps, fb) with explicit parameters. TLC can't resolve primed variables inside operator definitions (`ComputeVoteLimit(s)'` fails). All call sites updated with unprimed explicit values.
- [fix] TraceDone: Added stuttering action `l = Len(TraceLog) + 1 /\ UNCHANGED <<vars, l>>` to TraceNext. Prevents false deadlock at end of trace. Removed temporal PROPERTIES check from Trace.cfg (not needed with done action).
- Trace: basic_finalization.ndjson — PASSED (20 states, 18 events)

## Round 2 - Model Checking

### Spec fixes (Case B: spec too permissive)
- [fix] FinalizationSafety voting guard: Added chain ancestry check to Prevote and Precommit actions. Honest nodes must vote for descendants of their finalized block: `IF finalizedBlock[s] = 0 THEN TRUE ELSE IsAncestor(finalizedBlock[s], block, blockTree)`. Without this, nodes could vote for blocks on conflicting forks.
- [fix] Deterministic ApplyStandardChange: Added ordering guard — pick the ready change with smallest effective number, ties broken by smallest block number. Matches implementation's deterministic BTreeMap ordering.
- [fix] Deterministic ApplyForcedChange: Same deterministic ordering guard as ApplyStandardChange. Prevents non-deterministic application when multiple forced changes are ready.
- [fix] Recovery re-population: Updated Recover to re-populate pendingStandard and pendingForced from changeRecord (on-chain data) instead of clearing to {}. Implementation re-discovers changes by re-importing blocks on recovery.
- [fix] IsAncestor NilBlock handling: Added `b2 = NilBlock` and `bt[b2] = NilBlock` early returns to prevent out-of-domain errors when traversing uninitialized block tree entries.

### New variables and structural changes
- [new] changeRecord: Global variable `changeRecord[b]` tracks on-chain authority change parameters per block. Values: `[type |-> "none"]`, `[type |-> "standard", delay, newAuth]`, or `[type |-> "forced", delay, newAuth, medFin]`. Ensures on-chain determinism — all nodes see the same change for a given block.
- [new] MC.tla compound actions: MCProduceBlockWithStdChange and MCProduceBlockWithForcedChange atomically combine block production with authority change scheduling. Models implementation behavior where changes are embedded in blocks.
- [fix] MC.tla fork-bypass prevention: MCProduceBlock and MCProduceBlockWithStdChange require new blocks to have any pending forced change block as ancestor. Prevents blocks on sibling forks from bypassing a forced change. Implementation applies forced changes synchronously on block import, so blocks can't appear on a sibling fork before the change is applied.
- [fix] MC.tla single forced change limit: `\A b2 \in Block : changeRecord[b2].type /= "forced"` — at most one forced change in the system at a time. Multiple pending forced changes cause non-deterministic application order because we model per-node async application.
- [fix] MC.cfg Quorum: Changed from 2 to 3. With n=3, f=1: safety requires 3f+1=4 > n=3, so quorum must be 3 (all nodes must agree).

### Invariant adjustments (Case A: invariant too strong)
- [removed] VoteLimitRespected from MC.cfg: Vote limit can decrease retroactively when standard changes are added after votes are cast. Guard enforcement at vote time (in Prevote/Precommit) is the correct check.
- [removed] StandardChangeOrdering from MC.cfg: When finalization jumps multiple blocks, multiple standard changes can become ready simultaneously. Deterministic ordering in ApplyStandardChange ensures correct application.

### Model checking results
- Configuration: Server={s1,s2,s3}, Block={1,2,3,4}, MaxRound=2, Byzantine={s3}
- Simulation: 2.19M traces, 32.5M states, depth 30 — zero violations
- Invariants checked: FinalizationSafety, ElectionSafety, AuthoritySetConsistency, NoPrevoteSkip, ForcedChangeDependency, FinalizedBlockExists, RoundInBounds, EquivocationCorrectness, SetIdMonotonic, FinalizedMonotonic

## Round 3 - Trace Re-validation
- Trace: trace.ndjson (basic finalization) — PASSED (20 states)
- Trace: trace_substep.ndjson (sub-step finalization with lock acquire/write/release) — PASSED (20 states)
- Trace: trace_crash.ndjson (crash and recovery before voting) — PASSED (20 states)
- Trace: trace_multiround.ndjson (two rounds, incremental finalization) — PASSED (20 states)
