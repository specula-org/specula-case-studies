# Validation report — temporal-matching

**Scoped verification completed; the original full search remains INCOMPLETE and no global convergence is claimed.** This continuation performed substantive verification under the user's explicit 2026-09-11 instruction to adapt scopes and budgets. It did not repeat the old 30-minute run to reproduce the same handoff.

Source: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Priority execution uses one unversioned root Workflow queue, priority 3, new matcher enabled and fairness disabled, real file-backed SQLite SQL TaskStore V1. The separate fairness diagnostic uses real SQLite V2 with its configuration and interface limits recorded separately. Resource configuration and agent routing were unchanged.

## Completed implementation calibration

The active corpus has **24/24 complete traces**, **8/8 rejected controls**, and **84/88 observed action types**. It includes the prior 16 scenarios, allocation-renewal failure/retry, definite-rejection replacement retry, read wakeup while backoff is pending, acquisition retry, and root-validator valid/obsolete/canceled outcomes. The 10-minute validity age guard was waited in real time; the stable-owner test sets and records a one-hour queue idle timeout. Old 32 traces, original models and failed experimental traces remain archived; they are not silently relabeled as current-format evidence.

Review R1–R7 were addressed: bootstrap/provenance rejection now asserts instead of yielding zero states; the runner requires nonempty complete exploration; sync publication and Add receipt are separate; allocation errors can retry or publish terminal failure; definite noncommit can still be retryable; backoff timer state is independent; normal sync and acquisition retries are not incorrectly fault-budgeted; root validation has a separate model/trace extension. The idle-unload/canceled-History-fixture mismatch was diagnosed and excluded before recollection. See [changelog](changelog.md), [instrumentation](../harness/INSTRUMENTATION.md), and [active trace results](output/continuation-20260911/final-replay/validation-results.json).

## Completed bounded checks

| Completed scope | Distinct states | Depth | This invocation | Result |
|---|---:|---:|---:|---|
| Detailed core: 2 work/records, 2 pollers, 1 owner; normal sync and durable paths, no injected faults | 15,662,073 | 74 | 183.2s | [PASS](output/continuation-20260911/core-current/MC.out) |
| Detailed ownership: 1 work/record/poller, 2 owners; takeover and conditional rejection | 27,162,600 | 84 | 400.5s | [PASS](output/continuation-20260911/owner-current/MC.out) |
| Detailed read frontier: 2 work, 2 pollers; read failure/backoff + bypass and out-of-order completion | 18,611,033 | 79 | 180.1s | [PASS](output/continuation-20260911/read-backoff-resume/MC.out) |
| Detailed submitted-write frontier: 1 work, 2 calls; committed-error and receipt loss, 1 owner | 6,717,099 | 77 | 140.2s | [PASS](output/continuation-20260911/write-retry/MC.out) |
| Detailed replacement frontier: 1 work/caller/poller/owner; store failure, uncertainty, retry/renewal/final failure | 269,682 | 99 | 17.1s | [PASS](output/continuation-20260911/replacement-write/MC.out) |
| Detailed GC frontier: 2 work/records, 2 owners/pollers; old-owner GC and metadata, receipt/name reductions | 34,449,204 | 107 | 180.2s | [PASS](output/continuation-20260911/gc-orbit-finish/MC.out) |
| Conditional replacement recovery; stable owner and available store, no further faults | 8,055 | 61 | 5.7s | [PASS](output/continuation-20260911/recovery-replacement-groups/MC.out) |
| Conditional recovery after supported stop/reacquisition; no further faults | 12,584 | 60 | 9.9s | [PASS](output/continuation-20260911/recovery-takeover-groups/MC.out) |
| Separate root-validator model: 1 work/record/owner/poller; validity/disposal, stable-owner scope | 45,921 | 44 | 7.9s | [PASS](output/continuation-20260911/validator-core/MC.out) |
| Conditional composition: 4 records, 2 work/owners; assumes sound ack prefix and models closed write boundary | 13,615,348 | 35 | 28.3s | [PASS](output/continuation-20260911/queue-contracts-final/MC.out) |

All completed detailed safety scopes enable the priority safety and structural predicates; enabled names are not counted as independent coverage. `MCTypeOK` subsumes `TypeOK`. ReplacementBeforeRelease has no release witness in normal fault-free core scopes; its operative coverage is the replacement scopes. Stale-owner fencing is exercised in ownership scopes. The two progress checks use the unchanged ConditionalProgress predicate, weaker grouped processing assumptions, and **no VIEW, symmetry or state constraint**. Their source-action prefixes reach the declared frontier. GC's role/name and receipt reductions preserve both records and pollers; [search-strategy.md](search-strategy.md) gives the justification and restrictions.

The conditional composition model separately checks delayed GC/metadata/ownership with four storage records. It **assumes sound ack prefixes** and does not independently prove the reader algorithm or unresolved remote-store outcomes. Deliberately deleting past the bound and disabling write fencing both trigger expected counterexamples ([controls](output/continuation-20260911/verification-results.json)); they are not implementation findings.

Resumed distinct counts above are final cumulative counts for the recovered graph. Generated counts and runtime remain per invocation; no duplicate states or replayed checkpoint work are summed into a coverage total. Earlier incomplete slices leading to a completed resume remain recorded in the run index.

## Original and wider limits

The preserved original `MC.cfg` run ended at 1,800 seconds plus kill grace, exit 137. Its last sample was **307,620,915 distinct states, depth 16, 196,911,151 queued**. That result remains INCOMPLETE. Current-model same-bound projection, retired-frame reduction, canonical live UUIDs, source-action frontiers, grouped fairness, receipt commutation, role-specific alpha renaming and checkpoint continuation were actually attempted; their exact commands/hashes/results are retained.

| Retained broader check | Last sampled distinct | Depth | Status |
|---|---:|---:|---|
| `MC_original_projection.cfg` | 3,756,413 | 12 | [INCOMPLETE](output/continuation-20260911/original-bounds-projection/MC.out) |
| `MC_contract_acceptance.cfg` | 11,532,719 | 32 | [INCOMPLETE](output/continuation-20260911/contract-acceptance/MC.out) |
| `MC_contract_read.cfg` | 12,804,328 | 41 | [INCOMPLETE](output/continuation-20260911/contract-read/MC.out) |
| `MC_contract_replacement.cfg` | 23,144,586 | 52 | [INCOMPLETE](output/continuation-20260911/contract-replacement/MC.out) |


Mixed expiry/write-uncertainty/read and multi-owner replacement-failure combinations are broader than the completed isolated contracts. Their saved frontiers and simulations are evidence of exploration, not exhaustive passes or a theorem combining all scopes. Some exploratory GC slices timed out before subsequent reduced/resumed GC completion; the index preserves those results.

| Supplied hunt config, depth 100 / 120s | Last sampled traces | Last states checked | Result |
|---|---:|---:|---|
| `MC_hunt_S1_acceptance_ownership.cfg` | 35,989 | 12,391,475 | [NO_VIOLATION_OBSERVED](output/continuation-20260911/simulate-MC_hunt_S1_acceptance_ownership/MC.out) |
| `MC_hunt_S2_read_bypass.cfg` | 41,879 | 17,929,709 | [NO_VIOLATION_OBSERVED](output/continuation-20260911/simulate-MC_hunt_S2_read_bypass/MC.out) |
| `MC_hunt_S3_metadata_gc.cfg` | 35,531 | 12,700,729 | [NO_VIOLATION_OBSERVED](output/continuation-20260911/simulate-MC_hunt_S3_metadata_gc/MC.out) |
| `MC_hunt_S4_replacement.cfg` | 37,087 | 11,566,659 | [NO_VIOLATION_OBSERVED](output/continuation-20260911/simulate-MC_hunt_S4_replacement/MC.out) |


Simulation counts are the last periodic samples, not final totals or distinct states. The hunts retain their supplied bounds and predicates. No priority-model invariant violation was observed. Process-crash/transport observation and full History durability/lifecycle remain unvalidated; such actions in broad MC runs are modeled alternatives, not implementation-trace confirmation. No full fairness model convergence, Cassandra paging result, alternative-backend result or unconditional Worker-delivery guarantee is claimed.

## Separate code-origin fairness result

The existing S5/MC-5 candidate now has a controlled real-SQLite-V2 reproduction and a window-closed control. Late C completion after eviction undercounts loaded tasks and persists ack **(3000,3)** past unstarted B **(2000,2)**. The actual task-store query after that persisted ack omits B. Closing the callback/merge window preserves counts and returns B. This is **one code-origin candidate, CR-4**, not a new MC discovery; matcher and History-result interfaces are controlled and independent Phase 4/public-API confirmation remains pending. [Full evidence and scope](fairness-diagnostic.md).

## Pipeline handoff

Review `validation-report.md`, current model/trace changes and the explicit scope assumptions; then continue confirmation/classification. `findings.json` remains the MC-only mirror with zero MC findings. CR-4 is dispatched through modeling-brief.md's code-review candidate set and refers to the already-listed MC-5 mechanism, so count it once. All original cfg files remain byte-identical; all incomplete runs retain logs/snapshots and supported checkpoints. Future broader verification can resume those frontiers rather than restart completed analysis.

## Final artifact audit

[Final audit](output/continuation-20260911/final-audit.json) verifies all nine completed detailed checks against the current base/MC/Contract hashes, the current 24 trace hashes and store/readback sidecars, all original cfg bytes and 32 historical traces. Two additional validator controls reject a missing holder field and a fabricated obsolete result after canceled handoff at the exact changed event. Repository lint finished with zero issues; its equivalent if-chain-to-switch cleanup was checked on the actual sync receipt scenario. The instrumentation patch applies to the clean pinned index and is idempotent on the instrumented checkout.

Fairness standing-backlog short, fully-drain, many-keys and wide-range tests passed; these use the repository fake task manager and are not real-store evidence. The distinct SQLite V2 diagnostic and its controlled-window comparison provide the real-store fairness evidence. No production repair, external issue/report, merge or publication was performed.
