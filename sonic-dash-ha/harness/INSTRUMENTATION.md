# Instrumentation Guide: sonic-dash-ha

Guide for Phase 3 (validation) agent to adjust instrumentation when trace validation reveals issues.

## Architecture

- **Trace module**: `crates/hamgrd/src/tla_trace.rs` (copied from `harness/src/tla_trace.rs`)
- **Instrumented file**: `crates/hamgrd/src/actors/ha_scope.rs` (5 instrumentation points)
- **Module declaration**: `crates/hamgrd/src/main.rs` (adds `mod tla_trace;`)
- **Env var**: Set `HA_TRACE_FILE=path.ndjson` to activate tracing

## Instrumentation Points

After applying the patch, the instrumentation points are at these locations in `ha_scope.rs`:

### 1. Config Set → `on_config_set()` (after line ~507)

**Handler**: `handle_dash_ha_scope_config_table_message()`, inside the Set branch  
**Trigger**: After `self.dash_ha_scope_config = Some(...)` updates the config  
**Events emitted**:
- `receive_config` — only on first config (tracked by `config_received` flag)
- `change_desired_state` — only when `desired_ha_state` changes from previous

**Fields captured**: `desired_state` (from config), `ha_set_id`

### 2. Config Del → `on_config_del()` (after line ~489)

**Handler**: `handle_dash_ha_scope_config_table_message()`, inside the Del branch  
**Trigger**: Before `do_cleanup()` and `context.stop()`  
**Events emitted**:
- `go_to_dead` — only if `started` flag is true (state machine left Dead)

**Fields captured**: `dpu_up` (last known health)

### 3. VDpuState → `on_vdpu_state()` + `on_start_connecting()` (after line ~593)

**Handler**: `handle_vdpu_state_update()`  
**Trigger**: After vDPU managed check, before `update_dpu_ha_scope_table()`  
**Events emitted**:
- `dpu_health_change` — only when `vdpu.up` differs from last known
- `receive_vdpu_state` — only on first managed vDPU state
- `start_connecting` — only on first managed state (when bridges were empty)

**Fields captured**: `dpu_up` (from `vdpu.up`)

**Note**: `tla_first_managed` variable is set BEFORE the bridge creation block to correctly detect the first managed transition.

### 4. HaSetState → `on_haset_state()` (after line ~616)

**Handler**: `handle_haset_state_update()`  
**Trigger**: After vDPU managed check  
**Events emitted**:
- `receive_haset_state` — only on first haset state received

**Fields captured**: none (just the event occurrence)

### 5. try_init() in handle_message (line ~674)

**Location**: Top of `Actor::handle_message()` impl  
**Purpose**: Initialize tracing on first message. No-op if `HA_TRACE_FILE` not set.

## State Tracking

The trace module (`tla_trace.rs`) tracks per-node state to emit events only when spec preconditions would be satisfied:

| Field | Initial | Meaning |
|-------|---------|---------|
| `config_received` | false | First config processed → emit `receive_config` |
| `vdpu_received` | false | First vDPU managed → emit `receive_vdpu_state` |
| `haset_received` | false | First haset state → emit `receive_haset_state` |
| `last_dpu_up` | false | Previous DPU health → emit `dpu_health_change` on change |
| `last_desired` | "unspecified" | Previous desired state → emit `change_desired_state` on change |
| `started` | false | True after `start_connecting` → controls `go_to_dead` emission |

## Adding a New Event Type

1. Add an `on_<action>()` function in `tla_trace.rs` following the existing pattern
2. Add the trace call in `ha_scope.rs` (or `dpu.rs`, `ha_set.rs`) at the trigger point
3. Use `if crate::tla_trace::is_active() { crate::tla_trace::on_<action>(...); }` guard
4. Update the patch: `cd artifact/sonic-dash-ha && git diff > ../harness/patches/instrumentation.patch`

## Adding a New Field to an Existing Event

1. Edit the `on_<action>()` function in `tla_trace.rs` to include the new field in the `json!({...})` macro
2. Pass the new data as an additional parameter
3. Update the instrumentation call site in `ha_scope.rs`

## Moving a Capture Point (before → after or vice versa)

1. Move the `if crate::tla_trace::is_active()` block to the new location
2. Ensure the variables needed for the trace call are still in scope
3. For before→after: captured state reflects post-action values
4. For after→before: captured state reflects pre-action values

## Rebuild and Re-run

```bash
# From case-studies/sonic-dash-ha/
bash harness/clean.sh          # Revert previous instrumentation
bash harness/apply.sh          # Apply updated instrumentation
cd artifact/sonic-dash-ha
cargo build -p hamgrd          # Rebuild
HA_TRACE_FILE=../../traces/test.ndjson \
  cargo test -p hamgrd ha_scope_planned_up_then_down -- --nocapture
```

Or use the all-in-one script:
```bash
bash harness/run.sh
```

## Not-Yet-Instrumented Actions (Spec-First)

These actions model HLD-designed behavior not yet implemented in code:

- `send_request_vote`, `handle_request_vote`, `handle_vote_response` — election (#77)
- `become_connected` — peer discovery via BFD
- `handle_bulk_sync_done` — bulk sync
- `initiate_switchover`, `handle_switchover`, `complete_switchover_to_active/standby`, `switchover_failed` — switchover (HLD 8.2)
- `enter_standalone`, `exit_standalone`, `handle_peer_destroying`, `init_to_standby_timeout` — standalone (HLD 10.1)
- `complete_init_to_active` — DPU-driven activation (current code uses `activate_role_pending` but spec requires `haState = InitToActive`)

These require Silent Action wrappers in `Trace.tla` for validation to pass.
