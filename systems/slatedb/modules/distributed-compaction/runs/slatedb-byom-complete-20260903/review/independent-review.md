# Independent follow-up review

## Final adjudication

This review adds one new root cause and one known-unfixed root cause to the existing SlateDB case-study ledger.

| Pipeline entry | Final classification | Ledger action |
|---|---|---|
| MC-1 | Duplicate external compactions can panic a worker; exact match to Issue #1838 | Add as Known / Reported |
| MC-2 and MC-3 | Two triggers for the previously recorded coordinator-capacity bypass | Do not duplicate |
| CR-6 | Custom-scheduler L0 ordering corrupts the compaction watermark and blocks flushes | Add as New |
| CR-2 | False positive | Do not record |
| CR-3 and CR-4 | Known-fixed duplicates | Do not record |

The generated `4 reproduced` count is therefore not four new independent bugs.

## Known-unfixed bug: duplicate external compactions can panic a worker

Two public `Admin::submit_compaction` calls can submit the same `Full` plan before the manifest changes. Both records receive different compaction ids but the same sources and destination. The coordinator promotes both to `Scheduled`; the worker keys active work by compaction id, while the executor keys tasks by destination and asserts that the destination is absent.

The Level 0 reproduction observes both duplicate submissions reach `Scheduled`, then the second executor dispatch triggers the destination assertion and the public worker operation returns `Closed(Panic)`. This is an exact match to open upstream [Issue #1838](https://github.com/slatedb/slatedb/issues/1838), which describes duplicate manual requests, the same destination-keyed assertion, and the same worker-fatal consequence. It is Known and Reported, not new and not maintainer-confirmed.

## New bug: custom-scheduler L0 order can retain compacted input and block flushes

`CompactionScheduler::validate` accepts every proposal by default. A supported custom scheduler can therefore return the current L0 sources in oldest-to-newest order. `finish_compaction` removes all source L0s but treats the first source as the newest compacted watermark. Writer/compactor merge then trims only through that stale watermark and restores one physical L0 already represented by the new sorted run.

The Level 0 reproduction uses public `Db`, `CompactorBuilder::with_scheduler_supplier`, and `Db::flush_with_options` APIs. With `l0_max_ssts = 2`, it observes:

1. two L0 inputs submitted in reverse order;
2. one already-compacted L0 retained after writer refresh;
3. one later flush filling the remaining slot; and
4. the next public memtable flush timing out.

The target implementation documents that the newest L0 must be first but does not enforce it at the compactor-level boundary. A refreshed search on 2026-09-04 found no matching upstream issue or pull request. Current upstream main `71a96c5087a4447ae30d95dedfb0dfcb123ef1cb` still has the permissive default validator and derives the watermark from the first source. Novelty therefore remains New, subject to future upstream deduplication; Status remains blank because no report or maintainer confirmation exists.

## Existing capacity bug: do not count MC-2 and MC-3 again

MC-2 mixes one local and one external job; MC-3 uses two external jobs. Both demonstrate the same missing coordinator-wide capacity enforcement already recorded in the 2026-07-21 independent review and live tracker. They require the same repair and are not separate ledger bugs.

## Evidence boundary

- Both selected findings were reproduced against exact source commit `cc69461d902560bb5f4407a506f32cd154ede79d` without a production source patch.
- The archived scripts use public APIs; MC-1 needs no timing injection, and CR-6 needs no state injection.
- The new BYOM run started from previously reviewed verification artifacts. It is a follow-up/revalidation record, not independent blind discovery of the existing capacity bug.
- The generated severity report is retained as run evidence; this review controls case-study root-cause counts and tracker wording.
