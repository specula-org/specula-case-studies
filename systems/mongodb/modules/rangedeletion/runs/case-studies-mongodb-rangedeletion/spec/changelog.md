# Changelog: mongodb-rangedeletion Spec Validation

## Round 1 - Trace Validation
- All traces pass (basic_migration: 11 states, concurrent_migrations: 18 states)
- No fixes needed

## Round 1 - Model Checking
- MC.cfg: 376M states, 64M distinct, depth 38, 2min 30s — all 9 invariants pass
- No fixes needed

## Result
Converged in 1 round (no spec modifications required).

## Bug Hunting
- [pass] MC_hunt_lifecycle.cfg: Family 1 — No violations (NoTaskDeadlock, ServiceStateConsistency pass)
- [bug] MC_hunt_identity.cfg: Family 4 — TaskDocConsistency violated (9-state trace). Asymmetric migrationId filtering in deleteRangeDeletionTaskLocally deletes wrong migration's task doc.
- [bug] MC_hunt_ordering.cfg: Family 2 — ResumeInProgressFirst violated (20-state trace). Recovery doesn't prioritize previously-executing tasks in overlap ordering.
- [case-a] MC_hunt_queries.cfg: Family 3 — QueryNotAffected violated (11-state trace). Invariant too strong: new queries during deletion safe via MVCC/metadata versioning.

Bug hunting: 2 bugs found, 1 invariant adjustment.
