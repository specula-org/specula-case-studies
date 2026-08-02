# iccpd Brief Coverage Self-Audit

This audit was completed after reading the generated MC_hunt_*.cfg files.
It is brief-driven: only modeling-brief §2, §5, and §6.1 are assessed.
The modeled revision is 9df8ccbf72c31948741b5554d09c38ac6c1ec6e9.

## §2 Scenario coverage

| Brief scenario | Targeting hunt cfg | Mechanism made reachable | Enabled target |
|---|---|---|---|
| Scenario 1 — recovery evidence destroyed before failover | MC_hunt_scenario1.cfg | One warm announcement, disconnect, crash/restart, reconnect, netlink-loss flag, and optional later authoritative event; unrelated write/LAG/scheduler faults are zeroed | MCRecoveryBeforeAdvertise; MCWarmRecoveryTerminates |
| Scenario 2 — sync progress without delivery proof | MC_hunt_scenario2.cfg | Up to two same-session established resyncs, one object mutation, one positive-short write, one failed write, and a live nonprogress stream | MCLegalFSMState, MCSyncEnvelopeOrdering, MCConfigBeforeState, MCExchangeAgreement, MCDirtyStateAccounted; MCSyncEventuallyResolves |
| Scenario 3 — ACK certifies intent, not applied state | MC_hunt_scenario3.cfg | Four LAG transitions for DOWN/UP ABA, one external-apply failure, one peer-interface topology change, and one syncd EOF; unrelated sync/recovery faults are zeroed | MCCurrentIsolationBeforeTraffic, MCNoPeerLinkLoop |
| Scenario 4 — transport activity diverges from scheduler progress | MC_hunt_scenario4.cfg | One partial header, one persistent nonprogress source, one sidecar EOF, one established resync, and fallible writes | MCSyncEventuallyResolves, MCStuckSessionDetected |

No scenario is silently merged away. Scenario 1’s cfg intentionally covers both
the warm-cleanup obligation (MC1) and the restart/snapshot barrier (MC4).
Scenario 4’s cfg also enables the Scenario 2/4 shared sync-resolution property.

## §5 invariant coverage

The “enabled” column below was checked against the uncommented entries in the
actual hunt cfgs.

| Brief invariant | Type | Defined in base | Wired in MC | Enabled in hunt cfg(s) |
|---|---|---|---|---|
| TypeOK | Safety | base.tla:1501 | MCTypeOK, MC.tla:391 | All four scenario cfgs |
| LegalFSMState | Safety | base.tla:1513 | MCLegalFSMState, MC.tla:417 | MC_hunt_scenario2.cfg |
| SyncEnvelopeOrdering | Safety | base.tla:1520 | MCSyncEnvelopeOrdering, MC.tla:418 | MC_hunt_scenario2.cfg |
| ConfigBeforeState | Safety | base.tla:1524 | MCConfigBeforeState, MC.tla:419 | MC_hunt_scenario2.cfg |
| ExchangeAgreement | Safety | base.tla:1529 | MCExchangeAgreement, MC.tla:420 | MC_hunt_scenario2.cfg |
| DirtyStateAccounted | Safety | base.tla:1537 | MCDirtyStateAccounted, MC.tla:421 | MC_hunt_scenario2.cfg |
| WarmRecoveryTerminates | Liveness | base.tla:1593 | MCWarmRecoveryTerminates, MC.tla:426 | MC_hunt_scenario1.cfg |
| RecoveryBeforeAdvertise | Safety | base.tla:1545 | MCRecoveryBeforeAdvertise, MC.tla:422 | MC_hunt_scenario1.cfg |
| CurrentIsolationBeforeTraffic | Safety | base.tla:1554 | MCCurrentIsolationBeforeTraffic, MC.tla:423 | MC_hunt_scenario3.cfg |
| NoPeerLinkLoop | Safety | base.tla:1564 | MCNoPeerLinkLoop, MC.tla:424 | MC_hunt_scenario3.cfg |
| SyncEventuallyResolves | Liveness | base.tla:1600 | MCSyncEventuallyResolves, MC.tla:427 | MC_hunt_scenario2.cfg, MC_hunt_scenario4.cfg |
| StuckSessionDetected | Liveness | base.tla:1608 | MCStuckSessionDetected, MC.tla:428 | MC_hunt_scenario4.cfg |

Result: every §5 Safety invariant is defined, explicitly wired through
MC.tla, and enabled in at least one hunt cfg. The liveness properties are
also explicitly wired and enabled in their targeting cfgs.

## §6.1 model-checkable finding coverage

| Finding | Trigger represented in hunt cfg | Expected violated invariant/property | Targeting cfg |
|---|---|---|---|
| MC1 — warm state retained forever | MaxWarmLimit=1, MaxDisconnectLimit=1; reactive grace install and status reset are unbounded, while reconnect is not fair | MCWarmRecoveryTerminates | MC_hunt_scenario1.cfg |
| MC2 — live peers disagree after full/failed/partial sync | MaxResyncLimit=2, MaxPartialWriteLimit=1, MaxFailedWriteLimit=1, MaxObjectUpdateLimit=1, MaxNonProgressLimit=1 | MCExchangeAgreement, MCSyncEventuallyResolves (with the ordering/accounting safety monitors also enabled) | MC_hunt_scenario2.cfg |
| MC3 — stale/no-proof ACK enables traffic | MaxLagTransitionLimit=4, MaxApplyFailLimit=1, MaxPeerTopologyLimit=1, MaxSyncdEOFLimit=1; FIFO delivery and ACK receive/apply remain unbounded | MCCurrentIsolationBeforeTraffic, MCNoPeerLinkLoop | MC_hunt_scenario3.cfg |
| MC4 — stale reconstruction advertised before authoritative snapshot | MaxCrashLimit=1, MaxReconnectLimit=1; startup neighbor dump and later VLAN membership are unbounded and ordered as in code, while a repairing event is optional | MCRecoveryBeforeAdvertise | MC_hunt_scenario1.cfg |
| MC5 — complete nonprogress traffic masks stuck session | MaxNonProgressLimit=1 enables an ongoing unbounded nonprogress source; MaxResyncLimit=1 and MaxPartialHeaderLimit=1 create logical/physical stalls | MCStuckSessionDetected (and shared MCSyncEventuallyResolves) | MC_hunt_scenario4.cfg |

## Scope notes

- §6.2 test-verifiable and §6.3 code-review-only findings are intentionally not
  promoted into this audit, as directed by the skill checklist.
- TCP reordering/duplication is absent. wire[source] and inbox[destination]
  are sequences; only the head can be delivered or processed.
- A positive short write creates one invalid prefix and the receiver enters its
  body-retry/block path. It does not create arbitrary reordered frames.
- Raw TLV lengths, byte buffers, heap safety, SIGPIPE, exact neighbor tables,
  and Redis/ebtables syntax remain in the brief’s “Do Not Model” scope.
- There are no uncovered §2 scenarios, §5 Safety invariants, or §6.1 findings.
