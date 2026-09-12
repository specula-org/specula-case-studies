# Harness results — temporal-activity

**PASS: 21/21 complete real execution replays.** A full `timeout 30m bash harness/run.sh` run built the instrumented source, passed all 21 functional scenarios, projected complete states, and passed TLC on every trace. The final run is `evidence/run-20260911T031548Z-D6wqTn/`. The final corpus was also rechecked with the bundled checker used for MC.

| Evidence | Result |
|---|---:|
| Complete real traces / events | 21 / 2,414 |
| Independent cache/SQL AI comparisons | 187 |
| Delivered token/response comparisons | 24 |
| Independent task key assignments | 205 |
| Raw consistency corruptions rejected | 84 |
| Key-allocation corruptions rejected | 63 |
| Selective TLA+ corruptions rejected | 84 / 84 |
| Separately labeled synthetic controls | 5 / 5 generated and replayed; not real traces |

Each complete trace reaches terminal Activity consumption in a completed WFT, followed by independent reload and in-flight message accounting. A real two-Activity timeout scan, duplicate timer delivery after a lost acknowledgement, same-UUID start retry and rejected buffered Workflow close supplement the retained lifecycle, retry, cancellation and persistence/recovery cases.

The source is pinned at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Each scenario uses a real testcore cluster and independent file-backed SQLite/WAL/synchronous=NORMAL database. Exact binary, patch, configuration, source, raw/readback and tool identities remain in run provenance. The projector checks immutable submission fields against cache observations and actual SQL state separately; it does not evaluate TLA+ successors. The final independently retrieved History also matches the committed projection.

`../spec/validation-report.md` reports the completed bounded baseline, separate incomplete larger searches, case classifications and conditional progress assumptions. Historical incomplete harness/spec runs remain retained under their original hashes. No process/database restart, power-loss durability or administrative extension is claimed by this corpus.
