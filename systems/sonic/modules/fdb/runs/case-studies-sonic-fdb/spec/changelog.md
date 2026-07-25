# Changelog: sonic-fdb Spec Validation

## Round 1 - Trace Validation
- All 5 traces pass: basic_lifecycle (9), bridge_port_race (7), move_and_provision (7), tunnel_lifecycle (7), vlan_flush_and_age_drop (10)
- Added WF fairness to TraceSpec and PROPERTIES TraceMatched to Trace.cfg

## Round 1 - Model Checking
- BFS complete: 1,151,138 states, 73,422 distinct, depth 26, 13s — no violations
- All 5 structural invariants pass (BridgePortConsistency, PortFdbCountNonNeg, VlanFdbCountNonNeg, TunnelFdbCountNonNeg, TunnelRefCntNonNeg)

## Round 2 - Trace Validation (re-check after spec fix)
- All 5 traces pass (no regressions)

## Round 2 - Model Checking
- BFS complete: 1,054,264 states, 68,728 distinct, depth 28, 7s — no violations

## Bug Hunting Round 1
- [fix-spec] AgeFdbOnTunnel: added notifyTunnelOrch callback that triggers tunnel cleanup when refcnt=0 and fdb_count reaches 0 (Case B — fdborch.cpp:546)
- [fix-spec] RemoveFdbEntry: added tunnelFdbCount decrement and tunnel cleanup for tunnel entries via notifyTunnelOrch (Case B — fdborch.cpp:1739)
- [bug] FdbAsicConsistency: LEARN/AGE events silently dropped when bridge port OID stale — ASIC/m_entries diverge (Case C, Family 1)

## Bug Hunting Round 2
- [inv] TunnelCounterConsistency: new invariant checks tunnelFdbCount matches actual entry count (FlushFdbOnTunnel unreachable — trigger path outside model scope)
- [inv] NoPhantomAfterVlanFlush: new invariant catches Family 2 phantom entries (VLAN flush doesn't set is_flush_pending)
- [bug] NoPhantomAfterVlanFlush: phantom entries after flushFdbByVlan — is_flush_pending never set (Case C, Family 2, 5-state counterexample)
- hunt_tunnel_leak_r3: TunnelNoLeak + TunnelCounterConsistency pass, 821 states, depth 11 (FlushFdbOnTunnel unreachable)
- hunt_flush_phantom: NoPhantomAfterVlanFlush violated, 5-state counterexample

## Result
Converged in 2 rounds. Bug hunting: 2 bugs confirmed (Family 1 stale OID, Family 2 flush phantom).
