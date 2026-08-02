# MC-3 investigation evidence

## Source and counterexample

- Source: MC. `spec/output/MC_hunt_scenario2_replay_postfix_bfs.out:41` records a real `TermNonRegression` invariant violation.
- The trace creates two legitimate `HaScopeState` messages for the same destination and logical source: State 2 creates request 1 / generation 1 / term 1, and State 3 creates request 2 / generation 2 / term 2 (`...out:165-439`).
- Delivery is reordered. State 4 places request 2 in `inbox[n1]`; State 5 applies it and records `peerGeneration[n1] = 2`, `maxPeerGeneration[n1] = 2`, and `peerTerm[n1] = 2` (`...out:440-725`). State 6 then places the older request 1 in the same inbox; State 7 applies it and records `peerGeneration[n1] = 1`, `maxPeerGeneration[n1] = 2`, and `peerTerm[n1] = 1` (`...out:726-1004`).

## Code audit and call chain

The checkout is commit `f53422a4b5f0de372714fd309d1975ce34445633`, which is also the current upstream `master` returned by `git ls-remote origin`. The worktree has pre-existing Specula trace instrumentation; the product statements below are unchanged from `HEAD`. Where instrumentation shifted a line, both current and `HEAD` locations are noted.

1. A real NPU HA-scope actor constructs `HaScopeActorState` from its persisted local term in `crates/hamgrd/src/actors/ha_scope/npu.rs:1970-2005` (product `HEAD:1854-1889`) and calls `Outgoing::send` for the peer.
2. `crates/swbus-actor/src/state/outgoing.rs:37-50` converts every call into a separate SWBus request. `send_queued_messages` sends and retains every request independently by message ID at `outgoing.rs:98-140` (product `HEAD:75-105`). A successful response removes only that ID (`outgoing.rs:177-209`; product `HEAD:118-140`).
3. If an acknowledgement is lost or delayed, `drive_maintenance_loop` resends each retained raw request after 15 seconds, using the same request ID, at `outgoing.rs:211-281` (product `HEAD:143-183`). Retained requests are a `HashMap<MessageId, ...>` and carry no per-logical-key ordering relationship. They expire only after 60 seconds.
4. The receiving `ActorDriver` reads the normal SWBus request at `crates/swbus-actor/src/driver.rs:48-50`, calls `Incoming::handle_request` at `driver.rs:115`, and then calls the actor's normal `Actor::handle_message` entry point at `driver.rs:155-156,187`.
5. `Incoming::insert` identifies data only by `ActorMessage.key`. Every arrival for an existing key invokes `update_received` (`crates/swbus-actor/src/state/incoming.rs:49-57`), which unconditionally replaces the message, source, and request ID (`incoming.rs:147-154`). `handle_request` performs no duplicate-ID, sender-incarnation, timestamp, term, or sequence check (`incoming.rs:62-72`).
6. `HaScopeActor::handle_message` dispatches through `crates/hamgrd/src/actors/ha_scope/mod.rs:171-219` to `NpuHaScopeActor::handle_message_inner`, which recognizes the state-update key at `npu.rs:173-180` and calls `handle_ha_state_change`.
7. `handle_ha_state_change` decodes the just-overwritten cache entry and unconditionally replaces `peer_ha_state`, timestamp, `peer_term`, and peer ASIC acknowledgement at `npu.rs:749-779` (product `HEAD:708-738`). When the local target is standby, it also copies `peer_term` into `local_target_term` at current lines 772-774 (product `HEAD:731-733`). These values are committed to `STATE_DB/DASH_HA_SCOPE_STATE` by `ActorDriver` at `driver.rs:187-198`.
8. A concrete real consumer uses the regressed `local_target_term`: the disabled-config path invokes `update_dpu_ha_scope_table_with_params` at `npu.rs:1601-1610`, that method copies `local_target_term` into `DashHaScopeTable.ha_term` at `npu.rs:2333-2337` (product `HEAD:2195-2199`), and sends it to the real producer bridge at current lines 2343-2351. `ProducerBridge` accepts every valid request and calls `table.apply_kfv` at `crates/swss-common-bridge/src/producer.rs:46-52`; `ProducerTable::apply_kfv` writes a `Set` at `producer.rs:97-102`.

## Reachability and trigger scenario

All prerequisite states and inputs are reachable through normal interfaces:

1. Configure a switch-owned NPU HA scope, publish its vDPU and HA-set state, exchange heartbeat/vote/bulk-sync messages, receive peer Active term 1, and approve standby activation. The existing public-interface test `ha_scope_npu_launch_to_standby_then_down` performs that sequence at `crates/hamgrd/src/actors/ha_scope/mod.rs:884-1036` and asserts stable Standby with `local_target_term = 1` at lines 1038-1049.
2. The real peer advances and emits an Active state update at term 2. It may previously have emitted term 1 for the same `HaScopeActorState::msg_key(peer_scope_id)`. The HLD explicitly describes Active moving to a new term and Standby matching it.
3. The term-1 request remains eligible for raw resend if its acknowledgement was lost. The public `SimpleSwbusEdgeClient::send_raw` API is explicitly intended for resending with the same ID (`crates/swbus-edge/src/simple_client.rs:152-159`). Delivery of term 2 followed by the retained term 1 is therefore a legitimate adversarial protocol order and exactly instantiates counterexample States 4-7.
4. Both requests pass normal deserialization and actor dispatch. The term-2 arrival commits peer/local term 2. The delayed raw term-1 request then commits peer/local term 1.
5. A normal disabled config update drives the HA scope to Dead. `update_dpu_ha_scope_table_with_params` publishes the now-stale term 1 to `DASH_HA_SCOPE_TABLE`, although the accepted maximum was term 2.

## Safeguards and possible masks

- The SWBus header request ID is retained, but `Incoming` neither remembers handled IDs nor rejects duplicates. Its `version` counter is arrival count only and is not consulted before replacement.
- `HaScopeActorState` contains state, timestamp, and term but no sender incarnation or monotonic sequence (`crates/hamgrd/src/ha_actor_messages.rs:182-235`). The handler does not compare timestamps or terms.
- Responses are emitted by `ActorDriver` before actor processing (`driver.rs:124-156`), so a delivered request may be acknowledged independently of whether a newer logical update exists. A response can also be lost at the transport boundary.
- The 60-second outgoing expiry prevents indefinite memory retention but cannot undo an already delivered stale update or a stale DPU role request.
- Peer heartbeats are connection-establishment/retry or rehydration actions, not a steady-state reconciliation loop (`npu.rs:365-394,2060-2117`). When `peer_connected` is true, the pending connection check only resets a retry counter and sends no heartbeat (`npu.rs:2105-2117`). Open issue [#76](https://github.com/sonic-net/sonic-dash-ha/issues/76) separately proposes an actor timer for updating a local heartbeat field; it does not currently resynchronize peer term.
- Once the disabled-config path emits `DashHaScopeTable { ha_term: 1 }`, the producer bridge immediately applies it. No guard in that path compares the DPU request against the previously accepted maximum term.

## Developer knowledge and intent

- The SONiC SmartSwitch HA HLD, [Primary election section](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md#73-primary-election), states that a larger term means a node knows more flow history and should be preferred; it defines stable Standby as matching the Active side's term. The [clean-launch sequence](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md#811-clean-launch-on-both-sides) says Standby updates its term when it receives Active's state change.
- Open issue [sonic-dash-ha#77](https://github.com/sonic-net/sonic-dash-ha/issues/77) records the intended mechanism: peer HA state and term come from the peer hamgrd, exchanged whenever there is an update. It does not describe accepting an older update after a newer one or a tolerance for regression.
- `git blame` shows the generic outgoing send/resend behavior originated in commits `78b6e35f` and `6b5884cf`; incoming overwrite behavior originated in `78b6e35f`/`dc4758ed`; and the NPU peer-term copy originated in `6b5884cf` (PR #145). No nearby comment documents replay ordering as safe or intentional.
- Existing HA-scope tests exercise increasing terms (for example `mod.rs:884-1049`) and assert the peer term is copied into Standby's local term and then into a DPU update. No existing test delivers an older `HaScopeActorState` after a newer one.

## Known-status and precedent search

Novelty: **NEW**.

Searches covered all open issues, keyword searches across open/closed issues and PRs (`HaScopeActorState`, `peer_term`, `local_target_term`, stale, replay, resend, reorder, duplicate, sequence, incarnation), organization-wide matches, and the recently merged/closed PR list through 2026-08-01. Current upstream `master` equals the tested commit.

Potentially adjacent reports were re-checked and are not the same defect:

- [PR #209](https://github.com/sonic-net/sonic-dash-ha/pull/209) replaces a half-open SWBus connection after peer reconnect; it changes connection-store routing and does not order or deduplicate actor state messages.
- [PR #210](https://github.com/sonic-net/sonic-dash-ha/pull/210) makes a producer bridge replay an unchanged DB write after a DPU reset; it concerns producer-side table caching, not stale peer-state acceptance. Its subsequent revert also does not touch this site.
- [PR #211](https://github.com/sonic-net/sonic-dash-ha/pull/211) prefers a Standalone route candidate over a separately cached stale Active candidate; it changes HA-set route selection, not `Incoming`/`HaScopeActorState` ordering.
- [PR #167](https://github.com/sonic-net/sonic-dash-ha/pull/167) adds the configuration version to NPU `DASH_HA_SCOPE_STATE`; it is not a sender incarnation or message sequence and is not checked on peer-state arrival.
- Issue [#79](https://github.com/sonic-net/sonic-dash-ha/issues/79) concerns the diagnostic `sent_messages` key colliding across destinations and explicitly says that table is troubleshooting-only.

No issue, PR, commit, CVE, or advisory found in the upstream tracker reports the same stale same-key `HaScopeActorState` replay/overwrite mechanism at these sites.
