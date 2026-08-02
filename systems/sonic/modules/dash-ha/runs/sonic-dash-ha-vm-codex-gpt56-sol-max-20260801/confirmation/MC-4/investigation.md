# MC-4 investigation

Phase 1 evidence only; no verdict is made here.

## Finding and counterexample provenance

- Finding: `MC-4`, `CurrentPeerIsolation`, scenario “Peer re-pair while an old peer message is pending”.
- Source classification evidence: the supplied TLC output is a real violation trace, not a no-violation run. It reports `Error: Invariant CurrentPeerIsolation is violated` at `spec/output/MC_hunt_scenario3_repair_postfix_bfs.out:37`.
- Trace sequence:
  - States 2 and 3 create two valid `HaScopeState` messages from `peer-a` to `n1` (`...out:161-435`).
  - State 4 moves one `peer-a` message into `n1`’s inbox (`...out:436-578`).
  - State 5 executes `MCNpuHandleHaSetStateUpdateRePairResolved("n1")`, changes `currentPeer[n1]` to `peer-b`, and leaves the `peer-a` message pending (`...out:579-721`).
  - State 6 dispatches that message and records `peerConnected[n1] = TRUE`, `lastPeerEvent[n1] = "PeerConnected"`, `peerCacheSource[n1] = "peer-a"`, and `foreignApplied[n1] = TRUE` while `currentPeer[n1] = "peer-b"` (`...out:722-864`).
- Implementation checkout: `f53422a4b5f0de372714fd309d1975ce34445633` (`origin/master`). The checkout contains pre-existing Specula trace instrumentation. The relevant production behavior below is also present at `HEAD`; trace-only differences were checked with `git diff` and `git show HEAD:<path>`.

## Code audit

### Relevant sites

- Re-pair: `crates/hamgrd/src/actors/ha_scope/npu.rs:515-620`. `handle_haset_state_update` derives a new peer ID, and on a changed peer replaces `base.peer_vdpu_id` and `base.peer_sp` (`:559-569`). On successful resolution it does not reset `peer_connected`, clear peer-derived fields in `NpuDashHaScopeState`, invalidate pending protocol work, or establish a pairing generation.
- Dispatch: `crates/hamgrd/src/actors/ha_scope/npu.rs:93-260`. Any key for which `HaScopeActorState::is_my_msg` is true is sent to `handle_ha_state_change` (`:173-180`); the key’s actor ID is not compared with the current peer.
- Decode: `crates/hamgrd/src/actors/ha_scope/base.rs:125-136`. `decode_hascope_actor_message` calls `incoming.get(key)` and deserializes only the payload. Although `IncomingTableEntry` stores `source` (`crates/swbus-actor/src/state/incoming.rs:112-129`), this decoder does not inspect it.
- Apply/consumer: `crates/hamgrd/src/actors/ha_scope/npu.rs:749-793`. `handle_ha_state_change` copies the message’s state, timestamp, term, and ASIC-acked role into the durable NPU HA-scope state (`:764-779`) and turns the first such message into `PeerConnected` (`:781-787`). `handle_message_inner` immediately passes that event to `drive_npu_state_machine` (`:256-257`).
- Concrete state-machine consequence: while local state is `Connecting`, `next_state` trusts `peer_connected` and HA-set-up status and transitions to `Connected` (`crates/hamgrd/src/actors/ha_scope/npu.rs:1777-1785`). The transition queues a `VoteRequest` to the currently configured peer (`:1447-1450`) and persists/broadcasts the new local state (`:1638-1671`).
- Maintenance behavior: `check_peer_connection_and_retry` retries only when `peer_connected` is false (`crates/hamgrd/src/actors/ha_scope/npu.rs:2063-2104`). If contaminated state set it true, the scheduled connection check merely resets the retry counter and returns `None` (`:2105-2117`); it does not validate or repair peer identity.

### Public call chain and reachability

1. A peer creates `HaScopeActorState` through `HaScopeActorState::new_actor_msg` (`crates/hamgrd/src/ha_actor_messages.rs:195-219`). Production broadcasts exactly this message to the peer through `broadcast_ha_scope_state` (`crates/hamgrd/src/actors/ha_scope/npu.rs:1970-2006`).
2. `SimpleSwbusEdgeClient::send`/`send_raw` route the request with its source `ServicePath` (`crates/swbus-edge/src/simple_client.rs:145-199`). A distributed transport may retain a message while an HA-set update takes another route and arrives first.
3. `ActorDriver::run` receives each SWBus request (`crates/swbus-actor/src/driver.rs:43-55`). `handle_swbus_message` puts it in `Incoming` and calls the actor (`:82-157`), and `ActorRuntime::spawn` is the normal public actor entry point (`crates/swbus-actor/src/runtime.rs:12-25`).
4. `HaScopeActor::handle_message` selects the NPU variant and delegates to `handle_message_inner` (`crates/hamgrd/src/actors/ha_scope/mod.rs:171-220`), which follows the dispatch/apply chain above. On success, the driver commits internal changes and sends queued outputs (`crates/swbus-actor/src/driver.rs:187-209`).

The exact TLC micro-step “insert into `Incoming`, then process a re-pair request, then dispatch the old key” is not an implementation interleaving: one `ActorDriver` owns the actor/state and awaits insertion and actor handling in one loop iteration (`driver.rs:110-157`). That serialization is a safeguard for the in-table window only. It does not prevent the equivalent admissible distributed ordering: old peer emits a valid state message; the message is delayed in SWBus/network transport; HA-set re-pair is processed; then the old message is delivered and dispatched. No source or pairing-generation check distinguishes the delayed message at that point.

### Natural trigger scenario

1. Configure and launch an NPU-driven HA-scope actor with local vDPU `vdpu0` and current peer `vdpu1`; allow it to reach `Connecting` with the HA set up.
2. The old peer emits a normal `HaScopeActorState` update; transport delays delivery.
3. A normal `HaSetActorState` update replaces `vdpu1` with `vdpu3`, and peer SP resolution succeeds.
4. Transport delivers the already-valid `vdpu1` update from the old peer source.
5. Dispatch accepts it, persists its term/state/acked role, sets `peer_connected`, moves the local FSM to `Connected`, and sends a `VoteRequest` to `vdpu3`. This combines the new configured identity with former-peer protocol state.

Safeguards found for Phase 2 to test: actor-loop serialization prevents only the TLC inbox-level interleaving; eventual state from the new peer could overwrite the cache but is neither guaranteed nor checked before the immediate FSM side effect; the scheduled connection check trusts `peer_connected` and therefore does not correct the contamination.

## Developer-knowledge evidence

- Commit `36e3ff5df067e8087efd5996a884eac05fbf54e9` / [PR #157](https://github.com/sonic-net/sonic-dash-ha/pull/157), “Add support for new DPU pairing in-flight”, introduced the changed-peer branch. Its added test `ha_scope_npu_active_standby_shutdown_then_repair_with_new_peer` exercises an orderly sequence in which only the new peer sends messages after re-pair; it does not test a delayed former-peer message.
- PR #157 review [discussion r3158108179](https://github.com/sonic-net/sonic-dash-ha/pull/157#discussion_r3158108179) says the success path retains `peer_connected` and cached `peer_ha_state`/`peer_term`, and recommends clearing them. Other review comments [r3139783108](https://github.com/sonic-net/sonic-dash-ha/pull/157#discussion_r3139783108) and [r3139783125](https://github.com/sonic-net/sonic-dash-ha/pull/157#discussion_r3139783125) discuss connection reset and stale remote HA-set destinations. These are review observations about retained local caches/routes; none reports acceptance of a delayed former-peer message or missing source/epoch validation as a filed defect.
- [Issue #100](https://github.com/sonic-net/sonic-dash-ha/issues/100) asks what the re-pairing workflow should be, but its filed defect is unhandled config-table `DELETE`; it does not describe this handler/message mechanism.
- [PR #193](https://github.com/sonic-net/sonic-dash-ha/pull/193) added ASIC-acked-role gating at this state machine. It treats `HaScopeActorState` as the peer signal but does not discuss current-source or pairing-epoch validation.
- Recently merged [PR #209](https://github.com/sonic-net/sonic-dash-ha/pull/209) fixes a stale half-open SWBus connection that drops messages after a reboot. That is a different site and opposite transport consequence (messages fail to arrive), not former-peer payload acceptance after re-pair.
- `git blame HEAD` attributes the peer-message decoder/handler to the original NPU-driven infrastructure commit `6b5884cf259b76d3a6155a37d85c65d2817e82cd`; no nearby comment documents former-peer acceptance as intended.

## Known-status / precedent search

- Searched all three pages of the upstream `sonic-net/sonic-dash-ha` issue endpoint: 211 issue/PR entries total, open and closed. Keyword coverage included re-pair/pairing, new/old/former/stale peer, epoch, `HaScopeActorState`, `peer_vdpu_id`, and pending message. The only issue match was #100, which is not the same defect.
- Searched the 100 most recently closed upstream PRs (including merged and closed-unmerged entries). The relevant matches were #157, #193/#198, and #209; none reports this same message-source/generation mechanism. The recent list explicitly included July 2026 merges #211, #210, #209, #208, #205/#207, #203/#204, and #201/#202.
- Searched local commit messages, `git log -S`, blame, current tests, and repository comments/docs for the same terms and sites. No issue/PR/CVE/advisory or filed report of this exact mechanism at this handler was found.
- Novelty evidence: `NEW` (tracker and recently closed/merged PR search completed; no report of this mechanism at this site).

