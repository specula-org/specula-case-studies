# SlateDB

## Scope

Specula analyzed SlateDB's distributed-compaction coordination protocol, including external task submission, coordinator admission, worker claims and capacity, destination reservation, manifest and `.compactions` persistence, ownership transfer, and stale-state merge recovery.

## Bugs

The independent reviews of the [2026-07-21 distributed-compaction run](modules/distributed-compaction/runs/slatedb-dist-compaction-20260721-213543/review/independent-review.md) and the [2026-09-03 BYOM follow-up](modules/distributed-compaction/runs/slatedb-byom-complete-20260903/review/independent-review.md) record **3 new bugs, 1 known-unfixed bug, and 1 known-fixed bug**:

- **New, High:** externally submitted jobs can bypass the coordinator-wide concurrency limit, let two workers run jobs under a global limit of one, and make the next scheduling tick panic on unsigned underflow.
- **New, High:** a custom scheduler can submit L0 sources in reverse order, leave an already-compacted L0 consuming capacity, and block a later public memtable flush.
- **New, Minor, masked/weak:** an external cross-segment job can bypass the active destination-reservation check and consume execution capacity, although commit-time validation rejects the loser before duplicate output is published.
- **Known-unfixed, High:** duplicate external full-compaction submissions can reach a worker with the same destination and panic it; upstream tracks the mechanism in Issue #1838.
- **Known-fixed, Medium:** retrying a conflicted `.compactions` write could reject stale remote `Compacted` or terminal entries; upstream fixed the merge path in PR #1840 before the archived target revision.

The masked/weak item is recorded as a real admission and wasted-work bug, not as durable data corruption. The BYOM run's two capacity findings are different triggers for the already-recorded global-capacity root cause and are not counted again.
