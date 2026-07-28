# Modeling Brief: FRRouting/frr Zebra Route Realization

## 1. System Overview

- System: FRRouting/frr, Zebra route realization path at commit `ee765f7fa0d6533ec2479da3e442d17d4b93d474` (`frr-10.8.0-dev-82-gee765f7fa0`).
- Language/scale: C; the six requested core files total 25,450 LOC.
- Category: Category A (Distributed / Message-Passing). Route realization crosses protocol-daemon ZAPI messages, Zebra main-thread RIB state, a dataplane pthread/provider pipeline, kernel/provider completion messages, and owner/NHT notifications.
- Reference behavior: protocol route add/delete enters Zebra, RIB selects the winning route, dataplane realizes it, and route owners/NHT clients observe only confirmed realization state.
- Key implementation choices: RIB selection and `selected_fib` are updated before dataplane completion; dataplane contexts carry sequence numbers; owner route notifications carry prefix/table/status but no route generation; NHT stores a reduced snapshot of resolved route state.
- Concurrency model: Zebra and BGP are event-loop driven; dataplane work is transferred through asynchronous queues to a separate pthread and provider callbacks.

## 2. Scenarios

### Scenario 1: Dataplane Result Generation and Speculative RIB State

**Mechanism**: Zebra speculatively updates selected/FIB-visible route state before the dataplane result, then later results can be lost, late, loosely matched, or stale.

**Evidence**:
- Historical: `9b3489d043` fixed dplane result matching when route tags changed before result processing; `947ddf7b34` fixed wrong per-nexthop FIB flag mirroring after result processing; `c8453cd77e`/`51f201c006` fixed route replace failures reported as success; `a126f12003` and `e4acb14528` fixed failed install notifications/state; `c6eee91f66`/`da7393b8fd` fixed "ships in the night" late kernel/ASIC notifications.
- GitHub: #14481, #18722, #22345, and #6327 show still-active or unresolved NHG/dataplane timing failures around interface flaps and kernel NHG lifetime.
- Code analysis: `rib_install_kernel()` sets `dest->selected_fib` and calls `rib_update` before `dplane_route_add/update()` returns (`zebra/zebra_rib.c:706`, `zebra/zebra_rib.c:713`, `zebra/zebra_rib.c:716`). Enqueue failure only logs (`zebra/zebra_rib.c:733`). Context sequence numbers are assigned at submit (`zebra/zebra_dplane.c:4145`, `zebra/zebra_dplane.c:4148`, `zebra/zebra_dplane.c:4843`). `rib_process_result()` logs stale sequence mismatches but continues into install/failure/delete state updates and owner/NHT notification paths (`zebra/zebra_rib.c:2048`, `zebra/zebra_rib.c:2081`, `zebra/zebra_rib.c:2093`, `zebra/zebra_rib.c:2163`, `zebra/zebra_rib.c:2181`, `zebra/zebra_rib.c:2238`).

**Affected code paths**: `rib_process()`, `rib_process_update_fib()`, `rib_install_kernel()`, `rib_uninstall_kernel()`, `dplane_ctx_route_init()`, `dplane_route_update_internal()`, `rib_process_result()`, `rib_process_dplane_notify()`.

**Suggested modeling approach**:
- Variables: `ribRoute[prefix]`, `selectedFib[prefix]`, `routeGen[prefix]`, `ctxQueue`, `ctxSeq`, `ctxOldSeq`, `ctxStatus`, `kernelRoute[prefix]`, `ownerNotifyQueue`.
- Actions: split `RibSelect`, `DplaneSubmit`, `DplaneEnqueueFail`, `DplaneCompleteSuccess`, `DplaneCompleteFailure`, `DplaneCompleteStale`, `DplaneRouteNotify`, and `RibApplyResult`.
- Granularity: keep route selection and dataplane submission as separate actions; result application must branch on matching vs stale sequence and on normal result vs async notify.

**Priority**: High
**Rationale**: This is the densest historical bug cluster and maps directly to TLA+ message loss/reorder/staleness. Current code has a concrete sequence-mismatch path that does not stop later mutation.

### Scenario 2: Route-Owner/ZAPI Notification Correlation and BGP FIB-Pending State

**Mechanism**: BGP derives advertisement eligibility from Zebra route-owner notifications that are connection-local and correlated by prefix/table/status, not by route generation or path identity.

**Evidence**:
- Historical: #4770 introduced suppress-fib-pending and route-owner acknowledgments; #1799/#1852/#7818 added route notify/failure paths; `3fdb2079f6`, `0a9a77c88d`, `e104afb0d7`, `45cf4b17b5`, and `1b25fbf924` fixed multiple FIB-pending/notification accounting bugs.
- GitHub: #21298/#21384 adjusted convergence delay after FIB confirmation; #22359/#22411 and `67f78ccd10` show reconnect replay problems when Zebra loses route state while protocol daemons keep local RIB state.
- Code analysis: Zebra stores owner notification subscription only in `client->notify_owner` (`zebra/zserv.h:135`) and sets it per connection (`zebra/zapi_msg.c:850`). New clients are zero-initialized (`zebra/zserv.c:799`, `zebra/zserv.c:807`). Route notifications use `zserv_find_client(type, instance)`, which searches session `0` (`zebra/zapi_msg.c:763`, `zebra/zserv.c:1594`). The payload includes note, prefix, source prefix, table id, AFI, and SAFI, but no route generation or BGP path id (`zebra/zapi_msg.c:786`, `zebra/zapi_msg.c:804`, `zebra/zapi_msg.c:807`). BGP sets `BGP_NODE_FIB_INSTALL_PENDING` before checking Zebra usability (`bgpd/bgp_zebra.c:2056`, `bgpd/bgp_zebra.c:2086`) and applies any owner notification to the current destination by VRF/AFI/SAFI/prefix (`bgpd/bgp_zebra.c:3059`, `bgpd/bgp_zebra.c:3075`, `bgpd/bgp_zebra.c:3086`).

**Affected code paths**: `zread_route_notify_request()`, `route_notify_internal()`, `zsend_route_notify_owner_ctx()`, `bgp_zebra_route_install()`, `bgp_handle_route_announcements_to_zebra()`, `bgp_zebra_route_notify_owner()`, `bgp_zebra_connected()`, `bgp_suppress_fib_pending_set()`.

**Suggested modeling approach**:
- Variables: `ownerSubscribed[client]`, `zapiConn[client]`, `bgpPending[prefix]`, `bgpInstalled[prefix]`, `bgpSelectedPath[prefix]`, `notifyMsg` with prefix/table/status/generation.
- Actions: `BGPMarkPending`, `ZapiRouteSend`, `ZapiSendFail`, `ZebraOwnerNotify`, `OwnerNotifyDrop`, `OwnerNotifyLate`, `BGPApplyNotify`, `Reconnect`.
- Granularity: separate "mark pending" from "ZAPI add reaches Zebra" and separate "Zebra sends notify" from "BGP applies notify".

**Priority**: High
**Rationale**: Owner acknowledgments directly gate BGP advertisement under suppress-fib-pending; several historical bugs were production-impacting and current payloads still lack generation/path correlation.

### Scenario 3: NHT/RNH Observes Reduced or Stale Realization State

**Mechanism**: NHT maps route realization state into a reduced snapshot and may miss changes when registration/order, queued/installed flags, backup nexthops, or route metadata are not represented consistently.

**Evidence**:
- Historical: `60c67010f2`, `c5f7794faa`, `feb554e508`, `0aa2408323`, and `903f270bfa` fixed RNH old-vs-new comparison, resolved-prefix, protocol-type, specific-prefix, and queued/installed evaluation bugs. #21769 added forced withdraw/add after rapid route remove/add; #22780 and #22720 show current NHT coalescing and dplane-resolution-event concerns.
- Code analysis: `rnh_nexthop_valid()` requires `ROUTE_ENTRY_INSTALLED` and `NEXTHOP_FLAG_ACTIVE`, but not per-nexthop `NEXTHOP_FLAG_FIB` (`zebra/zebra_rnh.c:606`). Resolution skips queued routes only if they are not installed (`zebra/zebra_rnh.c:741`). `copy_state()` copies type/distance/metric/vrf/status/nhe but omits `instance` (`zebra/zebra_rnh.c:1020`, `zebra/zebra_rnh.c:1033`). `compare_state()` compares type/distance/metric/valid primary nexthops only (`zebra/zebra_rnh.c:1127`). New RNH entries are stored on a covering RIB dest if one already exists; `route_node_match()` returns only nodes with `info` (`zebra/zebra_rnh.c:139`, `lib/table.c:246`).

**Affected code paths**: `zebra_add_rnh()`, `zebra_rnh_store_in_routing_table()`, `zebra_rnh_resolve_nexthop_entry()`, `copy_state()`, `compare_state()`, `zebra_send_rnh_update()`, `zebra_rib_evaluate_rn_nexthops()`, `zread_rnh_register()`.

**Suggested modeling approach**:
- Variables: `rnhRegistered[prefix,client]`, `rnhAttachedDest`, `rnhSnapshot`, `nhtMsg`, `routeStatus`, `fibNexthops`, `activeNexthops`.
- Actions: `RegisterRNH`, `AttachRNH`, `RouteAddAfterRegister`, `EvaluateRNH`, `CompareRNHState`, `SendNHTUpdate`.
- Granularity: model NHT evaluation after dataplane results and after RIB add/delete separately; include a nondeterministic "coalesced delete/add" path.

**Priority**: High
**Rationale**: NHT has a long bug history and open issues; core route realization can diverge for clients even when Zebra's selected route is internally coherent.

### Scenario 4: MetaQ, Startup, Reconnect, and Queue Ordering Reconciliation

**Mechanism**: Route realization depends on ordered queues that compress multiple add/delete events into route-node work items; startup/reconnect paths must rebuild state that was lost while another component retained its local view.

**Evidence**:
- Historical: `6d69112959` fixed add/delete races by queueing route nodes instead of route entries; `d7ac4c4d88` added early route processing after NHG ordering bugs; `69906fdbd6` fixed duplicate MetaQ subqueue membership; `e53fa582bc` and `50ed71b6d7` fixed stale/overbroad MetaQ cleanup; #22654 was the current same-prefix wrong-table cleanup bug fixed by `50ed71b6d7`. #22359/#22411 and `67f78ccd10` show daemon-local routes can fail to replay after Zebra reconnect.
- Code analysis: route add/delete state is intentionally mutated before queueing (`zebra/zebra_rib.c:4018`, `zebra/zebra_rib.c:4075`, `zebra/zebra_rib.c:4122`). MetaQ blocks on dataplane input queue length (`zebra/zebra_rib.c:3218`). `MQ_SIZE` is 12, while `RIB_ROUTE_ANY_QUEUED` is hardcoded to `0x3F`, covering subqueues 0-5 only (`zebra/rib.h:189`, `zebra/rib.h:204`, `zebra/rib.h:262`). Current BGP reconnect callback registers the instance and retries deferred suppress config, with a TODO about kick-starting configured routes (`bgpd/bgp_zebra.c:3299`, `bgpd/bgp_zebra.c:3317`, `bgpd/bgp_zebra.c:3322`).

**Affected code paths**: `rib_link()`, `rib_addnode()`, `rib_delnode()`, `rib_meta_queue_add()`, `meta_queue_process()`, early route processing, VRF/table cleanup, `rib_sweep_table()`, `bgp_zebra_connected()`, `bgp_zebra_announce_table()`.

**Suggested modeling approach**:
- Variables: `metaQ`, `queuedBits[prefix]`, `earlyRouteQ`, `zebraKnownRoutes`, `ownerLocalRoutes`, `zebraRestarted`.
- Actions: `RouteAddQueued`, `RouteDelQueued`, `MetaQProcessOne`, `MetaQCleanupClient`, `ZebraRestart`, `OwnerReconnect`, `ReplaySelectedRoutes`, `StartupSweep`.
- Granularity: model queue coalescing explicitly but abstract away per-daemon policy; include table id and route type in route identity.

**Priority**: Medium/High
**Rationale**: Queue ordering is historically bug-dense and current reconnect/queue-mask facts are sharp, but some issues are better tested than model-checked.

### Scenario 5: Provider/NHG Boundary and Partial Dataplane Pipelines

**Mechanism**: Dataplane providers and kernel NHG realization can acknowledge, skip, delay, or drop parts of a multi-provider route update pipeline independently from Zebra's RIB state.

**Evidence**:
- Historical: `c41155221e`, `9e5c9e6d65`, and `38a2e2cb26` fixed provider ordering and shutdown races; `df00a58f7a` and `6349e49645` fixed dplane thread boundary violations; #22656 is an open provider-refresh PR because providers can restart and lose route state.
- Code analysis: route contexts copy route attributes including MTU/tag (`zebra/zebra_dplane.c:3994`, `zebra/zebra_dplane.c:3999`, `zebra/zebra_dplane.c:4002`), but kernel NHG mode marks same old/new NHE id and route type updates as success without a kernel route update (`zebra/zebra_dplane.c:7747`, `zebra/zebra_dplane.c:7756`). The FPM provider moves work into a provider-private queue (`zebra/dplane_fpm_nl.c:1801`) and later enqueues output without waking the dplane loop (`zebra/dplane_fpm_nl.c:1567`, `zebra/zebra_dplane.c:7063`). Shutdown pending checks only global/provider visible queues (`zebra/zebra_dplane.c:8009`, `zebra/zebra_dplane.c:8020`, `zebra/zebra_dplane.c:8032`).

**Affected code paths**: `dplane_update_enqueue()`, `dplane_thread_loop()`, provider callbacks, `kernel_dplane_process_func()`, FPM provider, `dplane_work_pending()`, `zebra_dplane_shutdown()`.

**Suggested modeling approach**:
- Variables: `providerIn`, `providerOut`, `providerPrivate`, `providerAlive`, `nhgInstalled`, `routeAttrs`, `kernelAttrs`.
- Actions: `ProviderAccept`, `ProviderSkipKernel`, `ProviderCompletePrivate`, `ProviderWake`, `ProviderRestart`, `ShutdownDrain`.
- Granularity: start with one kernel provider and an optional second provider; add provider-private queues only if Scenario 1/2 invariants remain underexplored.

**Priority**: Medium
**Rationale**: Strong implementation evidence exists, but FPM/provider internals can expand state space quickly and are partly out of the target scope unless they affect route-owner/NHT visibility.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| Zebra RIB selected vs confirmed FIB state | Scenario 1: `selected_fib` changes before dataplane completion | Separate `selectedFib`, `installed`, `queued`, `failed`, and `kernelRoute` variables |
| Dataplane contexts with generations | Scenario 1: current code carries seq/old_seq and has stale-result paths | Add `ctx.seq`, `ctx.oldSeq`, `ctx.op`, `ctx.status`; split matching and mutation |
| Async route notifications | Scenario 1 and 2: `DPLANE_OP_ROUTE_NOTIFY` is not sequence-gated | Add notify messages that can arrive late and match by prefix/type/instance only |
| Owner notification and BGP pending flags | Scenario 2: suppress-fib-pending is externally visible | Model subscription, send/drop/late delivery, BGP pending/installed flags |
| NHT reduced snapshot | Scenario 3: NHT can miss state that RIB tracks | Model snapshot compare fields and NHT update delivery |
| MetaQ route-node coalescing | Scenario 4: add/delete state is mutated before queued processing | Model one route-node queue item with multiple route-entry state changes |

### 3.2 Do Not Model

| What | Why |
|---|---|
| BGP policy and best-path correctness | Out of scope except as the route-owner boundary; model BGP as selected-path producer/consumer |
| OSPF/ISIS/RIP protocol correctness | Out of scope; include only as generic owners if needed |
| Linux kernel forwarding internals | No FRR-visible oracle beyond dataplane success/failure/notify |
| CLI/config parsing | Not route realization protocol logic |
| Memory-safety-only UAF/crash bugs | Important for code review/testing, but not the primary TLA+ safety target |
| EVPN/FPM deep internals | Model only if provider behavior is needed to exercise route realization divergence |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Route generations | `routeGen`, `ctxSeq`, `ctxOldSeq` | Distinguish current route state from stale dataplane results | 1 |
| Explicit dataplane queues | `ctxQueue`, `providerIn`, `providerOut`, `resultQueue` | Explore loss, delay, reorder, enqueue failure | 1, 5 |
| Kernel realization oracle | `kernelRoute`, `kernelAttrs`, `nhgInstalled` | Compare Zebra/BGP/NHT beliefs against realized route state | 1, 5 |
| Owner notification channel | `ownerSubscribed`, `notifyQueue`, `bgpPending`, `bgpInstalled` | Model suppress-fib-pending and late/lost acks | 2 |
| NHT state machine | `rnhAttachedDest`, `rnhSnapshot`, `nhtMsg` | Capture reduced snapshot and missed reevaluation | 3 |
| MetaQ coalescing | `metaQ`, `queuedBits`, `earlyRouteQ` | Represent route-node work compression and ordering | 4 |
| Startup/reconnect | `zebraRestarted`, `ownerLocalRoutes`, `zebraKnownRoutes` | Check reconciliation after Zebra loss/restart | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| OwnerInstalledImpliesCurrentFib | Safety | If BGP marks a route installed, Zebra has the same current prefix/table/generation selected and confirmed installed | Scenario 2 |
| NoStaleDplaneMutation | Safety | A dataplane result whose seq does not match the matched route generation cannot change installed/failed/queued flags, NHT state, or owner notifications | Scenario 1 |
| SelectedFibNeedsTerminalResult | Safety/Liveness | A selected route submitted to dataplane eventually reaches installed, failed, or explicit enqueue-failed state unless shutdown occurs | Scenario 1 |
| PendingImpliesOutstandingWork | Safety | If BGP has `FIB_INSTALL_PENDING`, a corresponding ZAPI add or Zebra dataplane/notify obligation exists | Scenario 2 |
| NotifyAppliesToMatchingGeneration | Safety | A route-owner notification can only mutate owner state for the route generation/table that caused it | Scenario 2 |
| NHTResolvedImpliesConfirmedRoute | Safety | A resolved NHT update references a current Zebra route with installed status and valid realized nexthops, with no newer unresolved generation pending | Scenario 3 |
| RNHRegistrationEventuallyAttached | Liveness | If an RNH client registers before a covering route exists, later route creation eventually attaches/evaluates it | Scenario 3 |
| MetaQSingleVisibleMembership | Safety | A route node is visible as queued whenever it is in any MetaQ route subqueue; no processing path misses static/BGP queued nodes | Scenario 4 |
| ReconnectEventuallyReplays | Liveness | After Zebra reconnect, stable owner-selected routes eventually reappear in Zebra or owner state stops waiting on them | Scenario 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC1 | A stale normal dataplane result logs seq mismatch but still mutates current route state or sends owner/NHT notification | `NoStaleDplaneMutation` | 1 |
| MC2 | Dataplane enqueue failure after `selected_fib`/FPM hook precommit leaves Zebra selected state without a terminal owner notification | `SelectedFibNeedsTerminalResult`, `OwnerInstalledImpliesCurrentFib` | 1, 2 |
| MC3 | Late `DPLANE_OP_ROUTE_NOTIFY` without sequence/generation matches a newer route and clears queued/replacing or reports offload state for the wrong generation | `NotifyAppliesToMatchingGeneration`, `NoStaleDplaneMutation` | 1, 2 |
| MC4 | BGP sets `FIB_INSTALL_PENDING` before a ZAPI add can be sent, or after reconnect loses notify subscription, causing permanent advertisement suppression | `PendingImpliesOutstandingWork`, `ReconnectEventuallyReplays` | 2, 4 |
| MC5 | NHT registration before a covering RIB dest exists is not attached/evaluated when a later route appears | `RNHRegistrationEventuallyAttached` | 3 |
| MC6 | Coalesced route delete/add or reduced NHT comparison suppresses a required NHT withdraw/add for a client | `NHTResolvedImpliesConfirmedRoute` | 3, 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV1 | Kernel-NHG route update with same old/new NHE id and type skips kernel update even if MTU/tag route attributes changed | Topotest with kernel nexthops enabled; change MTU/tag without NHG id change and compare FRR JSON vs kernel route attrs |
| TV2 | `RIB_ROUTE_ANY_QUEUED == 0x3F` omits static/BGP/high route subqueues from paths that ask "any queued" | Unit/topotest around `rib_update_table()` and kernel selfroute delete while BGP/static route node is queued |
| TV3 | Backup-only NHT resolution can be considered usable, but compare/send paths operate on primary FIB nexthops | Topotest with invalid primary and valid backup nexthop, then observe NHT update payload |
| TV4 | Threaded provider private completion can wait until unrelated dplane work wakes the main dplane loop | Provider/FPM-focused trace with single route ctx and no subsequent dplane work |
| TV5 | `ZCLIENT_SEND_FAILURE` after BGP route announcement dequeue is not requeued | Container topotest forcing socket failure during `bgp_handle_route_announcements_to_zebra()` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | Route-owner notify uses session 0 while doc defines `{protocol, instance, session_id}` and NHG notify uses full session lookup | Maintainer review whether route entries need session identity or explicit documentation that route ownership is session-0 only |
| CR2 | `copy_state()` and `compare_state()` omit `route_entry.instance` even though NHT update encoding sends instance | Audit whether instance-only changes are legal and should force an NHT update |
| CR3 | `zebra_dplane_shutdown()` frees providers before a later loop intended to clean provider queues | Review ordering; mainly shutdown hygiene unless route realization has provider-visible state to preserve |
| CR4 | BGP `ZAPI_ROUTE_REMOVE_FAIL` handler logs only; no retry/reconcile path | Maintainer decision on whether delete failure should trigger replay, resync, or explicit operator-only state |

## 7. Reference Pointers

- Full analysis report: `/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/analysis-report.md`
- Core source files: `doc/developer/zebra.rst`, `zebra/zebra_rib.c`, `zebra/zebra_dplane.c`, `zebra/zebra_rnh.c`, `zebra/zapi_msg.c`, `bgpd/bgp_zebra.c`
- Additional source references: `zebra/rib.h`, `zebra/zserv.c`, `zebra/zserv.h`, `lib/zclient.c`, `bgpd/bgpd.c`, `bgpd/bgp_route.h`, `zebra/rt_netlink.c`, `zebra/dplane_fpm_nl.c`
- High-signal commits: `9b3489d043`, `947ddf7b34`, `c8453cd77e`, `a126f12003`, `e4acb14528`, `c6eee91f66`, `da7393b8fd`, `3fdb2079f6`, `0a9a77c88d`, `e104afb0d7`, `1b25fbf924`, `903f270bfa`, `60c67010f2`, `6d69112959`, `d7ac4c4d88`, `69906fdbd6`, `50ed71b6d7`, `c41155221e`
- GitHub threads deeply reviewed: #14481, #18722, #22345, #7299, #20167, #20540, #18988, #18041, #21299, #22780, #21769, #22720, #22359/#22411, #22656, #20514/#20525, #17072, #22061, #22773
- Phase 2.5 harness constraint for later validation: build/run FRR only through Docker topotest image `ncp/frr-replay:ubuntu22-topotest`; real NDJSON traces only, synthetic traces only as debug aids.
