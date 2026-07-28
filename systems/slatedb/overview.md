# SlateDB

## Scope

Specula analyzed SlateDB's distributed-compaction coordination protocol, including external task submission, coordinator admission, worker claims and capacity, destination reservation, manifest and `.compactions` persistence, ownership transfer, and stale-state merge recovery.

## Bugs

The independent review of the [2026-07-21 distributed-compaction run](modules/distributed-compaction/runs/slatedb-dist-compaction-20260721-213543/review/independent-review.md) records **2 new bugs and 1 known-fixed bug**:

- **New, High:** externally submitted jobs can bypass the coordinator-wide concurrency limit, let two workers run jobs under a global limit of one, and make the next scheduling tick panic on unsigned underflow.
- **New, Minor, masked/weak:** an external cross-segment job can bypass the active destination-reservation check and consume execution capacity, although commit-time validation rejects the loser before duplicate output is published.
- **Known-fixed, Medium:** retrying a conflicted `.compactions` write could reject stale remote `Compacted` or terminal entries; upstream fixed the merge path in PR #1840 before the archived target revision.

Only the first new bug is an unmasked current correctness failure. The second is recorded as a real admission and wasted-work bug with an effective downstream safety mask, not as durable data corruption.
