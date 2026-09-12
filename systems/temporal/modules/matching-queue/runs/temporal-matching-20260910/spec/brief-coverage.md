> Current results and applicability supersede the generation-only status below: [validation-report.md](validation-report.md). All priority properties have completed applicable scoped checks; the original full and mixed-fault searches remain incomplete. The separate fair-path source candidate has a real SQLite V2 diagnostic and control, with formal V2 convergence and independent confirmation pending.

> Phase 3 status: 32 complete implementation traces passed and 5 controls rejected; baseline MC is INCOMPLETE. Run-bound evidence: `output/trace-validation-summary.json`.

# Brief coverage self-audit

Read against modeling-brief.md §2, §5 and §6.1 and the **actual uncommented INVARIANTS entries** in the generated hunt cfgs. Source is pinned at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; base is Category A, SQL V1/SQLite, priority 3, `useNewMatcher=true`, `enableFairness=false`. Preparation of a hunting cfg is not an executed hunt or confirmation.

## §2 scenarios

| Scenario | Targeting configuration | Mechanisms represented |
|---|---|---|
| S1 acceptance, uncertainty, fresh ownership | `MC_hunt_S1_acceptance_ownership.cfg` | FIFO enqueue/dequeue, ID allocation, atomic commit versus observed error, maxRead on all outcomes, successful-only notification, append-channel/caller response loss, same-work retries, takeover snapshot/CAS, range renewal, supported Stop and crash. |
| S2 reads and bypass | `MC_hunt_S2_read_bypass.cfg` | Captured lower/max/upper bounds, SQL snapshot/result/processing, expired and duplicate rows, stale empty-gap guard, locked registration versus matcher insertion, out-of-order completion. The fixed historical guards remain enabled. |
| S3 prefix, metadata, old-owner GC | `MC_hunt_S3_metadata_gc.cfg` | Exact outstanding/done prefix; drained check, reader-to-DB cache lock boundary, independent metadata write/response, lagging/regressing durable ack, captured unfenced GC, SQL batch limits, late old-owner I/O. |
| S4 History and replacements | `MC_hunt_S4_replacement.cfg`; `MC_live_S4.cfg` for conditional progress | History effect/reply, RequestId idempotence versus new outer start ID, transient retry, nontransient FIFO re-spool, uncertain replacement retry, failure/unload without original ack, Worker receipt after completion. |
| S5 fairness eviction/callback | **GATED, intentionally not enabled or claimed covered** | The brief §2 S5 and §3.1 require complete real-store priority traces and a bounded calibrated baseline before enabling V2 fairness. Complete priority traces and negative controls now pass; Phase 3 `MC.cfg` ended INCOMPLETE, so no convergence or fairness execution is claimed. No priority cfg is mislabeled as fairness coverage. See `gated-extensions.md` for the exact follow-up. |

## §5 safety properties

| Property | Definition and MC wiring | Enabled hunt cfgs (read from files) |
|---|---|---|
| `TypeOK` | `base.tla:1220`; inherited through `MC EXTENDS base` | `MC_hunt_S1_acceptance_ownership.cfg`, `MC_hunt_S2_read_bypass.cfg`, `MC_hunt_S3_metadata_gc.cfg`, `MC_hunt_S4_replacement.cfg` |
| `RecordIdentity` | `base.tla:1258`; inherited through `MC EXTENDS base` | `MC_hunt_S1_acceptance_ownership.cfg`, `MC_hunt_S2_read_bypass.cfg`, `MC_hunt_S3_metadata_gc.cfg`, `MC_hunt_S4_replacement.cfg` |
| `AcceptedWorkCovered` | `base.tla:1272`; inherited through `MC EXTENDS base` | `MC_hunt_S1_acceptance_ownership.cfg`, `MC_hunt_S2_read_bypass.cfg`, `MC_hunt_S4_replacement.cfg` |
| `AckPrefixSound` | `base.tla:1273`; inherited through `MC EXTENDS base` | `MC_hunt_S2_read_bypass.cfg`, `MC_hunt_S3_metadata_gc.cfg` |
| `DeletionSound` | `base.tla:1276`; inherited through `MC EXTENDS base` | `MC_hunt_S3_metadata_gc.cfg` |
| `RangeConditionalWrite` | `base.tla:1277`; inherited through `MC EXTENDS base` | `MC_hunt_S1_acceptance_ownership.cfg`, `MC_hunt_S2_read_bypass.cfg`, `MC_hunt_S3_metadata_gc.cfg`, `MC_hunt_S4_replacement.cfg` |
| `ReplacementBeforeRelease` | `base.tla:1278`; inherited through `MC EXTENDS base` | `MC_hunt_S4_replacement.cfg` |
| `PerOwnerCursorMonotonic` | `base.tla:1282`; inherited through `MC EXTENDS base` | `MC_hunt_S2_read_bypass.cfg`, `MC_hunt_S3_metadata_gc.cfg` |
| `FairAckWithinTrackedPrefix` | **Deferred with S5**; not defined as `TRUE`, not aliased to a priority property | None; explicit coverage exception imposed by the brief's calibration gate. |

`MC.cfg` enables core safety plus `MCTypeOK`, `ReaderAccounting`, and `CursorOrder`; scenario invariants are present but commented there. The four hunt cfgs enable the actual scenario properties above and omit the standalone structural checks. `TypeOK` remains core safety because §5 explicitly requests it.

`EventuallyDischarged` is defined as accepted logical work eventually obtaining a History start or legitimate disposal. `MC_live_S4.cfg` enables `ConditionalProgress`, under a stable ready owner and strong fairness of each reactive instance (eventual mutex acquisition, store completion, eligible polls and callback processing). Fault/input counters make interference finite. This cfg deliberately omits state pruning and symmetry; a truncated graph is not liveness evidence. It is **not executed or proved** by the generation smoke check.

## §6.1 questions and fault reachability

| ID | Trigger and targeting cfg | Expected property / status |
|---|---|---|
| MC-1 | S1 cfg permits commit-with-error, one takeover, one stop/crash, lost response, multiple same-work Adds; S2 cfg adds outstanding captured read/bypass schedules. | `AcceptedWorkCovered`. Initial committed-error admissions are separately in `audit.uncertain`; already accepted work keeps its obligation through uncertain replacement. Complete controlled traces replay successfully; targeted hunting awaits Phase 3 convergence. |
| MC-2 | S3 cfg has two owner lifetimes, delayed metadata and GC, takeover snapshot/CAS and uncertainty; read and delete lack a fabricated range guard. | `DeletionSound`, `AckPrefixSound`. No `GC <= durableAck` or globally monotone durable-ack claim. |
| MC-3 | S4 permits two History errors, replacement store failure/commit-error, response loss and reacquisition. `MC_live_S4.cfg` states recovery assumptions explicitly. | `ReplacementBeforeRelease`, `AcceptedWorkCovered`, conditional `EventuallyDischarged`. Complete real-store trace validation passed; invariant hunting and conditional progress remain pending. |
| MC-4 | **GATED backend alternative**, not reachable in SQL V1 cfgs. SQL empty range reads are complete for the captured interval. | `AckPrefixSound`, `AcceptedWorkCovered`; require measured empty nonterminal pages for the exact prospective backend/version/query first. |
| MC-5 | **GATED S5**, no runnable V2 hunt asserted here. | `FairAckWithinTrackedPrefix`, `AcceptedWorkCovered`; priority observations cannot discharge this candidate. |

## User priorities and boundaries

Q1 is represented by separate queue/server/caller acceptance, sync matching and durable spooling, logical identities and independent History/Worker outcomes. Q2 has all read/bypass/filter/ack windows, including gaps and duplicates. Q3 checks logical-work deletion independently of cached/durable ack. Q4 preserves per-owner DB/writer serialization, atomic SQL range conditions, old-owner reads/GC and supported fresh-manager recovery. Q5 retains the original through failed or uncertain replacement and states progress assumptions instead of asserting unconditional eventual Worker delivery.

CR-2 remains an explicit interface limitation: Internal/DataLoss and version-routing processing drops are not modeled as evidence of ineligibility. Configured unversioned normal queues exclude routing failures. History start acceptance is assumed durable or covered by History's recovery obligation; speculative History internals and its outbox are outside this model. Duplicate delivery and expired/obsolete logical stamps are allowed. Approximate backlog statistics are not conservation counters.

The mandatory audit is complete as a written audit, **with two explicit gated coverage gaps (MC-4 and S5/MC-5)**. This is not a claim that every brief safety question has an enabled hunt. Enabling fictitious backend behavior or expanding fairness before the user's prerequisites would violate the modeling boundary.
