# MC-5 investigation

## Scope and provenance

- Repository: `sonic-net/sonic-dash-ha`, source SHA `f53422a4b5f0de372714fd309d1975ce34445633` (`origin/master`).
- The checkout already contains uncommitted Specula trace instrumentation. At the affected sites its diff only clones operation IDs and emits trace events after the production updates; the UUID creation, edge detection, Redis rehydration, map merge, approval, and DPU-write behavior investigated below are unchanged from `HEAD`.
- Counterexample: `spec/output/MC_hunt_scenario4_recovery_postfix_bfs.out`. It is a real TLC violation: line 36 reports `Invariant PendingOperationBijective is violated`. State 3 is `MCDpuHandlePendingOperation("n1",1,1)` and has one durable pending operation `{[epoch |-> 1, id |-> 1]}`. State 4 is `MCCrash("n1")`; it preserves that pending operation while resetting `cachedPendingFlagEpoch[n1]` from 1 to 0. State 5 restarts/reactivates the process. State 6 is `MCDpuHandlePendingOperation("n1",1,2)` and contains two IDs for epoch 1: `{[epoch |-> 1, id |-> 1], [epoch |-> 1, id |-> 2]}`.

## Step 1: code audit

### Relevant implementation

- `crates/hamgrd/src/actors/ha_scope/base.rs:21-49`: `HaScopeBase::dpu_ha_scope_state` is the previous-DPU-state edge cache, and every fresh actor initializes it to `None`.
- `crates/hamgrd/src/actors/ha_scope/mod.rs:171-218`: normal actor dispatch initializes the DPU-driven variant from a `DASH_HA_SCOPE_CONFIG_TABLE` Set and then dispatches DPU state messages to that variant.
- `crates/hamgrd/src/actors/ha_scope/dpu.rs:87-127`: after a managed-vDPU update, the actor attaches an internal `NpuDashHaScopeState` entry and subscribes to the DPU `DASH_HA_SCOPE_STATE_TABLE`.
- `crates/swbus-actor/src/state/internal.rs:114-135`: `InternalTableEntry::new` rehydrates the internal entry by reading the existing row from Redis. Thus the NPU pending-operation list survives an actor/process crash.
- `crates/swss-common-bridge/src/consumer.rs:133-135,217-245`: a newly spawned consumer bridge sends the table's initial/rehydration records to the actor. A DPU flag that remains asserted is therefore delivered normally after restart; no synthetic message is needed.
- `crates/hamgrd/src/actors/ha_scope/dpu.rs:149-182`: the DPU update handler compares the incoming flags to `dpu_ha_scope_state.unwrap_or_default()`. For each false-to-true comparison it creates a fresh v4 UUID. Because a fresh actor's cache is `None`, a still-true rehydrated flag compares against default `false` and creates another UUID.
- `crates/hamgrd/src/actors/ha_scope/base.rs:445-493`: `update_npu_ha_scope_state_pending_operations` rehydrates the existing ID/type pairs, removes only explicitly approved UUIDs, and inserts every new pair keyed only by UUID. It performs no operation-type or DPU-generation reconciliation, so the fresh UUID is appended beside the persisted UUID.
- `crates/hamgrd/src/db_structs.rs:458-463,526-533`: the UUID/type lists are fields of `STATE_DB/DASH_HA_SCOPE_STATE`, the durable/public NPU state row.

### Call chain and reachability

Normal path: CONFIG_DB HA-scope Set -> `HaScopeActor::handle_message` -> DPU variant -> managed vDPU and HA-set state updates -> attach/rehydrate `STATE_DB/DASH_HA_SCOPE_STATE` and subscribe to DPU state -> DPU writes `activate_role_pending=true` -> consumer bridge calls `handle_dpu_ha_scope_state_update` -> fresh UUID is added to the NPU state row.

Crash/recovery path: abort/kill hamgrd without its config-delete cleanup -> Redis retains both the DPU `true` flag and NPU UUID row -> start a fresh actor from the same config -> managed-vDPU initialization reads the NPU row and a fresh DPU consumer bridge replays the still-true DPU row -> the volatile cache is default-false -> the handler appends a second UUID for the same asserted flag. This is a real API/normal-operation sequence and instantiates the counterexample's pending edge -> crash -> restart -> replayed pending edge sequence.

Concrete trigger for Phase 2:

1. Start the normal Redis-backed actor runtime and create a DPU-owned HA scope through its Swbus actor interface.
2. Deliver valid HA-set and managed-vDPU actor state, causing the production DPU-state consumer and persistent NPU state entry to be created.
3. Write a valid DPU `DASH_HA_SCOPE_STATE_TABLE` record with all pending flags false, then update `activate_role_pending` to true. Wait for the public NPU `DASH_HA_SCOPE_STATE` row to expose exactly one `activate_role` UUID.
4. Abort the actor task (unplanned crash, so `do_cleanup` is not called); leave both Redis rows unchanged.
5. Spawn a fresh `HaScopeActor` for the same scope and replay the same legitimate config/HA-set/vDPU startup inputs. The production DPU consumer rehydrates the still-asserted flag while the internal table rehydrates the old UUID.
6. Read the NPU `DASH_HA_SCOPE_STATE` row. Correct/idempotent recovery would retain one UUID; the suspected path produces two distinct UUIDs with two `activate_role` types for the one live flag.
7. Keep the same flag asserted and observe the row over a bounded settling period; then approve one ID and clear the DPU flag. Approval removes only that selected UUID, so the other remains advertised and can drive a second DPU action if separately approved.

### Consumers and safeguards

- `crates/hamgrd/src/actors/ha_scope/dpu.rs:99-100` identifies the NPU `DASH_HA_SCOPE_STATE` entry as the notification channel to the SDN controller. Duplicate UUID/type pairs are therefore externally visible state, not an unobserved local variable.
- `crates/hamgrd/src/actors/ha_scope/dpu.rs:64-79` consumes controller-approved UUIDs, and `dpu.rs:216-241` maps each approved UUID back to an operation type. `dpu.rs:244-273` emits the resulting request flags in the DPU `DASH_HA_SCOPE_TABLE`, making the DPU a second real consumer of each independently approved duplicate.
- Within one actor lifetime, the cached true flag prevents duplicate creation on an unchanged update. The cache is the only edge safeguard found and is lost on restart.
- Approval cleanup is UUID-specific (`base.rs:466-475`). A falling DPU pending flag updates HA-state fields but does not remove pending UUIDs. No periodic sync, loopback, resend, type-deduplication, or caller guard was found that automatically collapses or removes the leftover duplicate.
- Config deletion calls `do_cleanup` and deletes the NPU row (`base.rs:361-368`), but an unplanned process crash does not execute this cleanup and is the documented recovery case.

## Step 2: developer-knowledge evidence

- The original implementation was introduced by commit `6b5884cf259b76d3a6155a37d85c65d2817e82cd` / PR #145. Its restart comment remains at `dpu.rs:158-161`: a restart deliberately treats pending flags as new, but says a request already notified before restart should cause "no change" to the NPU state and no controller action. Fresh UUID insertion contradicts that stated idempotence premise.
- Commit `34cbd69281e4059e316a8dd6f87630c0210d9429` / merged PR #159 added NPU-driven crash rehydration. Current `npu.rs:1335-1340` states that rehydration side effects are idempotent, and `npu.rs:1371-1374` explicitly says not to re-create a pending operation during recovery.
- PR #159 inline review comment `https://github.com/sonic-net/sonic-dash-ha/pull/159#discussion_r3164967547` identified that generating a new UUID at the NPU `apply_rehydration_side_effects` site was non-idempotent and could break an in-flight approval. The merged implementation avoids re-creation at that NPU site. This is strong intent/precedent evidence, but it is a different producer site from the DPU flag-edge handler under investigation.
- Existing DPU-driven tests in `crates/hamgrd/src/actors/ha_scope/mod.rs:251-538` cover a normal false-to-true DPU pending flag, one generated UUID, controller approval, and flag clearing. They do not restart the DPU-owned actor while the flag stays true. The crash-rehydration unit test at `mod.rs:2699-2850` is NPU-driven and does not exercise `dpu.rs:149-182`.

## Step 3: known-status / precedent evidence

- Queried the upstream GitHub tracker across open and closed issues/PRs, including recently merged/closed work through PR #210, using terms covering `pending_operation_ids`, `activate_role_pending`, pending operation + crash/restart, UUID duplication, and DPU-driven rehydration. Also inspected local all-ref git history for pending-operation/restart/crash/rehydration changes.
- PR #159 is a same-shape precedent at the NPU rehydration producer, not the same DPU flag-edge cache site. Its files are limited to `npu.rs` and NPU tests; it neither reports nor repairs `dpu.rs:149-182`.
- Merged PR #210 (`https://github.com/sonic-net/sonic-dash-ha/pull/210`) fixes producer-bridge suppression of identical writes after a DPU control-plane reset. It does not address UUID identity, the DPU pending-flag edge cache, or the persisted pending-operation map.
- Closed issue #123 (`https://github.com/sonic-net/sonic-dash-ha/issues/123`) reports DPU state becoming out of sync after DPU restart due to leftover DPU_STATE_DB entries, but gives no pending-operation UUID mechanism and is at a different state/site.
- No upstream issue, PR (open, closed, or recently merged), or local git-history entry found reports the same volatile DPU pending-flag edge cache plus durable UUID-map duplication mechanism at `dpu.rs:149-182` / `base.rs:445-493`.
- Known-status evidence therefore supports `Novelty: NEW` for this site/mechanism. This is not a Phase-1 verdict.
