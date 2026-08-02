# MC-2 Phase 1 investigation

## Evidence scope

- Source checkout: `f53422a4b5f0de372714fd309d1975ce34445633` (`master`, identical to `origin/master` as checked with `git ls-remote` on 2026-08-01).
- The checkout already contains uncommitted Specula trace instrumentation. The affected route-selection logic itself is committed upstream; `git blame` attributes the cache/selector to `33d17dd`, `0ae944c`, and `f53422a`. The instrumentation-only `writer` argument and trace emits were treated as non-production provenance and were not used to establish reachability.
- Counterexample inspected: `spec/output/MC_hunt_scenario6_route_postfix_bfs.out`. TLC reports a real `RouteMatchesAckedOwner` violation. Its six-state trace sends `HaScopeState(Active, term=2, ackedRole=Dead)`, delivers/caches it, executes `MCHaSetComputeRouteFromReplay` at State 5, then reaches State 6 with `routeOwner=n1`, `routeTerm=2`, but `ackedTerm[n1]=1` and `ackedPairEpoch[n1]=1`.

## Step 1: code audit

### Relevant code and data flow

- `crates/hamgrd/src/ha_actor_messages.rs:183-216` defines `HaScopeActorState`. The normal message explicitly carries `new_state`, `term`, `vdpu_id`, `peer_vdpu_id`, and `acked_asic_ha_state`.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:1510-1525` orders an `Active` transition by incrementing the target term and issuing the `DASH_HA_SCOPE_TABLE` Active-role request. Then `drive_npu_state_machine` stores the logical state and broadcasts it at `crates/hamgrd/src/actors/ha_scope/npu.rs:1637-1646`, before a DPU acknowledgement is required.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:1970-2005` builds that broadcast from the logical state/current target term and independently copies the last `local_acked_asic_ha_state`. Thus a normal sender can emit logical `Active` for a new term while the carried ASIC acknowledgement is still `dead`, `standalone`, or otherwise stale.
- The acknowledgement arrives on a separate input. `crates/hamgrd/src/actors/ha_scope/npu.rs:623-663` updates `local_acked_asic_ha_state` and `local_acked_term` only upon `DPU_HA_SCOPE_STATE`, then broadcasts again.
- `crates/hamgrd/src/actors/ha_set.rs:74-78` defines `CachedHaScopeState` with only `new_state`, `vdpu_id`, and `peer_vdpu_id`. `crates/hamgrd/src/actors/ha_set.rs:537-552` drops the incoming `term` and `acked_asic_ha_state` while caching.
- `crates/hamgrd/src/actors/ha_set.rs:601-672` selects the unique logical `Active` scope as primary (after the recently-added Standalone precedence) without checking acknowledged role, acknowledged term, timestamp, source generation, or pairing epoch.
- The normal actor entry point is `crates/hamgrd/src/actors/ha_set.rs:1075-1099`; it dispatches every valid `HaScopeActorState` to `handle_ha_scope_state_update`. That handler caches/selects and emits a route write at `crates/hamgrd/src/actors/ha_set.rs:996-1029`.
- `update_vnet_route_tunnel_table` serializes the chosen primary and sends it to the production bridge at `crates/hamgrd/src/actors/ha_set.rs:262-364`. `VnetRouteTunnelTable` is the APPL_DB `VNET_ROUTE_TUNNEL_TABLE` at `crates/hamgrd/src/db_structs.rs:352-369`.
- The real consumer is `ProducerBridge`: `crates/swss-common-bridge/src/producer.rs:46-52` deserializes and applies the `KeyOpFieldValues`, and `crates/swss-common-bridge/src/producer.rs:97-114` invokes the table's asynchronous `set`. `crates/hamgrd/src/main.rs:146-174` starts this bridge for `VnetRouteTunnelTable` in production.

### Call chain and normal reachability

Normal sequence:

1. Configuration/VDPU updates create an NPU-owned HA set and make both vDPUs available to `HaSetActor` (`HaSetActor::handle_message`).
2. The real `NpuHaScopeActor` reaches `PendingActiveActivation -> Active` after an approved activation, or `SwitchingToActive/Standalone -> Active` after the peer control-plane and peer ASIC gates are satisfied (`npu.rs:1818-1823`, `1892-1900`, or `1924-1933`).
3. `apply_pending_state_side_effects` increments the term and enqueues the local ASIC Active request (`npu.rs:1510-1525`).
4. Without waiting for that local ASIC request to be acknowledged, `drive_npu_state_machine` commits logical `Active` and calls `broadcast_ha_scope_state` (`npu.rs:1637-1646`). The broadcast legitimately contains `new_state=Active`, the new target term, and the previous local ASIC-acked role (`npu.rs:1970-2005`).
5. The HA-set actor receives this ordinary actor message through its normal swbus entry, caches only the logical fields, selects the sender vDPU as route primary, and sends `VNET_ROUTE_TUNNEL_TABLE` to the bridge (`ha_set.rs:996-1029`, `262-364`).
6. `ProducerBridge` applies the route to APPL_DB (`producer.rs:46-52`, `97-114`).

This also instantiates the counterexample's admissible State 2 message and State 5 replay/route-compute step. No illegal internal state or private selector call is needed.

### Safeguards and later mechanisms found

- The selector requires at least two configured vDPUs, at least one reported scope state, and available VDPU data (`ha_set.rs:601-617`, `678-701`). Route serialization also requires a managed local DPU (`ha_set.rs:269-276`). None compares logical state with the carried acknowledgement/term.
- PR #211 changed ordering so one logical Standalone beats a cached logical Active. That guard covers the Standalone-versus-stale-Active case, but it does not cover a unique Active update whose own acknowledged role/term is stale.
- A later real DPU acknowledgement causes `NpuHaScopeActor` to broadcast again (`npu.rs:623-663`). The HA-set actor still ignores the acknowledgement and rewrites the same logical route; there is no consumer-side hold/reject guard. Until such an external acknowledgement or a later scope/config/cleanup event, the premature APPL_DB route remains installed.
- `ProducerBridge` applies the write unconditionally. No downstream filter was found in this repository that checks HA acknowledged ownership before applying `VNET_ROUTE_TUNNEL_TABLE`.

## Step 2: developer-knowledge evidence

- Merged PR #193, <https://github.com/sonic-net/sonic-dash-ha/pull/193>, states that logical peer state can lead/lag the role actually committed by hardware and calls the ASIC-acked role the authoritative gate. It added `acked_asic_ha_state` to `HaScopeActorState`, but changed the HA-scope state machine, not the HA-set route selector/cache.
- Merged PR #201, <https://github.com/sonic-net/sonic-dash-ha/pull/201>, states that control-plane and ASIC-ack views must both agree before role-sensitive HA-scope transitions. Its site is also the HA-scope state machine.
- Merged PR #211, <https://github.com/sonic-net/sonic-dash-ha/pull/211>, reports a same-file route-selection bug where a cached peer Active could beat a newer local Standalone. It fixed only precedence of Standalone over Active and added tests; it did not retain or validate acked role, acked term, timestamp/generation, or pairing freshness.
- Existing test `crates/hamgrd/src/actors/ha_set.rs:1599-1819` asserts that an ordinary logical `Active` `HaScopeActorState` immediately produces a VNET route with that vDPU primary. It does not supply or assert an ASIC acknowledgement. Existing HA-scope tests around `crates/hamgrd/src/actors/ha_scope/mod.rs:1338-1359` demonstrate the sender advancing and broadcasting logical Active immediately after issuing the Active-role request.
- No nearby comment documents route-before-local-ASIC-ack as an accepted behavior. The strongest stated design intent found points the other way: hardware acknowledgement is authoritative for role-sensitive progress.

## Step 3: known-status / precedent

- Search performed on 2026-08-01 over all 10 open issues, the sole open PR, the 100 most recently updated closed issues, the 100 most recently updated closed PRs, PR discussion/review comments for #193 and #211, and local `git log`/`git blame` history. Search terms included `VNET route`, `VnetRouteTunnelTable`, `route selector`, `stale active`, `acked_asic_ha_state`, `ASIC`, and `acked`.
- Related precedents were #193/#201 (same agreement principle, different state-machine site) and #211 (same route-selector site, different Standalone-precedence defect). Issues/PRs #175, #179, and #180 concern endpoint construction or missing route installation, not route eligibility before ASIC acknowledgement.
- No issue, merged/closed PR, or reviewed change found reports this exact mechanism at this site: `HaSetActor` discarding the already-carried acked role/term and selecting/programming an unacknowledged logical Active owner.
- Novelty evidence: `NEW` based on the tracker and git-history search above. Per the task constraint, no other Specula finding/report/dataset files were opened.

Phase 1 records evidence only; Phase 2 will determine the verdict after executing a reproduction.
