# Code Analysis Report: FRRouting/frr Zebra Route Realization

## 1. Methodology and Classification

Skill used: `specula-codex:code-analysis`.

Methodology followed:

1. Step 0 classification.
2. Phase 1 reconnaissance of structure, scale, concurrency model, and atomicity boundaries.
3. Phase 2 bug archaeology from git history plus GitHub issues/PRs.
4. Phase 3 deep analysis of the requested core files with exact source references and compensating-mechanism checks.
5. Phase 4 synthesis into the scenario-oriented `modeling-brief.md`.

Classification: Category A (Distributed / Message-Passing). Zebra route realization is not a replicated consensus protocol, but its correctness boundary is message ordering and observation across independent components: protocol daemons send ZAPI messages, Zebra main-thread RIB work is queued, the dataplane pthread/provider pipeline returns contexts, kernel/provider notifications can arrive asynchronously, and owners/NHT clients update their local state based on messages. BFT does not apply.

Repository:

- Source repo: `/home/ubuntu/network-control-plane/workspaces/frr/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850`
- Commit: `ee765f7fa0d6533ec2479da3e442d17d4b93d474`
- Describe: `frr-10.8.0-dev-82-gee765f7fa0`
- Git worktree status during analysis: clean.

## 2. Phase 1 Reconnaissance

### 2.1 Core Files Read

The requested files were read first and used as the scope spine:

| File | LOC | Role in route realization |
|---|---:|---|
| `doc/developer/zebra.rst` | 247 | ZAPI and dataplane architecture |
| `zebra/zebra_rib.c` | 5,540 | RIB route lifecycle, selection, queueing, dataplane result processing |
| `zebra/zebra_dplane.c` | 8,571 | Dataplane context creation, provider queues, dataplane thread loop, shutdown |
| `zebra/zebra_rnh.c` | 1,552 | NHT/RNH registration, route resolution, snapshot comparison, update send |
| `zebra/zapi_msg.c` | 4,302 | ZAPI route add/delete, route owner notify, NHT registration |
| `bgpd/bgp_zebra.c` | 5,238 | BGP-to-Zebra route send queue, suppress-fib-pending state, owner notify handling |

Total requested core LOC: 25,450.

Additional supporting files inspected: `zebra/rib.h`, `zebra/zserv.c`, `zebra/zserv.h`, `lib/zclient.c`, `bgpd/bgpd.c`, `bgpd/bgp_route.h`, `zebra/rt_netlink.c`, and `zebra/dplane_fpm_nl.c`.

### 2.2 Architecture Map

ZAPI is the protocol used by daemons to communicate with Zebra; daemons install routes and request NHT, and Zebra chooses what reaches the kernel forwarding table (`doc/developer/zebra.rst:12`, `doc/developer/zebra.rst:17`). ZAPI sessions are documented as `{protocol, instance, session_id}` (`doc/developer/zebra.rst:20`).

The dataplane subsystem programs the local kernel and runs in its own pthread (`doc/developer/zebra.rst:168`, `doc/developer/zebra.rst:171`). Dataplane batching assumes kernel netlink error messages are returned in send order and matched back to context objects (`doc/developer/zebra.rst:239`).

The Zebra route lifecycle is:

1. ZAPI route add/delete creates or removes `route_entry` objects (`zebra/zapi_msg.c:2148`, `zebra/zapi_msg.c:2177`, `zebra/zapi_msg.c:2329`, `zebra/zapi_msg.c:2344`).
2. RIB add/delete mutates route-entry state, then queues the route node (`zebra/zebra_rib.c:4018`, `zebra/zebra_rib.c:4075`, `zebra/zebra_rib.c:4122`).
3. `rib_process()` selects `new_selected` and `new_fib`, marks `ZEBRA_FLAG_SELECTED`, and calls add/update/delete FIB processing (`zebra/zebra_rib.c:1290`, `zebra/zebra_rib.c:1495`, `zebra/zebra_rib.c:1550`).
4. `rib_install_kernel()` sets `dest->selected_fib`, calls the RIB/FPM hook, then enqueues dataplane work (`zebra/zebra_rib.c:706`, `zebra/zebra_rib.c:713`, `zebra/zebra_rib.c:716`).
5. `dplane_ctx_route_init()` snapshots the route and assigns sequence numbers (`zebra/zebra_dplane.c:4014`, `zebra/zebra_dplane.c:4145`, `zebra/zebra_dplane.c:4148`).
6. The dataplane thread moves contexts through providers and returns result lists to Zebra main (`zebra/zebra_dplane.c:8122`, `zebra/zebra_dplane.c:8370`).
7. Zebra main processes results in `rib_process_result()` or async notifications in `rib_process_dplane_notify()` (`zebra/zebra_rib.c:1976`, `zebra/zebra_rib.c:2254`).
8. Route owners and NHT clients receive ZAPI messages and update local state (`zebra/zapi_msg.c:751`, `zebra/zebra_rnh.c:1151`, `bgpd/bgp_zebra.c:3047`).

### 2.3 Atomicity Boundaries

The key split points for modeling are:

- BGP local state mutation vs actual ZAPI send. `bgp_zebra_route_install()` can mark `BGP_NODE_FIB_INSTALL_PENDING` before checking Zebra connection/registration (`bgpd/bgp_zebra.c:2056`, `bgpd/bgp_zebra.c:2086`).
- ZAPI route add/delete reception vs RIB processing. RIB add/delete state is mutated before route-node processing (`zebra/zebra_rib.c:4075`, `zebra/zebra_rib.c:4131`).
- RIB selection vs dataplane acceptance. `dest->selected_fib` changes before `dplane_route_add/update()` returns (`zebra/zebra_rib.c:706`, `zebra/zebra_rib.c:716`).
- Dataplane enqueue vs provider completion. Contexts are put on `dg_update_list` and later moved through provider queues (`zebra/zebra_dplane.c:4777`, `zebra/zebra_dplane.c:8176`, `zebra/zebra_dplane.c:8240`).
- Dataplane result matching vs mutation. `rib_process_result()` first matches a route by prefix/type/instance/distance/metric special cases, then checks sequence (`zebra/zebra_rib.c:2028`, `zebra/zebra_rib.c:2046`).
- Zebra route owner notify vs BGP application. Notify payload has no route generation/path id (`zebra/zapi_msg.c:786`, `zebra/zapi_msg.c:804`), and BGP applies it to the current `bgp_dest` (`bgpd/bgp_zebra.c:3075`).
- NHT snapshot vs live RIB. `copy_state()` stores a reduced route-entry copy; later `compare_state()` compares only selected fields and valid primary nexthops (`zebra/zebra_rnh.c:1020`, `zebra/zebra_rnh.c:1127`).

## 3. Phase 2 Bug Archaeology

### 3.1 Git History Coverage

Search approach: `git log --all` over the requested core files with bug/fix/race/correctness/order keywords, plus targeted searches for route notify, dplane result, suppress-fib-pending, NHT/RNH, MetaQ, reconnect, shutdown, and backpressure.

Coverage statistics:

| Metric | Count |
|---|---:|
| Raw keyword commit hits | 1,343 |
| Non-merge hits | 1,118 |
| Merge hits | 225 |
| High-signal raw candidates screened | 143 |
| Unique high-signal subjects | 105 |
| Significant route-realization fixes analyzed | 84 |
| Excluded raw hits | 1,259 |

Excluded raw hits consisted of 225 merges, 38 duplicate/backport high-signal hits, and 996 low-signal or out-of-scope commits.

High-signal commit groups:

| Mechanism | Representative commits | Root cause pattern |
|---|---|---|
| MetaQ add/delete ordering | `6d69112959`, `d7ac4c4d88`, `69906fdbd6`, `e53fa582bc`, `50ed71b6d7` | Route-node queue compression and cleanup lost the identity/order of route-entry changes |
| RIB/FIB replacement identity | `0b560feb23`, `949ae9ba15`, `42aa465ed1` | Old/new FIB route identity was wrong during replace or connected/static transitions |
| Duplicate route identity | `526e172845`, `844b3a8748`, `c2713b2ac`, `a35ba7ba60`, `bf1312b8e` | "Same route" comparisons missed discriminators such as distance, ECMP NHs, local-vs-connected, or interface identity |
| Owner notification on admin distance | `2d3005068c`, `9a9f89267a`, `0492eea08e` | Zebra failed to notify, or over-notified, route owners when a better admin route won |
| Async result lifetime | `e96817f877`, `5f27bcba2a`, `2eb07de3d`, `607425e554` | Route-node/dest lifetime was not preserved across async delete/result processing |
| Result matching | `9b3489d043`, `947ddf7b34` | Dplane context result matched the wrong route or wrong nexthop cursor |
| Failed install/result status | `a126f12003`, `b96f64f76f`, `c8453cd77e`, `51f201c006`, `e4acb14528` | Dataplane/kernel failures were reported as success or did not clear queued/failed state |
| Async kernel/ASIC reorder | `c6eee91f66`, `da7393b8fd` | Late kernel/ASIC notifications overrode newer BGP delete/update state |
| Dataplane provider ordering/shutdown | `c41155221e`, `9e5c9e6d65`, `38a2e2cb26` | Work returned to Zebra at the wrong provider boundary or during shutdown |
| Dplane thread data model | `df00a58f7a`, `6349e49645` | Dplane pthread touched master-thread interface state directly |
| FPM/provider handoff | `b2fc167978`, `c1f29b4e87`, `0d0f516c76` | Provider/FPM handoff lost route messages or referenced freed route state |
| NHT/RNH evaluation and compare | `60c67010f2`, `c5f7794faa`, `feb554e508`, `0aa2408323`, `903f270bfa`, `f99f1ff50a` | RNH old/new comparison, queued route handling, or resolved-route fields were incomplete |
| RNH lifecycle/delete | `b43444f53a`, `70c0f18432`, `b046b633c5` | Deregistration/delete paths could run repeatedly or remove the wrong tracking entry |
| Suppress-fib-pending and owner ack | `3fdb2079f6`, `0a9a77c88d`, `e104afb0d7`, `45cf4b17b5`, `1b25fbf924` | BGP waited for missing acks, set pending on the wrong path, or updated unrelated BGP accounting from FIB notifications |
| BGP/Zebra reconnect replay | `67f78ccd10`, `b47a92e2e5` | Stable selected routes were not replayed to Zebra after reconnect, or stale loop state skipped replay |
| ZAPI notify metadata/encoding | `2af780650f`, `6fe9092eb`, `b74f72c1f`, `16d91fce` | ZAPI payloads lacked metadata or had encode/guard mismatches |

Note: some `--all` commits, including `67f78ccd10`, are present in repository history but are not ancestors of the analyzed checkout. They are retained as mechanism evidence, not as proof that current `HEAD` includes their fix.

### 3.2 GitHub Issue/PR Coverage

GitHub verification used `gh search issues`, `gh search prs`, `gh issue view --comments`, and `gh pr view --comments --reviews`. States were checked on 2026-07-27.

Coverage statistics:

| Metric | Count |
|---|---:|
| Broad unique candidates collected | 755 |
| Issues among candidates | 148 |
| PRs among candidates | 607 |
| Manually relevant candidates triaged | 54 |
| Deeply read threads | 43 |
| Confirmed or design-relevant | 30 |
| Excluded false/user/platform/design | 5 |
| Uncertain/env-limited/stale | 8 |
| Open relevant PRs reviewed | 12 |

Confirmed/design-relevant threads used as evidence:

| Ref | State on 2026-07-27 | Mechanism |
|---|---|---|
| #14481 | Open issue | `RTM_NEWNEXTHOP` can fail during carrier-down timing; route remains failed |
| #22345 | Open PR | Kernel-purged NHG delete treated as hard failure, blocking downstream propagation |
| #18722 | Open draft PR | Kernel NHG flush/delete or quick flap can reinstall route before NHG exists |
| #21415 | Open PR | RIB/FIB NHG context for FPM/SONiC is under repair |
| #6327 | Closed stale, unresolved | Routes failed to recover after interface reappearance with missing NHG id |
| #7299 | Open issue | Zebra removes kernel routes on interface down while kernel only marks linkdown |
| #20167 | Open PR | Connected delete/add coalesces during flaps and NHT sees no change |
| #20540 | Open PR | Kernel delete distance mismatch misses static route entry |
| #18988 | Open issue | BGP route not restored to FIB after GRE up event unless another NH exists |
| #22654 | Closed fixed by `50ed71b6d7` | Early route cleanup removed wrong same-prefix kernel route due missing table id |
| #18041 | Open issue | `RTM_NEWROUTE` before `RTM_NEWLINK` assigns VRF routes to default VRF |
| #21299 | Open issue | IPv6 link-local BGP route not reinstalled after MTU disables/re-enables IPv6 |
| #22780 | Open issue | BGP NHT state and Zebra coalescing leave no async NHT update after down/up |
| #21769 | Merged PR | Partial fix: synthesize NHT withdraw+add after rapid route remove/add |
| #22720 | Open PR | Adds NHT resolution events to dplane; review notes suppressed removals/NHG-id-only changes |
| #16793 | Open draft PR, disputed | NHT can mix recursive-route metadata with fully resolved nexthops |
| #22687 | Open PR | Cross-VRF recursive resolution copies recursive-hop VRF metadata |
| #21519 | Open PR | Recursive nexthop resolution drops SRv6 encap |
| #19712/#19718 | Fixed | vpnv6 SRv6 default route self-match was not programmed to VRF FIB |
| #22752 | Open issue | Inactive deleted self-recursive ECMP nexthop remains in reused NHG |
| #4770 | Merged PR | Foundational `bgp suppress-fib-pending` route-owner/FIB confirmation machinery |
| #1799/#1852/#7818 | Merged PRs | Route notify owner and failure notification paths |
| #21298/#21384 | Fixed | Post-FIB confirmation advertisement delay caused slow convergence |
| #22359/#22411 | Fixed | Routes learned while Zebra was down remained daemon-local after reconnect |
| #22656 | Open PR | Dataplane-provider refresh exists because providers can restart and lose route state |
| #20514/#20525 | Fixed | Inactive VRF/import-table/route-map crashed route realization path |
| #17072 | Open PR | NHE dependency UAF after recursive NHG refresh |
| #22061 | Open issue, repro-limited | Zebra dplane-thread crash during EVPN setup/teardown |
| #22773 | Open PR | BGP unnumbered synthetic neighbor update bypasses dplane and crashes with non-netlink provider |

Excluded examples:

- #15093: external switch/kernel-notification handling, not an FRR-visible route realization oracle.
- #22745: closed invalid due trusted ZAPI boundary.
- #12041: `--retain` expectation on normal stop, not route realization correctness.
- #7718: DANOS/platform-specific.
- #7176: insufficient Zebra route-realization evidence.

## 4. Phase 3 Deep Analysis

### 4.1 `zebra/zebra_rib.c`

Current route selection:

- `rib_process()` finds old/current selected and FIB routes (`zebra/zebra_rib.c:1290`, `zebra/zebra_rib.c:1341`).
- Removed entries are skipped for selection (`zebra/zebra_rib.c:1363`).
- `nexthop_active_update()` failure sends `ZAPI_ROUTE_FAIL_INSTALL` to the owner (`zebra/zebra_rib.c:1377`, `zebra/zebra_rib.c:1411`).
- New selected is flagged before dataplane add/update/delete (`zebra/zebra_rib.c:1495`, `zebra/zebra_rib.c:1550`).

Pre-ack RIB/FPM state:

- `rib_install_kernel()` installs/resolves NHG, sends better-admin-lost notification for some replace cases, sets `dest->selected_fib`, calls `hook_call(rib_update, ...)`, then calls `dplane_route_add/update()` (`zebra/zebra_rib.c:696`, `zebra/zebra_rib.c:702`, `zebra/zebra_rib.c:706`, `zebra/zebra_rib.c:713`, `zebra/zebra_rib.c:716`).
- On `ZEBRA_DPLANE_REQUEST_FAILURE`, it only logs failure to enqueue (`zebra/zebra_rib.c:733`). No owner failure notification is sent from this path.
- `rib_process_update_fib()` clears `ROUTE_ENTRY_CHANGED` after calling install/update paths (`zebra/zebra_rib.c:1138`, `zebra/zebra_rib.c:1198`).

Result matching and stale sequence:

- `rib_route_match_ctx()` matches by type/instance, with extra static/kernel and connected/local checks, but does not use sequence for candidate selection (`zebra/zebra_rib.c:1595`, `zebra/zebra_rib.c:1606`, `zebra/zebra_rib.c:1633`).
- `rib_process_result()` selects route candidates first (`zebra/zebra_rib.c:2028`) and only then checks `dplane_sequence` (`zebra/zebra_rib.c:2046`).
- If `re->dplane_sequence != seq`, the code logs a stale result but does not jump to `done` or suppress later mutations (`zebra/zebra_rib.c:2051`). The same is true for `old_re` mismatch (`zebra/zebra_rib.c:2081`).
- The handler then can set/clear `ROUTE_ENTRY_FAILED`, `ROUTE_ENTRY_INSTALLED`, update nexthop FIB flags from ctx, redistribute, notify owners, and evaluate NHT (`zebra/zebra_rib.c:2093`, `zebra/zebra_rib.c:2117`, `zebra/zebra_rib.c:2163`, `zebra/zebra_rib.c:2181`, `zebra/zebra_rib.c:2238`).

Async route notify:

- `rib_process_dplane_notify()` handles `DPLANE_OP_ROUTE_NOTIFY`, matches with `rib_route_match_ctx(..., async=true)`, and does not check sequence (`zebra/zebra_rib.c:2254`, `zebra/zebra_rib.c:2288`).
- It clears `ROUTE_ENTRY_QUEUED` and `ROUTE_ENTRY_ROUTE_REPLACING` immediately after match (`zebra/zebra_rib.c:2305`).
- If the matched route is not `selected_fib`, it may clear `INSTALLED` when no ctx nexthops have `NEXTHOP_FLAG_FIB`, then returns without owner/NHT notification (`zebra/zebra_rib.c:2313`, `zebra/zebra_rib.c:2327`).
- If selected, it updates offload flags, mirrors FIB flags from ctx, sends owner notifications depending on ACK/offload mode, and evaluates NHT (`zebra/zebra_rib.c:2353`, `zebra/zebra_rib.c:2368`, `zebra/zebra_rib.c:2378`, `zebra/zebra_rib.c:2386`).

Delete path:

- For delete results, the handler comments that core data structures were updated or removed when delete was issued (`zebra/zebra_rib.c:2200`).
- Delete success sends `ZAPI_ROUTE_REMOVED`; delete failure sends `ZAPI_ROUTE_REMOVE_FAIL` (`zebra/zebra_rib.c:2205`, `zebra/zebra_rib.c:2218`).
- `rib_sweep_table()` marks stale selfroutes as installed and FIB-active during startup so they can be removed (`zebra/zebra_rib.c:4924`, `zebra/zebra_rib.c:4950`, `zebra/zebra_rib.c:4954`).

MetaQ:

- `meta_queue_process()` blocks when dataplane input queue length exceeds the limit (`zebra/zebra_rib.c:3218`).
- The code comments say only route nodes are queued and add/delete order is preserved on the route entry itself (`zebra/zebra_rib.c:4018`).
- `MQ_SIZE` is 12 but `RIB_ROUTE_ANY_QUEUED` is hardcoded to `0x3F`, covering only subqueues 0-5 (`zebra/rib.h:204`, `zebra/rib.h:262`).
- Static routes map to subqueue 6 and BGP maps to subqueue 8 (`zebra/zebra_rib.c:120`, `zebra/zebra_rib.c:133`).
- Current code uses `RIB_ROUTE_ANY_QUEUED` in behavior branches such as table update skip and kernel selfroute delete handling (`zebra/zebra_rib.c:4787`, `zebra/zebra_rib.c:3025`).

Compensating mechanisms checked:

- Generic "queued route is always visible to NHT" is not true: NHT skips queued and not installed routes (`zebra/zebra_rnh.c:741`) and requires installed status (`zebra/zebra_rnh.c:606`).
- Shutdown result dropping is intentional terminal behavior: `rib_process_dplane_results()` drains results when `zrouter.in_shutdown` is true (`zebra/zebra_rib.c:5186`).
- Route-node queuing has `MQ_BIT_MASK` duplicate protection (`zebra/zebra_rib.c:3283`), but that does not compensate for branches using `RIB_ROUTE_ANY_QUEUED`.

### 4.2 `zebra/zebra_dplane.c`

Context and sequence:

- `struct zebra_dplane_ctx` is the ownership-transfer object between Zebra main and dataplane/provider threads (`zebra/zebra_dplane.c:450`).
- It carries `zd_seq`, `zd_old_seq`, provider id, status, and route payload (`zebra/zebra_dplane.c:455`, `zebra/zebra_dplane.c:466`, `zebra/zebra_dplane.c:472`).
- `dplane_ctx_route_init()` copies route attributes, nexthops, table/VRF, MTU, tag, distance, and instance (`zebra/zebra_dplane.c:3992`, `zebra/zebra_dplane.c:3994`, `zebra/zebra_dplane.c:3999`, `zebra/zebra_dplane.c:4001`, `zebra/zebra_dplane.c:4002`).
- Kernel-NHG mode fails context initialization if the needed NHG is neither installed nor queued (`zebra/zebra_dplane.c:4129`, `zebra/zebra_dplane.c:4140`).

Enqueue and provider loop:

- `dplane_update_enqueue()` puts contexts on `dg_update_list` and wakes the dataplane provider work loop (`zebra/zebra_dplane.c:4777`, `zebra/zebra_dplane.c:4785`, `zebra/zebra_dplane.c:4812`).
- `dplane_route_update_internal()` frees the context and returns failure if context init/enqueue fails (`zebra/zebra_dplane.c:4821`, `zebra/zebra_dplane.c:4881`, `zebra/zebra_dplane.c:4886`).
- `dplane_thread_loop()` transfers work through provider in/out queues and returns error lists before work lists to Zebra main (`zebra/zebra_dplane.c:8122`, `zebra/zebra_dplane.c:8220`, `zebra/zebra_dplane.c:8370`).
- The loop contains a TODO about improving error handling and undo across providers (`zebra/zebra_dplane.c:8226`).

Kernel-NHG route-attribute skip:

- `kernel_dplane_process_func()` marks a `DPLANE_OP_ROUTE_UPDATE` as success and skips kernel update if old/new NHE id and route type match under kernel nexthops (`zebra/zebra_dplane.c:7747`, `zebra/zebra_dplane.c:7756`).
- The context carries route attributes such as MTU and tag (`zebra/zebra_dplane.c:3999`, `zebra/zebra_dplane.c:4002`), and netlink encoding normally includes route tag/realm and MTU metrics (`zebra/rt_netlink.c:2617`, `zebra/rt_netlink.c:2652`).
- This is a concrete test-verifiable route realization question: same NHG id/type with changed route attributes.

Provider-private queue and shutdown:

- `dplane_provider_enqueue_out_ctx()` appends to a provider out queue and updates counters, but does not call `dplane_provider_work_ready()` (`zebra/zebra_dplane.c:7063`).
- FPM can move route contexts into its private `ctxqueue` (`zebra/dplane_fpm_nl.c:1801`) and later enqueue provider output (`zebra/dplane_fpm_nl.c:1567`).
- `dplane_work_pending()` checks only `dg_update_list` plus provider visible in/out queues (`zebra/zebra_dplane.c:8009`, `zebra/zebra_dplane.c:8020`, `zebra/zebra_dplane.c:8032`).
- `zebra_dplane_shutdown()` frees provider objects, then has a later loop intended to clean provider queues after the provider list has been emptied (`zebra/zebra_dplane.c:8416`, `zebra/zebra_dplane.c:8446`).

Compensating mechanisms checked:

- The kernel provider itself drains visible work in its normal callback path (`zebra/zebra_dplane.c:7783`).
- Provider-private queues matter to the route-realization model only if modeling non-kernel providers or provider restart/loss; otherwise they are a test/code-review target.

### 4.3 `zebra/zebra_rnh.c`

Resolution:

- `rnh_nexthop_valid()` requires route installed and nexthop active, while rejecting recursive, duplicate, and filtered nexthops (`zebra/zebra_rnh.c:606`).
- It does not require `NEXTHOP_FLAG_FIB`, so an installed route with active nexthops can satisfy NHT even if per-nexthop FIB flags lag or are stale.
- `zebra_rnh_resolve_nexthop_entry()` skips removed entries and non-selected/non-FIB-override entries (`zebra/zebra_rnh.c:724`, `zebra/zebra_rnh.c:732`).
- It skips queued routes only when they are not installed (`zebra/zebra_rnh.c:741`).

Registration and attachment:

- `zebra_add_rnh()` allocates a new RNH with `resolved_route` set to default family/prefix and immediately calls `zebra_rnh_store_in_routing_table()` (`zebra/zebra_rnh.c:224`, `zebra/zebra_rnh.c:244`).
- `zebra_rnh_store_in_routing_table()` uses `route_node_match()` and returns if no covering route table node with info exists (`zebra/zebra_rnh.c:139`, `zebra/zebra_rnh.c:153`).
- `route_node_match()` returns only nodes with `node->info` (`lib/table.c:246`, `lib/table.c:250`).
- Later RIB result reevaluation walks existing `dest->nht` lists; it does not obviously scan all RNH registrations on every route add (`zebra/zebra_rib.c:917`, `zebra/zebra_rib.c:952`).

Snapshot comparison:

- `copy_state()` copies type, distance, metric, vrf, status, and NHE, but not `route_entry.instance` (`zebra/zebra_rnh.c:1020`, `zebra/zebra_rnh.c:1033`).
- `zebra_send_rnh_update()` encodes `re->instance` to clients (`zebra/zebra_rnh.c:1222`).
- `compare_state()` compares type, distance, metric, and valid primary nexthops only (`zebra/zebra_rnh.c:1127`).
- `rnh_check_re_nexthops()` can use backup nexthops for route usability (`zebra/zebra_rnh.c:628`), while `compare_valid_nexthops()` starts with `next_valid_primary_nh()` (`zebra/zebra_rnh.c:1077`) and `zebra_send_rnh_update()` iterates `rib_get_fib_nhg(re)` (`zebra/zebra_rnh.c:1230`).

Compensating mechanisms checked:

- New or flag-changed NHT registration forces evaluation (`zebra/zapi_msg.c:1335`).
- Quick flap handling can synthesize NHT removal/add via `ROUTE_ENTRY_SEND_NHT_REMOVAL` (`zebra/zebra_rib.c:1513`, `zebra/zebra_rib.c:2238`), but open issues/PRs show this area remains active.

### 4.4 `zebra/zapi_msg.c`, `zserv`, and `lib/zclient.c`

Route-owner notify:

- `route_notify_internal()` finds the owner with `zserv_find_client(type, instance)` (`zebra/zapi_msg.c:763`).
- `zserv_find_client()` searches session id 0 (`zebra/zserv.c:1594`, `zebra/zserv.c:1599`), while `zserv_find_client_session()` supports full session lookup (`zebra/zserv.c:1608`).
- NHG notify uses `zserv_find_client_session(type, instance, session_id)` (`zebra/zapi_msg.c:716`, `zebra/zapi_msg.c:722`), so route notify and NHG notify differ in session handling.
- The route notify payload includes note, prefix, source prefix, table id, AFI, and SAFI (`zebra/zapi_msg.c:786`, `zebra/zapi_msg.c:804`, `zebra/zapi_msg.c:807`), but no route generation/path id/transaction id.
- `zread_route_notify_request()` sets `client->notify_owner` from a single byte (`zebra/zapi_msg.c:850`, `zebra/zapi_msg.c:855`).
- New `zserv` clients are zero-initialized (`zebra/zserv.c:799`, `zebra/zserv.c:807`), so notification subscription is connection-local unless explicitly resent.

Client send behavior:

- `zclient_send_message()` returns `ZCLIENT_SEND_FAILURE` if the socket is not connected (`lib/zclient.c:381`, `lib/zclient.c:383`).
- `zclient_failed()` stops and reconnects the client (`lib/zclient.c:341`, `lib/zclient.c:344`, `lib/zclient.c:345`).
- Buffered writes have a callback path (`lib/zclient.c:367`, `bgpd/bgp_zebra.c:1988`).

### 4.5 `bgpd/bgp_zebra.c`, `bgpd/bgpd.c`, and `bgpd/bgp_route.h`

BGP route send queue:

- `bgp_zebra_route_install()` sets `BGP_NODE_FIB_INSTALL_PENDING` when suppress-fib-pending is enabled and the dest is not already installed (`bgpd/bgp_zebra.c:2056`, `bgpd/bgp_zebra.c:2069`).
- It returns early for `main_zebra_update_hold` after setting pending (`bgpd/bgp_zebra.c:2075`).
- It checks `bgp_install_info_to_zebra()` only after pending handling (`bgpd/bgp_zebra.c:2086`). That helper returns false if the socket is down or Zebra does not know the BGP instance (`bgpd/bgp_zebra.c:74`, `bgpd/bgp_zebra.c:76`, `bgpd/bgp_zebra.c:79`).
- The announcement worker pops the queue inode, decrements queue count, sends add/delete, clears schedule flags, unlocks, clears queue pointers, and frees the inode (`bgpd/bgp_zebra.c:1894`, `bgpd/bgp_zebra.c:1907`, `bgpd/bgp_zebra.c:1936`, `bgpd/bgp_zebra.c:1949`, `bgpd/bgp_zebra.c:1963`, `bgpd/bgp_zebra.c:1968`).
- It breaks only on `ZCLIENT_SEND_BUFFERED`; ordinary send failure is not requeued in this function (`bgpd/bgp_zebra.c:1970`).

BGP notify consumer:

- BGP decodes route notify table id but looks up the current destination by VRF/AFI/SAFI/prefix (`bgpd/bgp_zebra.c:3059`, `bgpd/bgp_zebra.c:3075`).
- `ZAPI_ROUTE_INSTALLED` decrements pending, clears pending, sets installed, and announces the current selected path (`bgpd/bgp_zebra.c:3086`, `bgpd/bgp_zebra.c:3089`, `bgpd/bgp_zebra.c:3091`, `bgpd/bgp_zebra.c:3105`).
- `ZAPI_ROUTE_REMOVED` clears installed (`bgpd/bgp_zebra.c:3115`, `bgpd/bgp_zebra.c:3120`).
- `ZAPI_ROUTE_FAIL_INSTALL` and `ZAPI_ROUTE_BETTER_ADMIN_WON` decrement pending, clear pending/installed, and announce current selected if present (`bgpd/bgp_zebra.c:3124`, `bgpd/bgp_zebra.c:3129`, `bgpd/bgp_zebra.c:3140`, `bgpd/bgp_zebra.c:3145`).
- `ZAPI_ROUTE_REMOVE_FAIL` logs only (`bgpd/bgp_zebra.c:3162`).

Reconnect and subscription:

- `bgp_zebra_connected()` sends BFD registration, registers the BGP instance, retries deferred suppress-fib-pending config, and has a TODO about kick-starting peers/networks (`bgpd/bgp_zebra.c:3300`, `bgpd/bgp_zebra.c:3317`, `bgpd/bgp_zebra.c:3320`, `bgpd/bgp_zebra.c:3322`).
- Per-instance suppress-fib-pending config is deferred if the socket is not ready (`bgpd/bgpd.c:541`, `bgpd/bgpd.c:548`) and retried only if the deferred flag is set (`bgpd/bgpd.c:610`, `bgpd/bgpd.c:617`).
- Global wait-for-FIB sends `ZEBRA_ROUTE_NOTIFY_REQUEST` directly when needed (`bgpd/bgpd.c:484`, `bgpd/bgpd.c:485`).
- `zclient_send_reg_requests()` resends router-id/interface/redistribution registration, but no route notify subscription was found in that function (`lib/zclient.c:617`, `lib/zclient.c:631`).

Compensating mechanisms checked:

- BGP re-finds the current selected path on notify instead of storing a stale path pointer (`bgpd/bgp_zebra.c:3094`, `bgpd/bgp_zebra.c:3132`, `bgpd/bgp_zebra.c:3148`).
- Unmatched BGP destinations are ignored (`bgpd/bgp_zebra.c:3077`).
- `ZCLIENT_SEND_BUFFERED` is handled by a write-ready callback, so the send-failure concern is specifically `ZCLIENT_SEND_FAILURE`, not backpressure buffering.

## 5. Scenario Synthesis

The analysis groups findings by mechanism, not by file:

1. Dataplane result generation and speculative RIB state.
2. Route-owner/ZAPI notification correlation and BGP FIB-pending state.
3. NHT/RNH reduced or stale observation.
4. MetaQ, startup, reconnect, and queue ordering reconciliation.
5. Provider/NHG boundary and partial dataplane pipelines.

The highest-priority TLA+ work is Scenarios 1 and 2. They are message-ordering problems with externally visible route-owner state. Scenario 3 should be modeled if NHT correctness is a first-class goal. Scenario 4 should be partly modeled for queue coalescing/reconnect and partly tested for implementation-specific queue masks. Scenario 5 should be added only as much as needed to exercise provider loss/delay effects on Scenarios 1 and 2.

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

These are forward-looking mechanism questions. Closed historical bugs are cited as evidence of bug-prone mechanisms and are not listed as model-checking targets merely to reproduce old fixes.

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
| CR1 | Route-owner notify uses session 0 while doc defines `{protocol, instance, session_id}` and NHG notify uses full session lookup | Maintainer review whether route ownership is intentionally session-0 only |
| CR2 | `copy_state()` and `compare_state()` omit `route_entry.instance` even though NHT update encoding sends instance | Audit whether instance-only changes are legal and should force an NHT update |
| CR3 | `zebra_dplane_shutdown()` frees providers before a later loop intended to clean provider queues | Review shutdown cleanup ordering |
| CR4 | BGP `ZAPI_ROUTE_REMOVE_FAIL` handler logs only; no retry/reconcile path | Maintainer decision on retry/resync/operator-only semantics |

## 7. Exclusions and False Positives

- Generic "NHT observes every queued route" was excluded. Resolver skips queued routes that are not installed and requires installed/active nexthops (`zebra/zebra_rnh.c:741`, `zebra/zebra_rnh.c:606`).
- BGP sync label-manager client receiving route owner notifications was excluded. BGP route ownership uses the main session; the sync session has `session_id = 1` (`bgpd/bgp_zebra.c:4611`) while route notify searches session 0 (`zebra/zserv.c:1594`).
- Source-prefix notify mismatch was not prioritized. Zebra encodes source prefix (`zebra/zapi_msg.c:796`), but BGP route notify decode uses the non-srcdest helper (`lib/zclient.c:2221`). BGP's route input currently ignores srcdest redistributed routes in the checked path (`bgpd/bgp_zebra.c:544`).
- Shutdown result draining is intentional terminal behavior, not a normal route realization bug. Zebra drops dataplane results after shutdown starts (`zebra/zebra_rib.c:5186`).
- EVPN/FPM-only behavior was not used as a primary modeling target unless it affects route realization visibility across Zebra/BGP/NHT.
- Memory-safety-only crashes and stream encoding bounds were recorded as historical risk but excluded from model-checkable findings.

## 8. Phase 2.5 Harness Constraint for Later Work

This phase did not instrument or run FRR. For the later harness/trace-validation phase, the target-specific constraint must be followed:

- Build and run FRR through Docker topotest runtime, not directly on the host.
- Use image `ncp/frr-replay:ubuntu22-topotest`.
- Mount the host source tree at `/root/host-frr`, the run/output directory at `/tmp`, and persistent build cache at `/root/persist`.
- Let `/opt/topotests/entrypoint.sh` rebuild/install FRR.
- Run `/usr/lib/frr/zebra` and related daemons inside the container.
- Collect real NDJSON traces into `.specula-output/traces`.
- If instrumentation, rebuild, or real trace generation fails, mark Phase 2.5 / trace validation as blocked. Synthetic traces may only be debug aids.

## 9. Deliverables

- Primary modeling brief: `/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/modeling-brief.md`
- Detailed analysis report: `/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output/analysis-report.md`
