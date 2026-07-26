# MongoDB

## Scope

Specula analyzed and tested MongoDB's change streams, chunk and range migration, range deletion, resharding, movePrimary, initial sync, index builds, distributed transactions and transaction coordination, session and collection-incarnation handling, replicated fast counts, write blocking, collMod coordination, ticket scheduling, and Raft-related replication, reconfiguration, and timestamp paths.

## Bugs

Specula found 16 new bugs:

- Step-up auto-reconfiguration can lower `configTerm` below its previous value, producing an ordering-stale configuration that peers reject and stalling propagation.
- Migration abort can silently swallow `ShardNotFound` while marking the recipient range-deletion task ready, then forget the migration and leave the task permanently pending.
- Donor-side range-deletion cleanup omits the migration ID from its query, so an abort retry can delete another migration's task and leave orphaned data behind.
- Recovery loses whether an overlapping range-deletion task was already processing, allowing a later non-processing task to run first.
- Range-preserver invalidation can stop early on a non-monotonic shard placement version, allowing secondary queries to read orphaned documents.
- Step-up recovery makes range-deletion tasks ready without invalidating range preservers, allowing stale queries to read orphaned documents.
- The committed migration-cleanup path does not handle `ShardNotFound`, so removal of the recipient after the commit decision can cause an infinite recovery loop.
- Donor-side readiness updates omit the migration ID, so recovery can mark another migration's task ready and delete data prematurely.
- Recovery can replay a non-idempotent orphan-count increment after rollback, double-counting orphans used in balancer size calculations.
- A routing-table refresh failure after a successful migration commit does not schedule recovery, leaving the coordinator and donor cleanup stalled until a later step-up or restart.
- A two-phase index-build abort followed by failover can leave a stale `config.system.indexBuilds` coordination document on the new primary.
- Rollback of an uncommitted replica-set write-block document can leave in-memory blocking enabled, causing the node to reject user writes if it later becomes primary.
- Sharded legacy time-series `collMod` can ignore a failing non-owning DB-primary participant and return success while leaving persistent metadata inconsistency.
- Unclean fast-count recovery can retain pre-drop totals across a same-UUID collection recreation and publish inflated record and data-size counts.
- In a latent API combination not reached by any audited supported public configuration, `OrderedTicketSemaphore` can over-wake waiters during immediate resize and issue two acquisitions from one permit.
- Sharded legacy time-series `collMod` can release its critical section before updating local metadata, creating a transient window in which time-based reads miss an existing document.
