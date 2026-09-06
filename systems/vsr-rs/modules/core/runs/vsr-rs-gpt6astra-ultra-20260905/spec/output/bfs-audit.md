# Independent BFS evidence audit

Audit time: 2026-09-05T15:16:10.035633+00:00.

**PASS for record integrity and planned runtime: all six hunting BFS runs exhausted their allocated 30-minute budgets without a reported TLC error or counterexample. All six searches remain incomplete.** `bfs-summary.json` matches the actual final periodic progress samples in the six `tlc.out` files. `convergence.json` likewise matches the successful trace round and the budget-limited `MC.cfg` run; its `workflow_converged_within_budget` flag must retain that stated bounded meaning.

## Runtime and last ordinary BFS progress samples

Each hunting run declared `-t 30`, used the runner's 1800-second watchdog plus an outer 1860-second timeout, and returned 124 with the runner's `Timed out` marker. The independently checked `started_utc`/`finished_utc` differences agree with recorded monotonic elapsed times within 0.01 seconds. The watcher implementation at `scripts/infra/run_model_check.sh:430,529,543` distinguishes timeout from watchdog failure and abnormal exit. Each complete `tlc.out` is present verbatim in its `launch.out`; neither log contains a reported TLC error, violation, JVM exception, out-of-memory failure, or fatal error.

| Config | Elapsed seconds | Last progress UTC | Depth reached | Generated | Distinct | Queue sample |
|---|---:|---|---:|---:|---:|---:|
| `MC_hunt_scenario1.cfg` | 1803.797 | 2026-09-05 15:05:05 | 16 | 195,207,726 | 38,357,729 | 21,913,627 |
| `MC_hunt_scenario1_five.cfg` | 1804.432 | 2026-09-05 15:05:05 | 14 | 175,536,147 | 33,041,202 | 21,296,373 |
| `MC_hunt_scenario2.cfg` | 1804.715 | 2026-09-05 15:05:05 | 16 | 214,061,904 | 42,502,326 | 25,730,664 |
| `MC_hunt_scenario3_recovery.cfg` | 1802.393 | 2026-09-05 15:05:51 | 15 | 715,571 | 255,684 | 115,939 |
| `MC_hunt_scenario3_recovery_five.cfg` | 1802.328 | 2026-09-05 15:05:43 | 9 | 87,053 | 39,756 | 25,771 |
| `MC_hunt_scenario3_requests.cfg` | 1802.505 | 2026-09-05 15:05:31 | 9 | 505,527 | 182,469 | 130,986 |

Generated and distinct counts are lower bounds on work performed before interruption. Queue counts are point-in-time samples and are not lower bounds or final queue sizes. The reported depth is the depth reached by that periodic sample, not a completed graph diameter. None of these logs contains TLC's exhaustive-completion success message; every sampled queue is nonempty. All six depths are at most 25, so all six require the workflow's simulation follow-up on unchanged bounds.

Exact final periodic progress samples, including TLC rate fields:

```text
MC_hunt_scenario1.cfg
Progress(16) at 2026-09-05 15:05:05: 195,207,726 states generated (6,211,870 s/min), 38,357,729 distinct states found (1,216,252 ds/min), 21,913,627 states left on queue.
MC_hunt_scenario1_five.cfg
Progress(14) at 2026-09-05 15:05:05: 175,536,147 states generated (6,250,016 s/min), 33,041,202 distinct states found (1,109,692 ds/min), 21,296,373 states left on queue.
MC_hunt_scenario2.cfg
Progress(16) at 2026-09-05 15:05:05: 214,061,904 states generated (7,356,133 s/min), 42,502,326 distinct states found (1,327,716 ds/min), 25,730,664 states left on queue.
MC_hunt_scenario3_recovery.cfg
Progress(15) at 2026-09-05 15:05:51: 715,571 states generated (21,364 s/min), 255,684 distinct states found (7,071 ds/min), 115,939 states left on queue.
MC_hunt_scenario3_recovery_five.cfg
Progress(9) at 2026-09-05 15:05:43: 87,053 states generated (2,984 s/min), 39,756 distinct states found (1,589 ds/min), 25,771 states left on queue.
MC_hunt_scenario3_requests.cfg
Progress(9) at 2026-09-05 15:05:31: 505,527 states generated (13,775 s/min), 182,469 distinct states found (4,980 ds/min), 130,986 states left on queue.
```

## Safety and temporal counts

The first three configs check invariants without temporal properties. The three scenario-3 configs additionally run temporal-property checking, which prints a separate count across its temporal branches. Those larger branch-graph counts must not be substituted for ordinary reachable distinct states, added to safety-state totals, or treated as additional independent protocol coverage. The table above consistently uses the ordinary `Progress(...)` counts. Last temporal-check announcements were:

- `MC_hunt_scenario3_recovery.cfg`: `Checking 24 branches of temporal properties for the current state space with 4633170 total distinct states at (2026-09-05 15:03:44)`
- `MC_hunt_scenario3_recovery_five.cfg`: `Checking 160 branches of temporal properties for the current state space with 3542605 total distinct states at (2026-09-05 15:03:42)`
- `MC_hunt_scenario3_requests.cfg`: `Checking 32 branches of temporal properties for the current state space with 3712748 total distinct states at (2026-09-05 15:03:28)`

Completed periodic temporal checks apply to the explored partial graph under the configured service assumptions. They do not establish general request/recovery liveness.

## Convergence record

The four fresh trace logs contain explicit completed-model-checking success messages and no errors; all trace/spec hashes in `round1-traces/parallel-results.json` still match. The final `MC.cfg` run started at 2026-09-05 14:04:51 UTC, used 32 workers, a 16 GiB heap and 64 GiB off-heap fingerprint set, declared a 30-minute budget, and ended with the runner's timeout marker. Its last actual progress line is:

```text
Progress(19) at 2026-09-05 14:33:58: 1,299,398,606 states generated (45,772,311 s/min), 232,574,619 distinct states found (8,474,441 ds/min), 128,644,184 states left on queue.
```

This exactly matches `convergence.json`: depth 19; 1,299,398,606 generated; 232,574,619 distinct; queue sample 128,644,184; `exhaustive: false`. The `completed_utc` field is the record's completion timestamp, not a final TLC state-count timestamp. The earlier `MC_round1_bfs.out` and `MC_round1_bfs_retry.out` attempts are excluded from these coverage numbers; the cited run is `MC_round1_bfs_final.out` only.

## Hash agreement

Every hunting directory's copied `base.tla`, `MC.tla`, and config matches its `run.json` SHA-256, the current semantic input, the initial `inputs/` copy, and `inputs/manifest.json`. `convergence.json` hashes likewise match the live and initial `base.tla`, `MC.tla`, and `MC.cfg`. No bounds, invariants, or model changes are concealed between those audited snapshots.

| Input | Matching SHA-256 |
|---|---|
| `base.tla` | `447085336c6ab1948127bc82c5293ad5fdf16e5235aa210900e6ae15f4d94453` |
| `MC.tla` | `82c684326f596d23927a7940dc571b69bf733a6603a71811952f82b03df0c2e4` |
| `MC.cfg` | `e65455a5286a106ddd1d3707cb79b986c5c1e0938486ee4d65198b21384c6711` |
| `MC_hunt_scenario1.cfg` | `3e423621bd5de8a1b678ca80aa36473b857aad4a9206e9b82c6ce58a802c0b10` |
| `MC_hunt_scenario1_five.cfg` | `7e3bb73a3ad912a405034d2f92627e89461f444445f1cf3e5cfd6ea5f943f020` |
| `MC_hunt_scenario2.cfg` | `ec49d3d1a6c28acc06a7d93d5a084ac80007cd94ab9dce96d9f30d69635f1f1e` |
| `MC_hunt_scenario3_recovery.cfg` | `b75f0cecb8e9fa75e4132769736ddd36e2d04087ef695242296a42e6adf161f1` |
| `MC_hunt_scenario3_recovery_five.cfg` | `cf23c66df178d2c1074b281a88285bed2d701cc516527d00bd8620e88e1a610a` |
| `MC_hunt_scenario3_requests.cfg` | `173e6615f38b78e6c44c056134468accfc592acb706dd3ac49ee46982cd2f39b` |

## Audited evidence identity

| Evidence | SHA-256 at audit |
|---|---|
| `bfs-summary.json` | `6455ee981a98724b34ea2bdc0cd7112d90384497b66be2b4b7942c5a5fe28757` |
| `convergence.json` | `f3e397094ab2a6b93ddaf34d239591f5e882552129e902479afd0e3a42f4b589` |
| `MC_round1_bfs_final.out` | `afae8ff66ce35c7fb8dac2f9d5a8dfd905c03e67aa3efeff2c2720d1f659e2ae` |
| `MC_round1_bfs_final.launch.out` | `4bf7742a5df5b5cc7eab42235bc7b32c4ff5478f4554c0003a9d1454421675a4` |
| `MC_hunt_scenario1_bfs/tlc.out` | `0b03af40661b04724b0e9710aadfe13febf6366192f117305c180213e3de7dad` |
| `MC_hunt_scenario1_five_bfs/tlc.out` | `bffa576cc371c1b769dfc0c8d80de3d4939e50d5c7a45316b4514ca657b4b6ca` |
| `MC_hunt_scenario2_bfs/tlc.out` | `51f23913e74344a9bbf2eba3d467abd16c494e21aa9dde5fbd277c671aee61f3` |
| `MC_hunt_scenario3_recovery_bfs/tlc.out` | `7038bcd001fa8192edd98baf5bc6232be4bb2d41bab9f54029a81fc402c26511` |
| `MC_hunt_scenario3_recovery_five_bfs/tlc.out` | `6f924341a85b7672c268758346b94a81df923fd82e7f2e604261c2a727f3a759` |
| `MC_hunt_scenario3_requests_bfs/tlc.out` | `8236b9c87986a6ac9bf99779958841daa48fca636d771156478e858f91cb5e77` |

The corresponding six `run.json` and `launch.out` files were read and cross-checked directly, including per-run wall-clock intervals and copied-file hashes. This audit launched no TLC/build process and created only `spec/output/bfs-audit.md`; simulations in progress are outside this report.
