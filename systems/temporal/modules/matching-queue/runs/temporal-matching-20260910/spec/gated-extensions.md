> Current extension status: priority calibration and scoped checking completed. The S5/MC-5 mechanism was reproduced in a separate real SQLite V2 diagnostic; see [fairness-diagnostic.md](fairness-diagnostic.md). This does not validate a complete fairness TLA+ suite or Cassandra paging. The remaining extension work below stays explicit.

# Gated follow-up, not priority coverage

## MC-4 backend paging

Selected executable model is SQL TaskStore V1 with SQLite ordered SELECT/LIMIT (`common/persistence/sql/task_v1.go:114-155`, `sqlplugin/sqlite/task_v1.go:45-74`). An empty selected interval contains no retained row; no arbitrary empty page action is allowed. Cassandra source returns continuation at `common/persistence/cassandra/matching_task_store_v1.go:154,187-188`; the brief does not establish the proposed Apache Cassandra version/configuration can return an empty nonterminal page.

After a real-store capability trace establishes that behavior, introduce a separately named backend module with `(rows, continuation, exhaustedInterval)` read results. Retain the actual reader's ignoring of continuation (`pri_task_reader.go:222-244`, `db.go:700-715`). Add `MC_hunt_S2_paging_<backend>.cfg` enabling `AckPrefixSound` and `AcceptedWorkCovered`; preserve SQL as a negative control. Preserve conditional batch atomicity, metadata-on-append and backend TTL semantics in that module, rather than adding a free page-loss fault to SQL.

## S5 / MC-5 fairness

Gate: complete real queue + real SQL V1 normal, overlap and failure/reload traces with negative controls, followed by a calibrated bounded priority baseline. The 32 original/fresh priority traces and five controls now satisfy the controlled trace gate; the current Phase 3 baseline ended INCOMPLETE. No `FairAckWithinTrackedPrefix == TRUE` placeholder or empty hunting cfg is supplied.

Then build a **separate V2 suite** from the brief's exact A/B/C/Y/Z/R schedule. Required state: `(pass,id)` levels, exact key counters, real outstanding entries versus ack markers, read/atEnd, `ackPin`, write-merge queue, evicted acks, loaded count, and the paused replacement callback. Preserve current membership/eviction guards and writer pinning. Split `fair_task_reader.go:153-218` around re-spool I/O, allow `mergeTasksLocked:514-551` to evict the outstanding callback's record, then execute `advanceAckLevelLocked:608-637`. Keep the SQL/Cassandra V2 store distinct from V1.

Required property: `FairAckWithinTrackedPrefix` must reject an ack advance across evicted, unresolved B and any loaded-count mismatch. Target `MC_hunt_S5_fairness.cfg` must actually enable that property plus `AcceptedWorkCovered`; zero unrelated ownership/fault limits while retaining at least six storage records and the replacement/merge schedule. Do not claim weighted fairness or a confirmed upstream bug from this source schedule. Full source schedule and compensations remain in `../analysis-report.md`.
