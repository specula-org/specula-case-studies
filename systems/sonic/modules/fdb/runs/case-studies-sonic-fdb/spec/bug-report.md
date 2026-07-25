# Bug Report — sonic-net/sonic-swss FDB Bridge Port Lifecycle

## Summary

- Bug families tested: 5
- Bugs found: 2 (confirmed by model checking)
- Bugs structurally modeled: 1 additional (trigger path outside model scope)
- Configs run: MC_hunt_stale_bp.cfg, MC_hunt_flush_pending.cfg, MC_hunt_tunnel_leak.cfg, MC_hunt_origin_priority.cfg, MC_hunt_counter_drift.cfg, MC_hunt_flush_phantom.cfg

## Convergence

- Converged in 2 rounds (Round 1 clean; Round 2 after Case B fix for AgeFdbOnTunnel/RemoveFdbEntry tunnel cleanup callback)
- 5/5 traces validated: basic_lifecycle (9), bridge_port_race (7), move_and_provision (7), tunnel_lifecycle (7), vlan_flush_and_age_drop (10)
- Structural MC: 1,054,264 states, 68,728 distinct, depth 28 — all 5 structural invariants pass

---

## Bug 1: Stale Bridge Port OID Silently Drops FDB Events

- **Bug Family**: Family 1 — Stale Bridge Port OID
- **Severity**: Critical
- **Invariant violated**: FdbAsicConsistency (`asicEntries \subseteq DOMAIN mEntries`)
- **Config**: MC_hunt_stale_bp.cfg
- **Counterexample**: 2 states (output: spec/output/MC_hunt_stale_bp_r2.out)

### Trace Summary

1. **Init** — no bridge ports, no FDB entries
2. **LearnFdbEntryDropped(m1, v1, p1)** — SAI LEARNED event arrives for port p1, but `getPortByBridgePortId()` fails because bridge port OID is not in `saiOidToAlias`. ASIC has the entry (`asicEntries = {<<m1,v1>>}`) but orchagent silently drops it (`mEntries = {}`).

The 2-state trace is the minimal violation path. The real-world scenario is:
1. Port added to VLAN (bridge port created)
2. FDB entries learned on that port
3. Port removed from VLAN, triggering `removeBridgePort()`
4. `removeBridgePort()` calls `flushFDBEntries()` (async), then immediately calls `saiOidToAlias.erase()` and sets `m_bridge_port_id = SAI_NULL_OBJECT_ID`
5. SAI LEARNED/AGED events arrive for the now-stale bridge port — orchagent drops them
6. ASIC and `m_entries` diverge permanently

### Root Cause

`removeBridgePort()` (portsorch.cpp:7283-7345) erases the bridge port from `saiOidToAlias` (line 7334) **before** the flush notification arrives. Any SAI events referencing the now-stale OID are silently dropped by `FdbOrch::update()` (fdborch.cpp:296-312) because `getPortByBridgePortId()` fails.

The async flush (`flushFDBEntries()` at line 7318-7320) is fire-and-forget — the bridge port is removed immediately without waiting for the flush to complete.

### Affected Code

- `portsorch.cpp:7318-7323` — async flush followed by immediate bridge port removal
- `portsorch.cpp:7334-7343` — `saiOidToAlias.erase()` before flush notification arrives
- `fdborch.cpp:296-312` — `getPortByBridgePortId()` failure causes silent drop for LEARNED/AGED/MOVE events

### Historical Evidence

- sonic-buildimage#26531 — 75-minute production traffic blackhole, 1046 dropped FDB events after LAG transition (CRITICAL, UNFIXED)
- sonic-buildimage#13069 — "Failed to get port by bridge port ID" under VLAN churn (UNFIXED)
- sonic-buildimage#7538 — FDB entry not removed after port removed from VLAN (UNFIXED)
- sonic-swss#290, #304 — Bridge port remove fails because FDB not flushed first (UNFIXED, since 2017)

### Recommendation

Defer `saiOidToAlias.erase()` until after the flush notification is processed. The bridge port OID must remain in the lookup map during the window between `flushFDBEntries()` and `SAI_FDB_EVENT_FLUSHED`.

---

## Bug 2: Phantom FDB Entries After VLAN Flush (is_flush_pending Not Set)

- **Bug Family**: Family 2 — FDB Flush / is_flush_pending Race
- **Severity**: High
- **Invariant violated**: NoPhantomAfterVlanFlush
- **Config**: MC_hunt_flush_phantom.cfg
- **Counterexample**: 5 states (output: spec/output/hunt_flush_phantom.out)

### Trace Summary

1. **Init** — empty state
2. **AddVlanMember(p1, v1)** — bridge port created for p1
3. **LearnFdbEntry(m1, v1, p1)** — entry learned, added to both `mEntries` and `asicEntries`, counters incremented
4. **FlushFdbByVlan(v1)** — SAI flush issued for VLAN v1. Dynamic entries removed from `asicEntries`. But `is_flush_pending` is **NOT** set on any entries (the bug).
5. **HandleFlushNotificationVlan(v1)** — flush notification arrives. `handleSyncdFlushNotif` iterates entries and checks `is_flush_pending` — all entries have `is_flush_pending=FALSE`, so **all are skipped**. Entry `<<m1,v1>>` remains in `mEntries` as a phantom.

**Violating state**: `mEntries` contains `<<m1,v1>>` (dynamic, ORIGIN_LEARN, port=p1, is_flush_pending=FALSE) but `asicEntries = {}`. Software cache has a permanent phantom entry that doesn't exist in hardware.

### Root Cause

`flushFdbByVlan()` (fdborch.cpp:1149-1177) sends the SAI flush command but **never sets `is_flush_pending`** on matching entries. Compare with `flushFDBEntries()` (fdborch.cpp:1135-1146) which DOES set the flag. When the FLUSHED notification arrives, `handleSyncdFlushNotif()` (fdborch.cpp:222) checks `is_flush_pending` and skips entries that don't have it set.

### Affected Code

- `fdborch.cpp:1149-1177` — `flushFdbByVlan()` missing `is_flush_pending = true` on matching entries
- `fdborch.cpp:208-276` — `handleSyncdFlushNotif()` checks `is_flush_pending` per entry
- `fdborch.cpp:222` — the `is_flush_pending` check that causes entries to be skipped

### Historical Evidence

- sonic-swss#4428 — VLAN flush doesn't work due to key format mismatch (UNFIXED)
- commit 8dae3564 — entries cleared by syncd flush notification even when re-added after flush
- commit bbbd5f44 — `handleSyncdFlushNotif` was entirely missing; internal cache/counters never updated

### Recommendation

Add `is_flush_pending = true` to entries matching the flush criteria in `flushFdbByVlan()`, mirroring the logic in `flushFDBEntries()` at lines 1135-1146.

---

## Structurally Modeled: VXLAN Tunnel Lifecycle Leak (Family 3)

- **Bug Family**: Family 3 — VXLAN Tunnel Bridge Port Lifecycle Leak
- **Status**: Structurally modeled in spec but not reproducible by MC (trigger path outside model scope)
- **Mechanism**: `clearFdbEntry()` (fdborch.cpp:181-203) decrements `m_fdb_count` but does NOT call `notifyTunnelOrch()`. DIP tunnel bridge ports are never cleaned up after administrative FDB flushes.

The spec correctly models this via `FlushFdbOnTunnel` with `UNCHANGED tunnelFdbCount` (line 524). However, the action requires `is_flush_pending=TRUE` on tunnel entries, and no action in the modeled scope sets this flag on tunnel entries (tunnel bridge port flush is not modeled). The bug exists in the implementation but cannot be triggered by the current model's state space.

**Evidence in code**: Compare `clearFdbEntry()` (fdborch.cpp:181-203, no `notifyTunnelOrch`) with the AGED path (fdborch.cpp:546, calls `notifyTunnelOrch`) and `removeFdbEntry` (fdborch.cpp:1739, calls `notifyTunnelOrch`).

---

## Not Reproduced

| Bug Family | Config | States Explored | Depth | Result |
|------------|--------|-----------------|-------|--------|
| Family 3 — Tunnel Leak | MC_hunt_tunnel_leak.cfg | 821 | 11 | No violation (FlushFdbOnTunnel unreachable — tunnel bridge port flush not in model scope) |
| Family 4 — Origin Priority | MC_hunt_origin_priority.cfg | 1,511 | 14 | No violation (NoOrphanFdbEntry is a stub; origin-mismatch DEL modeled as UNCHANGED vars) |
| Family 5 — Counter Drift | MC_hunt_counter_drift.cfg | 32,787 | 18 | No violation (CounterConsistency + VlanRemovable pass — MOVE counter bug does not apply because MOVE doesn't change VLAN) |

### Notes on Family 5

The modeling brief identified "MOVE event doesn't update vlan.m_fdb_count" as a bug. However, FDB MOVE events change the port (bridge_port_id) but not the VLAN — the entry's VLAN is part of the key `<<MAC, VLAN>>` and is immutable. Since the VLAN doesn't change during a MOVE, `vlan.m_fdb_count` correctly remains unchanged. The CounterConsistency invariant confirms this: `vlanFdbCount[v] = Cardinality(EntriesForVlan(v))` holds across all 32,787 states. The reported bug appears to be a false positive in the code analysis.

---

## Spec Fixes During Bug Hunting

| Fix | Type | Description |
|-----|------|-------------|
| AgeFdbOnTunnel tunnel cleanup | Case B | Added tunnel deletion when refcnt=0 and fdb_count reaches 0 via notifyTunnelOrch callback (fdborch.cpp:546) |
| RemoveFdbEntry tunnel handling | Case B | Added tunnelFdbCount decrement and tunnel cleanup for tunnel entries via notifyTunnelOrch (fdborch.cpp:1739) |
| TunnelCounterConsistency | New invariant | Checks tunnelFdbCount matches actual entry count (Family 3 detection) |
| NoPhantomAfterVlanFlush | New invariant | Checks no phantom dynamic entries after VLAN flush notification (Family 2 detection) |
