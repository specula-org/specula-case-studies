# Independent bug review

## Final adjudication

The second review records **2 new bugs and 1 known-fixed bug**. One new item is a strong, unmasked failure; the other is a masked/weak admission defect whose current demonstrated impact is wasted execution and a failed job.

| Candidate | Final classification | Severity | Recorded? |
|---|---|---:|---:|
| MC-2 / CR-5 | External submissions overrun the global capacity bound and panic the coordinator | High | New |
| CR-1 | Cross-segment destination-reservation admission gap, masked at commit | Minor | New |
| CR-2 | Crash-window recovery remains manifest- and GC-safe | — | No |
| CR-3 | The real executor suppresses completion after reclaim stops the task | — | No |
| CR-4 | Stale terminal/`Compacted` merge failure fixed by upstream PR #1840 | Medium | Known, fixed |
| MC-1 | Same-segment duplicate behavior exists only in the model; product validation rejects it | — | No |

The archived [confirmation report](../spec/confirmed-bugs.md) remains provenance evidence, but this review is the final novelty, deduplication, and severity decision.

## New bug: external submissions bypass the global concurrency bound

### Mechanism

`CompactorOptions.max_concurrent_compactions` is documented as the total number of concurrent compactions, while `CompactionWorkerOptions.max_concurrent_compactions` is explicitly per worker. See [`config.rs` lines 1096-1128](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/config.rs#L1096-L1128) and [`config.rs` lines 1188-1203](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/config.rs#L1188-L1203).

Normal scheduler proposals are capped by the coordinator's available capacity. The capacity calculation directly subtracts the observed running count from the configured maximum. See [`compactor.rs` lines 1123-1158](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor.rs#L1123-L1158).

External requests take a different path. `Admin::submit_compaction()` persists a `Submitted` job, and `maybe_validate_submitted_compactions()` promotes every valid tiered submission to `Scheduled` without applying the coordinator-wide capacity budget. See [`admin.rs` lines 187-204](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/admin.rs#L187-L204) and [`compactor.rs` lines 1164-1222](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor.rs#L1164-L1222). Multiple standalone workers can therefore each claim a job under their own local limit and make the coordinator observe more running jobs than its global maximum. The next direct subtraction underflows.

### Archived reproduction and impact

The archived [MC-2 wrapper](../repro/test_bugMC-2_external_submissions_bound.sh) exercised public DB, admin, standalone coordinator, and standalone worker APIs with a test-only timing gate. Its [verdict](../confirmation/MC-2/verdict.json) records two different jobs simultaneously reaching `Running` with `max_concurrent_compactions = 1`, followed by:

```text
attempt to subtract with overflow
background task panicked unexpectedly
```

The independently generated CR-5 reproducer reaches the same admission path. CR-5 and MC-2 are therefore deduplicated into one new bug. The live harm is an exceeded coordination invariant and compactor liveness failure; it is not merely a model-only state.

The archived novelty search found broad manual-compaction coordination Issue #288 and PR #1926, which fixed different `Compacted` accounting. It did not find the external-submission capacity bypass. The finding is recorded as new, subject to upstream deduplication.

## New masked/weak bug: external submissions bypass active destination reservation

### Mechanism

Internal proposals enter `CompactorState::add_compaction()`, which rejects a destination already reserved by any active compaction across all segments. See [`compactor_state.rs` lines 976-1023](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor_state.rs#L976-L1023).

An unknown remote `Submitted` entry is instead accepted by `merge_remote_compactions()` and later promoted by `maybe_validate_submitted_compactions()`. That route does not re-run the global active-destination check. See [`compactor_state.rs` lines 878-944](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor_state.rs#L878-L944). The ordinary validation path checks committed destinations and same-segment active L0 work, but not cross-segment active destination reservations. See [`compactor.rs` lines 910-1044](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor.rs#L910-L1044).

### Archived reproduction and mask

The [CR-1 wrapper](../repro/test_bugCR-1_cross_segment_destination_collision.sh) and [verdict](../confirmation/CR-1/verdict.json) show two disjoint-segment jobs becoming `Scheduled` while both reserve destination sorted run `200`. This proves a reachable product admission defect and avoidable execution.

The current commit path is an effective safety mask. It validates each `Compacted` entry against the updated manifest; after the first job publishes destination `200`, the second fails destination-overwrite validation and is marked `Failed`. See [`compactor.rs` lines 836-908](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor.rs#L836-L908) and [`compactor.rs` lines 1046-1073](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor.rs#L1046-L1073).

The archived run observed only one durable destination and a failed losing job. It did not establish duplicate publication or data corruption. This review therefore records the live admission and wasted-work behavior as a `Minor` new bug and labels it `MASKED/WEAK`. The archive's `Critical` classification is based on the counterfactual consequence if the current commit-time validation did not exist.

## Known-fixed bug: stale terminal state rejected during conflict recovery

CR-4 describes the retry path after a sequenced `.compactions` write conflict. Local state may already have committed or pruned a job while the reloaded persisted view still contains an older `Compacted`, `Completed`, or `Failed` entry. The pre-fix merge treated a remote terminal entry absent from local state as invalid instead of bringing it back for validation or retention cleanup.

Upstream [PR #1840](https://github.com/slatedb/slatedb/pull/1840), “fix: merge_remote_compactions should accept stale terminal/compacted entries,” is the exact mechanism match. It merged on 2026-06-25 as [`8e8b36cebaa7dd791d9d315c08ec3ee3e8219d24`](https://github.com/slatedb/slatedb/commit/8e8b36cebaa7dd791d9d315c08ec3ee3e8219d24). The archived target is 61 commits ahead and contains that fix. Its current merge logic and comments explicitly accept stale `Compacted` and terminal entries for downstream resolution. See [`compactor_state.rs` lines 892-918](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor_state.rs#L892-L918).

CR-4 is recorded as known-fixed, not as a current target defect and not as a new report.

## Rejected and deduplicated candidates

- **CR-2:** the crash between manifest and `.compactions` writes is deliberately recovered. A pre-manifest crash leaves sources to be rescheduled; a post-manifest crash leaves the correct manifest and can safely mark the stale entry failed. The target documents both cases in [`compactor.rs` lines 836-858](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor.rs#L836-L858), and the archived reproduction did not violate manifest or GC safety.
- **CR-3:** the proposed stale completion did not survive the real executor lifecycle. The archived product test showed reclaim stopping and removing the task before its completion could be published.
- **CR-5:** this independently reproduced the same external-submission concurrency bypass as MC-2 and is not counted twice.
- **MC-1:** the model allowed conflicting same-segment external work that the implementation rejects through its active same-segment L0 check. See [`compactor.rs` lines 1018-1038](https://github.com/slatedb/slatedb/blob/cc69461d902560bb5f4407a506f32cd154ede79d/slatedb/src/compactor.rs#L1018-L1038).

## Review provenance and limits

- Review date: 2026-07-28
- Archived target: [`slatedb/slatedb@cc69461d902560bb5f4407a506f32cd154ede79d`](https://github.com/slatedb/slatedb/tree/cc69461d902560bb5f4407a506f32cd154ede79d)
- Source review: exact immutable target plus upstream PR #1840 and its merge commit
- Runtime evidence: archived Level 1 results and confirmation outputs; no new runtime test was executed during curation
- Novelty boundary: repository history and tracker evidence available during the archived run and second review; new items remain subject to upstream deduplication

The generated confirmation worktrees and Rust test source are absent from the ZIP as standalone members. The curated record preserves the original wrappers and full verdict output, so reproduction claims are limited to those archived results.
