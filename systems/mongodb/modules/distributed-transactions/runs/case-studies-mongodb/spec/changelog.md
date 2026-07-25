# MongoDB v3 Spec Changelog (Router & Resource Contention)

## Round 1 - Trace Validation
- [fix] ASSUME: moved `Cardinality(Shard) >= 2` from base.tla to MC.tla — single_shard trace has only 1 shard, ASSUME failed during trace validation
- [fix] TraceRouterStartTxn: added ValidateParticipants and ValidateDisallowSWS constraints — RouterStartTxn non-determinism picked wrong participants/kinds, causing deadlock at next trace event

All 4 traces pass: single_shard (3 events), read_only (3 events), basic_2pc_commit (8 events), sws_commit (4 events).

## Round 1 - Model Checking
BFS with MC.cfg (3 shards w/symmetry, 1 router, 1 txn, MaxTickets=3, CoordTicketExempt=TRUE, all fault bounds=1, MaxRetry=2).

Structural invariants (CommitTypeConsistency, TicketPoolNonNegative, SWSCorrectness, DecisionIrreversible, AllParticipantsReachTerminal):
- 7,568 states, 2,495 distinct, depth 13 — **all pass**, no violations.

Extension invariants (enabled for early bug detection):
- [bug] ClassificationMatchesReality: VIOLATED in 7 states (Case C). Session reaper fires on prepared s2 → coordinator classifies NoSuchTxn as ack → s2 in cAcks but state is SSReaped. Known bug SERVER-105751. (output/MC_classification_violation.out)

No spec modifications needed — violation is a real implementation bug, not a spec issue.

## Convergence
Converged in 1 round. Only Trace.tla was modified (participant constraint for trace validation). base.tla had one ASSUME moved to MC.tla (no behavioral change).

## Bug Hunting
- [bug] NoTicketDeadlock: MC_hunt_family2.cfg, 4-state counterexample — known fixed bug SERVER-60682. Pre-fix (CoordTicketExempt=FALSE): all tickets held by prepared txns, coordinator blocked. (Case C, known/fixed)
- [bug] ClassificationMatchesReality: MC_hunt_family3.cfg, 7-state counterexample — known bug SERVER-105751. Session reaper + DecisionAckError misclassification. (Case C, known)
- [bug] NoSilentDataLoss: MC_hunt_family3.cfg (sans ClassificationMatchesReality), 9-state counterexample — downstream consequence of SERVER-105751. (Case C, known)
- [pass] Family 1 (Router Path): 466 states, all invariants hold
- [pass] Family 4 (SWS Retry): 478 states, all invariants hold

## Result
Converged in 1 round. Bug hunting: 2 known bugs confirmed (SERVER-60682, SERVER-105751), 0 new bugs found.
