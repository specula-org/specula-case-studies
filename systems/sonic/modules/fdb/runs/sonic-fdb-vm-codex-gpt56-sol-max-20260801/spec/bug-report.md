# Bug Report — SONiC FDB

## Summary

- Scenarios tested: 5
- Bugs found: 7
- Configs run: MC_hunt_mc1_stale_flush.cfg, MC_hunt_mc2_stale_age.cfg, MC_hunt_mc4_vtep_replacement.cfg, MC_hunt_mc6_topology_reuse.cfg, MC_hunt_scenario_1_flush.cfg, MC_hunt_scenario_2_incarnation.cfg, MC_hunt_scenario_3_deferred.cfg, MC_hunt_scenario_4_nhg_graph.cfg, MC_hunt_scenario_5_restart.cfg
- Validated source revision: 4f3dda156e52ed7647b1dbf900d54d87efaea455
- Targeted diagnostic: the scenario-2 hunt was also rerun with `MaxRepairFailureLimit = 0` to separate the replacement stale-LEARN result from repair-failure injection.
- Convergence result: all four implementation traces pass; MC.cfg completes with no violation or deadlock over 56,211 generated / 1,949 distinct states at diameter 15

### Hunt Coverage

| Config | Generated / Distinct Before Stop | Diameter | Result |
|---|---:|---:|---|
| MC_hunt_mc1_stale_flush.cfg | 5,181 / 1,806 | 18 | FlushAckMatchesRequest violated |
| MC_hunt_mc2_stale_age.cfg | 13,970 / 4,552 | 13 | StaleEventCannotDeleteNewer violated |
| MC_hunt_mc4_vtep_replacement.cfg | 76 / 40 | 9 | TunnelRefExact violated |
| MC_hunt_mc6_topology_reuse.cfg | 223 / 96 | 7 | NoDanglingTopologyReference violated |
| MC_hunt_scenario_1_flush.cfg | 195,035 / 68,395 | 7 | NoDanglingTopologyReference violated |
| MC_hunt_scenario_2_incarnation.cfg | 54,150 / 14,650 | 9 | UniqueEffectiveDestination violated |
| MC_hunt_scenario_3_deferred.cfg | 463 / 227 | 9 | LatestDesiredWins violated |
| MC_hunt_scenario_4_nhg_graph.cfg | 1,575 / 498 | 9 | TunnelRefExact violated |
| MC_hunt_scenario_5_restart.cfg | 30 / 15 | 9 | RestartConverges violated |

## Bug 1: A delayed FLUSHED callback deletes a post-flush relearn

- **Scenario**: Scenario 1 — multi-stage flush protocol
- **Severity**: High
- **Invariant violated**: FlushAckMatchesRequest
- **Config**: MC_hunt_mc1_stale_flush.cfg
- **Counterexample**: 17 states, output/repair_RR003_MC_hunt_mc1_stale_flush_bfs.out

### Trace Summary

1. FdbOrch commits learned generation 1 for k1 on p1.
2. A dynamic flush succeeds, removes ASIC generation 1, and sets the cached entry's boolean pending flag; its FLUSHED callback is delayed.
3. SAI learns generation 2 for the same key and port after the successful flush. The same-port duplicate path leaves the existing FdbData object—and therefore its pending flag—in place while the new notification becomes the current semantic incarnation.
4. The delayed generation-1 FLUSHED callback sees the still-true flag and clears the current software entry.
5. Cache and STATE_DB are absent while ASIC/kernel retain generation 2. The repaired audit records that the successful flush removed generation 1 but the callback removed generation 2.

### Root Cause

FdbData stores only `is_flush_pending`, with no request or entry incarnation. A successful flush sets that flag at orchagent/fdborch.cpp:1492-1500. A later same-port local LEARN/MOVE returns as a duplicate at lines 154-160, so it does not replace the FdbData object or clear the flag. The FLUSHED handler then filters only by scope, SAI type, MAC, and the boolean at lines 302-358 and clears the current key even when hardware learned it after the flush.

### Affected Code

- orchagent/fdborch.h:84: the pending state is a single boolean
- orchagent/fdborch.cpp:154: same-port local notification returns without replacing FdbData
- orchagent/fdborch.cpp:308: acknowledgement cleanup tests only is_flush_pending
- orchagent/fdborch.cpp:1499: a successful flush sets the same boolean marker

### Recommendation

Invalidate pending flush ownership when a later LEARN/MOVE establishes a new incarnation, or track a local per-key generation alongside the pending request and require the callback to match it. If callback payloads cannot identify an incarnation, resynchronize the key against ASIC state before destructive cleanup.

---

## Bug 2: A delayed AGE event deletes a newer FDB incarnation

- **Scenario**: Scenario 2 — notification incarnation
- **Severity**: High
- **Invariant violated**: StaleEventCannotDeleteNewer
- **Config**: MC_hunt_mc2_stale_age.cfg
- **Counterexample**: 11 states, output/repair_RR003_MC_hunt_mc2_stale_age_bfs.out

### Trace Summary

1. SAI learns k1 generation 1 on p1 and queues the notification.
2. An AGE notification for generation 1 is delayed while SAI subsequently learns generation 2 for the same key and bridge port.
3. FdbOrch processes the newer learn and commits generation 2 to cache and STATE_DB.
4. FdbOrch then processes the delayed AGE. It removes software generation 2 even though the event belongs to generation 1.
5. The cache and STATE_DB are absent while ASIC/kernel still contain generation 2; lastDeletion records eventGen 1 and removedGen 2.

### Root Cause

The AGE path looks up the mutable current entry using MAC/BV identity at orchagent/fdborch.cpp:612. Its only staleness signal is a bridge-port mismatch at line 621; a same-port re-learn is indistinguishable, and even the different-port branch deliberately continues at lines 630-631. The handler then commits deletion at line 779 and notifies observers without validating the notification against an entry incarnation.

### Affected Code

- orchagent/fdborch.cpp:612: AGE resolves to the current mutable cache entry
- orchagent/fdborch.cpp:621: staleness detection compares only bridge-port identity
- orchagent/fdborch.cpp:630: the stale-port branch deliberately continues
- orchagent/fdborch.cpp:779: the current entry is deleted from software state

### Recommendation

Associate notification work with an entry incarnation or equivalent tombstone/sequence. Reject AGE cleanup when the event no longer identifies the installed version; for payloads that cannot carry a generation, preserve enough local lifecycle state or perform an authoritative resync before deleting a newer cache entry.

---

## Bug 3: VTEP replacement credits the new member to the old endpoint

- **Scenario**: Scenario 4 — tunnel/NHG graph mutation
- **Severity**: Medium
- **Invariant violated**: TunnelRefExact
- **Config**: MC_hunt_mc4_vtep_replacement.cfg
- **Counterexample**: 7 states, output/repair_RR003_MC_hunt_mc4_vtep_replacement_bfs.out; independently reproduced in 7 states by output/repair_RR003_MC_hunt_scenario_4_nhg_graph_bfs.out

### Trace Summary

1. An active g1 group is created with endpoint ep2 and an FDB reference.
2. VTEP replacement from ep2 to ep1 removes the old member and decrements ep2.
3. Creation of the ep1 next hop and member succeeds.
4. The implementation-equivalent transition increments ep2 again instead of ep1.
5. The final group contains ep1, but tunnelRefs reports ep1 = 0 and ep2 = 1. Both supplied NHG hunting configurations reach this mismatch.

### Root Cause

updateL2NhgVtepIp erases the old member and decrements m_nhg_vtep[nh_id] at orchagent/l2nhgorch.cpp:620-623. After creating the new member, line 634 calls updateRemoteEndPointIpRef with m_nhg_vtep[nh_id].ip, which still contains the old endpoint. The cached IP is not changed to new_vtep_ip until line 653, after the per-group loop.

### Affected Code

- orchagent/l2nhgorch.cpp:620: old membership and reference are removed
- orchagent/l2nhgorch.cpp:634: the new edge increments the still-cached old endpoint
- orchagent/l2nhgorch.cpp:653: the endpoint cache is updated too late

### Recommendation

Increment new_vtep_ip directly for every successfully created member, and commit the logical endpoint only after all group mutations succeed. On partial failure, roll back the new/old edge accounting or persist a resumable transaction phase and recompute exact reference counts before retry.

---

## Bug 4: Bridge-port teardown continues after its FDB flush fails

- **Scenario**: Scenarios 1 and 4 — flush/topology lifecycle
- **Severity**: High
- **Invariant violated**: NoDanglingTopologyReference
- **Config**: MC_hunt_mc6_topology_reuse.cfg
- **Counterexample**: 7 states, output/repair_RR003_MC_hunt_mc6_topology_reuse_bfs.out; independently reproduced in 7 states by output/repair_RR003_MC_hunt_scenario_1_flush_bfs.out

### Trace Summary

1. SAI learns k1 on bridge port p1, leaving a live ASIC/kernel FDB reference to bridge-port generation 1.
2. PortsOrch begins removing p1 and invokes the dynamic FDB flush.
3. SAI returns failure for the flush, so the hardware FDB entry remains.
4. PortsOrch nevertheless removes the bridge-port object and publishes p1 as removed.
5. The final state has bpPresent[p1] = false while the ASIC FDB still points to p1 generation 1. Two independently bounded configurations reproduce the same causal sequence.

### Root Cause

FdbOrch::flushFDBEntries returns void. A SAI failure is only logged at orchagent/fdborch.cpp:1486-1490, so the caller cannot retain teardown ownership. PortsOrch calls it at orchagent/portsorch.cpp:7506 and immediately proceeds to remove_bridge_port at line 7510 without waiting for either flush success or asynchronous cleanup.

### Affected Code

- orchagent/fdborch.cpp:1443: flushFDBEntries has no result channel
- orchagent/fdborch.cpp:1486: a failed SAI flush is only logged
- orchagent/portsorch.cpp:7506: bridge-port teardown ignores flush completion
- orchagent/portsorch.cpp:7510: the referenced bridge port is removed anyway

### Recommendation

Make flush initiation/completion an explicit teardown dependency. Propagate synchronous failure, retain a retry owner, and do not remove the bridge port until the flush succeeds and matching cleanup is confirmed; alternatively perform a safe compensating purge before publishing topology removal.

---

## Bug 5: A delayed LEARN reclassifies a newer MCLAG remote entry as local

- **Scenario**: Scenario 2 — notification incarnation
- **Severity**: High
- **Invariant violated**: UniqueEffectiveDestination
- **Config**: MC_hunt_scenario_2_incarnation.cfg
- **Counterexample**: 9 states, output/repair_RR003_MC_hunt_scenario_2_incarnation_bfs.out; reproduced with repair-failure injection disabled by output/repair_RR003_MC_hunt_scenario_2_no_repair_failure_bfs.out

### Trace Summary

1. SAI emits a local generation-1 LEARN on p1 and then ages that hardware entry before FdbOrch consumes either notification.
2. A newer MCLAG input installs generation 2 for the same key and port as a remote-owned logical dynamic row and an ASIC static row.
3. The old AGE is disposed through the remote/static repair branch without removing the current row.
4. FdbOrch then consumes the delayed generation-1 LEARN. The same-port MCLAG branch unconditionally sets the ASIC entry to dynamic and stores the notification as a locally learned row.
5. `storeFdbEntryState` removes MCLAG ownership and publishes the stale generation. The model's ghost incarnations leave ASIC/kernel at generation 2 and cache/STATE_DB/observer at generation 1; in production-visible terms, the newer remote row has been reclassified as local and made age eligible.

### Root Cause

The notification queue and `m_entries` carry no common incarnation. When a LEARN finds a same-port MCLAG row, orchagent/fdborch.cpp:470-503 assumes the local learn is current, changes the installed type to dynamic, and calls `storeFdbEntryState`. That store replaces the origin with `FDB_ORIGIN_LEARN` and deletes the MCLAG state row at lines 169-190, even when the notification predates the MCLAG update.

### Affected Code

- orchagent/fdborch.cpp:439: LEARN resolves only by mutable MAC/BV identity
- orchagent/fdborch.cpp:470: same-port MCLAG LEARN assumes the notification is current
- orchagent/fdborch.cpp:480: the handler changes the current ASIC row to dynamic
- orchagent/fdborch.cpp:500: the delayed LEARN is committed through `storeFdbEntryState`
- orchagent/fdborch.cpp:184: replacing MCLAG origin deletes its state-table ownership

### Recommendation

Version MCLAG ownership against queued SAI notifications, or retain a local tombstone/sequence that lets the LEARN handler reject work older than the current remote update. Before converting a same-port MCLAG row to local, reconcile the notification against authoritative ASIC/control-plane state; do not delete MCLAG ownership solely from mutable MAC/BV identity.

---

## Bug 6: Deferred SET replay applies an obsolete destination

- **Scenario**: Scenario 3 — deferred latest intent
- **Severity**: Medium
- **Invariant violated**: LatestDesiredWins
- **Config**: MC_hunt_scenario_3_deferred.cfg
- **Counterexample**: 8 states, output/repair_RR003_MC_hunt_scenario_3_deferred_bfs.out

### Trace Summary

1. While the port/VLAN dependency is absent, a SET for k1 to p1 is appended to saved work.
2. A newer SET for the same key to p2 is appended behind it; p2 is now the desired destination.
3. The dependency appears and updateVlanMember begins replay in insertion order.
4. The old p1 item is popped and committed first while the latest p2 item remains queued.
5. appliedIntent is p1 while desiredDest is p2, so obsolete intent becomes real state before the latest request is applied.

### Root Cause

Missing dependency handling appends SavedFdbEntry objects to a per-port vector at orchagent/fdborch.cpp:1848-1871. SavedFdbEntry equality compares only MAC and VLAN at orchagent/fdborch.h:101-104, so destination/value is not a latest-intent key. updateVlanMember moves and drains the vector in original order at orchagent/fdborch.cpp:1753-1785, invoking addFdbEntry for every stale copy. Each successful invocation emits an observer notification at orchagent/fdborch.cpp:2305.

### Affected Code

- orchagent/fdborch.h:101: saved-work identity excludes destination and generation
- orchagent/fdborch.cpp:1852: missing dependencies append instead of coalescing
- orchagent/fdborch.cpp:1767: replay drains insertion-ordered historical work
- orchagent/fdborch.cpp:2305: each obsolete replay is externally notified

### Recommendation

Represent deferred FDB work as latest intent keyed by MAC, VLAN, and origin, with a monotonic generation. Replace superseded SETs, make DELETE cancel all older saved work, and replay only the current generation while preserving retry ownership on failure.

---

## Bug 7: Startup discards the one-shot kernel NHG dump before NVO readiness

- **Scenario**: Scenario 5 — restart reconstruction
- **Severity**: High
- **Invariant violated**: RestartConverges
- **Config**: MC_hunt_scenario_5_restart.cfg
- **Counterexample**: 10 states, output/repair_RR003_MC_hunt_scenario_5_restart_bfs.out

### Trace Summary

1. fdbsyncd crashes, and kernel NHG g1 appears while the process is down.
2. Startup issues the GETNEXTHOP dump while NVO readiness is false.
3. The g1 dump item is observed but filtered; dumpSeen and missedDump both become true.
4. CONFIG_DB later enables the EVPN NVO.
5. Warm replay and bake complete, but L2_NEXTHOP_GROUP is not part of AppRestartAssist replay.
6. Restart settles with kernelNhg[g1] = true and appNhg[g1] = false. With no later live kernel event, the planes stutter forever and RestartConverges fails.

### Root Cause

fdbsyncd registers netlink handlers and performs RTM_GETNEXTHOP before adding the EVPN NVO CONFIG_DB table to its steady-state select loop at fdbsyncd/fdbsyncd.cpp:27-31 and 77-100. FdbSync::onMsgNhg immediately returns while m_isEvpnNvoExist is false at fdbsyncd/fdbsync.cpp:1138-1144. AppRestartAssist registers VXLAN_FDB and VXLAN_REMOTE_VNI only at fdbsyncd/fdbsync.cpp:40-45, so no persisted L2-NHG row repairs the discarded dump item.

### Affected Code

- fdbsyncd/fdbsyncd.cpp:89: GETNEXTHOP is issued before NVO configuration is consumed
- fdbsyncd/fdbsyncd.cpp:98: CONFIG_DB selection is added only after the startup dumps
- fdbsyncd/fdbsync.cpp:40: warm replay omits the L2 NHG table
- fdbsyncd/fdbsync.cpp:1138: pre-NVO NHG messages are discarded

### Recommendation

Establish NVO readiness before consuming the NHG snapshot, or queue pre-readiness dump records and replay them after configuration. Also include L2_NEXTHOP_GROUP in restart reconstruction or issue a second authoritative NHG dump during reconciliation so convergence does not depend on a future live event.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|---|---|---:|---|
| None | — | — | Every supplied final hunting configuration produced a violation |

## Spec Adjustments During Hunting

- Added an explicit quiescent select-loop transition so deadlock checking distinguishes terminal input exhaustion from a blocked in-progress operation.
- Refined LatestDesiredWins so an older generation with the same latest value is not itself unsafe.
- Required flush, VTEP replacement, FDB-reference, and notification-failure actions to respect the corresponding serialized implementation guards.
- Required the modeled startup GETNEXTHOP dump to be observed before NVO CONFIG processing, eliminating a source-impossible skipped-dump liveness trace.
- Replaced request-epoch equality in FlushAckMatchesRequest with execution-time incarnation coverage, and kept the AGE-specific stale-event oracle out of the flush-only hunt.
- Added explicit cache-origin state and a bounded MCLAG input, constrained MOVE repair failures to MCLAG-origin bridge-port changes, and modeled the implementation's continuing MOVE notification path.
- Distinguished logical remote type from installed SAI type, required ordinary AGE to target installed dynamic entries, and preserved static type across raw LEARN/MOVE delivery until the guarded FdbOrch conversion.
- Added the implementation's successful/already-satisfied remote/static AGE repair branch; a matching installed entry is compensation and a queued hardware notification is continuation ownership.
