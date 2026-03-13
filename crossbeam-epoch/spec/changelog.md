# Changelog: crossbeam-epoch Spec Validation

## Round 1 - Trace Validation
- All 5 traces pass without modifications: basic_pin (91 states), nested_pin (70 states), epoch_advance (2237 states), concurrent_epoch (1539 states), finalize (58 states)

## Round 1 - Model Checking
- BFS with MC.cfg: 203M states generated, 15.1M distinct, depth 30 — all 11 invariants pass (92s)
- No spec or invariant modifications needed

## Bug Hunting
- MC_hunt_epoch.cfg (correct impl): 3.6M states, BFS complete — no violations
- MC_hunt_finalize.cfg (correct impl): 1.6M states, BFS complete — no violations
- MC.cfg simulation (correct impl): 1.1B states, 5.97M traces, depth 32 — no violations
- MC_hunt_nested.cfg (buggy NestedPinCollect): SafeReclamation violated in 11 states — confirms Issue #105
- MC_hunt_tailreach_mini.cfg (buggy pop): TailReachability violated in 14 states — confirms Issue #238
- MC_hunt_tailreach.cfg (buggy pop): TailReachability violated in 19 states — confirms Issue #238

## Hunt v2 — Extended Attack Surface

### Spec Extensions (base.tla)
- H1: Non-atomic scan (`StartScan` → `ScanOneThread` → `CompleteScan`/`AbortScan`)
- H2: Repin (`Repin` safe, `RepinUnsafe` unsafe)
- H3: Stale bag sealing (`PushLocalBagStale` — weak memory model)
- H4: Non-atomic finalize (`FinalizeStart` → `FinalizePushAndUnpin` → `FinalizeComplete`)
- New variables: `scanSet`, `finalizePhase`
- MC.tla: 5 new constants, 10 new MC wrapper actions

### Bug Hunting Results
- MC.cfg (v2 baseline): 203M states, BFS — all 11 invariants pass (10m)
- MC_hunt_repin.cfg (H2 unsafe): **SafeReclamation violated** in 15 states (24s) — confirms type system reliance
- MC_hunt_stale.cfg (H3): **SafeReclamation violated** in 15 states (30s) — confirms SeqCst fence criticality
- MC_hunt_scan_stale.cfg (H1+H3): SafeReclamation violated in 15 states (12s) — same H3 pattern, no new attack
- MC_hunt_combo.cfg (H1+H2safe+H4): 21.2B states, 1.52B distinct, depth 36, BFS complete — **no violations** (3h22m)
- MC_hunt_all.cfg (all hunts, simulation): 1.46B states, 8.8M traces — no violations

### Spec Fix
- `FinalizePushAndUnpin`: added `accessed' = [accessed EXCEPT ![t] = {}]` (clear ghost var on unpin)

## Result
Converged in 1 round. 0 new bugs in correct implementation under sequential consistency.
2 verification findings: (1) RepinUnsafe confirms &mut self is load-bearing, (2) StaleBag confirms SeqCst fence is load-bearing.
2 known-bug reproductions confirmed (Issue #105, Issue #238).
Total coverage: ~24B states generated, 1.54B distinct states.
