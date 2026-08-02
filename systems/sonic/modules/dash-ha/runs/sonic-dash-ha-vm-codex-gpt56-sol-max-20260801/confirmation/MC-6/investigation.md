# MC-6 investigation

Phase 1 evidence only. Source checkout: `sonic-dash-ha` commit
`f53422a4b5f0de372714fd309d1975ce34445633` (2026-07-28).

## Step 1: code audit

### Counterexample and claimed transition

The supplied TLC output
`spec/output/MC_hunt_scenario5_lifecycle_postfix_bfs.out` contains a real
`Invariant ParentBeforeScope is violated` trace. Its six states are:

1. The HA set and its scope are applied at configuration epoch 1.
2. `MCConsumerBridgeConfigSet("n2", 2)` advances the other node's bridge
   configuration.
3. `MCConsumerBridgeConfigDelete("n1")` removes the parent configuration on
   `n1` while both objects are still applied.
4. A reactive step moves the parent actor to `Deleting`, drops its
   registrations, and queues the HA-set delete while the scope remains applied.
5. The producer-side HA-set delete is pending while the scope remains applied.
6. The producer completes the parent delete (`haSetApplied["n1"] = 0`) while
   `scopeApplied["n1"] = 1`; the child still has the epoch-1 parent cache.

The trace uses ordinary configuration set/delete and reactive/producer steps;
it does not use a modeled fault action.

### Relevant implementation and call chain

- A normal `DASH_HA_SET_CONFIG_TABLE` `Del` reaches
  `HaSetActor::handle_dash_ha_set_config_table_message` at
  `crates/hamgrd/src/actors/ha_set.rs:799`. Lines 807-813 synchronously call
  `do_cleanup` and then stop the parent actor.
- `HaSetActor::do_cleanup` at `ha_set.rs:1041` queues deletion of
  `DASH_HA_SET_TABLE`, the VNET route, and BFD sessions and unregisters the
  parent from its vDPU actors (`ha_set.rs:1049-1062`). It neither sends a
  tombstone/invalidation to registered HA-scope actors nor waits for a child
  acknowledgement.
- `delete_dash_ha_set_table` creates the parent `Del` and sets only the dying
  actor's `dash_ha_set_programmed` field to false (`ha_set.rs:240-259`). That
  local field is not communicated to an already-registered child before the
  actor stops.
- Parent creation takes the opposite path: after issuing the parent `Set`,
  `update_dash_ha_set_table` emits `HaSetActorState` to every registered scope
  (`ha_set.rs:180-225`). There is no corresponding parent-deletion message.
- The actor framework's child-side incoming table is an insert/update-only
  `HashMap` (`crates/swbus-actor/src/state/incoming.rs:11-15,49-57`); no removal
  API is present. Parent actor termination therefore does not erase the last
  `HaSetActorState` stored in the child's incoming table.
- `HaScopeBase::get_haset` reads that stored message solely by key
  (`crates/hamgrd/src/actors/ha_scope/base.rs:111-123`). The NPU state machine
  interprets presence as a guarantee that the parent is programmed
  (`ha_scope/npu.rs:1587-1596`).
- A later normal child event reaches
  `NpuHaScopeActor::update_dpu_ha_scope_table_with_params`; it again accepts the
  cached parent and emits a `DASH_HA_SCOPE_TABLE Set` containing the configured
  `ha_set_id` (`ha_scope/npu.rs:2310-2351`).
- Child cleanup is independently keyed to a `DASH_HA_SCOPE_CONFIG_TABLE Del`
  (`ha_scope/mod.rs:171-187`). Deleting only the parent configuration does not
  execute that path.

The normal-entry call chain is therefore:

`HA-set CONFIG_DB Del -> ConsumerBridge/SWBus message -> HaSetActor config-Del
handler -> do_cleanup -> parent producer Del -> parent actor stop`, while the
independently configured child actor remains live and retains the last parent
state message.

### Reachable trigger scenario

1. Create a normal NPU-driven HA scope whose configuration references an HA
   set, and supply its ordinary vDPU state.
2. Create the referenced HA set and supply global configuration plus both vDPU
   states. The real parent actor emits its `DASH_HA_SET_TABLE Set` and then its
   `HaSetActorState` to the child.
3. Deliver ordinary DPU HA-set state `up`, then `down`, so the real child state
   machine emits an applied `standalone` scope.
4. Delete only the HA-set configuration while leaving the child scope
   configuration present.
5. After the parent producer `Del` completes and the parent actor terminates,
   update the live child configuration. Its normal state-machine path can read
   the cached parent and emit another child `Set`.

No private cleanup method, internal-state mutation, impossible peer message, or
fault injection is needed for this sequence.

### Safeguards and downstream behavior to test in Phase 2

Current downstream sources were inspected at `sonic-swss` commit
`4f3dda156e52ed7647b1dbf900d54d87efaea455` and `sonic-sairedis` commit
`9bd6103824e4590b24fbce2bc014d8902b51eccb` with SAI commit
`c67f1152309ca08a94de0be8634a733c5cb25c35`.

- `DashHaOrch::addHaScopeEntry` resolves the parent HA-set object and supplies
  it as `SAI_HA_SCOPE_ATTR_HA_SET_ID` when creating the scope
  (`sonic-swss/orchagent/dash/dashhaorch.cpp:525-551`).
- SAI declares this attribute as an object-id reference to
  `SAI_OBJECT_TYPE_HA_SET`
  (`SAI/experimental/saiexperimentaldashha.h:240-249`).
- sairedis Meta increments references for object-id attributes on create
  (`meta/Meta.cpp:5971-6012`) and rejects removal of a referenced non-switch OID
  with `SAI_STATUS_OBJECT_IN_USE` (`meta/Meta.cpp:1573-1652`).
- `DashHaOrch::removeHaSetEntry` retains its in-memory parent entry when SAI
  removal fails (`dashhaorch.cpp:370-398`). `handleSaiRemoveStatus` maps
  `SAI_STATUS_OBJECT_IN_USE` to `task_need_retry`
  (`orchagent/saihelper.cpp:734-769`), and the HA-set consumer retains the
  delete task for another attempt (`dashhaorch.cpp:401-463`).

These paths make the concrete questions for reproduction: whether hamgrd emits
the parent delete without invalidating the live child, and whether the actual
Meta reference guard fires for the HA-scope-to-HA-set pair rather than allowing
the underlying parent object to be removed.

## Step 2: developer-knowledge evidence

- [sonic-dash-ha PR #102](https://github.com/sonic-net/sonic-dash-ha/pull/102)
  introduced actor cleanup. Its description assigns HA-set cleanup to removal
  of the HA-set table/route and vDPU unregistration, while HA-scope cleanup is
  separately triggered by its own originator deletion and removes the scope
  table/state plus registrations. It does not describe a parent-to-child
  cascade or acknowledgement barrier.
- [sonic-dash-ha PR #145](https://github.com/sonic-net/sonic-dash-ha/pull/145)
  introduced the NPU-driven scope infrastructure and state machine.
- Commit `1aa2ea834fd5d23cc6dfc156eb611489bde7aba4`, merged as
  [sonic-dash-ha PR #205](https://github.com/sonic-net/sonic-dash-ha/pull/205)
  on 2026-07-14, fixed creation ordering. The PR states that a child must not
  program before its parent, identifies the independent actor/ConsumerBridge
  streams as having no inherent ordering, and makes `HaSetActorState` the
  child's programming acknowledgement. It resets the parent's local
  `dash_ha_set_programmed` flag during deletion, but its changed paths do not
  invalidate an `HaSetActorState` already cached by a live child. The filed bug
  fixed by that PR, buildimage issue 28073, concerns the initial/reboot creation
  path rather than parent cleanup.
- The nearby source comment at `ha_scope/npu.rs:1588-1592` says that presence of
  `HaSetActorState` guarantees the parent entry is programmed. That comment
  documents why a stale message changes child behavior.
- Existing HA-set actor coverage exercises parent cleanup and expects parent
  table/route/BFD deletes plus vDPU unregistrations
  (`ha_set.rs:2394-2409`). It does not run a real surviving scope actor or
  assert child invalidation/acknowledgement before the parent delete.
- [sonic-swss PR #4557](https://github.com/sonic-net/sonic-swss/pull/4557),
  merged 2026-06-10, changes state-DB update behavior when an HA-set entry is
  missing in `DashHaOrch`. It does not change or report hamgrd parent cleanup,
  child cache invalidation, or SAI parent-removal ordering.

## Step 3: known-status and precedent search

Search date: 2026-08-01. GitHub searches covered open issues, closed issues,
open PRs, closed/merged PRs, and recently updated/merged results in
`sonic-net/sonic-dash-ha`, `sonic-net/sonic-buildimage`, and
`sonic-net/sonic-swss`. Queries included:

- `HA set deletion scope`
- `HaSetActorState delete`
- `DASH_HA_SET_TABLE HaScopeActor cleanup`
- `parent HA set delete scope`
- `OBJECT_IN_USE HA Set`
- `DASH_HA_SET_TABLE delete HA scope`

The closest results were PR #205/buildimage issue 28073 (parent-before-child on
creation), PR #206/buildimage issue 28162 (ignoring empty DPU state-table `Del`
notifications), PR #102 (independent actor cleanup), PR #4557 (downstream state
update when a parent lookup is missing), and sonic-swss PR #4566 (generic DASH
retry handling, explicitly excluding HA orchestrators). None reports the same
mechanism at the same site: parent HA-set config cleanup terminating without
invalidating/draining an already-live child scope's cached
`HaSetActorState`.

**Novelty evidence:** `NEW` for this mechanism/site.
