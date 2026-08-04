# Apache Ratis

## Scope

Specula analyzed and tested Apache Ratis's Raft implementation, including pre-vote and priority elections, asynchronous log replication and commit, joint-consensus membership changes, leader-lease and ReadIndex reads, snapshots, and crash recovery.

## Reviewed 2026-08-03 runs

Three focused runs were added for Apache Ratis at source commit `7eedc1deed07fc883bfe448b2d33438b7a0e994e` using Codex `gpt-5.5` with `xhigh` effort. The runs are archived under:

- `modules/system/runs/ratis-gpt55-xhigh-system-20260803`
- `modules/server/runs/ratis-gpt55-xhigh-server-20260803`
- `modules/grpc/runs/ratis-gpt55-xhigh-grpc-20260803`

The raw Phase 4 outputs are preserved in each run directory. The reviewed conclusions are in each run's `review/independent-review.md`.

## Reviewed findings

Reviewed, reportable findings from these runs:

| Module | Finding | Reviewed disposition |
| --- | --- | --- |
| `system` | Stale AppendEntries success after a higher-term vote can let an old leader acknowledge an entry absent from the next leader. | `REPRODUCED`, Critical |
| `system` | Metadata persistence failure can leave an accepted higher term non-durable across restart. | `REPRODUCED`, High |
| `system` | Type-only step-down queue deduplication can drop a later higher-term step-down event. | `REPRODUCED`, High |
| `server` | Async flush failure can still advance `flushIndex`/`commitIndex` and return success. | `REPRODUCED`, Critical |

Other model-checking outputs are retained as historical evidence but are not promoted here as confirmed bugs. In particular, the `system` append-compose finding remains component-level without a stronger external-consumer reproduction, and the `grpc` findings are best treated as masked/spec-repair candidates rather than reproduced user-visible bugs.
