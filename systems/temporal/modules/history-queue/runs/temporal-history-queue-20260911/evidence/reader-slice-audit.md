# Reader, slice, scope and action audit

Pinned source: temporalio/temporal@0c010ce5fe8c0180aa7573c72fe8fc87c6df7025. Category A; Go mutex interleavings implement distributed queue recovery boundaries. This audit is source review and native controlled execution, not model checking.

## Complete reading and concurrency map

All 17 production files in reader-core-files.txt were read completely, including reader.go, reader_group.go, slice.go, scope.go, range.go, tracker.go, iterator.go, convert.go, grouper.go, monitor.go, mitigator.go, reader_quotas.go and all five action implementations. Reader tests were read completely; slice selection, shrink, merge and predicate tests were read for relevant paths. Adjacent complete paging_iterator.go and task definitions plus queue_base.go/queue_immediate.go were cross-read with the checkpoint reviewer. The architecture documentation is a transactional-outbox comparison, not a formal reference algorithm.

Reader list, iterator state, tracker maps and scope edits are guarded by ReaderImpl.Mutex (reader.go:180-369,438-487). Executable.Ack/Cancel uses its own mutex and can interleave between reader turns. The queue event loop serializes processNewRange, checkpoint and handleAlert (queue_immediate.go:136-160); moving a scope between readers cannot be interleaved with a checkpoint publication by another queue event. Reader execution may run between move steps, but the old durable queue state remains the recovery source until the move is captured in a checkpoint. The model must retain both this queue-event program counter and independently scheduled reader/executor actions.

## CR-1: checkpoint removal detaches the next-read cursor

Status: SOURCE-REVIEW DISCOVERY; reproduced with native reader and queue checkpoint code. Native file-backed SQLite evidence independently confirms durable retention and reconstruction. No TLA+/MC result and no full-engine adversarial workflow outcome is claimed.

Root cause: reader.go:350-369 removes an empty list element but leaves nextReadSlice pointing to that element. In contrast, SplitSlices, MergeSlices, AppendSlices, ClearSlices and CompactSlices call resetNextReadSliceLocked (reader.go:226,269,302,317,346). Next reader turn uses the removed element's Value then its Next (reader.go:454-480); Go container/list removal disconnects the element, so Next is nil even when the reader still owns later slices.

Reachable trigger at the queue/reader boundary:

1. A reader owns at least two ordered, nonadjacent scopes, with later eligible Transfer rows. Nondefault reader1 is supported by the normal move-group action and durable reconstruction (action_move_group.go:49-102; queue_base.go:171-184).
2. The first slice's last returned batch exactly fills BatchSize and ends at ExclusiveMax-1. Iterator.Next advances its remaining minimum to the task key's successor (iterator.go:47-60). SelectTasks exits on batch fullness before removing its exhausted iterator; MoreTasks only checks iterator count (slice.go:366-418).
3. All tracked tasks at that first slice are ACKed before the next reader turn. ShrinkScope chooses min(min pending key, first remaining iterator key); both now permit the scope to become empty (slice.go:307-332; tracker.go:85-107).
4. Queue checkpoint calls ShrinkSlices and removes the list element. Its local cursor remains attached to the removed element. Another reader turn drains its iterator, then assigns nil to nextReadSlice.
5. Later scope remains unread. Notify cannot fix the pointer (reader.go:372-382); loads with nil return immediately (449-451). Native default polling, repeated checkpointing and notification leave reader1 stalled when no movement or compaction action is applicable.

Compensation and impact:

- Work is NOT physically deleted: checkpoint deletion minimum is taken from every retained reader scope (queue_base.go:316-328); the SQLite test shows the later Activity row survives at the deletion boundary.
- Work is NOT omitted from the durable checkpoint: reader1's remaining scope persists and survives independent durable readback and manager reconstruction. newQueueBase and NewReader rebuild a valid cursor (queue_base.go:171-184; reader.go:107-131), and the later task is submitted. Following its ACK, cleanup removes the final row.
- Default reader is usually masked by processNewRange's Append/Merge reset, including an empty newly readable scope. Only default reader gets periodic queue polling (queue_base.go:262-292). Movement, compaction or ClearSlices can also repair a cursor incidentally; these are conditional on thresholds or new incoming slices, not guaranteed eventual actions.
- Immediate Transfer cannot get a reader-stuck monitor alert: monitor.go:164-169 restricts that path to scheduled queues and reader0. The persisted nonempty reader is not removed by checkpoint's empty-reader cleanup (queue_base.go:321-324).
- This is indefinite live-reader inaccessibility under a quiescent eligible backlog, repairable by reader/shard reload or a real cursor-resetting action. It is not demonstrated data loss, workflow completion failure, or production incidence. Ordinary executor eligibility must be supplied by a later full-engine fault reproduction.

Evidence:

- reader_checkpoint_cursor_analysis_test.go, TestAnalysisReaderCheckpointCursor: minimal batch1, healthy read-before-shrink submits [1,3]; fault submits [1], leaves a nonempty unread scope with nil cursor, Notify ineffective; scope reconstruction submits3. Exact command: `go test -tags test_dep ./service/history/queues -run '^TestAnalysisReaderCheckpointCursor$' -count=1 -v -timeout=2m`; raw reader-cursor-test.log. Scheduler Ack and pagination are controlled here.
- queue_base_recovery_sqlite_test.go, TestQueueBaseSuite/TestCheckpointSQLiteReaderCursor: actual queue checkpoint, SQLite production ExecutionManager/ShardManager and serialization, batch100, two readers, independent SQLite readback and manager reconstruction. Final native preparation loads501 tasks in two default scopes, real checkpoint moves the namespace to reader1, then ACKs400 and checkpoints to produce [401,501) and [502,503). After manager reconstruction, healthy submits101; injected schedule submits100, leaves row502 and durable reader1 min502. Three checkpoint/poll/Notify cycles do not repair; reconstruction submits502 and subsequent checkpoint deletes it. Raw checkpoint-sqlite-final-tests.log; standalone cursor-stalled.sqlite and external Python readback retain the stalled row. ACK is controlled and workflow mutable state is not populated; shard context resources delegate to real stores. SQLite connPool retains physical connections: factory/manager reconstruction is not process restart. The final independent SQL connection and post-process snapshot readback provide independent persistence evidence.
- Existing reader tests test shrink output scopes and loading across slices separately, but do not compose the full-batch ACK/removal/cursor interleaving (reader_test.go:280-310,396-508). Existing entire queues package passes (queues-all-tests.log).
- Upstream refreshed 2026-09-11: five issue+PR searches for ShrinkSlices, nextReadSlice, reader stall, slice checkpoint, queue cursor found zero results; full history and relevant discussions read. This supports 'not found in inspected upstream evidence', not a guarantee of novelty. #11353 addresses a different already-fixed unsynchronized tail read; #11253 addresses statistics-map escape. Neither repairs ShrinkSlices.

## CR-2: duplicate-key pending statistics merit follow-up

Source-level observation, not confirmed user-visible defect: tracker.go:58-74 and79-83 overwrite pendingExecutables by task key while incrementing pendingPerKey unconditionally. Cross-reader scope predicates can legitimately widen to universal (slice.go:476-488), and restart re-reads all scope ranges, so duplicate-key executables can exist across readers; merging such trackers can count more group entries than retained executable keys. Shrink decrements once for a retained ACKed executable; residual group counts may keep an unnecessarily broad predicate and influence group mitigation choices.

Compensation: monitor pending count uses len(pendingExecutables), not this group count (slice.go:300-303,373-375,468), and an empty range is removed regardless of residual predicate groups. Duplicate downstream delivery is permitted. No demonstrated unfinished-obligation loss or sustained stall is attributed to these counters. Retain as test-verifiable accounting/mitigation observation; test with actual overlapping reload scopes and merge, then distinguish temporary overcount from a progress consequence. Do not turn 'duplicate delivery exists' into a failed safety invariant.

## Explicitly excluded suspicions and design boundaries

| Observation | Re-read compensation / reason | Disposition |
|---|---|---|
| Task moves out of source reader before destination merge | Same queue event loop serializes mutation with checkpoint; destination creation is infallible memory operation; crash retains older durable scopes | No demonstrated durable gap; model live interleaving and actual durable boundary |
| Out-of-order ACK lets shrink pass earlier pending task | tracker.shrink retains minimum non-ACKed key; slice also retains minimum unread iterator key | Refuted local skip hypothesis |
| Predicate shrinks before unread tasks are known | shrinkPredicate returns while any iterator remains | Refuted |
| Predicate size fallback introduces tasks not in original scope | Widening permits duplicate work; does not exclude originally covered work | Intentional; do not impose exact-once or disjoint cross-reader coverage |
| Clear cancels the only executable | Clear shrinks safely then recreates persistence iterator before clearing tracked objects; Cancel is not counted as ACK | Recoverable reload obligation retained |
| IDs above configured reader count cannot read | reader_quotas.go:24-38 maps unknown callers to lowest configured priority | Refuted abandonment hypothesis under positive rate/capacity |
| reader-stuck action moves Immediate tasks without max bound | Monitor cannot generate this alert for immediate queues | Out of primary model |
| Reader registration failure leaves unowned slices | Persistence reader registration was removed; current GetOrCreateReader is memory-only | Obsolete historical design; do not model current registration I/O |
| Boundary equality in iterator disjoint assertion | Adjacent iterator ranges are mergeable and must have already been merged; #2996 discussion confirms intent | Not an off-by-one bug |
| monitor stats retained after Stop or task Cancel | Ownership recovery uses durable scopes, not monitor counters; callbacks after stop cannot establish new ownership | No new protocol conclusion; local resource behavior outside primary proof |

## Source-backed model obligations

Range containment is inclusive minimum / exclusive maximum (range.go:30-61). Namespace predicates are conjunctions with range membership (scope.go:27-60); split is complementary before optional widening. Merge may split into up to three ranges and uses predicate OR only where ranges coincide (slice.go:164-219). Compaction can cover gaps, which may produce duplicate replay on reload, while live iterators are the union of previously unread ranges (slice.go:264-305). Persistence conversion retains reader IDs, all ranges/predicate trees and exclusive reader high watermark (convert.go:14-101,123-173).

The minimal useful abstraction contains slice identities, ordered per-reader lists, nextReadSlice, iterator remaining intervals and tracked executable identities/status, besides logical scope sets. Replacing NextRead with 'choose any eligible task in any scope' assumes away CR-1. A fairness assumption can schedule only actual enabled code actions; it must not invent a cursor reset or spontaneous healthy-shard reload.
