# Bug Report — temporal-matching

## Summary

- Priority model-checking findings: **0**. Deliberate mutant controls are excluded.
- Code-origin implementation candidates reproduced in this continuation: **1**, existing S5/MC-5, dispatched as CR-4; independent confirmation/classification pending.
- Original full baseline: **INCOMPLETE**. Nine detailed scopes and one conditional composition check completed; four supplied hunt configurations received bounded simulation.
- Current implementation traces: 24/24; controls: 8/8 rejected.

## Not Reproduced

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

| Retained broader check | Last sampled distinct | Depth | Status |
|---|---:|---:|---|
| `MC_original_projection.cfg` | 3,756,413 | 12 | [INCOMPLETE](output/continuation-20260911/original-bounds-projection/MC.out) |
| `MC_contract_acceptance.cfg` | 11,532,719 | 32 | [INCOMPLETE](output/continuation-20260911/contract-acceptance/MC.out) |
| `MC_contract_read.cfg` | 12,804,328 | 41 | [INCOMPLETE](output/continuation-20260911/contract-read/MC.out) |
| `MC_contract_replacement.cfg` | 23,144,586 | 52 | [INCOMPLETE](output/continuation-20260911/contract-replacement/MC.out) |


| Supplied hunt config, depth 100 / 120s | Last sampled traces | Last states checked | Result |
|---|---:|---:|---|
| `MC_hunt_S1_acceptance_ownership.cfg` | 35,989 | 12,391,475 | [NO_VIOLATION_OBSERVED](output/continuation-20260911/simulate-MC_hunt_S1_acceptance_ownership/MC.out) |
| `MC_hunt_S2_read_bypass.cfg` | 41,879 | 17,929,709 | [NO_VIOLATION_OBSERVED](output/continuation-20260911/simulate-MC_hunt_S2_read_bypass/MC.out) |
| `MC_hunt_S3_metadata_gc.cfg` | 35,531 | 12,700,729 | [NO_VIOLATION_OBSERVED](output/continuation-20260911/simulate-MC_hunt_S3_metadata_gc/MC.out) |
| `MC_hunt_S4_replacement.cfg` | 37,087 | 11,566,659 | [NO_VIOLATION_OBSERVED](output/continuation-20260911/simulate-MC_hunt_S4_replacement/MC.out) |

## Code-origin diagnostic CR-4

Late fair completion after eviction can insert an obsolete ack marker, undercount loaded tasks and move durable ack past an unstarted task. This is the existing S5/MC-5 mechanism, reproduced through real fair reader/writer and SQLite V2 with controlled matcher/History interfaces. It is not an MC finding. See [fairness-diagnostic.md](fairness-diagnostic.md) for execution, source anchors, countermeasure candidate, control and remaining confirmation limits.

All model/control fixes and scope boundaries are in [changelog.md](changelog.md), [search-strategy.md](search-strategy.md) and [validation-report.md](validation-report.md).
