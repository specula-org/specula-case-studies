# Instrumentation Spec: SONiC FDB Bridge Port Lifecycle

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "port": "<port_alias>",
  "vlan": "<vlan_name>",
  "mac": "<mac_address>",
  "vtep": "<remote_vtep_ip>",
  "bridge_port_exists": true|false,
  "in_oid_map": true|false,
  "entry_exists": true|false,
  "entry_origin": "learn"|"provisioned"|"vxlan_advertized"|"mclag_advertized",
  "entry_port": "<port_alias>",
  "port_fdb_count": <int>,
  "vlan_fdb_count": <int>,
  "is_flush_pending": true|false,
  "tunnel_exists": true|false,
  "tunnel_ref_cnt": <int>,
  "tunnel_fdb_count": <int>,
  "new_port": "<port_alias>",
  "origin": "learn"|"provisioned"|"vxlan_advertized"|"mclag_advertized"
}
```

Fields are optional per event type. Only fields relevant to each action are emitted.

### State Fields

| Implementation Getter/Field | TLA+ Variable | Type |
|---|---|---|
| `port.m_bridge_port_id != SAI_NULL_OBJECT_ID` | `bridgePortExists[port]` | BOOLEAN |
| `saiOidToAlias.find(bp_oid) != end()` | `port \in saiOidToAlias` | BOOLEAN |
| `m_entries.find(key) != end()` | `key \in DOMAIN mEntries` | BOOLEAN |
| `m_entries[key].origin` | `mEntries[key].origin` | Origin enum |
| `m_entries[key].port` (bridge_port -> alias) | `mEntries[key].port` | Port |
| `port.m_fdb_count` | `portFdbCount[port]` | Nat |
| `vlan.m_fdb_count` | `vlanFdbCount[vlan]` | Nat |
| `m_entries[key].is_flush_pending` | `mEntries[key].is_flush_pending` | BOOLEAN |
| `tunnelExists (tnl_users_ not empty)` | `tunnelExists[vtep]` | BOOLEAN |
| `getRemoteEndPointRefCnt(vtep)` | `tunnelRefCnt[vtep]` | Nat |
| `tunnel.fdb_count` | `tunnelFdbCount[vtep]` | Nat |

## Section 2: Action-to-Code Mapping

### 1. AddVlanMember

- **Spec action**: `AddVlanMember(p, v)`
- **Code location**: `portsorch.cpp:doVlanMemberTask()` ADD path (~line 5900)
- **Trigger point**: After successful `addBridgePort()` return (or after VLAN member add if bridge port already existed)
- **Event name**: `add_vlan_member`
- **Fields**: `port`, `vlan`, `bridge_port_exists`, `in_oid_map`
- **Notes**: Capture `bridge_port_exists` AFTER the operation completes — it will be TRUE if this was the first VLAN membership

### 2. RemoveVlanMember

- **Spec action**: `RemoveVlanMember(p, v)`
- **Code location**: `portsorch.cpp:doVlanMemberTask()` DEL path (lines 5942-5962)
- **Trigger point**: After `removeVlanMember()` succeeds, BEFORE `removeBridgePort()` is called
- **Event name**: `remove_vlan_member`
- **Fields**: `port`, `vlan`, `bridge_port_exists`, `in_oid_map`
- **Notes**: Capture before bridge port removal. The `removeBridgePort` call at line 5950 is a separate event sequence.

### 3. FlushFDBForRemove

- **Spec action**: `FlushFDBForRemove(p)`
- **Code location**: `portsorch.cpp:removeBridgePort()` line 7318-7320 — `flushFDBEntries()` call
- **Trigger point**: After `flushFDBEntries()` returns
- **Event name**: `flush_fdb_for_remove`
- **Fields**: `port`
- **Notes**: This is the async flush request. The actual cleanup happens later via `HandleFlushNotification`.

### 4. RemoveBridgePortHW

- **Spec action**: `RemoveBridgePortHW(p)`
- **Code location**: `portsorch.cpp:removeBridgePort()` lines 7322-7343
- **Trigger point**: After `sai_bridge_api->remove_bridge_port()` succeeds AND `saiOidToAlias.erase()` completes
- **Event name**: `remove_bridge_port_hw`
- **Fields**: `port`, `bridge_port_exists` (=FALSE), `in_oid_map` (=FALSE)
- **Notes**: Capture AFTER both SAI removal and OID map erasure. This is the point where Family 1 race window opens.

### 5. HandleFlushNotification

- **Spec action**: `HandleFlushNotification(p)`
- **Code location**: `fdborch.cpp:update()` SAI_FDB_EVENT_FLUSHED handler (line 640) → `handleSyncdFlushNotif()` (lines 208-276)
- **Trigger point**: After `handleSyncdFlushNotif()` completes processing
- **Event name**: `handle_flush_notification`
- **Fields**: `port`, `port_fdb_count`, `vlan_fdb_count`
- **Notes**: Port-scoped flush. The `port` field comes from the `bridge_port_id` in the SAI notification. If `getPortByBridgePortId` fails for FLUSHED events, `port` will be empty — capture the bridge_port_id raw value for debugging.

### 6. HandleFlushNotificationVlan

- **Spec action**: `HandleFlushNotificationVlan(v)`
- **Code location**: `fdborch.cpp:handleSyncdFlushNotif()` VLAN-scoped path (lines 244-259)
- **Trigger point**: After the VLAN-scoped iteration completes
- **Event name**: `handle_flush_notification_vlan`
- **Fields**: `vlan`, `vlan_fdb_count`
- **Notes**: VLAN-scoped flush notification. Distinct from port-scoped flush.

### 7. FlushFdbByVlan

- **Spec action**: `FlushFdbByVlan(v)`
- **Code location**: `fdborch.cpp:flushFdbByVlan()` (lines 1149-1177)
- **Trigger point**: After SAI `flush_fdb_entries()` call returns
- **Event name**: `flush_fdb_by_vlan`
- **Fields**: `vlan`
- **Notes**: Family 2 bug: this function does NOT set `is_flush_pending`. The trace won't show any flag changes — that's the bug.

### 8. LearnFdbEntry

- **Spec action**: `LearnFdbEntry(mac, v, p)`
- **Code location**: `fdborch.cpp:update()` SAI_FDB_EVENT_LEARNED handler, new entry path (lines 405-415)
- **Trigger point**: After `storeFdbEntryState()` succeeds
- **Event name**: `learn_fdb_entry`
- **Fields**: `mac`, `vlan`, `port`, `entry_exists` (=TRUE), `entry_origin` (="learn"), `entry_port`, `port_fdb_count`, `vlan_fdb_count`
- **Notes**: Only for new entries (not MAC moves or existing MCLAG entries)

### 9. LearnFdbEntryDropped

- **Spec action**: `LearnFdbEntryDropped(mac, v, p)`
- **Code location**: `fdborch.cpp:update()` lines 296-312, `getPortByBridgePortId` failure with non-FLUSHED event
- **Trigger point**: At the `return` statement after the error log
- **Event name**: `learn_fdb_entry_dropped`
- **Fields**: `mac`, `vlan`, `port` (raw bridge_port_id as hex string for debugging)
- **Notes**: Family 1 indicator. The `port` here is the alias that WOULD have been used if the OID was still in the map.

### 10. AgeFdbEntry

- **Spec action**: `AgeFdbEntry(mac, v)`
- **Code location**: `fdborch.cpp:update()` SAI_FDB_EVENT_AGED handler, dynamic non-MCLAG path (lines 531-544)
- **Trigger point**: After `storeFdbEntryState()` with `update.add = false`
- **Event name**: `age_fdb_entry`
- **Fields**: `mac`, `vlan`, `entry_exists` (=FALSE), `port_fdb_count`, `vlan_fdb_count`

### 11. AgeFdbEntryDropped

- **Spec action**: `AgeFdbEntryDropped(mac, v)`
- **Code location**: `fdborch.cpp:update()` lines 296-312, same as LearnFdbEntryDropped but for AGED event
- **Trigger point**: At the `return` statement
- **Event name**: `age_fdb_entry_dropped`
- **Fields**: `mac`, `vlan`
- **Notes**: Family 1 indicator. AGED event dropped because bridge port OID not in map.

### 12. MoveFdbEntry

- **Spec action**: `MoveFdbEntry(mac, v, newPort)`
- **Code location**: `fdborch.cpp:update()` SAI_FDB_EVENT_MOVE handler (lines 549-623)
- **Trigger point**: After counter updates and `storeFdbEntryState()` at line 617
- **Event name**: `move_fdb_entry`
- **Fields**: `mac`, `vlan`, `new_port`, `entry_exists` (=TRUE), `entry_port` (=new_port), `port_fdb_count` (new port count), `vlan_fdb_count`
- **Notes**: Family 5: `vlan_fdb_count` is NOT updated by the code (bug). Capture it anyway to verify the spec matches the (buggy) implementation.

### 13. AddFdbEntryProvisioned

- **Spec action**: `AddFdbEntryProvisioned(mac, v, p)`
- **Code location**: `fdborch.cpp:addFdbEntry()` (lines 1278-1629) with `origin = FDB_ORIGIN_PROVISIONED`
- **Trigger point**: After `m_entries[entry] = storeFdbData` at line 1566
- **Event name**: `add_fdb_entry_provisioned`
- **Fields**: `mac`, `vlan`, `port`, `entry_exists` (=TRUE), `entry_origin` (="provisioned"), `port_fdb_count`, `vlan_fdb_count`

### 14. RemoveFdbEntry

- **Spec action**: `RemoveFdbEntry(mac, v, origin)`
- **Code location**: `fdborch.cpp:removeFdbEntry()` (lines 1632-1741)
- **Trigger point**: After `m_entries.erase(entry)` at line 1721 (or at origin-mismatch return at line 1691)
- **Event name**: `remove_fdb_entry`
- **Fields**: `mac`, `vlan`, `origin`, `entry_exists` (FALSE if deleted, TRUE if origin-mismatch skip), `port_fdb_count`, `vlan_fdb_count`
- **Notes**: Family 4: capture both the successful deletion AND the origin-mismatch skip to detect phantom entries.

### 15. LearnFdbOnTunnel

- **Spec action**: `LearnFdbOnTunnel(mac, v, vtep)`
- **Code location**: `fdborch.cpp:addFdbEntry()` with `origin = FDB_ORIGIN_VXLAN_ADVERTIZED`
- **Trigger point**: After `m_entries[entry] = storeFdbData`
- **Event name**: `learn_fdb_on_tunnel`
- **Fields**: `mac`, `vlan`, `vtep`, `entry_exists` (=TRUE), `tunnel_fdb_count`, `tunnel_ref_cnt`

### 16. AgeFdbOnTunnel

- **Spec action**: `AgeFdbOnTunnel(mac, v)`
- **Code location**: `fdborch.cpp:update()` AGED handler for tunnel entries + `notifyTunnelOrch` at line 546
- **Trigger point**: After `storeFdbEntryState()` and `notifyTunnelOrch()`
- **Event name**: `age_fdb_on_tunnel`
- **Fields**: `mac`, `vlan`, `entry_exists` (=FALSE), `tunnel_fdb_count`, `tunnel_exists`
- **Notes**: Family 3: AGED path correctly calls notifyTunnelOrch.

### 17. FlushFdbOnTunnel

- **Spec action**: `FlushFdbOnTunnel(mac, v)`
- **Code location**: `fdborch.cpp:clearFdbEntry()` (lines 181-203) when entry port is a tunnel
- **Trigger point**: After `clearFdbEntry()` completes
- **Event name**: `flush_fdb_on_tunnel`
- **Fields**: `mac`, `vlan`, `entry_exists` (=FALSE)
- **Notes**: Family 3 BUG: `clearFdbEntry` does NOT call `notifyTunnelOrch`. The trace will NOT show `tunnel_fdb_count` change — that's the bug. Capture `tunnel_fdb_count` anyway to confirm it stays unchanged.

### 18. AddRemoteVNI

- **Spec action**: `AddRemoteVNI(vtep)`
- **Code location**: `vxlanorch.cpp:EvpnRemoteVnip2pOrch::addOperation()` (lines 2449-2533)
- **Trigger point**: After `addTunnelUser()` at line 2516
- **Event name**: `add_remote_vni`
- **Fields**: `vtep`, `tunnel_exists` (=TRUE), `tunnel_ref_cnt`

### 19. DelRemoteVNI

- **Spec action**: `DelRemoteVNI(vtep)`
- **Code location**: `vxlanorch.cpp:EvpnRemoteVnip2mpOrch::delOperation()` or `deleteDynamicDIPTunnel()` (lines 1182-1241)
- **Trigger point**: After refcnt decrement in `updateRemoteEndPointRefCnt()`
- **Event name**: `del_remote_vni`
- **Fields**: `vtep`, `tunnel_exists`, `tunnel_ref_cnt`

## Section 3: Special Considerations

### 3.1 Single-Threaded Event Loop

SONiC orchagent is single-threaded. Events arrive via Redis consumers and SAI notification callbacks. The callback runs in the same thread as the main event loop. This means:
- No true concurrency within orchagent
- Race conditions arise from the ORDER of event processing, not parallel execution
- SAI flush is the exception: it's fire-and-forget to ASIC, notification comes back asynchronously

### 3.2 SAI Notification Timing

SAI notifications (LEARNED, AGED, MOVE, FLUSHED) arrive via a callback registered at startup. The notification is queued to the event loop and processed when the current task completes. Key implication:
- Between `flushFDBEntries()` and the FLUSHED notification, multiple other events can be processed
- New LEARN events can arrive and be processed before the FLUSHED notification

### 3.3 Bridge Port OID Mapping

The `saiOidToAlias` map uses SAI object IDs (64-bit integers) as keys. For tracing, convert to port alias strings. The mapping is:
- Inserted in `addBridgePort()` at portsorch.cpp:7274
- Erased in `removeBridgePort()` at portsorch.cpp:7334
- Queried in `getPortByBridgePortId()` at portsorch.cpp:1970-1986

### 3.4 FDB Entry Key Format

FDB entries are keyed by `<<MAC, VLAN>>` in the spec. In the implementation:
- Key: `FdbEntry` struct with `mac` (sai_mac_t) and `bv_id` (sai_object_id_t for VLAN)
- The `bv_id` is a SAI VLAN OID, not the VLAN ID integer
- Tracing should emit VLAN name (e.g., "Vlan1000") not the SAI OID

### 3.5 Tunnel Port vs Physical Port

FDB entries can reference either physical ports or VXLAN tunnel ports. In the trace:
- Physical port entries: `port` field is the port alias (e.g., "Ethernet0")
- Tunnel entries: `vtep` field is the remote VTEP IP (e.g., "10.0.0.1")
- The spec uses `Port \cup RemoteVTEP` as the union type for `mEntries[k].port`

### 3.6 Bootstrap State

orchagent starts with no bridge ports, no FDB entries, and no tunnels. The base spec's `Init` matches this. No special bootstrap handling is needed.

### 3.7 Instrumentation Strategy

Instrument at the orchagent level (not SAI or syncd):
1. **fdborch.cpp**: Add trace emit points in `update()`, `handleSyncdFlushNotif()`, `addFdbEntry()`, `removeFdbEntry()`, `clearFdbEntry()`, `flushFDBEntries()`, `flushFdbByVlan()`
2. **portsorch.cpp**: Add trace emit points in `doVlanMemberTask()`, `removeBridgePort()`, `addBridgePort()`
3. **vxlanorch.cpp**: Add trace emit points in `addOperation()`, `delOperation()`, `deleteDynamicDIPTunnel()`

Use a simple NDJSON logger with an environment variable toggle (e.g., `SONIC_FDB_TRACE_FILE`). When the env var is set, emit trace events to the specified file. When unset, no-op.
