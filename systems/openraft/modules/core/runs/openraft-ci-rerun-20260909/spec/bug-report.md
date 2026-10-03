# Bug Report — openraft

## Summary

**Incremental result: no implementation bug was confirmed for the 2026-09-09 source update.** The update-focused model and trace harness converged on the affected IO/initialization paths; the broad full-state BFS remained budget-limited with no violation observed.

- Source revision: `15f927e1358d41ffc1297516f781029dbf8ca86a`
- Implementation traces: 4/4 passed, with 8 events across 3 instrumented action types
- Trace coverage: 3/47 mapped action types; 44 mapped action types remain unobserved by implementation traces
- Bugs established by model checking: 0
- Incremental configs executed: `Update_focused.cfg`, `Update_full.cfg`, and affected prior `MC_hunt_scenario2_io.cfg`
- Final full-search last report: 84,024,319 generated; 17,476,123 distinct; depth 17; 6,487,067 queued; no violation before timeout
- Broad simulation: 160,000 traces / 14,381,960 states; no violation

## Workflow Decision

The source update changed Scenario 2's IO completion boundary: durable append completion now updates a watch slot, while `io_completion_forwarder()` later sends `Notification::LocalIO`. The model was updated to represent that bridge. Initialization was also updated to model append, IO-gated response, then election.

TLC counterexamples during validation were classified as model issues, not implementation bugs: one zero-index prefix access, one unparenthesized TLA disjunction assignment, and one overly strict cursor invariant that required `localCommitted <= submittedIO.log` even though OpenRaft intentionally allows local commit accepted to lead submitted log IO and gates apply at `min(log_progress.submitted, apply_progress.accepted)`.

## Scenario Coverage

The table records inherited hunting views. Only the update-affected IO pipeline hunt was selected for this incremental source delta.

| Scenario | Config | States explored | Result |
|---|---|---:|---|
| Restored leadership and recovery reads | `MC_hunt_scenario1_recovery.cfg` | 0 | Not selected: source delta did not touch this mechanism |
| Persistence-before-ack I/O pipeline | `MC_hunt_scenario2_io.cfg` | 3,322 generated / 1,081 distinct | Passed exhaustively |
| Membership transactions and session fencing | `MC_hunt_scenario3_membership.cfg` | 0 | Not selected: source delta did not touch this mechanism |
| Snapshot, membership, and purge lifecycle | `MC_hunt_scenario4_snapshot.cfg` | 0 | Not selected: source delta did not touch this mechanism |
| Heartbeat, replication, and read paths | `MC_hunt_scenario5_paths.cfg` | 0 | Not selected: source delta did not touch this mechanism |

## Coverage and Assurance Limits

- The real trace suite exercises only `HandleElectionTimeout`, `EngineHandleVoteRequest`, and `SnapshotHandlerTriggerSnapshot`; `initialize_then_election` adds an assertion-only order check and emits the subsequent election event. It does not currently validate the modeled persistence, replication, commit/apply, membership, recovery, full snapshot/purge, heartbeat, or read transitions against implementation traces.
- The broad full-state BFS for `Update_full.cfg` timed out with a nonempty queue. The result is an update-focused no-finding result, not a proof of all OpenRaft safety invariants.
- The supplied configurations select OpenRaft's advanced ordered `LeaderId` mode. `StandardElectionSafety` is conditional and therefore does not independently test textbook one-leader-per-term behavior in these runs.
- Liveness properties are defined but intentionally not enabled; no liveness conclusion is made.
- The trace and MC specifications were updated by this incremental validation round. Harness-generated source edits remain test-only behind `cfg(all(test, feature = "specula-trace"))`.
