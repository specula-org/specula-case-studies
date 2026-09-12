# Brief coverage self-audit

Audited the actual active `INVARIANTS`, `PROPERTIES`, and fault constants in all `MC*.cfg` files after writing Phase 2. This is the mandatory Phase 2.5 deliverable. Target: Category A, Temporal `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`, one cluster/shard, immediate Transfer, SQL/SQLite WAL. Code-generation checks are recorded separately in `checks/validation.md`; configuration coverage is not completed exploration or implementation-trace convergence.

## Brief §2 and user priorities

| Scenario / priority | State and actual mechanism | Targeting cfg |
|---|---|---|
| S1 / Q1 uncertain publication | `s.pub` allocation/epoch/pending/result; atomic `UpdateWorkflowExecutionCommit`; commit and completion/timeout split; `HighWatermark`; renewal fences before clearing pending; lost notification does not gate polling | `MC_hunt_s1_publication.cfg` |
| S2 / Q2,Q5 live cursor and scope | Ordered identity-bearing `lists`, `cursor`, `detached`, real iterator intervals including `[hi,hi)` after a full batch, independent executable identities; shrink, range/predicate splits, merge, compaction, clear cancellation and movement handoff | `MC_hunt_s2_cursor.cfg` diagnoses CR-1; `MC_hunt_s2_coverage.cfg` checks durable consequences without stopping at the already-known cursor diagnostic; `MC_hunt_s2_progress.cfg` checks fair service |
| S3 / Q3 delete versus checkpoint | Separate captured scopes, DELETE commit/reply, volatile `memory`, copied `snaps`, fenced UpdateShard commit/reply, persisted `db.queue`; snapshot order is unconstrained within an epoch | `MC_hunt_s3_checkpoint.cfg`; `MC_hunt_s3_cleanup.cfg` |
| S4 / Q4 ownership | Distinct volatile owners; `AcquireShardBegin`, `RenewRangeLockedCommit`, `AcquireShardComplete`; only actual protected SQL stores check epochs; late executors and unfenced immediate DELETE remain possible | `MC_hunt_s4_ownership.cfg` |
| S5 / Q5 responsibility | Matching spool/start, terminal discard, obsolescence, worker completion, durable DLQ acceptance, retries and volatile ACK are distinct observations; Matching/DLQ effects precede their replies | `MC_hunt_s5_responsibility.cfg`; `MC_hunt_s5_terminal_contract.cfg` deliberately tests the strict claim against the documented terminal-drop policy |

The S2 safety and progress configs are deliberate additional views of the same scenario, not extra discoveries. Strict terminal-policy diagnostics are separate from the no-terminal-drop contract used by S1–S4 and the primary S5 hunt. No scheduled cleanup, Matching backlog algorithm, timer compensation, CHASM, replication, visibility or archival is inferred from this model.

## Brief §5: actual enabled properties

All operators are defined in `base.tla` and inherited by `MC.tla`. Scenario properties are commented out in `MC.cfg`; the following entries were read from active hunt cfg blocks.

| Brief property | Enabled hunt cfgs | Oracle boundary |
|---|---|---|
| AtomicPublication | S1 publication | Historical workflow mutation and inserted-row receipts agree; rows may later be deleted. One ordinary generated Transfer obligation per modeled transaction. |
| SafeReadFrontier | S1 publication, S4 ownership | An unresolved write still admissible at the durable epoch cannot commit below a retired queue frontier. Committed-but-unobserved writes remain tracked but need not block after fencing. |
| UnfinishedObligationCovered | S1 publication, S2 coverage, S3 checkpoint, S4 ownership, S5 responsibility, S5 terminal contract | Strict transport responsibility requires durable row plus reconstruction coverage or actual downstream/obsolete/DLQ responsibility. `terminal` is deliberately not acceptance. |
| SafeImmediateDeletion | S3 checkpoint, S3 cleanup, S4 ownership, S5 responsibility | Every original task in the physical deletion receipt has a responsibility endpoint. SQLite deletes exactly `[deleteMin,capturedMin)`, not a globally assumed prefix. |
| CurrentEpochWrites | S1 publication, S4 ownership | Compares requested and actual durable epochs recorded at protected store commit, not epochs after subsequent takeover. |
| LiveCursorSoundness | S2 cursor | Structural/progress diagnostic, expected to fail for the existing CR-1 mechanism. A detached cursor alone is not proof of a stranded later task. |
| RecoverableScopeCoverage | S2 coverage, S2 progress, S3 checkpoint | Reconstructing `db.queue` must cover unresolved extant rows below its high frontier, with predicates. Reader predicates may overlap. |
| EligibleDispatchProgress | S2 progress via `CheckedDispatchProgress` | Stable active ownership and per-reader/executable/store fair service. No unconditional shard reload, operator DLQ replay or worker completion is assumed. |
| EventualCleanup | S3 cleanup via `CheckedEventualCleanup` | Stable ownership, finite faults, fair checkpoint/store service; permanently responsible prefix rows eventually disappear physically. |

`NoPhantomEffect`, `CompletedWasStarted`, `AckDisposition` are the core safety checks used in every hunt. `TypeOK`, `ReaderStructure`, `MCTypeOK` are convergence structural checks; they are not substituted for scenario checks. `ContractObligationCovered`/`ContractImmediateDeletion` expose a explicitly weaker terminal-policy interpretation for interactive analysis and are **not counted** as additional brief coverage.

## Brief §6.1: reachable composition setups

| Finding | Required trigger and enabled budgets | Expected oracle / cfg |
|---|---|---|
| MC-1 | Delayed appended write, 1 unknown reply, 1 takeover plus unbounded reactive same-owner renewal within the epoch horizon; checkpoint and DELETE run while the old queue lives; 1 lost DELETE and 1 lost shard reply; allocation bound 3 | SafeReadFrontier / UnfinishedObligationCovered, S1 publication; S4 ownership |
| MC-2 | Full batch1, three tasks, two readers and three namespace groups; move threshold1; clear keeps late calls; predicate limit1 permits widening after unions; partial iterator intervals and range splits retain their boundary states; takeover1, retry1, lost Matching reply1 | RecoverableScopeCoverage / UnfinishedObligationCovered, S2 coverage; fair-service S2 progress. CR-1 separately targets LiveCursorSoundness. |
| MC-3 | Two simultaneous snapshot slots; repeatable external and checkpoint snapshot captures; same-epoch commits can reorder; definite DELETE failure1, committed DELETE lost reply1, shard failure1/lost reply1, ownership replacement1 | SafeImmediateDeletion / RecoverableScopeCoverage, S3 checkpoint; EventualCleanup, S3 cleanup |
| MC-4 | Real Matching/DLQ acceptance before lost reply; Matching loss1, DLQ loss1, terminal error1/unexpected errors2 to reach DLQ; takeover1 and stop1; clear/split/move/compact remain enabled | UnfinishedObligationCovered, S5 responsibility and S4 ownership; S2 coverage checks related scope consequences |

No §6.1 item is silently routed to a config with its trigger disabled. These are reachability budgets, not completed exhaustive-search claims.

## Scope of the abstraction and remaining handoffs

- Production batch100 is scaled to batch1/2 while preserving the **full versus partial batch branch** and the unremoved empty iterator. Move threshold500/multiplier3 and predicate bytes are represented by small threshold/group capacity. Harness traces must record the production values and use matching constants or an explicitly justified batch quotient. The supplied cfg is not a claim that production defaults equal these small numbers.
- Each publication request represents one ordinary Workflow/Activity Transfer task and its workflow mutation. Atomic co-publication of multiple Transfer tasks by the same real transaction needs a bundle extension before replaying such a transaction; unrelated timer rows are outside this queue projection. The current model does not split a real transaction into multiple intermediate commits.
- A reader batch is one action under its reader mutex as proposed by the brief. Store and downstream outcomes are separate actions. A harness must serialize observations at modeled linearization points; arbitrary unsynchronized JSON line order is not a complete trace. A concurrent database-read snapshot/DELETE-return schedule needing buffered read rows requires a finer batch adapter before claiming coverage.
- Slice/executable/snapshot identities come from finite pools. Normal ACK/read/checkpoint/retry actions have no counters, but a finite pool can prevent an otherwise legal allocation. These capacities are part of each bound; liveness conclusions require sufficient free representation capacity. MessageBuffer is a state constraint in safety configs only; liveness configs deliberately omit symmetry and state pruning.
- Queue mitigation choices (range split, compaction, clear) abstract alert thresholds and permit their code-faithful transformations when applicable. This over-approximates when mitigation is invoked. Clear cancellation is split into individual wrapper state changes while holding the reader lock. Interactions are represented; exact monitor counts and production policy scheduling are not verified.
- Merge retains one executable per duplicate key. Group-count inflation CR-2/TV-2 is not modeled as exact arithmetic; the audit must retain that native-test question, including effects on mitigation thresholds and predicate shrinking. CR-3 batching/semaphore bookkeeping is likewise a source/native timing question, not an additional dedicated hunt.
- MergeWithSlice follows the actual same-predicate versus split-and-union branches and the incoming-first tie at equal minima. Duplicate-wrapper retention follows the implementation map-size/overwrite rule. Empty iterator split endpoints belong to the left half only. Trace validation checks the retained wrapper identity.
- Downstream responsibility is set-valued, so duplicate Matching/DLQ acceptance is allowed but duplicate counts and business/operator replay progress are not quantified. Terminal Internal/DataLoss drop is explicit. An obsolete observation requires independent evidence of completed/removed/stamp-invalid work or a durable replacement; it cannot be derived from a nil executor return.
- Same-owner reacquisition retains its live queue and cursor; new-owner acquisition reconstructs from the exact persisted snapshot. MaxEpoch2 is a horizon, not an assumption that a lost owner always recovers within it. Temporal antecedents state eventual active ownership explicitly; a horizon-ending lost owner does not prove dispatch progress.
- TV-1 full-engine workflow impact, TV-3 actual workflow transaction readback and History Context reacquisition, TV-4 real UpdateShard outcome readback, complete implementation traces and negative controls remain harness/validation/confirmation work. Existing native CR-1 evidence is neither MC-first discovery nor a new end-user-loss claim.

## Validation update (2026-09-11)

Six complete implementation traces (534 records, 46/65 named actions) and eight corruption controls pass after repairing multi-slice Clear and detached-slice capture. Real executor cursor-stall/healthy/reload evidence now covers TV-1 through durable Matching acceptance, with controlled scheduling and a lifecycle shell; worker completion is still separate. CR-2 native controls confirm accounting inflation but preserve empty-range removal. CR-3 native semaphore controls show finite contention succeeds and lifecycle cancellation belongs to shutdown. Exact evidence and final MC status are in `validation-report.md`; a broad incomplete baseline cannot establish convergence or authorize post-convergence hunting. No trace coverage is claimed for prefetched/partial read errors, publication uncertainty across full acquisition, concurrent shard snapshots, late callbacks, terminal/obsolete/worker endpoints, or DLQ within the complete trace suite.
