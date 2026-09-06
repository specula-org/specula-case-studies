# Independent simulation evidence audit

Audit time: 2026-09-05T15:40:24.611948+00:00.

**All six mandatory simulation follow-ups exhausted their allocated 30-minute budgets without a reported TLC violation, counterexample, or runtime error.** The audit verified the original simulation logs and copied inputs after resuming the interrupted session. These are bounded random searches, not exhaustive proofs. No TLC process was started, restarted, stopped, or modified by this audit.

## Completion evidence and limits

Each original launch record requests `-t 30 -S -n 999999999 -p 100 -w 5 -m 8G -M 4G`, with `timeout_seconds: 1800` and `outer_timeout_seconds: 1860`. The six original TLC JVMs were observed running after the provider interruption; all six original JVM PIDs are absent from `/proc` at this audit. Every `launch.out` ends with the runner's explicit `Timed out` marker. The complete `tlc.out` text appears verbatim in its corresponding `launch.out`. The logs contain no reported TLC error, invariant/temporal violation, JVM exception, out-of-memory failure, or fatal error, and no `counterexample.json` was emitted.

The provider interruption prevented the original driver from recording completion fields. The original launch metadata is preserved separately as `run.launch.json` in every run directory. All original fields are unchanged in recovered `run.json`. The recovered progress arrays, log hashes, rounded elapsed durations, and final-write timestamps were independently cross-checked against the original files; recovery provenance is explicitly recorded in every JSON record. The `124` result is **inferred from the wrapper's timeout branch**, not an OS-collected return value. `scripts/infra/run_model_check.sh` waits for the JVM, distinguishes watchdog failure from watchdog timeout, sets `EXIT_CODE=124` on watchdog timeout, and emits the observed `Timed out` marker only for that value. `src/specula/tlc_resources.py:enforce_timeout` waits the requested 1800 seconds before sending SIGTERM to the original JVM identity.

The completion times below are **filesystem modification times of the final `launch.out` writes**, not exact process-exit timestamps. Their intervals from the original `started_utc` metadata are filesystem-derived wall durations, not recovered monotonic measurements. All exceed 1800 seconds and precede the 1860-second outer bound. Combined with the explicit timeout branch and observed exited original JVMs, this supports full budget consumption without inventing missing process telemetry.

| Config | Original JVM PID | Start UTC | Final launch write UTC | Derived wall seconds | Result |
|---|---:|---|---|---:|---|
| `MC_hunt_scenario1.cfg` | 784640 | 2026-09-05T15:06:44.039162+00:00 | 2026-09-05T15:36:44.668036+00:00 | 1800.628874 | Budget timeout; inferred wrapper result 124 |
| `MC_hunt_scenario1_five.cfg` | 784653 | 2026-09-05T15:06:44.048899+00:00 | 2026-09-05T15:36:44.669036+00:00 | 1800.620137 | Budget timeout; inferred wrapper result 124 |
| `MC_hunt_scenario2.cfg` | 784628 | 2026-09-05T15:06:44.030052+00:00 | 2026-09-05T15:36:44.620036+00:00 | 1800.589984 | Budget timeout; inferred wrapper result 124 |
| `MC_hunt_scenario3_recovery.cfg` | 784688 | 2026-09-05T15:06:44.069594+00:00 | 2026-09-05T15:36:44.577037+00:00 | 1800.507443 | Budget timeout; inferred wrapper result 124 |
| `MC_hunt_scenario3_recovery_five.cfg` | 784671 | 2026-09-05T15:06:44.061138+00:00 | 2026-09-05T15:36:44.518037+00:00 | 1800.456899 | Budget timeout; inferred wrapper result 124 |
| `MC_hunt_scenario3_requests.cfg` | 784706 | 2026-09-05T15:06:44.080095+00:00 | 2026-09-05T15:36:44.514037+00:00 | 1800.433942 | Budget timeout; inferred wrapper result 124 |

## Last periodic progress samples

Every simulation used maximum depth 100. Each TLC log contains 29 periodic progress samples; the last sample was written about one minute before the watchdog deadline. Counts below are those last reported samples, so they are lower bounds on work done before termination. States checked include repeated visits across random traces and must not be called unique reachable states or added to BFS distinct counts. Mean trace length is a reported sample statistic, not a completed graph diameter or evidence that every trace reached depth 100.

| Config | Seed | States checked | Traces generated | Mean length | Variance | Standard deviation |
|---|---:|---:|---:|---:|---:|---:|
| `MC_hunt_scenario1.cfg` | -7779495975857643353 | 131,614,373 | 1,058,385 | 77 | 505 | 22 |
| `MC_hunt_scenario1_five.cfg` | 5523295472982188219 | 188,856,259 | 1,544,266 | 78 | 483 | 22 |
| `MC_hunt_scenario2.cfg` | 8670264126931185200 | 196,883,558 | 1,590,914 | 78 | 460 | 21 |
| `MC_hunt_scenario3_recovery.cfg` | 6674517494790157010 | 2,369,826 | 23,499 | 78 | 485 | 22 |
| `MC_hunt_scenario3_recovery_five.cfg` | 8725687031880804619 | 257,917 | 2,532 | 78 | 494 | 22 |
| `MC_hunt_scenario3_requests.cfg` | 8280694003555120065 | 438,450 | 3,560 | 78 | 491 | 22 |

Exact final periodic samples:

```text
MC_hunt_scenario1.cfg
Progress: 131614373 states checked, 1058385 traces generated (trace length: mean=77, var(x)=505, sd=22)
MC_hunt_scenario1_five.cfg
Progress: 188856259 states checked, 1544266 traces generated (trace length: mean=78, var(x)=483, sd=22)
MC_hunt_scenario2.cfg
Progress: 196883558 states checked, 1590914 traces generated (trace length: mean=78, var(x)=460, sd=21)
MC_hunt_scenario3_recovery.cfg
Progress: 2369826 states checked, 23499 traces generated (trace length: mean=78, var(x)=485, sd=22)
MC_hunt_scenario3_recovery_five.cfg
Progress: 257917 states checked, 2532 traces generated (trace length: mean=78, var(x)=494, sd=22)
MC_hunt_scenario3_requests.cfg
Progress: 438450 states checked, 3560 traces generated (trace length: mean=78, var(x)=491, sd=22)
```

The scenario-3 configurations include temporal checking under their configured communication, recovery, and service assumptions. No sampled counterexample was reported; these finite random searches do not establish general request/recovery liveness. See the existing `bfs-audit.md` and final bug report for the separate BFS evidence and property scope.

## Input identity

All 18 copied simulation inputs (`base.tla`, `MC.tla`, and the per-run config) match their original launch SHA-256 values, the live semantic inputs, `output/inputs/` snapshots, and `output/inputs/manifest.json`. The matching config hashes are also identical to those independently recorded in `bfs-audit.md`; bounds and property wiring were unchanged between BFS and simulation. Source revision in every original launch record is `3ac0104a567092139534c9022205d02281a2da41`.

| Input | SHA-256 |
|---|---|
| `base.tla` | `447085336c6ab1948127bc82c5293ad5fdf16e5235aa210900e6ae15f4d94453` |
| `MC.tla` | `82c684326f596d23927a7940dc571b69bf733a6603a71811952f82b03df0c2e4` |
| `MC_hunt_scenario1.cfg` | `3e423621bd5de8a1b678ca80aa36473b857aad4a9206e9b82c6ce58a802c0b10` |
| `MC_hunt_scenario1_five.cfg` | `7e3bb73a3ad912a405034d2f92627e89461f444445f1cf3e5cfd6ea5f943f020` |
| `MC_hunt_scenario2.cfg` | `ec49d3d1a6c28acc06a7d93d5a084ac80007cd94ab9dce96d9f30d69635f1f1e` |
| `MC_hunt_scenario3_recovery.cfg` | `b75f0cecb8e9fa75e4132769736ddd36e2d04087ef695242296a42e6adf161f1` |
| `MC_hunt_scenario3_recovery_five.cfg` | `cf23c66df178d2c1074b281a88285bed2d701cc516527d00bd8620e88e1a610a` |
| `MC_hunt_scenario3_requests.cfg` | `173e6615f38b78e6c44c056134468accfc592acb706dd3ac49ee46982cd2f39b` |

## Audited original log identity

| Evidence | SHA-256 |
|---|---|
| `MC_hunt_scenario1_simulation/tlc.out` | `e1e17730aa7ae71eabfe53e07136b756056a22fb8491dd22562b2a4287ebbe62` |
| `MC_hunt_scenario1_simulation/launch.out` | `4f10e7459e8390c9ab0b93a9577f200a13c9cef9c6d576e9682fe0263167f1cb` |
| `MC_hunt_scenario1_five_simulation/tlc.out` | `273b57643717a7e80d29e3a90e1e412bba6941b8868c633a201543f8aad4a690` |
| `MC_hunt_scenario1_five_simulation/launch.out` | `edc5c0fe0ba0c1082de3d88ad9a2fad7ca6456ee6ff0c81d794a7e115b5d8363` |
| `MC_hunt_scenario2_simulation/tlc.out` | `a692d3d153240adbf6d0d118afc92e763c7b89641e45202e138e1c726bd2ec77` |
| `MC_hunt_scenario2_simulation/launch.out` | `1f60bb28c687831a5636c8d31e73b46ec32c3ff99b11d5bd8de0cbeb1b6854e4` |
| `MC_hunt_scenario3_recovery_simulation/tlc.out` | `599d33c6dcdbb0d6e132ca2e786a3ab7dd1fcc5a2c610e66fcd2b86edcea32fc` |
| `MC_hunt_scenario3_recovery_simulation/launch.out` | `1dd995cada11b30df09052a0cd9896ed97e174d79f1df1c8406f5c7b395d3786` |
| `MC_hunt_scenario3_recovery_five_simulation/tlc.out` | `fc3433c3adb12523bfed1652060fb3ad6116af62dd5ed02e792bece6dc65f30e` |
| `MC_hunt_scenario3_recovery_five_simulation/launch.out` | `6b29f70c17172d794c18ededbdbd59a4070a23e5199d3e0d11b77f009990fcd4` |
| `MC_hunt_scenario3_requests_simulation/tlc.out` | `b14806f7a033d8083c1c991db14c6b53fa2a0226cbdb530b10e59413394500e4` |
| `MC_hunt_scenario3_requests_simulation/launch.out` | `21cc2eee727d63044a2999e364f54a9cc292509e145a6db6447aced93d1bfb23` |

This audit creates only `spec/output/simulation-audit.md`. It reuses completed BFS, trace-validation, and convergence evidence, and does not rerun any prior analysis or search.
