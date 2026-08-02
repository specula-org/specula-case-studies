# iccpd Code Analysis Report

## Executive Summary

This audit analyzed SONiC `iccpd` at commit `9df8ccbf72c31948741b5554d09c38ac6c1ec6e9` as a **Category A distributed/message-passing system**. The daemon is a single-threaded protocol engine whose meaningful concurrency comes from two peers, TCP delivery, timers, kernel/netlink events, process restart, and asynchronous `mclagsyncd`/ASIC effects—not from shared-memory workers.

The highest-value results are four mechanism families:

1. Peer warm-reboot grace is recorded and immediately erased, while its fallback timeout is unreachable during disconnection. Ordinary failover cleanup can therefore be suppressed forever.
2. Synchronization stages, dirty flags, and delta queues are committed after one unchecked one-shot write. In addition, a legal Sync Request received in `EXCHANGE` increments the mLACP FSM into `ERROR`.
3. IF_UP acknowledgement is not bound to a LAG transition and can be sent without a matching peer interface or a successfully applied isolation rule. A stale/false ACK can enable unsafe traffic; ACK loss can leave a healthy LAG disabled.
4. Blocking/fragmented streams and ignored sidecar failure can stop the sole scheduler or permanently separate desired, shadow, and applied forwarding state.

The primary handoff is `modeling-brief.md`. This report preserves the audit trail, including historical coverage, current open fixes, exact code traces, compensating mechanisms, false-positive exclusions, and verification recommendations.

## 1. Scope, Revision, and Method

### 1.1 Target

| Item | Value |
|---|---|
| Repository | `/users/Pial/targets/sonic-buildimage-iccpd` |
| Upstream | [sonic-net/sonic-buildimage](https://github.com/sonic-net/sonic-buildimage) |
| Revision | `9df8ccbf72c31948741b5554d09c38ac6c1ec6e9` |
| Focus | `src/iccpd`: ICCP/mLACP protocol, peer synchronization, failover, restart, and recovery |
| Language/scale | C; 23,641 physical C/header lines under `src/iccpd`, about 21 K after bundled tree/control-client exclusions |
| Reference | [RFC 7275](https://www.rfc-editor.org/rfc/rfc7275.html) |
| Category | A — distributed/message-passing, non-BFT |

No repository files were modified. Only the two requested documents were created in the output directory.

### 1.2 Four-phase execution

- **Phase 1 — Reconnaissance**: mapped process structure, state machines, messages, roles, event sources, side effects, recovery entry points, and atomicity boundaries.
- **Phase 2 — Bug archaeology**: audited all 15 history objects touching core ICCPd code (14 logical changes), collected 80 potentially relevant issues, deeply read 30 complete issue threads and all 93 comments, and audited every intent-filtered open bug-fix PR (12 descriptions and all 17 discussion comments).
- **Phase 3 — Deep analysis**: complete reads of the principal transport/FSM/synchronization/recovery files were split across parallel reviewers, then cross-checked at exact source lines and against callers, compensations, git blame, open PRs, deployment wrappers, and RFC behavior.
- **Phase 4 — Modeling synthesis**: applied the output-value litmus, grouped by mechanism, retained closed fixes only as evidence/reference, and separated model-checkable questions from test/code-review work.

### 1.3 Files read completely

Core sources read end-to-end:

- `src/iccpd/src/iccp_main.c`
- `src/iccpd/src/system.c`
- `src/iccpd/src/scheduler.c`
- `src/iccpd/src/iccp_csm.c`
- `src/iccpd/src/app_csm.c`
- `src/iccpd/src/mlacp_fsm.c`
- `src/iccpd/src/mlacp_sync_prepare.c`
- `src/iccpd/src/mlacp_sync_update.c`
- `src/iccpd/src/mlacp_link_handler.c`
- `src/iccpd/src/iccp_netlink.c`
- `src/iccpd/src/iccp_ifm.c`
- `src/iccpd/src/port.c`

The corresponding protocol/state/wire headers were read completely: `system.h`, `scheduler.h`, `iccp_csm.h`, `app_csm.h`, `mlacp_fsm.h`, `mlacp_tlv.h`, `mlacp_link_handler.h`, `mlacp_sync_prepare.h`, `mlacp_sync_update.h`, `msg_format.h`, `iccp_ifm.h`, `iccp_netlink.h`, and `port.h`. CLI/control/display files and deployment/YANG files were read along the paths required to verify command, schema, startup, and multi-domain claims.

## 2. Phase 1 — Structural Map

### 2.1 Runtime and concurrency model

`scheduler.c:462-486` repeatedly handles events and advances FSMs. The five permanent descriptors plus control, syncd, signal, and peer descriptors are dispatched inline in `iccp_netlink.c:2168-2242`; each CSM then advances ICCP, application, and mLACP FSMs serially (`scheduler.c:102-117`).

`scheduler.c:59-72` implements mutex wrappers as no-ops, but this is **not a current data race**: there is no `pthread_create` in the ICCPd tree, daemonization forks before the event loop, and the signal handler only writes the signal pipe. Consequently:

- handlers and FSM transitions are atomic with respect to one another only while they do not block;
- a blocking receive/write or inline sleep freezes every peer, timer, netlink update, CLI action, and failover transition;
- global scratch buffers are safe under the present serial ownership assumption, not under hypothetical worker-thread introduction.

### 2.2 State machines and persistent views

| Layer | States / role | Source |
|---|---|---|
| ICCP CSM | `NONEXISTENT`, `INITIALIZED`, capability negotiation, connecting, operational | `iccp_csm.h:82-91`, `iccp_csm.c` |
| Application CSM | six RFC-shaped states are declared, but implementation jumps directly to operational | `app_csm.h:33-58`, `app_csm.c:80-98` |
| mLACP | `INIT`, `STAGE1`, `STAGE2`, `EXCHANGE`, `ERROR` | `mlacp_fsm.h:39-46`, `mlacp_fsm.c` |
| Sync response | system config → aggregation config/state/info → peer-link → ARP → ND → done | `mlacp_fsm.h:50-61`, `mlacp_fsm.c:1393-1463` |
| Session role | lower-address connector is active; accepted peer is standby | `scheduler.c:579-701`, `iccp_csm.c:845-869` |

The in-memory `System`, `CSM`, local/peer interfaces, and MAC/ARP/ND trees are control-plane shadows. Authoritative/reconstructed information also arrives from netlink and `mclagsyncd`; forwarding effects are delegated through socket messages, shell/ebtables commands, and STATE_DB updates.

### 2.3 Message and failure boundaries

| Logical operation | Actual boundary sequence | Interleavings/failures |
|---|---|---|
| Peer state update | mutate/clear local state → `write` → TCP delivery → peer handler | short/error write, disconnect, delayed delivery, no retry |
| Full synchronization | Start → several config/state messages → End → stage advance | any write can fail; no transaction/epoch proof; legal resync can alter wrong FSM state |
| LAG-up handshake | local disable → peer update → external isolation → ACK → local enable | missing peer object, external failure, ACK loss/delay/ABA |
| Warm failover | receive marker → disconnect handler → reset → timeout/reconnect | marker erased, timeout unreachable, cleanup skipped |
| Sidecar update | desired/shadow mutation → syncd/kernel write → optional DB update | partial/blocking send, stale fd, ignored failure, crash/restart |
| Netlink recovery | enumerate/read event → mutate shadow → advertise/apply | `UNKNOWN` state, replay ordering, transient link bounce, incomplete address replay |

### 2.4 Reference comparison

The reference is ICCP/mLACP in RFC 7275. Material deviations are:

- RFC §§4.2 and 4.4 define separate six-state ICCP and application state machines. SONiC bypasses the application Connect/A-bit/version exchange (`app_csm.c:80-98`).
- RFC §3.3/§4.5 assumes transport flow control, retransmission, in-order and lossless application delivery. SONiC uses a one-shot `write` and commits state on failure/short write (`iccp_csm.c:245-281`).
- RFC §5 does not make ICCP-owned keepalive the sole peer-death proof. SONiC uses a custom heartbeat and refreshes it on any complete message (`iccp_netlink.c:2225-2235`).
- RFC §§7.2.9-7.2.10 reserve Sync Request number zero for unsolicited Sync Data and require correlation. SONiC always requests with zero and never validates response identity (`mlacp_sync_prepare.c:49-146`; `mlacp_fsm.c:538-568`).
- RFC §7.2.3 limits Node ID to 0-7. SONiC constructs values with the high bit set and mutates its local Node ID on collision (`mlacp_fsm.c:873-884`; `mlacp_sync_update.c:44-79`).
- RFC §9.2.2 requires collision rejection/suspension and ordered re-initialization/purge on identity change. SONiC continues after mutation/NAK and uses custom replay behavior.
- Raw TCP port 8888 replaces the RFC LDP transport, and custom heartbeat, warmboot, MAC, ARP, ND, peer-link, port-channel, and IF_UP_ACK TLVs extend the protocol.

Homogeneous SONiC peers share these deviations, so deployed same-version operation is less exposed than standards interoperability. The selected formal model therefore treats them as implementation semantics while retaining RFC ordering and synchronization obligations.

## 3. Phase 2 — Bug Archaeology

### 3.1 Git history coverage

`git rev-list --all --count -- src/iccpd/src src/iccpd/include` returned 15 commit objects. PR #4819 appears as two equivalent hashes on divergent histories, leaving 14 logical changes. Every object and diff was reviewed; eight are dedicated bug/hardening changes, one is the initial import with embedded repairs, and five are feature/build/cleanup changes.

| Commit / PR | Classification | Root cause and disposition |
|---|---|---|
| `524cf9e56` / [#2514](https://github.com/sonic-net/sonic-buildimage/pull/2514) | Initial feature | Imported the original ICCPd state machines plus embedded warm-reboot/failover fixes; several current recovery defects originate here. |
| `4c55adfd6` / [#4422](https://github.com/sonic-net/sonic-buildimage/pull/4422) | Feature | Added IPv6 ND synchronization; later history and current self-comparison show this path remains error-prone. |
| `2398992d5` / [#4540](https://github.com/sonic-net/sonic-buildimage/pull/4540) | Build | Autotools/debian packaging; no core correctness change. |
| `82b6bcfbb`, `44a2cd8b1` / [#4819](https://github.com/sonic-net/sonic-buildimage/pull/4819) | Feature/import | Same logical enhancement on two histories; introduced the current syncd framing/IF_ACK generation. It also re-imported an older `iccp_cmd_show.c`, losing #5214's fix. |
| `570dbf52f` / [#5112](https://github.com/sonic-net/sonic-buildimage/pull/5112) | Bug fix | Zero-initialized netlink `rtattr` pointer tables before optional attribute use. Current equivalent paths retain the initialization. |
| `426b6aaf5` / [#5214](https://github.com/sonic-net/sonic-buildimage/pull/5214) | Bug fix, regressed | Reset per-domain CLI output length. Later #4819 overwrote the fix; current `iccp_cmd_show.c:64-142` carries stale `len` across CSMs. Supported YANG limits domains to one, reducing production reachability. |
| `31dd0b3bf` / [#11197](https://github.com/sonic-net/sonic-buildimage/pull/11197) | Build fix | Added a missing semicolon; local syntactic defect only. |
| `7d1b99a88` / [#11694](https://github.com/sonic-net/sonic-buildimage/pull/11694) | Hardening | Replaced unsafe string APIs; current code has additional, separately audited size-contract defects. |
| `a73d443c1` / [#15162](https://github.com/sonic-net/sonic-buildimage/pull/15162) | Cleanup | Whitespace-only source normalization. |
| `c01f03164` / [#18270](https://github.com/sonic-net/sonic-buildimage/pull/18270) | Hardening | Added `memset`/copy/`strncpy` bounds. The startup-token fix introduced/left a wrong capacity guard at `iccp_cmd.c:137-143`. |
| `e57d46c7a` / [#18269](https://github.com/sonic-net/sonic-buildimage/pull/18269) | Cleanup | Removed an unused function. |
| `34c8adb93` / [#21172](https://github.com/sonic-net/sonic-buildimage/pull/21172) | Critical bug fix | Replaced fixed stack isolation collection that overflowed with many LAGs; corresponds to the crash reported in #16075. |
| `a06aeebd1` / [#26567](https://github.com/sonic-net/sonic-buildimage/pull/26567) | Security hardening | Validated variable entry counts/message lengths for PortChannel/MAC/ARP/ND TLVs. Fixed those count-driven overreads, but base/fixed TLVs remain unchecked. |
| `30ac069cf` / [#26930](https://github.com/sonic-net/sonic-buildimage/pull/26930) | Security hardening | Added inner bounds to ARP/ND update handlers. Current fixed-message and envelope gaps remain independent. |

The churn hotspots agree with the findings: `mlacp_link_handler.c` dominates, followed by `iccp_netlink.c`, `iccp_ifm.c`, `mlacp_fsm.c`, `mlacp_sync_update.c`, and `scheduler.c`.

#### Closed-fix PR discussion verification

The eight dedicated historical fix PRs were also checked against their complete public conversation/review threads, validation claims, and current source. GitHub REST was rate-limited (`403`, remaining quota zero), so the audit used the public conversation HTML plus every deferred review-thread fragment; all requested fragments returned HTTP 200. Counts below are DOM-derived and could not be independently REST-cross-checked.

| PR | Discussion read | Validation claimed | Current compensation / caveat |
|---|---|---|---|
| [#5112](https://github.com/sonic-net/sonic-buildimage/pull/5112) | 3 general, 2 reviews, 1 inline | MCLAG L2 HLD scenarios, no attached output | Effective: live neighbor attribute table remains zeroed at `iccp_ifm.c:679`; second old parser was removed. |
| [#5214](https://github.com/sonic-net/sonic-buildimage/pull/5214) | 3 general, 2 reviews, 3 inline/replies | Four MCLAG groups displayed correctly | **Regressed** by #4819: `len=0` disappeared and current `iccp_cmd_show.c:64-142` reproduces carry-over for raw multi-domain input. |
| [#11197](https://github.com/sonic-net/sonic-buildimage/pull/11197) | 0 general, 1 approval, 0 inline | Rebuilt package and inspected log | Effective at `scheduler.c:873-874`; no demonstrated runtime failure preceded it. |
| [#11694](https://github.com/sonic-net/sonic-buildimage/pull/11694) | 0 general, 32 reviews, 30 resolved threads/36 comments | None supplied | Landed changes remain. Review correctly rejected unsafe `memset_s`/`sizeof(*buf)` transformations and narrowed the patch; it was hardening, not exhaustive proof. |
| [#18270](https://github.com/sonic-net/sonic-buildimage/pull/18270) | 0 general, 9 reviews, 8 threads/10 replies; 2 UI-unresolved | None supplied | **Partial/defective**: `unset_peer_link` still clears 20 bytes through a 16-byte field; exact-capacity checks use `>`; the token guard reads uninitialized `token` and is not a capacity check. |
| [#21172](https://github.com/sonic-net/sonic-buildimage/pull/21172) | 0 general, 1 approval, 0 inline | Forced a 20-byte buffer with two LAGs; warning/no overflow/session established | Memory overwrite is blocked, but >2048-byte isolation sets are logged and omitted rather than chunked, so functional isolation can remain incomplete. |
| [#26567](https://github.com/sonic-net/sonic-buildimage/pull/26567) | 0 general, 3 reviews, 1 inline | Crafted `0xffff` MAC-count scenario described; no attached run | Effective for four variable-count handlers at `mlacp_fsm.c:575-724`; fixed TLVs/base envelope remain outside scope. |
| [#26930](https://github.com/sonic-net/sonic-buildimage/pull/26930) | 0 general, 1 approval, 0 inline | Malformed-count test proposed; outer guard would fire first | Inner ARP/ND checks remain at `mlacp_sync_update.c:905-924,1233-1252`; fixed header must already be readable and callers ignore the error return. |

Six repairs remain effective within their intended scope; #5214 was reintroduced and #18270 remains materially incomplete/incorrect. These closed fixes are evidence and regression context, not model-check targets.

### 3.2 GitHub issue coverage

Nineteen keyword/label searches produced 80 candidate issues. Thirty were selected for full-thread verification; their bodies and all 93 comments were read, not title-classified. The three parallel batches contained 10 issues/20 comments, 10/11, and 10/62. Final classification: **16 confirmed defects/design defects**, **10 excluded from ICCPd correctness modeling**, and **4 unresolved hypotheses**.

| Issue | Classification | Verified result |
|---|---|---|
| [#17606](https://github.com/sonic-net/sonic-buildimage/issues/17606) | Uncertain | FDB/ASIC asynchronous behavior was hypothesized, but the thread does not prove the ICCPd cause. |
| [#16075](https://github.com/sonic-net/sonic-buildimage/issues/16075) | Confirmed/core | ICCPd stack crash on peer reconnect with about 25 LAGs; isolation-list overflow was fixed by #21172. Adjacent orchagent behavior was unresolved. |
| [#19618](https://github.com/sonic-net/sonic-buildimage/issues/19618) | Confirmed/deployment | Standby system-MAC programming failed without `NET_ADMIN`; fixed on master by #19324, absent on the older branch. |
| [#19556](https://github.com/sonic-net/sonic-buildimage/issues/19556) | Confirmed/deployment | Same system-MAC/container-capability defect and fix lineage as #19618. |
| [#19909](https://github.com/sonic-net/sonic-buildimage/issues/19909) | Confirmed/adjacent | Static allow-move to dynamic FDB transition can hit invalid SAI behavior and crash orchagent; still open, outside ICCPd proper but relevant to external apply. |
| [#14953](https://github.com/sonic-net/sonic-buildimage/issues/14953) | Excluded | LACP fallback combined with MCLAG is unsupported, not a demonstrated supported-path protocol bug. |
| [#21339](https://github.com/sonic-net/sonic-buildimage/issues/21339) | Confirmed/config | YANG/config validation mismatch; genuine configuration-plane defect, not a peer-FSM target. |
| [#21529](https://github.com/sonic-net/sonic-buildimage/issues/21529) | Excluded/adjacent | Confirmed FlexCounter/syncd crash, but not an ICCPd defect. |
| [#19323](https://github.com/sonic-net/sonic-buildimage/issues/19323) | Confirmed/integration | Legacy ebtables isolation application failed; fixed by #19324 and retained as evidence that external apply can fail. |
| [#6640](https://github.com/sonic-net/sonic-buildimage/issues/6640) | Uncertain | Custom/incomplete backport lacked `mclagsyncd`; insufficient evidence against supported mainline. |
| [#28697](https://github.com/sonic-net/sonic-buildimage/issues/28697) | Confirmed/current | Startup parser calls `strlen(token)` in the capacity guard rather than checking destination capacity; proposed zero-init alone is insufficient. |
| [#28696](https://github.com/sonic-net/sonic-buildimage/issues/28696) | Confirmed/current | Eight direct `realloc` assignments leak the old display buffer on failure; low-severity local error handling. |
| [#28695](https://github.com/sonic-net/sonic-buildimage/issues/28695) | Confirmed/qualified | 20-byte clear through a 16-byte subobject is C-level overflow, but disconnect reset and valid NUL-terminated interface names neutralize much of the claimed runtime impact. |
| [#6590](https://github.com/sonic-net/sonic-buildimage/issues/6590) | Excluded | Cosmetic/reporting issue with no protocol consequence. |
| [#27640](https://github.com/sonic-net/sonic-buildimage/issues/27640) | Confirmed/adjacent | STP packaging defect; real but outside ICCPd. |
| [#27641](https://github.com/sonic-net/sonic-buildimage/issues/27641) | Confirmed/adjacent | Companion STP packaging defect; real but outside ICCPd. |
| [#25816](https://github.com/sonic-net/sonic-buildimage/issues/25816) | Excluded | VPP test/enablement request, not an ICCPd bug. |
| [#26088](https://github.com/sonic-net/sonic-buildimage/issues/26088) | Excluded | VPP enablement request, not a failure in the target. |
| [#10245](https://github.com/sonic-net/sonic-buildimage/issues/10245) | Excluded | Resolved test-infrastructure problem with no production ICCPd path. |
| [#4473](https://github.com/sonic-net/sonic-buildimage/issues/4473) | Uncertain | Global systemd `Requires` reboot problem; ICCPd contribution was not isolated. |
| [#5310](https://github.com/sonic-net/sonic-buildimage/issues/5310) | Confirmed/adjacent | Original activation policy plus a confirmed TH1 isolation/SAI failure later fixed in the #4819/swss stack. |
| [#9855](https://github.com/sonic-net/sonic-buildimage/issues/9855) | Excluded | Expected packaging/feature policy, not a defect. |
| [#9153](https://github.com/sonic-net/sonic-buildimage/issues/9153) | Confirmed/adjacent | Platform-environment isolation failure in `mclagsyncd`, fixed by #8945. |
| [#9984](https://github.com/sonic-net/sonic-buildimage/issues/9984) | Confirmed/current integration | `mclagsyncd` crash followed by failed restart; root remained unresolved and matches the stale-fd/reconnect audit. |
| [#8798](https://github.com/sonic-net/sonic-buildimage/issues/8798) | Uncertain | Feature masking suspected; discussion did not establish an ICCPd root cause. |
| [#18400](https://github.com/sonic-net/sonic-buildimage/issues/18400) | Excluded | Docker/environment failure misattributed to ICCPd. |
| [#10055](https://github.com/sonic-net/sonic-buildimage/issues/10055) | Excluded | Generic build failure without target-specific defect evidence. |
| [#18997](https://github.com/sonic-net/sonic-buildimage/issues/18997) | Excluded | Unsupported vendor tunnel knob; ICCPd remained operational. |
| [#20087](https://github.com/sonic-net/sonic-buildimage/issues/20087) | Confirmed/adjacent | ZTP/configuration defect, not in peer synchronization but a real deployment failure. |
| [#4503](https://github.com/sonic-net/sonic-buildimage/issues/4503) | Confirmed/service | Startup dependency noise was fixed by disabling ICCPd/`mclagsyncd` by default; service integration rather than protocol logic. |

### 3.3 Open bug-fix PR coverage

As of 2026-07-31 UTC, 19 term/label sweeps returned 32 unique open PR hits. Intent inspection excluded 20 unrelated multi-chassis/BGP/platform changes or generic non-bug changes. All 12 remaining bug-fix descriptions and all 17 discussion comments were read.

| PR | Current audit result |
|---|---|
| [#27611](https://github.com/sonic-net/sonic-buildimage/pull/27611) | Current: late FDB path tests the zeroed transient `mac_msg.age_flag` instead of persistent `mac_info`; wrong delete/age behavior remains at `mlacp_link_handler.c:2843-2865`. |
| [#24868](https://github.com/sonic-net/sonic-buildimage/pull/24868) | Current: ND update compares old fields to themselves, so a changed existing neighbor is not queued (`iccp_ifm.c:574-588`). `gcc -Wlogical-op` confirms both tautologies. |
| [#17304](https://github.com/sonic-net/sonic-buildimage/pull/17304) | Partly current: peer-interface name sizing remains a C contract problem, but reset/valid-name paths substantially limit the claimed impact. |
| [#7769](https://github.com/sonic-net/sonic-buildimage/pull/7769) | Partly current: VLAN trees/state-DB replay supersede pieces, but the 512-byte member/config accumulation remains memory-unsafe and startup ordering still loses quiet L2 neighbors. |
| [#7760](https://github.com/sonic-net/sonic-buildimage/pull/7760) | Current: helper compares peer `po_id`, while a caller passes local `ifindex` (`mlacp_link_handler.c:341-354,1396`). |
| [#7724](https://github.com/sonic-net/sonic-buildimage/pull/7724) | Current: warm grace and peer-link lifecycle repair is unmerged; exact timeout-erasure path is confirmed. |
| [#7714](https://github.com/sonic-net/sonic-buildimage/pull/7714) | Current: no GARP/unsolicited NA after standby system-ID restoration and only one remembered address per family. |
| [#7685](https://github.com/sonic-net/sonic-buildimage/pull/7685) | Current: interface-MAC refresh bounces links down/up (`iccp_netlink.c:674-676,775-777`), creating avoidable traffic transitions. |
| [#7684](https://github.com/sonic-net/sonic-buildimage/pull/7684) | Current: initial reconstruction treats `IF_OPER_UNKNOWN` as down (`iccp_netlink.c:920,1016-1017`). |
| [#7680](https://github.com/sonic-net/sonic-buildimage/pull/7680) | Original >65 KiB syncd framing defect was superseded/fixed by #4819; current fragmented-header accounting is a different residual defect. |
| [#6613](https://github.com/sonic-net/sonic-buildimage/pull/6613) | Obsolete/observability only; not a protocol correctness target. |
| [#3764](https://github.com/sonic-net/sonic-buildimage/pull/3764) | Unresolved: Actor_System/teamd update race and proposed delay were disputed; retained as a test/review reference, not a confirmed source finding. |

## 4. Phase 3 — Verified Current Findings

Severity reflects supported-path impact; “confirmed” means the execution path and absence of compensation were verified in current source, not that a new runtime reproducer was executed.

### F1 — Peer warm-reboot grace can suppress failover forever (High, confirmed)

1. A peer warmboot TLV sets `peer_warm_reboot_time` (`mlacp_sync_update.c:1342-1349`).
2. On EOF/timeout, `scheduler_session_disconnect_handler` calls `mlacp_peer_disconn_handler` and then `iccp_csm_status_reset` (`scheduler.c:831-856`).
3. The peer-disconnect handler clears the peer marker, sets `warm_reboot_disconn_time`, and returns before FDB conversion, ICCP-down notification, isolation cleanup, traffic re-enable, system-MAC restoration, and interface recovery (`mlacp_link_handler.c:2376-2439`).
4. Status reset immediately zeros both timestamps (`iccp_csm.c:129-146`).
5. Independently, `mlacp_fsm_transit` returns when the socket/application is non-operational before testing the 90-second disconnected-grace timeout (`mlacp_fsm.c:935-965`).

If the peer never returns, neither reconnect nor ordinary failure cleanup occurs. Reconnect deliberately preserves state and clears grace, which is useful for a successful warm restart but does not compensate for permanent loss. Local warm shutdown is intentionally preservation-oriented and is not the defective path.

### F2 — Established Sync Request moves `EXCHANGE` to `ERROR` (High, confirmed)

`mlacp_sync_receiver_handler` accepts Sync Request in Exchange (`mlacp_fsm.c:1338-1340`). The receiver invokes `mlacp_sync_send_all_info_handler` (`557-569`), which sends Start/Data/End and then blindly increments `current_state` (`1438-1463`). With enum values `EXCHANGE=3`, `ERROR=4` (`mlacp_fsm.h:39-46`), a legal resync causes `EXCHANGE → ERROR`.

The outer switch has no recovery action for `ERROR` (`mlacp_fsm.c:1017-1032`); later messages are dequeued/freed without mLACP processing. Local `need_to_sync` itself emits such requests (`1569-1576`), including after unknown purge handling. Depending on traffic, heartbeat may time out and flap or unrelated complete frames may keep a useless session alive.

### F3 — Synchronization commits after failed or partial peer writes (High, confirmed)

`iccp_csm_send` performs one blocking `write`, logs `ret != msg_len`, and returns without suffix retry, output queue, rollback, or session teardown (`iccp_csm.c:245-281`). No `SIGPIPE` handler/ignore or `MSG_NOSIGNAL` protects it.

Destructive/advancing callers include:

- initial aggregation config/state flags cleared regardless of result (`mlacp_fsm.c:190-252`);
- MAC, ARP, and ND deltas removed/freed before unchecked send (`260-366`);
- Start/Data/End response stage advanced regardless of all send results (`1438-1463`);
- requester enters wait after an unchecked request (`1497-1517`);
- `need_to_sync`, system/config, purge, and port flags are cleared after unchecked sends (`1569-1645`);
- a positive short write counts as success when clearing `changed` (`1634-1645`).

A failed Sync End can leave responder in Exchange and requester in Stage2; positive partial write corrupts framing when the next message follows the declared prefix. The 6 MiB socket buffers reduce frequency but do not guarantee full writes. The active connector alone has a 100 ms send timeout; the accepted side can block the entire scheduler.

### F4 — Sync responses are uncorrelated and incomplete (High interoperability / Medium deployed, confirmed)

The request builder hard-codes request number zero (`mlacp_sync_prepare.c:49-98`); response generation merely echoes the stored value (`105-146`). Sync Data receipt checks only the Start/End flag and clears `wait_for_sync_data` without comparing a request identity (`mlacp_fsm.c:538-568`). RFC 7275 reserves zero for unsolicited Sync Data and requires a unique nonzero Sync Request identifier.

On established resync, “all info” sends system/aggregation/port-channel/peer-link and current ARP/ND delta queues, but has no MAC sync state and does not repopulate persistent ARP/ND entries (`mlacp_fsm.c:1393-1463`). Initial Exchange entry performs the repopulation elsewhere (`mlacp_fsm.c:1008-1015,1102-1225`). Thus a recovery request cannot reliably heal a missed persistent table update.

Unknown Purge Config also sets `need_to_sync` (`mlacp_sync_update.c:99-123`) rather than being silently discarded as RFC 7275 §9.2.2 specifies, giving same-version peers an internal trigger for the established-resync defect.

Homogeneous peers serialize one staged request on FIFO TCP, reducing stale-response likelihood; old-connection data/ACK cannot cross a reconnect. Same-session unsolicited Data is legal at the protocol level; unsolicited and mismatched Data are both accepted without correlation.

### F5 — IF_UP acknowledgement is not proof of current isolation (High, confirmed)

Local LAG down disables traffic; up waits for peer ACK (`mlacp_link_handler.c:2067-2099,3588-3637`). However:

- `mlacp_fsm_update_Aggport_state` returns success even if no peer interface matched (`mlacp_sync_update.c:165-210`);
- receipt of any UP sends ACK regardless of that result (`mlacp_fsm.c:508-534`);
- desired isolation is changed before a direct syncd write, unchecked `system(ebtables)`, and ignored STATE_DB/helper results (`mlacp_link_handler.c:1021-1220`);
- the ACK contains no generation, and receipt ignores its isolation field and pending provenance, checking only current `po_active` before enabling (`mlacp_tlv.h:447-470`; `mlacp_fsm.c:759-793`).

Concrete supported traces are: no matching PIF yet ACK enables traffic; external apply fails yet ACK is sent; and delayed ACK for UP1 arrives after DOWN/UP2 while current `po_active` is true. ACK while currently down is rejected and an old TCP epoch cannot cross reconnect, so those broader claims were excluded. ACK loss also has no retry and can leave a healthy LAG disabled until another flap/session cleanup.

### F6 — MLAG detach can permanently preserve traffic-disable (High, confirmed)

Configuration delete calls detach before unbind (`iccp_cli.c:395-457`; `mlacp_link_handler.c:3158-3183`). The detach handler enables only if no peer link exists or the peer link is the detached PortChannel (`mlacp_link_handler.c:2128-2138`), which is false in normal distinct-peer-link configuration. Unbind clears `lif->csm` (`app_csm.c:265-280`); later purge attempts enable, but `set_l3_itf_state(..., enable)` rejects `!lif->csm` (`mlacp_fsm.c:1595-1610`; `mlacp_link_handler.c:3622-3637`).

The pinned swss code only clears isolation configuration on interface delete; it changes `traffic_disable=false` only after an explicit enable message. No later mLACP transition owns the detached interface, so this is not externally compensated.

### F7 — One partial peer header can freeze all protocol progress (High availability, confirmed)

Peer sockets are blocking. Once epoll reports at least one byte, `scheduler_session_read_handler` loops `recv(..., 0)` until all eight header bytes arrive (`scheduler.c:129-170`). A configured peer sending 1-7 bytes and pausing blocks the sole loop indefinitely. Payload reads use `MSG_DONTWAIT`, so “the body read itself blocks” is false; nevertheless its EAGAIN path sleeps inline for roughly the whole session timeout (`185-239`). Small configured timeout values can also underflow the last sleep calculation.

No timer, netlink event, other CSM, sidecar event, or signal-pipe action executes while blocked. Accepted-side peer and direct syncd writes create the same scheduler-wide backpressure class.

### F8 — `mclagsyncd` fragmentation and EOF handling break the stream lifecycle (High, confirmed)

The syncd header is four bytes (`msg_format.h:503-508`). If the initial bulk receive ends with 1-3 header bytes, the handler fetches the missing bytes but never increments `num_bytes_rxed` (`mlacp_link_handler.c:3426-3478`). It then computes a stale remainder and reads excess payload/following-frame bytes over the completed header tail (`3481-3549`). A separate EAGAIN retry starts from `-1` and adds the received length, recording one byte too few (`3369-3420`). Complete-header/body-only fragmentation was checked and is not defective.

EOF/error returns `MCLAG_ERROR` (`3369-3543`), but `iccp_handle_events` ignores the return and neither closes nor sets the fd negative (`iccp_netlink.c:2212-2215`). Reconnect runs only when `sync_fd <= 0` (`scheduler.c:469-474`), leaving a stale positive fd and possible EPOLLHUP spin. Later unprotected sends can raise SIGPIPE. The shipped wrapper/supervisor configuration does not provide reliable source-level recovery.

### F9 — Fixed TLVs and the outer frame remain memory-unsafe (Critical for compromised/configured peer, confirmed)

The receive envelope checks only `msg_len >= 4` (`scheduler.c:172-181`). With 16-bit `msg_len=65535`, total wire/copy size is 65,539 bytes, three beyond `g_csm_buf[65536]` (`iccp_csm.h:40`; `scheduler.c:172-244`). At the minimum, an eight-byte LDP-only RG APP frame reaches ICC/TLV casts without the required bytes (`iccp_csm.c:602-768`; `app_csm.c:100-128`; `mlacp_fsm.c:447-793,1296-1382`).

Aggregator Config trusts peer `agg_name_len`; a value up to 255 is copied to a 20-byte name and one flag combination can dereference a PIF that was never created (`mlacp_sync_update.c:85-158`; `mlacp_tlv.h:67-100`). The base NAK parser uses `(icc_hdr + sizeof(ICCHdr))`, advancing by 16 structures rather than 16 bytes (`iccp_csm.c:640-651`).

The raw Neighbor Advertisement handler independently dereferences its fixed message without a minimum packet length, does not require each option length to fit the remaining bytes, and copies a six-byte link-layer address without validating option size (`iccp_netlink.c:1960-2019`). Unlike peer TLVs, this malformed-packet surface can be reached from an adjacent network and belongs in fuzz/ASan validation.

Recent #26567/#26930 correctly fixed variable-list/inner ARP/ND bounds; those old overreads are false positives at HEAD. Exposure is limited to a configured peer IP, but there is no authentication, so a compromised/misbehaving peer remains sufficient.

### F10 — Unsupported APP frames form an unbounded live-session queue (High/Medium, confirmed)

RG APP DATA is enqueued by `iccp_csm.c:742-745`. `app_csm_enqueue_msg` forwards only parameter types strictly inside its recognized mLACP range; Connect, boundary, and unknown types go to `app_msg_list` (`app_csm.c:100-145`). `app_csm_dequeue_msg` has no caller and the application FSM never consumes this queue (`80-98,155-166`). Every complete frame also refreshes peer heartbeat (`iccp_netlink.c:2225-2235`). A configured peer can therefore remain transport-live while growing the heap and making no application progress.

### F11 — External forwarding shadow can diverge after late FDB and failed writes (Medium, confirmed)

During a local-down/peer-up late FDB ADD, `do_mac_update_from_syncd` clones/inserts the original LAG record before redirecting only the stack copy to the peer link and returning (`mlacp_link_handler.c:2654-2693,2903-2925`). The persistent clone lacks both redirected `ifname` and pending flag, so LAG-up repair does not select it (`1738-1940`) and it was never queued to the peer.

Separately, `iccp_send_fdb_entry_to_syncd` updates `add_to_syncd` even when the external send failed or the fd was invalid (`1643-1662`), while later deletion depends on that bit (`2967-2970,3004-3008`). These are concrete examples of desired/shadow state being treated as applied state.

### F12 — Restart/netlink reconstruction is incomplete and incorrectly scheduled (High, confirmed)

The daemon startup order is GETLINK, GETADDR, configuration load, GETNEIGH, then syncd connect (`scheduler.c:383-395`). VLAN membership is populated only by later `mclagsyncd` messages (`mlacp_link_handler.c:3295-3324`). During the earlier neighbor dump, L2 SVI ARP/ND is accepted only when its MLAG/peer-link VLAN tree already contains that VLAN (`iccp_ifm.c:188-268,448-528`). Existing L2 neighbors are therefore discarded on restart, and there is no second `iccp_neigh_get_init` call. Direct L3 PortChannel neighbors and later live ARP/NA events can compensate individually; a quiet network remains incomplete.

Netlink loss recovery also lacks a reliable reconciliation cycle:

- route receive failure sets `need_sync_netlink_again`, but resync runs only after a later successful route event (`iccp_netlink.c:2059-2075`), so a quiet post-ENOBUFS system never retries;
- generic/team failure sets a separate flag with no independent trigger (`1859-1868`);
- recovery clears flags before unchecked work (`2035-2053`);
- the route snapshot is GETLINK-only (`iccp_ifm.c:63-114`), with no address/neighbor re-dump or mark-and-sweep for missed deletes; team resync likewise never removes cached members absent from its reply.

Additional current approximations compound this gap:

- initial reconstruction reads flags but decides up solely from `operstate == IF_OPER_UP` (`iccp_netlink.c:918-924,958-962,1010-1017`); `IF_OPER_UNKNOWN|IFF_LOWER_UP` becomes down until a later event, matching #7684;
- FDB handlers can destructively act on that wrong state (`mlacp_link_handler.c:2788-2825,2887-2925`);
- every standby MAC transition records desired state after logged/ignored apply errors and deliberately bounces links down/up (`iccp_netlink.c:668-688,715-726,769-816,2341-2454`), matching #7685;
- only one IPv4 and one global IPv6 address are stored; later addresses/replacements are ignored and deletion can mark an interface L2 while another kernel address remains (`port.h:136-141`; `iccp_netlink.c:1307-1468`);
- standby system-ID restoration sends no GARP/unsolicited NA, matching #7714.

The formal question is the barrier between `kernelTruth`, `observedState`, and advertisement/application; it does not assume every restart takes the same failing trace.

### F13 — Current open-PR implementation defects remain (Medium, confirmed)

- Existing ND changes are suppressed because `iccp_ifm.c:574-575` compares stored fields to themselves; `neigh_update` remains false and the update is not enqueued (`574-588`, #24868).
- Late FDB handling checks a newly zeroed `mac_msg.age_flag`, not persistent `mac_info`, at `mlacp_link_handler.c:2843-2865` (#27611).
- `peer_po_is_alive` compares `po_id` (`mlacp_link_handler.c:341-354`) but a caller supplies local `ifindex` (`1396`, #7760).
- PortChannel member construction still uses a 512-byte fixed buffer and accumulates `snprintf`'s would-have-written length; after truncation, the next pointer and unsigned remaining size go out of bounds (`port.h:146`; `iccp_netlink.c:166,232-241,320-329`, #7769).

These are implementation-local and should be regression-tested/code-reviewed, not expanded into TLA+ state.

### F14 — Node identity and application handshake violate RFC semantics (Medium deployed / High interoperability, confirmed)

Fresh Node ID generation sets the high bit and runs before the configured sender address is installed (`mlacp_fsm.c:873-884`; `iccp_csm.c:118-127`; `system.c:175-190`); the random nibble is process-deterministic because no `srand` call exists. Collision receipt increments the local ID and succeeds (`mlacp_sync_update.c:44-79`); NAK handling decrements and continues (`mlacp_fsm.c:1246-1287`). RFC 7275 instead defines 0-7 and requires notification/suspension until configuration is corrected.

The application FSM declares the RFC states but jumps to `APP_OPERATIONAL` whenever base ICCP becomes operational (`app_csm.c:80-98`). No mLACP Connect/A-bit/version handshake is sent or required. Homogeneous SONiC peers compensate by making the same shortcut; compliant interoperability is not assured.

### F15 — Neighbor cache identity omits interface/VRF (Medium, confirmed)

Persistent and outgoing ARP matching/removal use only IPv4 address (`mlacp_sync_update.c:843-899`); ND uses only the 16-byte address (`1171-1228`). Entries carry interface names and local interfaces carry master/VRF information, so identical neighbor addresses on distinct VLANs/VRFs collapse, overwrite, or remove the wrong record. A two-interface integration test is preferable to modeling full neighbor tables.

### F16 — Lower-level robustness defects (Low/Medium, confirmed or qualified)

- `readfd_count` increments on every peer accept/connect but is never decremented; it sizes a stack VLA and `epoll_wait` batch on every loop (`system.c:84-85`; `scheduler.c:345-346,639-640,823-895`; `iccp_netlink.c:2170-2179`). Stale fds themselves are removed; only over-allocation grows.
- Existing dynamic MAC, remote orphan ADD, and no peer-link can free an RB-node record then dereference it in a log (`mlacp_sync_update.c:347-369`); logger arguments are evaluated regardless of debug level.
- Duplicate/out-of-order TEAM removed events can enter the add branch when `po_id == -1`, resurrecting membership (`iccp_netlink.c:220-229,297-316`).
- `iccp_cmd.c:137-143` has the startup token-capacity bug; `iccp_cmd_show.c` has eight direct `realloc` assignments; the 20-vs-16 interface clear is C UB but operationally mitigated.
- #5214's per-domain CLI `len` reset was regressed by #4819, but current supported schema allows only one MCLAG domain.

## 5. Compensations, Refutations, and Explicit Exclusions

The following suspected findings were rejected or narrowed after tracing compensating paths:

| Suspected claim | Resolution |
|---|---|
| Stub mutexes cause races | False at HEAD: no worker threads; the single event loop serializes ownership. They would be unsafe if threading were introduced. |
| Global scratch buffers are racing | False under current serial scheduler/signal-pipe design. |
| Shared statics/global CSM selection create production multi-domain failures | `prev_state` and VLAN-MAC recovery really mishandle simultaneous CSMs, but `sonic-mclag.yang:39-44` enforces `max-elements 1`; sequential replacement passes INIT and works. Excluded from the current supported-path model. |
| #5214 is fully fixed | False historically: #4819 regressed it. Current effect still requires unsupported multi-domain input, so retained as low/code-review evidence. |
| Body receive blocks in `recv` | False: body uses `MSG_DONTWAIT`; its inline retry sleeps still block the sole scheduler for about the timeout. Header receive is truly blocking. |
| Any-message heartbeat is accidentally called | Intentional transport-activity policy; not a defect alone. Its composition with an unprocessed/error session remains a liveness question. |
| Request number zero necessarily causes stale response between sessions | Overstated: TCP FIFO, one staged outstanding request, and a new socket epoch reduce it; same-session unsolicited/mismatched data and standards interop remain. |
| IF_UP ACK from an old connection can enable a new one | False: TCP epoch prevents cross-reconnect delivery. Same-session down/up ABA remains. |
| ACK while current LAG is down enables traffic | False: current `po_active` guard rejects it. |
| Connected warmboot timeout is broken | False: its connected timer path runs. Only disconnected grace is erased/unreachable. |
| Local warm shutdown skipping cleanup is a bug | Intentional preservation for local process restart. The peer-announced warm disconnect path is defective when peer never returns. |
| All syncd sends mishandle partial writes | False: `iccp_send_to_mclagsyncd` loops over partial/EAGAIN. Several critical direct writes bypass it, and callers still mishandle applied-state failures. |
| Current variable-count TLV overreads from #26567/#26930 remain | False: those specific list and ARP/ND inner checks are present. Fixed/base-envelope handlers remain independently unsafe. |
| `iccp_csm_init_mac_msg` currently overflows | Potential missing defensive bound, but all current call sites pass the exact structure size. Not reported as a current bug. |
| Default “up” when peer interface is absent creates unsafe forwarding | The default drives more isolation, so it is conservative for loop prevention. The unconditional ACK path is the unsafe exception. |
| `once_connected` proves a multi-domain bug | Schema excludes simultaneous domains; the guarded bridge-MAC action is device-global and no sequential failure was found. |
| PortChannel allocation/name parsing failures are supported | YANG requires `PortChannel[0-9]{1,4}`; malformed-name path is schema-unreachable. |
| Blocking accepted writes are a frequent production incident | Not established; 6 MiB buffers reduce likelihood. The absence of timeout/full-write semantics is still a correctness/availability gap. |

## 6. Verification Performed and Remaining

### 6.1 Static/source verification

- Re-read each reported line with surrounding control flow and caller/callee context.
- Used `rg` exhaustively for send wrappers, state/timer fields, dequeue callers, signal handling, `pthread_create`, reconnect fd mutation, and side-effect return handling.
- Used `git log --all`, `git show`, `git blame`, and `git log -G` to determine origin, regression, and whether later changes compensate.
- Ran targeted GCC syntax/warning checks. `-Wlogical-op` independently reports both `iccp_ifm.c` ND self-comparisons; other checks produced warnings but no parse failure.
- Cross-checked supported configuration against SONiC YANG and sidecar behavior against the pinned swss dependency/deployment scripts.

### 6.2 Runtime verification not performed

The repository contains no focused ICCPd unit/integration suite for these state transitions, and the target checkout was not configured as a full SONiC build environment. No live namespace/ASIC, ASan, or fake peer/syncd execution was performed. Consequently, source-confirmed findings have concrete proposed tests in the modeling brief rather than fabricated runtime results.

### 6.3 Model-check output-value litmus

Each §6.1 modeling candidate asks an open composition question rather than recreating a closed fix:

| Candidate | Predicted useful Phase-4 conclusion |
|---|---|
| MC1 | Identify whether every combined warm/crash/reconnect trace terminates in either recovered or ordinary-failover state, and the minimal missing transition if not. |
| MC2 | Determine whether fallible FIFO send plus legal resync admits a session-live disagreement, and which sync epoch/dirty-state guard prevents it. |
| MC3 | Produce or refute a same-session generation trace where traffic precedes current peer isolation. |
| MC4 | Determine the required reconstruction barrier before restarted state is advertised or applied. |
| MC5 | Establish whether transport activity can indefinitely mask lack of protocol progress under realistic fairness. |

None has the predictable conclusion “the already-merged bounds fix is useful,” “defense in depth only,” or “documented intent”; the closed commits remain confined to scenario evidence/reference.

## 7. Phase 4 — Scenario Selection and Handoff

The modeling brief groups current evidence into four mechanisms:

1. recovery evidence lifecycle;
2. unacknowledged synchronization commit;
3. generation-free data-plane acknowledgement;
4. transport activity versus protocol/scheduler progress.

The recommended bounded model has two nodes, one MCLAG domain, one LAG, one replicated object, one abstract sidecar, per-direction FIFO channels, and explicit crash/restart/timer actions. It should not model raw bytes, full MAC/neighbor sets, arbitrary TCP reordering, unsupported multi-domain state, CLI/memory defects, or already-fixed historical revisions.

The authoritative spec-generation handoff is [modeling-brief.md](./modeling-brief.md).

## 8. Reference Index

- [RFC 7275](https://www.rfc-editor.org/rfc/rfc7275.html): §§3.3, 4.2, 4.4, 4.5, 5, 7.2.3, 7.2.9, 7.2.10, 9.2.2.
- State/transport: `src/iccpd/src/scheduler.c`, `iccp_csm.c`, `app_csm.c`, `mlacp_fsm.c`.
- Sync/update: `src/iccpd/src/mlacp_sync_prepare.c`, `mlacp_sync_update.c`.
- Failover/data plane: `src/iccpd/src/mlacp_link_handler.c`.
- Recovery/events: `src/iccpd/src/iccp_netlink.c`, `iccp_ifm.c`, `system.c`.
- Definitions: `src/iccpd/include/iccp_csm.h`, `mlacp_fsm.h`, `mlacp_tlv.h`, `msg_format.h`, `system.h`.
- Closed-fix PRs: [#5112](https://github.com/sonic-net/sonic-buildimage/pull/5112), [#5214](https://github.com/sonic-net/sonic-buildimage/pull/5214), [#11197](https://github.com/sonic-net/sonic-buildimage/pull/11197), [#11694](https://github.com/sonic-net/sonic-buildimage/pull/11694), [#18270](https://github.com/sonic-net/sonic-buildimage/pull/18270), [#21172](https://github.com/sonic-net/sonic-buildimage/pull/21172), [#26567](https://github.com/sonic-net/sonic-buildimage/pull/26567), [#26930](https://github.com/sonic-net/sonic-buildimage/pull/26930).
