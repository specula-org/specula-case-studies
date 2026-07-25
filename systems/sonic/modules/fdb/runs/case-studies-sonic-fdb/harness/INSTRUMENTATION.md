# Instrumentation Guide: SONiC FDB Bridge Port Lifecycle

## Architecture

The trace harness has two components:

1. **Instrumentation patch** (`patches/instrumentation.patch`): Modifies the real orchagent source files (fdborch.cpp, portsorch.cpp, vxlanorch.cpp) to emit trace events via `tla_trace.h`. All instrumentation is `#ifdef SONIC_FDB_TRACE` guarded.

2. **Standalone harness** (`src/fdb_harness.cpp`): A self-contained C++ program that models the FDB state machine faithfully and emits trace events matching the spec schema. Used when the full SONiC build environment is not available.

## Instrumentation Points

### fdborch.cpp

| Event | Function | Trigger Point | Line (after patch) |
|-------|----------|---------------|-------------------|
| `learn_fdb_entry` | `update()` | After `storeFdbEntryState()` in LEARNED handler | ~line 425 |
| `learn_fdb_entry_dropped` | `update()` | At `return` after `getPortByBridgePortId` failure (non-FLUSHED) | ~line 318 |
| `age_fdb_entry` | `update()` | After `storeFdbEntryState()` in AGED handler | ~line 555 |
| `age_fdb_entry_dropped` | `update()` | Same as learn_dropped (AGED event type) | ~line 318 |
| `age_fdb_on_tunnel` | `update()` | Same as age_fdb_entry, when port.m_type == TUNNEL | ~line 555 |
| `move_fdb_entry` | `update()` | After `storeFdbEntryState()` in MOVE handler | ~line 630 |
| `handle_flush_notification` | `update()` | After `handleSyncdFlushNotif()` in FLUSHED handler (port-scoped) | ~line 655 |
| `handle_flush_notification_vlan` | `update()` | After `handleSyncdFlushNotif()` in FLUSHED handler (VLAN-scoped) | ~line 660 |
| `flush_fdb_by_vlan` | `flushFdbByVlan()` | After SAI `flush_fdb_entries()` returns | ~line 1180 |
| `add_fdb_entry_provisioned` | `addFdbEntry()` | After `m_entries[entry] = storeFdbData` (ORIGIN_PROVISIONED) | ~line 1580 |
| `learn_fdb_on_tunnel` | `addFdbEntry()` | After `m_entries[entry] = storeFdbData` (ORIGIN_VXLAN_ADVERTIZED) | ~line 1585 |
| `remove_fdb_entry` | `removeFdbEntry()` | After `m_entries.erase(entry)` (success) or at origin-mismatch return | ~line 1735 / 1700 |

### portsorch.cpp

| Event | Function | Trigger Point | Line (after patch) |
|-------|----------|---------------|-------------------|
| `add_vlan_member` | `doVlanMemberTask()` | After `addBridgePort() && addVlanMember()` succeeds | ~line 5942 |
| `remove_vlan_member` | `doVlanMemberTask()` | After `removeVlanMember()`, before `removeBridgePort()` | ~line 5955 |
| `flush_fdb_for_remove` | `removeBridgePort()` | After `flushFDBEntries()` returns | ~line 7325 |
| `remove_bridge_port_hw` | `removeBridgePort()` | After `saiOidToAlias.erase()` and `m_bridge_port_id = SAI_NULL_OBJECT_ID` | ~line 7345 |

### vxlanorch.cpp

| Event | Function | Trigger Point | Line (after patch) |
|-------|----------|---------------|-------------------|
| `add_remote_vni` | `EvpnRemoteVnip2pOrch::addOperation()` | After `addTunnelUser()` | ~line 2525 |
| `del_remote_vni` | `VxlanTunnel::deleteDynamicDIPTunnel()` | After `updateRemoteEndPointRefCnt()` | ~line 1210 |

## How to Add a New Field to an Event

1. Find the emit call in the instrumented file (search for the event name string)
2. Add the field to the `nlohmann::json({...})` initializer list
3. The field name must match what `Trace.tla` expects (check `ValidatePostState*` functions)
4. Rebuild with `-DSONIC_FDB_TRACE`

Example:
```cpp
SONIC_TLA_TRACE_EMIT(nlohmann::json({
    {"event", "learn_fdb_entry"},
    {"mac", update.entry.mac.to_string()},
    {"vlan", vlanName},
    {"port", update.port.m_alias},
    {"new_field", some_value}   // <-- add here
}));
```

## How to Add a New Event Type

1. Choose the trigger point in the orchagent code
2. Add a new `#ifdef SONIC_FDB_TRACE` block with the emit call
3. Add a corresponding `TraceXxx` action wrapper in `Trace.tla`
4. Add it to `TraceNext` disjunction

## How to Move a Capture Point

Each emit call has a comment indicating whether state is captured BEFORE or AFTER the operation. To move:

1. Cut the `#ifdef SONIC_FDB_TRACE ... #endif` block
2. Paste it at the new location
3. Verify the variables in scope still exist at the new location
4. Re-generate the patch: `cd artifact && git diff orchagent/ > ../harness/patches/instrumentation.patch`

## How to Rebuild and Re-run

### Standalone harness (no SONiC SDK needed):
```bash
cd .specula-output && bash harness/run.sh
```

### Full SONiC build (requires SONiC build environment):
```bash
# Apply instrumentation
bash harness/apply.sh

# Build with trace flag
cd case-studies/sonic-fdb/artifact/sonic-swss
make CXXFLAGS="-DSONIC_FDB_TRACE" -C tests/mock_tests

# Run tests with trace output
SONIC_FDB_TRACE_FILE=trace.ndjson tests/mock_tests/tests --gtest_filter="*Fdb*"
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SONIC_FDB_TRACE_FILE` | Path to NDJSON output file. Set to enable tracing in instrumented orchagent. |
| `TRACE_OUTPUT_DIR` | Directory for standalone harness trace output (default: current directory). |

## State Capture Levels

All instrumentation points use **full capture** — the orchagent is single-threaded, so all state is accessible at every emit point. No weak or specialized capture levels are needed.
