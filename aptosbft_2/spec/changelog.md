# Aptos BFT — Round 2 Spec Validation Changelog

## Round 1 - Trace Validation
All 4 trace files passed on first run:
- `normal.ndjson` (245 events) — 606 states generated
- `timeout.ndjson` (53 events) — 73 states generated
- `opt.ndjson` (67 events) — 75 states generated
- `epoch_change.ndjson` (38 events) — 45 states generated

No spec changes needed for trace validation.

## Round 1 - Model Checking
- MC.cfg BFS: ran 30 minutes, reached depth 14, explored 277,460,643 distinct states (2,235,783,171 generated), TLC killed by its own -t budget; no invariant violations found. Output: `output/MC_run2.out`.

## Result
Converged in 1 round. Both phases passed without spec modifications. Proceeding to bug hunting.

## Bug Hunting

### Family 1 (`MC_hunt_family1.cfg`)
- BFS: 3-state counterexample for `RecoverPreservesLastVote` in 4s (Bug 1). Output: `output/MC_hunt_family1_bfs_recoverpreserveslastvote.out`.
- Variant `MC_hunt_family1_nodoublevote.cfg` (RecoverPreservesLastVote removed): 8-state counterexample for `NoDoubleVote` in 1min 29s (Bug 2). Output: `output/MC_hunt_family1_nodoublevote_bfs.out`.

### Family 3 (`MC_hunt_family3.cfg`)
- BFS: 12-state counterexample for `CommitEpochBound` in 5min 36s (Bug 4). Output: `output/MC_hunt_family3_bfs.out`.

### Family 2 (`MC_hunt_family2.cfg`)
- BFS still running.

### Family 4 (`MC_hunt_family4.cfg`)
- BFS still running; first attempt SIGBUS'd due to contention (`output/MC_hunt_family4_bfs.out`). Re-launched with larger memory (`output/MC_hunt_family4_bfs2.out`).

### Family 5 (`MC_hunt_family5.cfg`)
- BFS still running.
