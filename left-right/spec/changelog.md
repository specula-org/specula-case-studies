# Spec Changelog: left-right

## Round 1 - Trace Validation
- [fix] Trace.cfg: Changed Reader from model values {R1,R2} to strings {"r1","r2"} — TLC cfg parser doesn't support record constructor syntax for ReaderMapping
- [fix] Trace.tla: Removed CONSTANT ReaderMapping, made MapReader(tid) == tid since Reader uses string IDs
- Validated: basic_publish (12 events, 16 states), concurrent_rw (20 events, 63 states) — both pass

## Round 1 - Model Checking
- MC.cfg (no faults): 25.3M states, 5.5M distinct, depth 59, 14s — all 6 invariants pass
- No spec or invariant modifications needed

## Result
Converged in 1 round. Bug hunting: 0 new bugs found (3 expected fault-injection violations confirmed, 1 clean pass).

## Bug Hunting
- MC_hunt_ordering: MCOrderingNoWriteWhileRead violated (6 states) — expected, confirms SeqCst fence necessity
- MC_hunt_absorb: MCAbsorbApplyCorrectness violated (10 states) — expected, confirms deterministic absorb requirement
- MC_hunt_deadlock: Deadlock (11 states) — expected, confirms clone-while-guarded deadlock (historical 02eb63b)
- MC_hunt_variants: PASS (147M states, 33M distinct, depth 61) — all publish variants safe
