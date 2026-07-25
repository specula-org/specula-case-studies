# SONiC — Findings from a Specification-Driven Review

These are findings from a Specula run on SONiC. Specula is a TLA+-based pipeline that drives code analysis, spec generation, and trace-validated model checking against a target system; the SONiC run covered `sonic-swss` (orchagent and the sibling daemons under the swss umbrella), `sonic-sairedis` (syncd), and three protocol daemons — iccpd (MCLAG), linkmgrd (active-active mux), and hamgrd (DASH HA).

Findings are split into three parts:

- **Part I — Reliability and correctness.** Cases where SONiC components diverge from what nearby code or the spec appears to assume, in ways that could leave software and hardware state desynchronized, drop legitimate updates, or accumulate stale resources.
- **Part II — Availability.** Cases where a protocol path or a warm-reboot path fails in a way that takes a daemon out of service, blocks recovery, or makes the device data plane unreachable.
- **Part III — Independently rediscovered.** Cases that already have an open PR or issue upstream; we mention them because the same model checking run independently flagged the path.

All file paths are relative to the named repository unless noted; line numbers reference each repository's main branch at the time of review. Reproduction status is noted per cluster: `repro-real` for tests that drive the actual buggy function with the consequence observed (some additionally compile under AddressSanitizer); `repro-partial` for tests that drive the buggy code path but where the consequence is inferred; `model-only` for findings that are reasoned from spec and source.

**The orchagent and warm-reboot findings appear first in each part, per the recipient's focus.**

---

## Part I — Reliability and correctness

### Cluster A — `FdbOrch` ↔ `PortsOrch` event ordering (orchagent)

`FdbOrch` and `PortsOrch` jointly maintain the bridge-port → alias mapping and the in-memory `m_entries` FDB table. Three independent gaps in the FDB removal and flush paths cause `m_entries` to fall out of sync with the ASIC, with no reconciliation path. Each finding lives in a different function, but they share a shape: a removal step happens before an asynchronous SAI notification, and the notification handler does not tolerate the resulting transient.

**A.1 — `removeBridgePort` clears `saiOidToAlias` before the SAI flush completes**
*Files:* `sonic-swss/orchagent/portsorch.cpp:7346, 7368-7369` and `sonic-swss/orchagent/fdborch.cpp:315-343`.

`removeBridgePort()` issues `flushFDBEntries(bridge_port_id)` (an asynchronous SAI call) at line 7346, removes the bridge port at line 7357, and erases `saiOidToAlias[bridge_port_id]` at line 7368. Between step (1) and the deferred `SAI_FDB_EVENT_FLUSHED` callback, the ASIC may continue to report `LEARNED`, `AGED`, and `MOVE` events on the now-erased OID. `FdbOrch::update` (fdborch.cpp:315-343) tolerates `FLUSHED` for an unknown OID — it logs and continues — but for any other event type it logs an error and returns silently. Events the ASIC actually delivered are dropped on the floor, and `m_entries` ends up permanently inconsistent with the ASIC. There is no later reconciliation path. The `is_flush_pending` plumbing on the FLUSHED branch shows the author was aware of this window for the flush case; the gap is that the same tolerance is not extended to the other event types.

This finding has a strong field signal: `sonic-buildimage#26531` reports a 75-minute production traffic blackhole with 1046 dropped FDB events triggered by LAG transitions, currently UNFIXED. `#13069`, `#7538`, `sonic-swss#290`, and `sonic-swss#304` describe the same family of "bridge port remove leaves entries behind." A targeted gtest exists at `tests/mock_tests/flush_syncd_notif_ut.cpp` (`ConsolidatedFlushVlanandPortBridgeportDeleted`), but it manually sets `is_flush_pending=true` rather than exercising the race — the race itself is untested. (`model-only` — reproduction is a Python state-machine model.)

**A.2 — `flushFdbByVlan` does not set `is_flush_pending`**
*File:* `sonic-swss/orchagent/fdborch.cpp:1256-1290`.

`flushFdbByVlan()` issues a VLAN-scope flush to SAI but, unlike its sibling `flushFDBEntries()` (line 1242-1253), does not iterate `m_entries` to mark `is_flush_pending=true` before issuing the flush. When `handleSyncdFlushNotif()` (line 227-295) receives the FLUSHED notification, it strictly requires `is_flush_pending` and skips entries that are not marked. The result is that VLAN-scope flushes leave phantom entries in `m_entries` (software has them, hardware does not); subsequent `LEARNED` events on the same MAC are dropped as duplicates, and `m_fdb_count` monotonically grows. `git blame` traces `flushFdbByVlan()` to PVST PR #3425 (commit `5a8d403d`), which postdates the `is_flush_pending` mechanism (commit `8dae3564`) — the new function landed without picking up the existing convention. `sonic-swss#4428` ("VLAN flush does not work") points at the same path. (`model-only`.)

**A.3 — `clearFdbEntry` (FLUSH path) does not call `notifyTunnelOrch`**
*File:* `sonic-swss/orchagent/fdborch.cpp:200-222`.

The three FDB removal paths in `fdborch.cpp` are asymmetric: AGED (line 591) calls `notifyTunnelOrch`, DEL (line 1906) calls it, and FLUSH (line 218, inside `clearFdbEntry`) does not. `notifyTunnelOrch` is the only trigger point for `VxlanTunnelOrch::deleteDynamicDIPTunnel()` — the `fdb_count → 0` cleanup of dynamic DIP tunnels. When FDB entries are removed via FLUSH, the corresponding dynamic DIP tunnel never has its `fdb_count` decremented and is never freed; the matching SIP tunnel is then stuck in `del_tnl_hw_pending` because `getDipTunnelCnt() > 0`. `sonic-buildimage#12361` reports warmboot stuck on VXLAN cleanup — the same tunnel-leak symptom — currently UNFIXED. Commits `750e0649` and `867e355b` previously attempted EVPN NVO ordering changes here and were reverted, indicating the area is fragile. (`model-only`.)

The natural fix for all three is small and mechanical (mirror what the sibling functions already do), but they are worth treating as a cluster: any one in isolation can be argued away as a corner case, while the three together describe a systematic gap in how `FdbOrch` accounts for asynchronous SAI events.

### Cluster B — Warm-reboot reconciliation in swss (orchagent)

Three findings on the warm-reboot reconciliation path inside `sonic-swss`. They are not all in `orchdaemon.cpp`, but they all run during the orchagent-led warm-reboot phase, and they all leave software state misaligned with what the rest of the system has been told.

**B.1 — `AppRestartAssist::contains()` is a one-way subset check**
*File:* `sonic-swss/warmrestart/warmRestartAssist.cpp:198, 339-352`.

The reconcile cache decides whether a replayed entry is `SAME` or `NEW` by calling `contains(found->second, fvVector)`. The helper checks "every element of `right` is in `left`" — i.e., "is `new` a subset of `old`?" When a post-reboot replay has a field *removed* from the pre-reboot cached entry (an interface moved out of a VRF, a route changed from multipath to single-path, a nexthop attribute removed), `contains(old, new) = true` and the cache treats the entry as `SAME`, keeping the old value. Reconcile then re-applies the old field-set to AppDB, resurrecting the deleted field. The `add field` and `change value` cases work correctly — only the `remove field` case is silently absorbed.

The natural fix is bidirectional: `if (!contains(old, new) || !contains(new, old))`, restoring the symmetric behavior `std::equal()` had before commit `f3d0279a` (2019-06) replaced it. The 2019 commit comment explained the reorder-tolerance motivation but did not flag that the new helper had become unidirectional. (`repro-real` — gtest in `mock_tests` driving the real `AppRestartAssist::insertToMap()`.)

**B.2 — Ring buffer fields are not atomic, and `warmRestartCheck` ignores the ring buffer**
*Files:* `sonic-swss/orchagent/orchdaemon.cpp:1014-1026, 1178-1209` and `sonic-swss/orchagent/orch.h:200-206`.

Two related issues in the same buffer. First, the ring-buffer state (`int head`, `int tail`, `bool idle_status`) is read and written from both the consumer (main) thread and the producer thread without any `std::atomic` or fencing. On x86 the single-word loads and stores are hardware-atomic, but the C++ memory model still permits compiler reorderings; on the ARM-based platforms used by some SmartSwitches and DPUs this becomes observable. Second, `warmRestartCheck()` calls `getTaskToSync(ts)` against the consumer queue only (line 1186) and decides READY based on `ts.size() != 0` (line 1188) — it does not look at the ring buffer that sits between the producer and consumer. Events still in the ring buffer when READY is sent are processed in the drain loop at lines 1014-1026, which runs *after* `warmRestartCheck` returns. The window between READY and drain-completion is the window in which an external warmboot orchestrator can begin its snapshot/freeze sequence; events processed after READY can be missed.

The atomic fix is mechanical (`int → std::atomic<int>`, `bool → std::atomic<bool>`). The READY-before-drain fix moves the READY notification to after drain and freeze, so the contract "READY means no unprocessed events" actually holds. We suggest splitting them into separate PRs because they have very different review profiles; PR #2471 and commit `2b02c249` show the area is actively maintained. (`repro-real` for both — gtests using the actual `RingBuffer` class.)

**B.3 — `Syncd::applyView` Stage 2 is non-atomic and `syncd_apply_view()` is `void`**
*Files:* `sonic-sairedis/syncd/Syncd.cpp:4904-4909` (with a documented design note at `:4797-4799`); `sonic-swss/orchagent/orchdaemon.cpp:34, 1123, 1134`.

Stage 2 of `applyView` first executes operations on the ASIC (line 4906) and then updates Redis (line 4909). The window between the two is unprotected: any termination of syncd in that window (`kill -9`, OOM, segfault) leaves the ASIC at the new view and Redis at the old one. The next warm reboot computes its diff against stale Redis content, so the operation set it produces is wrong — extra deletes, missing adds, mismatched attributes. The author flagged the issue at line 4797-4799: *"Second stage is destructive, so if there will be bug in comparison logic or any asic operation will fail, then syncd will crash, since asic will be in inconsistent state."* That is a documented design assumption rather than an oversight; the assumption holds only if syncd is the *only* process that can fail in Stage 2, and a kernel OOM kill or a process-supervisor `SIGTERM` is sufficient to break it.

The companion gap on the orchagent side is that `syncd_apply_view()` is declared `void` and called without `try/catch`, followed by an unconditional `setWarmStartState(RECONCILED)` at line 1134. Whether `applyView` succeeded, threw, or wrote half a view, orchagent declares the warm reboot reconciled. Changing the signature to `sai_status_t` and gating RECONCILED on success are both small. The Stage 2 atomicity question is harder and we treat it as a design discussion rather than a PR proposal. (`repro-partial` — the orchagent-side `void` signature is exercised; the cross-process Stage 2 race is reasoned from source and the author's own comment.)

### Cluster C — iccpd (MCLAG) FSM and parsing

Five point-level reliability findings in the MCLAG ICCP daemon. They are independent but all touch the same ICCP processing surface and we mention them together. C.1 is the most consequential — the FSM transition into a non-recoverable state — and we lead with it.

**C.1 — `mlacp_sync_send_all_info_handler` advances `current_state` unconditionally**
*File:* `sonic-buildimage/src/iccpd/src/mlacp_fsm.c:1377` (and call site `:570`).

The MCLAG FSM uses `INIT=0, STAGE1=1, STAGE2=2, EXCHANGE=3, ERROR=4`. `mlacp_sync_send_all_info_handler` ends in `MLACP(csm).current_state++` — correct when called at STAGE2 to advance to EXCHANGE. The same handler is also reached from `mlacp_sync_recv_syncReq` (line 570) when a peer in EXCHANGE issues a re-sync (commonly after a NAK with `need_to_sync = 1`). The increment fires there too, advancing EXCHANGE → ERROR. ERROR has no recovery path; the FSM is wedged until the keepalive times out the session (~30s default) and a fresh session is established. The natural fix is one line at 1377: increment only when `current_state < EXCHANGE`. (`repro-real` — two-peer C harness drives the real FSM into ERROR.)

**C.2 — `mac_age_flag` checks the wrong variable**
*File:* `sonic-buildimage/src/iccpd/src/mlacp_link_handler.c:2843, 2860, 2849, 2865`.

In `do_mac_update_from_syncd`, four lines reference `mac_msg` — the syncd-event stack struct, `memset(0)` at line 2691, whose `age_flag` is therefore always zero — where they should reference `mac_info`, the entry stored in the per-CSM RB tree that carries the peer's aging state. `!(0 & MAC_AGE_PEER)` is constantly true, so the deletion guard "do not delete if the peer hasn't aged" is not enforced. Other paths in the same function reference `mac_info->age_flag` correctly; the four buggy lines are isolated outliers consistent with a copy-paste from the wrong struct. This matches the symptom in `sonic-buildimage#17606` ("MAC inconsistency between ICCPD and chip"). The fix is a four-line literal substitution. (`repro-real`.)

**C.3 — NAK TLV pointer arithmetic**
*File:* `sonic-buildimage/src/iccpd/src/iccp_csm.c:649, 661`.

`NAKTLV* nak = (NAKTLV*)(icc_hdr + sizeof(ICCHdr));` — `icc_hdr` is `ICCHdr*`, so C scales the offset to `16 × sizeof(ICCHdr) = 256` bytes rather than the intended 16. The correct expression is `(NAKTLV*)((char*)icc_hdr + sizeof(ICCHdr))`. Whatever sits at offset 256 in the receive buffer is parsed as a NAK status code; in our reproduction we observe the function logging `"ICCP Rejected Message"` for a payload that had `STATUS_CODE_ICCP_RG_REMOVED` at the correct offset. The same line is followed by a `sleep(1)` that blocks the entire single-threaded scheduler for a full second, which is a separate issue worth flagging as cleanup. (`repro-real` with `--wrap` syslog interception.)

**C.4 — NDISC self-comparison (copy-paste)**
*File:* `sonic-buildimage/src/iccpd/src/iccp_ifm.c:574-575`.

The NDISC update detector compares `ndisc_info->op_type != ndisc_info->op_type`, with the same self-comparison pattern for `ifname` and `mac_addr`. All three comparisons are constantly false, `neigh_update` never reaches 1, and the code path that copies `ndisc_msg->mac_addr` over `ndisc_info->mac_addr` is unreachable. IPv6 neighbor updates from the peer are silently discarded. The ARP handler in the same file is the correct shape and serves as the reference; the right-hand side should be `ndisc_msg->*` everywhere. (`repro-real` — `objcopy --globalize-symbol` exposes the static function and a synthetic `ndmsg`/`rtattr` array drives it under ASan.)

**C.5 — `set_mac_local_age_flag` and `mlacp_sync_mac` disagree on EXCHANGE re-entry**
*Files:* `sonic-buildimage/src/iccpd/src/mlacp_link_handler.c:1720` and `sonic-buildimage/src/iccpd/src/mlacp_fsm.c:1017-1056`.

When a MAC ages locally, `set_mac_local_age_flag` only enqueues a DEL to the peer when `current_state == EXCHANGE`. In any other state (session reconnecting, INIT/STAGE1/STAGE2, ERROR) it sets `MAC_AGE_LOCAL` on the local entry and stops. That guard is correct as far as it goes — sync messages cannot be sent during handshake. The companion responsibility on EXCHANGE re-entry is to compensate, and `mlacp_sync_mac` (the EXCHANGE-entry FDB resync function) does walk the RB tree, but the `MAC_AGE_LOCAL` branch (lines 1041-1052) only logs and does not enqueue a DEL. The peer's FDB therefore retains the entry until its own hardware aging timer (~5 minutes) fires.

The resync function is exactly the right place to compensate; the fix is a few lines in the `MAC_AGE_LOCAL` branch to enqueue `MAC_SYNC_DEL`, preserving the existing `peer_itf_name` skip. We flag one open question for the maintainer: lines 1022-1025 carry a comment about warm-reboot semantics for the LOCAL flag that we want to make sure the fix does not regress. (`repro-partial` — write-side guard miss is observed; the EXCHANGE-re-entry compensation gap is reasoned from source.)

### Cluster D — linkmgrd Active-Active state machine

Two findings in `LinkManagerStateMachineActiveActive.cpp`. Both touch the `(LinkProber, MuxState, LinkState)` transition table, but they are different shapes of error.

**D.1 — Missing transition handlers for `{LPWait, MuxError, LinkUp}` (and family)**
*File:* `sonic-linkmgrd/src/link_manager/LinkManagerStateMachineActiveActive.cpp:653-774`.

The `initializeTransitionFunctionTable` block registers entries only for `LP ∈ {Active, Unknown}`. The `LP=Wait` row is empty across the table. When a startup-time mux reports `Error` before the first ICMP heartbeat lands, the composite state is `(LPWait, MuxError, LinkUp)`, the lookup falls through to the base-class `noopTransitionFunction`, and neither `startMuxProbeTimer()` nor `setMuxState()` is called. Recovery depends on a subsequent heartbeat pulling LP out of `Wait` — but a mux in `Error` is not necessarily a context where ICMP probes complete. There is also a copy-paste artifact at line 703 (`[Active][Unknown][Up]`) that duplicates line 676; the cell the author likely intended is the missing `[Unknown][Error][Up]`. The same family has been accepted upstream three times (#169, #175, #178), each time fixing a different missing cell. (`repro-real` — gtest in the linkmgrd test suite.)

**D.2 — Forwarding ToR is selected while DefaultRoute is `Wait`**
*File:* `sonic-linkmgrd/src/link_manager/LinkManagerStateMachineActiveActive.cpp:807`.

```cpp
} else if (mDefaultRouteState != DefaultRoute::NA) {
    switchMuxState(nextState, mux_state::MuxState::Label::Active);
}
```

`mDefaultRouteState` is initialized to `Wait` (`LinkManagerStateMachineBase.h:673`), where `Wait` semantically means "no DefaultRoute notification has arrived yet." The DR feature exists to prevent a forwarding ToR from being chosen when the upstream default route is unhealthy — its contract is that becoming forwarding requires confirmed DR health. The condition `!= NA` accepts both `OK` and `Wait`, treating "unknown" as "healthy." During startup, between linkmgrd coming up and the routing stack delivering the first DR notification (typically a few hundred milliseconds to a few seconds), if LP has reached `Active` and mux reports `Standby`, the ToR commits to forwarding while DR is in fact unknown. The same feature uses `== OK` for its health check at line 1147; line 807 is inconsistent with the feature's own definition. The fix is `!= NA → == OK`, one line. (`repro-real` — gtest.)

### Cluster E — DASH HA actor lifecycle (hamgrd)

Three findings in `sonic-dash-ha/crates/hamgrd/src/`. Two are SET/DEL asymmetries — the SET path broadcasts to registered actors, the DEL path does not — and the third is a one-character constructor bug that becomes load-bearing as soon as the first two are fixed.

**E.1 — HA-set deletion does not notify registered ha-scope actors**
*File:* `crates/hamgrd/src/actors/ha_set.rs:154-170` (`delete_dash_ha_set_table`) and `:621-643` (`do_cleanup`).

`update_dash_ha_set_table` (line 127-152) broadcasts `HaSetActorState{up: true}` to every actor registered against the HA set. The matching `delete_dash_ha_set_table` and `do_cleanup` paths do not broadcast the corresponding `up: false`. Registered ha-scope actors continue to act as if the HA set is up, holding stale references to a resource the controller has already deleted. The fix is to mirror the SET broadcast — and E.3 below is the prerequisite that lets the broadcast actually carry `up: false`. Adjacent issues (`#111` "actor handler not unregistered on termination", `#100` "DELETE op unhandled by hamgrd") have already been merged; this is the same family but a new instance. (`repro-real` — `cargo test` with `#[should_panic(expected = "Timed out")]`.)

**E.2 — DPU deletion does not notify registered vDPU actors**
*File:* `crates/hamgrd/src/actors/dpu.rs:137-140` (local DPU `do_cleanup`) and `:376-378` (remote DPU Del).

The same shape as E.1, one layer down. `update_dpu_state` (the SET path) broadcasts `DPUStateUpdate` to subscribers; the local `do_cleanup` only calls `delete_reset_info(internal)`, and the remote path simply calls `context.stop()`. vDPU actors registered against a deleted DPU continue to query state from a resource that no longer exists. Combined with E.1, a teardown of (HA set + DPU) leaves orphan actors at two layers. (`repro-real`.)

**E.3 — `HaSetActorState::new_actor_msg` ignores the `up` parameter**
*File:* `crates/hamgrd/src/ha_actor_messages.rs:144-145`.

```rust
pub fn new_actor_msg(up: bool, my_id: &str, ha_set: DashHaSetTable) -> Result<ActorMessage> {
    ActorMessage::new(Self::msg_key(my_id), &Self { up: true, ha_set })  // hardcoded
}
```

The companion `VDpuActorState::new_actor_msg` at line 116-117 has the correct `&Self { up, dpu }`. Today this is latent — every call site passes `true`, so the hardcoded `true` happens to match — but as soon as E.1's fix begins broadcasting `up: false` from the deletion path, this constructor silently coerces it back to `true`. We mention all three together because shipping E.1 and E.2 without E.3 makes the broadcast ineffective. (`repro-real` — cargo test that calls `new_actor_msg(false, ...)` and observes `up=true` in the produced struct.)

---

## Part II — Availability

### Cluster F — Warm-reboot recovery has no fallback (orchagent + sairedis)

Three independent paths in the warm-reboot recovery flow leave the device in a non-self-healing state under recoverable failures. F.1 and F.2 are the higher-priority items; F.3 is presented as a design discussion.

**F.1 — APPLY_VIEW failure → orchagent restart loop, no cold-restart fallback**
*Files:* `sonic-sairedis/syncd/Syncd.cpp:366-396, 5407` and `sonic-swss/orchagent/orchdaemon.cpp:853-859`.

When `applyView` fails, syncd enters `processEventInShutdownWaitMode` and returns FAILURE for all subsequent NOTIFY messages (`Syncd.cpp:388`). The comment at line 371-374 explains this is intentional, to avoid a deadlock with orchagent during INIT_VIEW; what it does not provide is an exit path. Orchagent's `init()` calls `warmRestoreAndSyncUp()` (line 853-859), gets FAILURE, returns `false`, and `main()` calls `exit(EXIT_FAILURE)`. supervisord restarts orchagent, which retries against the still-stuck syncd, gets FAILURE again, and exits again. The loop is per-second; the device's data plane is offline until an operator manually triggers a cold restart over the management network — which on a ToR routed through the device itself may require console access.

`sonic-buildimage#7072` reports the same loop ("APPLY_VIEW fail → no recovery"). The `Syncd.cpp:5407` FIXME ("on warm restart there is no switches defined in DB, not supported yet") and the `orchdaemon.cpp:1161` TODO ("Update this section accordingly once pre-warmStart consistency validation is ready") are matching evidence that the recovery-side validation was never wired up. A bounded retry policy with a watchdog-driven cold-restart fallback is the natural shape of the fix; that touches platform integration and is appropriate as a design discussion rather than a single PR. (`repro-real` for the orchagent-side state-precondition check; the cross-process Shutdown-Wait loop is reasoned from source and the author's comment.)

**F.2 — `assert()` for state preconditions disappears under `NDEBUG`**
*File:* `sonic-swss/warmrestart/warmRestartHelper.cpp:157`.

```cpp
assert(getState() == WarmStart::RESTORED);
```

In a debug build, this aborts orchagent and folds into F.1's restart loop. In a release build (`NDEBUG`), the assertion is compiled out and `reconcile()` proceeds against a state machine whose precondition has not been checked, operating on a possibly stale `m_restorationVector`. The release-build path silently writes incorrect FV data into AppDB. The fix is to replace the assert with a runtime check — `if (...) throw runtime_error(...)` or a logged early return. This is small and zero-risk and we suggest landing it independently of the larger F.1 discussion. (`repro-real` — gtest constructs a `WarmStartHelper` in `INITIALIZED` and observes the assert would fire.)

**F.3 — No cross-component reconciliation gating (orchagent + neighsyncd + fdbsyncd + vxlanmgrd …)**
*Files:* `sonic-swss/orchagent/orchdaemon.cpp:1130-1134` and `sonic-swss/warmrestart/warmRestartAssist.cpp:303`; six historical point-fixes.

Each warm-restart component runs its own `AppRestartAssist` instance with an independent timer and unconditionally calls `WarmStart::setWarmStartState(m_appName, RECONCILED)` when its timer fires. There is no cross-component check. When component A (e.g., fdbsyncd) reconciles before component B (e.g., vxlanmgrd) on which it depends, FDB entries that reference VXLAN tunnels are programmed to AppDB (and onward to the ASIC) before the tunnels exist. The dependency is transient, but stale forwarding can persist for tens of seconds depending on timer skew.

The clearest evidence is the comment at `orchdaemon.cpp:1130-1133`, written in commit `8bfdea086` (2018):

> *"The 'RECONCILED' state of orchagent doesn't mean the state related to neighbor is up to date."*

The author has acknowledged in writing that RECONCILED does not imply dependency completion; six follow-up commits (`5796e544`, `4a174f4f`, `721f47d9`, `3da2e676`, `a8a28a84`, `7dd3be98`) each added another point fix without addressing the systemic gap. We note this as a design discussion rather than a PR proposal — a cross-component dependency gate is an architectural change that benefits from maintainer input on shape before code is written. (`repro-real` for the absence-of-gate property; the resulting data-plane misforwarding is `repro-partial`.)

### Cluster G — neighsyncd reconcile-vs-dump race (orchagent siblings)

**G.1 — Reconcile timer starts before the netlink dump completes**
*Files:* `sonic-swss/neighsyncd/neighsyncd.cpp:62, 67` and `sonic-swss/warmrestart/warmRestartAssist.cpp:258-306`.

```cpp
sync.getRestartAssist()->startReconcileTimer(s);   // 5s timer starts (line 62)
...
netlink.registerGroup(RTNLGRP_NEIGH);               // line 65
netlink.dumpRequest(RTM_GETNEIGH);                  // dump fired here (line 67)
```

The reconcile timer starts at line 62; the netlink dump that produces the events the timer is meant to wait for is fired at line 67. The default timer is 5 seconds (`neighsync.h:10`). When the dump completes within the timer window, the system works; when it does not — large neighbor tables, post-reboot CPU/netlink contention — the timer fires first, `reconcile()` walks the cache, marks every entry that was not refreshed by the (incomplete) dump as `STALE`, and issues real `ProducerStateTable::del()` calls against AppDB. Orchagent and SAI propagate the deletes to the ASIC; the kernel still has the entries, so traffic traps to CPU and follows the slow path until the next NUD reachable timeout (~30s) repopulates them.

We reproduced the race materialization with a real `Select` / `SelectableTimer` / `ProducerStateTable` harness (`Bug4_RealTimerRaceCausesDeletion` in our gtest) and observed the timer-driven `reconcile()` issuing AppDB deletes for legitimate entries before the worker finished its replay. We did not reproduce the underlying "dump takes longer than 5 seconds" condition under production load; the race is a structural property of the code ordering, not a probability claim.

The natural fix is dump-driven completion: track `NLMSG_DONE` and start (or arm) the reconcile timer only after the dump completes. That decouples the timer from "how long the dump took" and removes the implicit assumption that 5 seconds is enough. We suggest this as an issue first, with a sketched patch — bumping the timer is mask, not fix. (`repro-real` for the timer race itself; the underlying slow-dump trigger is `model-only`.)

### Cluster H — iccpd availability paths

Three findings in iccpd that can take the MCLAG control plane out of service. We treat them as availability rather than reliability because each one's user-visible failure mode is "MCLAG does not work" rather than "MCLAG works but produces a wrong result."

**H.1 — `scheduler_csm_read_callback` lacks an upper bound on `msg_len`** *(security-relevant)*
*File:* `sonic-buildimage/src/iccpd/src/scheduler.c:174-194`.

```c
if (ntohs(ldp_hdr->msg_len) >= MSG_L_INCLUD_U_BIT_MSG_T_L_FIELDS) {  // lower bound only
    data_len = ntohs(ldp_hdr->msg_len) - MSG_L_INCLUD_U_BIT_MSG_T_L_FIELDS;
} else { goto recv_err; }
recv_len = recv(csm->sock_fd, &data[pos], data_len, MSG_DONTWAIT);
```

`g_csm_buf` is a 65536-byte BSS global (`iccp_csm.c:58`). `LDPHdr` is 8 bytes (packed). The maximum `msg_len = 0xFFFF` produces `data_len = 65531`, total write `8 + 65531 = 65539` — three bytes past the end of `g_csm_buf`, into the adjacent BSS global. We reproduced this under AddressSanitizer; ASan reports `global-buffer-overflow WRITE of size 65531` at `scheduler.c:194`, "0 bytes to the right of global variable g_csm_buf of size 65536." A peer (or peer-link MITM) sends a header with `msg_len = 0xFFFF` and the requisite payload; iccpd writes past the buffer.

Because iccpd has no cryptographic auth and runs on an authenticated peer-link, the realistic threat is a compromised peer ToR rather than an anonymous internet attacker. Even discounting RCE potential — and we are not claiming RCE here — the reliable DoS via repeated crash-and-restart by itself takes MCLAG out of service. The fix is one line, mirroring the existing lower-bound check: reject `msg_len > CSM_BUFFER_SIZE - sizeof(LDPHdr) + MSG_L_INCLUD_U_BIT_MSG_T_L_FIELDS`. PR `#18270` recently accepted a bound check in the same file. We expect this finding is best routed via the SONiC Security Advisory channel rather than a public PR. (`repro-real` with ASan stack trace.)

**H.2 — Heartbeat timeout check fires during the handshake window**
*Files:* `sonic-buildimage/src/iccpd/src/scheduler.c:75-89` (`heartbeat_check`) and `sonic-buildimage/src/iccpd/src/mlacp_fsm.c:850, 882` (heartbeat send).

The heartbeat sender is gated by `sock_fd > 0 && app_csm.current_state == APP_OPERATIONAL`; the heartbeat timeout check at `scheduler.c:75-89` is gated only by `sock_fd > 0`. While the TCP connection is up but the ICCP application has not yet reached `APP_OPERATIONAL`, neither side sends heartbeats, but the local timeout check is already running. `heartbeat_update_time` is captured at TCP up; once `session_timeout` (default 15s, `iccp_csm.c:130`) elapses on wall-clock, the timeout fires and `scheduler_session_disconnect_handler` tears down the session. Reconnect lands in the same state, and the loop is deterministic.

A natural amplifier sits at `scheduler.c:214`: on the partial-recv retry path, the maximum sleep is `(session_timeout * 1e6) - total_retry_time`, i.e., almost the full 15 seconds — a single retry chain can push the handshake past the timeout on its own. The fix is to gate `heartbeat_check` on the same `APP_OPERATIONAL` condition as the sender (and refresh `heartbeat_update_time` inside the handshake window). The `scheduler.c:214` sleep size is a separate concern worth flagging. (`repro-partial` — state-injection test demonstrates the gating asymmetry; the end-to-end handshake-stuck loop is reasoned from source.)

**H.3 — `readfd_count` is never decremented**
*Files:* `sonic-buildimage/src/iccpd/src/scheduler.c:348, 642` (`++`) and `:827` (no `--`).

`readfd_count` is incremented on `accept()` and on connection establishment but never decremented in `scheduler_unregister_sock_read_event_callback()` — only `FD_CLR()` is called. Every disconnect/reconnect cycle pushes it one higher. The counter is used at `iccp_netlink.c:2170` to size a stack-allocated `epoll_event` array, so the stack frame grows monotonically with the number of session flaps the daemon has seen. On long-running deployments with frequent flaps, this approaches and eventually exceeds the pthread stack size and the daemon crashes — the user-visible effect is the MCLAG control plane stops, which is why we list it under availability rather than under correctness. The fix is to add a matching `--` in the unregister path. (`repro-real` — five connect/disconnect cycles drive the counter from 0 to 5 with no decrement.)

---

## Part III — Independently rediscovered

While reviewing iccpd warm-reboot wiring we observed that `scheduler.c:853-855` (in `scheduler_session_disconnect_handler`) writes `csm->warm_reboot_disconn_time` and is then immediately followed by `iccp_csm_status_reset(csm, 0)` at `iccp_csm.c:150`, which resets the same field to 0. The warm-reboot timeout at `mlacp_fsm.c:874` therefore never fires and FDB cleanup is skipped after warm boot. This is tracked in PR `#7724` (open). We did not reproduce the issue ourselves; our model checking flagged the same write-then-clear order.

Separately, while reviewing ICCP TLV parsing we found that `mlacp_sync_update.c:564-569` (and the analogous loops at `:917` for ARP and `:1239` for NDISC) read `count = ntohs(tlv->num_of_entry)` directly as the loop bound without cross-checking against `tlv->icc_parameter.len`. A peer that advertises `len` covering a single 30-byte `mLACPMACData` entry but `num_of_entry = 100` causes the loop to read ~3000 bytes past the buffer. We did reproduce this one — under ASan we observe `heap-buffer-overflow READ of size 1` at `mlacp_sync_update.c:229` (called from `:569`), one byte past a 36-byte region. This is tracked in PR `#26567` (open).

We mention both as confidence checks on our review process rather than as new findings.

---

## Closing

Thank you for taking the time to review these. The findings are split across orchagent, syncd, iccpd, hamgrd, and linkmgrd, but the orchagent and warm-reboot items in Clusters A, B, F, and G are the core of what we want feedback on — they are the places where a small fix has a large effect on the warm-reboot guarantee, and where the alternative (a design discussion) would benefit most from your judgment on the right shape.

Reproductions are described per cluster: `repro-real` for tests that drive the actual buggy function with the consequence observed, `repro-partial` for tests that drive the buggy code path but where the consequence is inferred, and `model-only` for findings reasoned from spec and source. The companion `specs/` directory contains the TLA+ models (per-module `base.tla` / `MC.tla` / `Trace.tla` plus invariants and bug-hunt configs); the `reproductions/` directory contains the test sources.

We expect some of these to land cleanly, others to be reframed, and possibly one or two to come back as misunderstandings on our side. We are happy to follow up on any item in more depth — reproduce in a specific configuration, sketch a patch, or talk it through.

Please let us know which (if any) you would like more context on.
