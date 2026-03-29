# Flurry Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] InitResize (Trace.tla): inlined InitResize in trace handler with count sync from trace state. Wide-timebox puts increment count via atomic add_count before init_resize checks `count >= sizeCtl`, but their events are emitted later. Syncing count from the trace's observed `state.count` resolves the off-by-one. (Trace: test_treeify.json)

## Round 1 - Model Checking
- No violations (MC.cfg: 1.14M states, 281K distinct, depth 36)
- Converged in Round 1

## Bug Hunting
- [fix-spec] HelpTransfer (base.tla): added guards `sizeCtl /= -(rs+1)` and `transferIndex > 0` to prevent joining resize after finisher already determined. Added HelpTransferBail for bail-out path. Matches map.rs:1099-1109 checks. (Case B — NoSkippedBins violated in MC_hunt_resize.cfg, 28-state counterexample)
- Re-validated: 3/3 traces pass, MC.cfg 468K states clean
- MC_hunt_resize.cfg: 3.35M states, depth 61, PASS (exhaustive)
- MC_hunt_reclaim.cfg: 39K states, depth 21, PASS (exhaustive)
- MC_hunt_treelock.cfg: 13K states, depth 10, PASS (exhaustive)
- MC_hunt_treeify.cfg: 38K states, depth 21, PASS (exhaustive)

## Result
Converged in 1 round (+1 Case B spec fix during bug hunting). Bug hunting: 0 real bugs found across 4 configs, 3.44M+ total states (all exhaustive BFS).
