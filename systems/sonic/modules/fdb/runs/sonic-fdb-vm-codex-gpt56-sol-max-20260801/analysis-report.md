# SONiC FDB Code-Analysis Report

## Audit metadata

| Field | Value |
|---|---|
| System | `fdb` in `sonic-net/sonic-swss` |
| Repository | `/users/Pial/targets/sonic-swss-fdb` |
| Upstream | <https://github.com/sonic-net/sonic-swss> |
| Revision | `4f3dda156e52ed7647b1dbf900d54d87efaea455` (`master`) |
| Analysis date | 2026-08-01 UTC |
| Language | C++ |
| Category | **Category A — Distributed / Message-Passing** |
| Reference algorithm | SONiC FDB bridge-port lifecycle, learning/aging/move notification handling, flush/counter semantics, VXLAN/L2-NHG object lifecycle, and warm-restart reconciliation |
| Primary handoff | `modeling-brief.md` beside this report |

## Executive conclusions

The relevant concurrency is not parallel access to C++ containers. It is the ordering of independently queued Redis, netlink, SAI-notification, timer, and configuration messages across `fdbsyncd`, `orchagent`, syncd, and the ASIC. A synchronous SAI call often starts a multi-stage operation whose completion is observed later, after other inputs may have changed the same logical MAC or topology object.

Five mechanisms dominate both history and current code:

1. Flush request, hardware deletion, `FLUSHED` delivery, software cleanup, observer delivery, and topology removal lack a common generation.
2. LEARN/AGE/MOVE events identify a mutable `(MAC, BV)` but not the incarnation or destination transition that produced the event.
3. Deferred work is sometimes append-only and sometimes acknowledged when a dependency is absent; neither policy consistently implements “latest desired state wins.”
4. Tunnel, endpoint, NHG, bridge-port, and VLAN-member graphs are mutated stepwise without a durable transaction phase or uniform rollback/retry owner.
5. Startup and warm restart reconstruct from different snapshots, while some kernel inputs are one-shot and are filtered before enabling configuration is processed.

The highest-confidence current defects found by direct code tracing are:

- STP VLAN flush succeeds in SAI but never marks matching entries pending, so its later acknowledgement cannot clean FdbOrch state.
- MCLAG remote-only deletion checks the local-MAC cache and can skip the kernel/cache delete.
- `updateL2NhgVtepIp` attributes the new member reference to the old endpoint and removes members before replacement is known to succeed.
- fdbsyncd's initial NHG dump precedes NVO readiness, and ignored messages have no replay path.
- MacMoveGuard forgets failed port re-enable work during timed recovery and its accepted threshold value `1` cannot disable either port on the first native move.
- Bridge-port/VLAN-member and P2P/P2MP tunnel paths have multiple post-create/post-remove windows in which a retry begins from partially committed state or the failed operation is acknowledged.

Several additional behaviors are confirmed in code but need a platform/event-contract decision before calling them defects: deleting the current entry after an explicitly stale AGE, same-bridge-port MOVE counter behavior, the run-global native-MOVE latch, and unconditional DEL-before-SET publication in `macAddVxlan`.

## Methodology and coverage

### Step 0: category classification

This is Category A. The state machine spans message-passing boundaries: Linux netlink, CONFIG/APP/STATE/ASIC Redis tables, SAI calls, syncd notifications, and separate daemon select loops. The core FDB handlers are serialized within a process, so Category B lock-free/CAS analysis is not the appropriate primary method. The route ring-buffer option is unrelated to FDB data. No Byzantine protocol is present, so the BFT overlay does not apply.

The analysis followed all four phases of the installed Specula `code-analysis` skill and its bug-archaeology, deep-analysis, distributed-analysis, and modeling-brief references. Three parallel subagents plus the root agent were used, which is the maximum parallelism supported by the four-slot environment: git history, GitHub issue/open-PR archaeology, and deep FdbOrch/Ports/VXLAN review ran concurrently.

### Phase 1: reconnaissance

The reviewed core/supporting scope contains 24,478 lines:

| Module | Lines | Role and review depth |
|---|---:|---|
| `orchagent/fdborch.{cpp,h}` | 2,695 | APP FDB reconciliation, SAI notifications, flush protocol, counters; line-complete deep review |
| `fdbsyncd/fdbsync{,d}.{cpp,h}` | 1,746 | kernel/STATE to APP projection, NVO and NHG startup; line-complete deep review |
| `orchagent/l2nhgorch.{cpp,h}` | 968 | L2 NH/NHG SAI graph and tunnel refs; line-complete deep review |
| `orchagent/macmoveguard.{cpp,h}` | 1,779 | move detection, mitigation, recovery, persistence; line-complete deep review |
| `warmrestart/warmRestartAssist.{cpp,h}` | 482 | table snapshot/reconciliation semantics; line-complete review |
| `orchagent/vxlanorch.{cpp,h}` | 3,460 | remote-VNI and tunnel/endpoint lifecycle; lifecycle paths traced end-to-end |
| `orchagent/portsorch.{cpp,h}` | 12,670 | bridge ports, VLAN members, refs, PVID, failure boundaries; affected paths traced end-to-end |
| `orchagent/stporch.{cpp,h}` | 678 | fast-age entry point; complete relevant-state review |
| **Total** | **24,478** | Direct FDB/warm logic is approximately 7.7 KLOC |

Supporting definitions, daemon construction/order, `Orch2` consume semantics, notification queues, and four focused unit-test files were also inspected. Every reported finding was re-read at its exact lines, traced through callers/callees, checked for rollback/retry/wakeup compensators, compared with tests, and searched in GitHub discussions.

### Phase 2: git archaeology

- 797 distinct commits touch the core history path set.
- Required case-insensitive keyword counts, overlapping by design: `fix` 268, `bug` 31, `race` 26, `panic` 0, `deadlock` 1, `correctness` 1, `crash` 38, `corrupt` 0, `leak` 4, `inconsistent` 3, `wrong` 11.
- The required-keyword union contains 288 hashes.
- A domain-subject sweep (`fdb|bridge|mac|vxlan|evpn|tunnel|flush|learn|aging|warm`) found 230 hashes.
- A semantic `git log -G` sweep over FDB, bridge-port, learning-mode, counter, flush, and tunnel symbols found 145 hashes.
- The combined candidate union was 442 hashes. Diffs for all 442 were reviewed; a full 797-subject scan found the additional #2538 lineage.
- 66 significant corrective lineages were identified across 115 hashes: 113 from the candidate union plus two supplemental #2538 hashes. Cherry-picks, release twins, and development-series commits were collapsed.
- 329 candidate hashes were excluded as unrelated, feature/architecture introductions, duplicate lineages, or superseded development commits.
- Historical lineage severity: 3 Critical, 52 High, 10 Medium, 1 Low.
- Lineage hotspots, counting a lineage once per touched subsystem: FdbOrch 28, PortsOrch 26, VXLAN 13, FdbSync 3, warm assist 3, notifications 2.

The complete 66-lineage ledger appears later in this report. Fixed historical bugs are evidence for mechanism selection only; none was copied into the model-checkable target table.

### Phase 2: GitHub issue and open-PR archaeology

GitHub CLI was unavailable, so official GitHub REST/HTML surfaces were used with pagination.

- 37 search variants were attempted; 35 completed directly and two initially hit rate limiting.
- 292 unique search candidates were collected: 248 PRs and 44 issues.
- All 455 currently open PRs were screened.
- Search candidates and open PRs overlap by 47, producing a screening union of 700 unique threads.
- 59 open PRs matched the broad FDB/bridge lexical filter. All were classified: 31 plausible bug-fix-intent PRs and 28 feature/test/docs/mechanical/unrelated exclusions.
- 106 discussions were deeply read, including full bodies, issue comments, reviews, and inline review comments. #4262 alone required 53 issue comments, 384 inline comments, and 366 reviews.
- Classification: 65 confirmed bug/fix, 12 design defects, 5 disputed/false, 0 user-error, 3 uncertain, and 21 non-defect/context exclusions. Thus 77 discussions provide confirmed defect/design evidence; 26 were excluded as disputed or context, with 3 uncertain.

The full classifications and all 31 open bug-fix-intent PRs are recorded below.

### Phase 3: deep analysis and verification

The review used the Category A patterns specified by the skill:

- identify nodes/processes, message types, persisted/volatile state, and nondeterministic delivery;
- split operations at I/O and ownership boundaries;
- compare corresponding add/delete, local/remote, P2P/P2MP, normal/warm, and request/ack paths;
- inject failure conceptually after every external mutation;
- trace stale, duplicate, missing, reordered, and coalesced events;
- follow every deferred-work path to a concrete wakeup or reconciliation source;
- compare cache/reference/counter updates with the hardware object graph;
- search blame/history and full GitHub discussion for novelty and acknowledged intent.

### Tests and execution limits

Four focused GTest files contain 174 declared tests: 63 fdbsyncd, 85 FdbOrch/VXLAN, 10 flush-notification, and 16 MacMoveGuard tests. In the fdbsyncd file, 42 of 63 tests contain a vacuous `ASSERT_TRUE(true)` or nonnegative-size assertion. Flush-notification tests manually seed `is_flush_pending`; the STP test comments that `flushFdbByVlan` updates it but does not assert the flag. The same-port MOVE test does not assert counts. MacMoveGuard tests cover thresholds 2/3 and successful re-enable, not threshold 1 or recovery failure. The focused L2-NHG/FdbOrch test is disabled.

No built test binary or configured build tree was present, so this was a static audit; tests were not executed. The suggested failure-injection and integration tests are listed in the modeling brief. The repository was clean before analysis, and no source files were modified.

## Structural model

### Processes, planes, and messages

| Component/plane | Authoritative-looking state | Inputs | Outputs/side effects |
|---|---|---|---|
| Linux bridge/kernel | FDB, VXLAN links, nexthops/groups | FRR, bridge, link lifecycle | netlink NEW/DEL NEIGH/LINK/NEXTHOP |
| `fdbsyncd` | `m_fdb_mac`, remote cache, `m_mac`, `m_intf_info`, `m_l2NhgMap` | netlink, STATE_DB, CONFIG NVO | APP VXLAN_FDB, REMOTE_VNI, L2_NHG rows; kernel bridge commands |
| Redis databases | desired APP/CONFIG rows and observed STATE rows | producers and warm replay | independent consumer streams, overwrite/coalescing semantics |
| `FdbOrch` | `m_entries`, saved FDB vectors, port/VLAN/CRM counts | APP rows, ASIC FDB notifications, flush requests | synchronous SAI calls, STATE_DB, observers, neighbor/tunnel callbacks |
| Ports/STP/VXLAN/L2NHG orchs | bridge/VLAN/tunnel/NHG object caches and refs | config/APP consumers, observer calls | multi-object SAI graph mutation and notifications |
| syncd/ASIC | hardware bridge/FDB/tunnel graph | SAI calls | asynchronous FDB LEARN/AGE/MOVE/FLUSHED events |
| warm assist | cached pre-restart table image and reconciliation state | APP rows and replay timer | SET/DEL reconciliation after dependent daemons restore |

### Concurrency and atomicity boundaries

Within one `orchagent` select iteration, ordinary C++ map mutation is serialized. The following boundaries remain non-atomic:

1. a Redis producer update versus another table's update or consumer priority;
2. a netlink snapshot dump versus enabling CONFIG rows and concurrent live deltas;
3. a successful SAI flush call versus ASIC removal and later consolidated/per-entry notification;
4. one SAI object mutation versus the next object, cache/refcount commit, or observer delivery;
5. a retryable consumer row versus the external event needed to wake the consumer;
6. process death between APP/STATE publication, SAI mutation, and cache commit;
7. byte-identical notification dedup versus semantically distinct AGE/LEARN/MOVE transitions.

The model should therefore use event actions and crash/failure steps, not shared-memory thread interleavings.

### Reference-lifecycle comparison

The expected bridge/FDB lifecycle has four conceptual rules: dependencies precede references; a newer destination supersedes older events; a successful flush is matched to its eventual cleanup; and warm reconciliation makes desired/kernel/cache/ASIC state converge. The implementation deviates in these ways:

- logical FDB identity is `(MAC, BV)`, while destination port is partly stored in the map key and partly in the value;
- there is a Boolean pending flag instead of a request/incarnation epoch;
- dependency handling alternates between retain (`false`), append-and-ack (`true`), and drop-and-ack (`true`);
- no single owner transactionally updates NHG membership, endpoint refs, bridge ports, and tunnel objects;
- planned warm restart snapshots only selected APP tables and explicitly does not make every kernel-derived table durable;
- platform move encoding may be native MOVE or AGE+LEARN, and code treats these forms differently.

## Current-code findings

Severity reflects plausible production consequence, not ease of exploitation. “Confirmed” means the code path and missing compensator are directly established; “contract-dependent” means the behavior is certain but whether the environment can lawfully supply the triggering event requires SAI/vendor confirmation.

### Scenario A: asynchronous flush and topology teardown

#### F01 — STP VLAN flush has no pending generation

- **Severity / status**: High; confirmed current defect; no direct GitHub tracker found.
- **Trace**: STP fast-age calls `StpOrch::stpVlanFdbFlush` (`stporch.cpp:363-377,488-571`). `FdbOrch::flushFdbByVlan` sends a successful dynamic VLAN flush (`fdborch.cpp:1661-1688`) but never sets `FdbData::is_flush_pending`. Every normal request path marks pending after success (`1298-1317,1443-1502,1517-1659`). `handleSyncdFlushNotif` removes a matching entry only when the flag is true (`294-368`).
- **Consequence**: ASIC entries disappear, while `m_entries`, STATE_DB, CRM usage, per-port/VLAN counts, neighbor/tunnel observers, and potentially saved topology references remain stale.
- **Compensators checked**: no STP-specific cleanup, later full reconciliation, or alternate flag setter exists. The ack is consumed once.
- **Tests**: `fdborch_vxlan_ut.cpp:3198-3230` has an inaccurate comment but no flag/cleanup assertion; flush-notification tests seed the flag manually.
- **Introduction/novelty**: introduced with PVST `5a8d403d344ea9f4569ed99250b7f57cdcc31e99` (#3425). Exact-code GitHub searches found zero discussion of this omission.
- **Verification bucket**: test-verifiable; the generalized generation race is model-checkable.

#### F02 — dynamic flush marks nonmatching static entries pending

- **Severity / status**: Medium; confirmed behavior with a credible later-lifecycle effect.
- **Trace**: both the ALL request and scoped helper request `SAI_FDB_FLUSH_ENTRY_TYPE_DYNAMIC` (`fdborch.cpp:1298-1305,1479-1486`) but mark every cached entry in scope pending without checking `sai_fdb_type` (`1311-1317,1492-1500`). Ack cleanup is type-filtered (`294-368`).
- **Consequence**: a static entry can retain a pending marker indefinitely. If its bridge port later vanishes, `removeFdbEntry` treats pending plus missing BP as proof it was flushed and clears it (`2334-2344`).
- **Compensators checked**: later SET overwrites data in some paths, but there is no general pending reset or request epoch.
- **Verification bucket**: code review plus a focused dynamic/static test; model the generalized scope/type match.

#### F03 — completed membership/topology removal cannot retain a failed flush

- **Severity / status**: High; confirmed failure-atomicity gap.
- **Trace**: `removeVlanMember` removes the SAI member and commits cache/ref changes before notifying FdbOrch (`portsorch.cpp:8060-8114`). The observer invokes void `flushFDBEntries` (`fdborch.cpp:1753-1763`), which only logs SAI failure (`1431-1503`). `removeBridgePort` likewise flushes and then removes the BP (`portsorch.cpp:7470-7531`). Some callers erase the config task even when the subsequent `removeBridgePort` result is ignored (`6099-6114`).
- **Consequence**: topology deletion may be acknowledged while FDB rows/hardware references remain, or a BP can be disabled/partially removed without a retry owner.
- **Compensators checked**: async ack cleanup helps only after a successful SAI flush; a failed request creates no pending marker and no durable retry.
- **GitHub corroboration**: current open [#2961](https://github.com/sonic-net/sonic-swss/pull/2961), [#3211](https://github.com/sonic-net/sonic-swss/pull/3211), and [#4458](https://github.com/sonic-net/sonic-swss/pull/4458) cover related retained references and stale cache variants, but not this exact observer status gap.
- **Verification bucket**: model-check topology/flush overlap; unit-test direct SAI failure.

### Scenario B: learning, aging, moves, identity, and counters

#### F04 — an explicitly stale AGE deletes the current destination

- **Severity / status**: High if stale per-port AGE is permitted; contract-dependent modeling target.
- **Trace**: on mismatched bridge-port ID, code logs “Stale aging event,” replaces `update.port` with the current port, and explicitly continues to delete (`fdborch.cpp:621-631`). It then decrements current counts and clears the current entry (`766-790`).
- **Consequence**: delayed AGE(A) after MOVE A→B can erase the live B software entry and its observers even though the payload names A.
- **Compensators checked**: a future LEARN can restore state, but no incarnation check exists. `fdborch_vxlan_ut.cpp:4094-4130` codifies deletion rather than proving the platform ordering contract.
- **Verification bucket**: model-check under explicit SAI assumptions; obtain vendor/SAI contract confirmation before filing as a defect.

#### F05 — same-bridge-port or duplicate MOVE is not counter-idempotent

- **Severity / status**: Medium; confirmed behavior, event-contract dependent.
- **Trace**: MOVE loads `port_old` and `update.port` as independent copies; even when both name the same BP, it decrements the old copy and then increments the new copy (`fdborch.cpp:793-869`). The final store writes `N+1`. VLAN count is unchanged. LRU dedup collapses only byte-identical events still in flight (`58-84`), not separated duplicates.
- **Consequence**: port FDB count can drift upward, delaying tunnel/BP cleanup.
- **Tests**: `fdborch_vxlan_ut.cpp:1665-1708` injects a same-port MOVE but does not assert the count.
- **Verification bucket**: focused test plus event-contract review.

#### F06 — map-key port identity can remain stale after APP destination update

- **Severity / status**: High; confirmed representation inconsistency.
- **Trace**: `FdbEntry::operator<` and equality ignore `port_name` (`fdborch.h:22-36`). Notification insertion explicitly erases before reinsert to refresh the key (`fdborch.cpp:145-178`), but APP add/update assigns `m_entries[entry]` without an unconditional erase (`2222-2244`). `std::map` keeps the original key object. `notifyObserversFDBFlush` selects entries by the key's `port_name` (`1691-1713`), and missing-BP cleanup also uses key identity.
- **Consequence**: neighbor/mirror flush observers can miss the new port or attribute cleanup/counters to the old port.
- **Compensators checked**: the value has current BP/destination, but the observer explicitly reads the key. Existing update tests verify ASIC BP, not key/observer identity.
- **Verification bucket**: code-review-only representation decision plus regression test.

#### F07 — notification repair failures have no retry carrier

- **Severity / status**: High; confirmed failure-handling gap.
- **Trace**: MCLAG/VXLAN remote AGE recreation logs failure and returns (`fdborch.cpp:679-720`); dynamic-control-learn mutates cache/state before create and can return on failure (`723-762`); remote-to-local LEARN/MOVE set-attribute failures are logged but cache/observer commits continue (`472-590,823-882`). The notification is popped and cannot remain in `m_toSync`.
- **Consequence**: software may claim an entry/type/destination that the ASIC lacks, or the ASIC may retain a partial attribute set.
- **Compensators checked**: future events may heal incidentally; no timer, desired row, rollback, or repair queue owns the failed work.
- **Verification bucket**: code review for retry ownership and SAI failure-injection tests; general failure-carrier property belongs in the model.

#### F08 — MacMoveGuard timed recovery forgets a failed port re-enable

- **Severity / status**: High; confirmed current defect; no tracker found.
- **Trace**: `releaseBadMac` marks the MAC good, removes its reference, calls re-enable, but unconditionally erases `m_disabledPorts` even when re-enable returns false, then clears the MAC's disabled-port set and rewrites persistence (`macmoveguard.cpp:635-692`). `checkRecovery` will not retry because the MAC is no longer bad (`734-775`).
- **Consequence**: a physical port remains administratively down while both in-memory and STATE_DB recovery ownership are lost.
- **Compensators checked**: `clearAllState` (`80-106`) and restart restore (`857-909`) correctly retain failed ports, confirming the expected policy; they cannot recover a row already deleted by `releaseBadMac`. PortsOrch can legitimately return false (`portsorch.cpp:1809-1827,2300-2334`).
- **Tests/novelty**: the unit hook always succeeds and tests only the success path (`macmoveguard_ut.cpp:583-617`). Full [#4602](https://github.com/sonic-net/sonic-swss/pull/4602) review fixed the two compensating paths but never discussed `releaseBadMac`.
- **Verification bucket**: direct unit test and code fix.

#### F09 — accepted threshold 1 performs no port mitigation on the first native move

- **Severity / status**: Medium/High; confirmed current defect under documented configuration range; no tracker found.
- **Trace**: config accepts all thresholds `>=1` (`macmoveguard.cpp:169-180`). A native MOVE carries old and new ports (`fdborch.cpp:892-900`), but `handleMacMove` records only `new_alias` (`macmoveguard.cpp:411-436`). At count 1 the threshold fires (`448-469`), pins the sole recorded new port, and has no other port to disable (`494-589`).
- **Consequence**: the first move satisfies the configured threshold but the DISABLE_PORT action changes no port; mitigation begins only after another move exposes a second “new” port.
- **Tests/novelty**: existing cases use thresholds 2/3 and alternate ports. The full #4602 discussion contains no `port_old`, `ports_seen`, or threshold-1 coverage.
- **Verification bucket**: direct unit test and design review of whether “threshold” counts moves or distinct ports.

#### F10 — native-MOVE detection is latched globally for the process lifetime

- **Severity / status**: Medium; confirmed behavior, platform-contract dependent.
- **Trace**: the first native MOVE sets `m_nativeMovesSeen` globally and disables all subsequent LEARN-path synthesis (`macmoveguard.cpp:305-325,392-399`).
- **Consequence**: if a platform or bridge-port class mixes native MOVE and AGE+LEARN encodings, later moves on the latter path are never counted.
- **Compensators checked**: the learned cache is still updated, but no per-port/per-MAC capability state exists. If the SAI implementation guarantees one encoding globally, the behavior is intentional.
- **Verification bucket**: model only under a mixed-encoding environment assumption; otherwise exclude.

### Scenario C: deferred dependency and latest-intent semantics

#### F11 — saved FDB replay can overwrite newer intent or resurrect after delete

- **Severity / status**: High; confirmed queue semantics defect.
- **Trace**: missing port/BP/VLAN membership appends a saved entry and returns true, causing the consumer row to be acknowledged (`fdborch.cpp:1842-1872,1202-1229`). A later SET does not replace older saved work. Dependency-ready replay moves and applies every vector entry in order and ignores the return (`1766-1787`). DEL removes only the first matching saved entry and stops (`2444-2489`).
- **Consequence**: old destination A can overwrite newer B on replay; duplicate saved entries can survive one DEL and later resurrect; retryable SAI failure during replay can lose desired work.
- **Compensators checked**: one replay can append itself again if dependencies are still absent, but no per-key desired generation or full duplicate purge exists.
- **Tests**: `tests/test_fdb.py:324-380` covers one SET before membership, not SET/SET/DEL permutations.
- **Verification bucket**: generalized latest-intent model-check plus permutation tests.

#### F12 — late source NVO causes remote-VNI work to be acknowledged without apply

- **Severity / status**: High; confirmed live/unresolved design defect.
- **Trace**: both P2P and P2MP add paths return true when the source VTEP pointer is absent (`vxlanorch.cpp:2521-2528,2691-2697`); `Orch2::doTask` erases on true (`orch.cpp:1251-1308`). NVO creation assigns the pointer but does not scan or wake dropped rows (`vxlanorch.cpp:2829-2842`). NVO before source tunnel can throw through `getVxlanTunnel().at()` (`vxlanorch.h:281-284`), and the catch path also erases by default.
- **Consequence**: a valid remote VNI is permanently absent until a producer emits another SET or an external reconciliation occurs.
- **Compensators/limits**: Orch construction orders NVO before remote-VNI orchs (`orchdaemon.cpp:615-630`), reducing but not eliminating unordered selectable arrival. Missing VLAN/VNI-map cases correctly return false. Test helpers directly install the source pointer.
- **History**: #2756/#2757 changed these cases to retain work, but #2772/[#2773](https://github.com/sonic-net/sonic-swss/pull/2773) reverted the fix because it conflicted with warm workaround #2626; the revert explicitly called for a proper solution.
- **Verification bucket**: live scenario evidence and integration test; historical fixes remain reference-only.

#### F13 — parent NHG before member is dropped without retry

- **Severity / status**: High; confirmed one-shot ordering gap.
- **Trace**: `FdbSync::onMsgNhg` validates every referenced member against `m_l2NhgMap`; an unknown member logs and returns before publishing the group (`fdbsync.cpp:1254-1265`). Netlink dump/live message handling has no deferred parent queue or subsequent scan.
- **Consequence**: parent-before-child delivery leaves the APP L2-NHG row absent even after all members arrive.
- **Compensators checked**: a later NEWNEXTHOP for the parent can heal; child arrival alone does not.
- **Verification bucket**: netlink ordering integration test; generalized dependency replay in the model.

### Scenario D: L2-NHG, tunnel, bridge-port, and VLAN-member failure atomicity

#### F14 — VTEP replacement increments the old endpoint reference

- **Severity / status**: High; confirmed current defect, previously noticed in a closed mega-PR but not tracked open.
- **Trace**: `updateL2NhgVtepIp` removes the old member, decrements the old endpoint, and may clean its tunnel (`l2nhgorch.cpp:605-623`). It creates a member for `new_vtep_ip` (`625-633`) but increments `m_nhg_vtep[nh_id].ip`, which is still the old IP (`634-635`); the cache changes to new IP only at `653`.
- **Consequence**: the old DIP stays pinned or is recreated as a phantom reference, the new DIP has no NHG reference and can be deleted while still used, and later delete tries to decrement the wrong/missing new ref.
- **Compensators checked**: VXLAN ref decrement guards absence (`vxlanorch.cpp:1109-1143`), but that only logs; zero-ref cleanup (`1251-1271`) makes the mismatch materially affect tunnel lifetime.
- **Novelty**: [#4262's inline review](https://github.com/sonic-net/sonic-swss/pull/4262#discussion_r3143391702) identified this and delete-before-create. The author claimed a ref fix in a [follow-up](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135), but current master still contains both; no open tracker exists.
- **Verification bucket**: direct refcount/tunnel-lifetime test and code fix.

#### F15 — VTEP replacement is non-atomic and retry can no longer find removed members

- **Severity / status**: High; confirmed current defect.
- **Trace**: for every referencing group, `updateL2NhgVtepIp` removes/erases the old member before creating its replacement (`l2nhgorch.cpp:596-640`). On create failure it returns before updating the cached IP (`653`). Consumer retry retains the SET (`798-830`), but `has_next_hop` searches group membership that was already erased (`597`), so the failed group is skipped. With multiple groups, some can be converted before a later one fails.
- **Consequence**: one group permanently loses the member or groups split between endpoints; a one-member group may remain as an empty forwarding destination.
- **Compensators checked**: `updateL2Nhg` prechecks that the new tunnel exists (`692-697`), so the decisive reachable injection is SAI create/member failure. No rollback log or reconstruction scan exists.
- **Verification bucket**: SAI failure-injection test and multi-group model scenario.

#### F16 — existing NHG can remain active with zero or partial members

- **Severity / status**: High; confirmed state exposure, failure timing dependent.
- **Trace**: existing group update removes stale members first (`l2nhgorch.cpp:353-383`) and then adds replacements (`385-430`). If additions fail and the group becomes empty, only a newly created group is erased; an existing group is not explicitly deactivated (`497-506`). Partial groups remain active and return false for retry (`509-514`). `hasActiveL2Nhg` checks only `is_active` (`875-877`), and FdbOrch accepts that flag (`fdborch.cpp:1176-1185`).
- **Consequence**: remote FDB can reference an empty/partial NHG bridge port during or after an unsuccessful update.
- **Compensators checked**: fair retry can add missing members in some update paths, but an erased membership in F15 cannot be recovered by that retry. No `active ⇒ nonempty` guard exists.
- **Verification bucket**: model-check and injected-error test.

#### F17 — bridge-port create can orphan a SAI object after hostif failure

- **Severity / status**: High; confirmed for PHY/LAG bridge ports.
- **Trace**: `addBridgePort` successfully creates SAI BP (`portsorch.cpp:7441-7452`), then returns false if hostif KEEP fails (`7454-7459`). Cache/OID-map/observer commit starts only at `7460`; there is no `remove_bridge_port` rollback. Retained config work retries with the cached null BP and can create another object.
- **Scope/compensators**: `setHostIntfsStripTag` bypasses TUNNEL/NHG (`portsorch.cpp:3124-3132`), so this exact window is PHY/LAG only. Retaining the task is not rollback because it cannot discover the first object.
- **Tests**: current test covers router-port rejection, not post-create hostif failure (`portsorch_ut.cpp:2987-3022`).
- **Verification bucket**: direct failure-injection test and rollback review.

#### F18 — VLAN-member post-create/post-remove failure corrupts retry state

- **Severity / status**: High; confirmed, with a process-abort retry path.
- **Trace (add)**: SAI VLAN member create succeeds (`portsorch.cpp:7744-7755`), then untagged PVID failure returns before cache/ref/observer commit (`7760-7778`) and without removing the SAI member. Retry can create a duplicate.
- **Trace (remove)**: SAI member removal and `m_portVlanMember` erase happen (`8077-8092`), then default-PVID failure returns before VLAN membership/ref/observer commit (`8096-8112`). Config retains the task, but retry sees VLAN cache membership and reaches the assertion that `m_portVlanMember` contains it (`8070-8074`).
- **Consequence**: leaked/duplicate hardware on add; inconsistent caches followed by assertion/process abort on remove.
- **Compensators checked**: no rollback reconstructs the erased member record or re-creates the removed SAI object.
- **Verification bucket**: direct failure-injection tests at both PVID boundaries.

#### F19 — P2P remote-VNI add can acknowledge a phantom tunnel install

- **Severity / status**: High; confirmed return-propagation/partial-commit gap.
- **Trace**: P2P add ignores critical `addTunnelUser` and `addVlanMember` returns (`vxlanorch.cpp:2570-2586`). Dynamic tunnel setup inserts object/ref state and ignores `createTunnelHw` result (`1155-1187`; failure sites `885-949`); `addTunnelUser` ignores BP creation (`1744-1764`). A PortsOrch tunnel with null OID and a STATE_DB row can therefore exist before the remote-VNI SET returns true.
- **Consequence**: APP/config claims the remote VNI is consumed, but BP/member/hardware tunnel can be absent; a new SET can increment endpoint/IMR refs again.
- **Compensators/limits**: an initially missing/inactive VTEP and missing VLAN/VNI map correctly cause retry (`1722-1736,2537-2548`). Once phantom port state exists, those checks no longer guarantee recovery.
- **Verification bucket**: code-review transaction ownership and failure-injection integration test.

#### F20 — remote-VNI deletion acknowledges failed teardown

- **Severity / status**: High; confirmed.
- **Trace**: P2P DEL returns true when VLAN-member removal fails (`vxlanorch.cpp:2643-2649`). `delTunnelUser` can consume last-ref BP-removal failure before decrement/cleanup (`1813-1828`), and the non-DIP branch mutates refs before a consumed BP failure (`1787-1809`). P2MP retries its first member-remove failure but consumes later BP cleanup failure (`2810-2819`). Config VLAN DEL similarly ignores zero-ref BP-removal status (`portsorch.cpp:6103-6110`).
- **Consequence**: membership, BP, tunnel, or endpoint refs remain stranded with no pending desired row.
- **Compensators checked**: P2MP's initial member-remove return is correctly propagated; this was excluded from the defect scope.
- **Verification bucket**: code review and per-boundary teardown tests; general retry-ownership invariant in the model.

#### F21 — P2MP endpoint teardown cannot resume after late failure

- **Severity / status**: High; confirmed.
- **Trace**: `removeVlanEndPointIp` removes the L2MC member, decrements BP ref, and erases the endpoint before resetting flood attrs/removing the group (`portsorch.cpp:7955-8055`). A late failure returns false after persisting the erased endpoint. Remote DEL retries, sees the endpoint absent, treats it as spurious, and returns true (`vxlanorch.cpp:2794-2800`).
- **Consequence**: residual flood-group state and refs can remain permanently; retry cannot identify the transaction phase.
- **Compensators checked**: no phase record or rollback exists. P2MP add also acknowledges `addVlanMember` failure (`2741-2746`) while flood-group setup is progressive (`portsorch.cpp:7797-7938`).
- **Verification bucket**: direct late-failure tests and resumable-transaction code review.

### Scenario E: startup and warm-restart reconstruction

#### F22 — initial NHG dump is filtered before NVO readiness and never replayed

- **Severity / status**: High; confirmed startup loss; no direct tracker found.
- **Trace**: warm assist registers VXLAN_FDB and REMOTE_VNI only, not APP_L2_NEXTHOP_GROUP (`fdbsync.cpp:40-45`). `m_isEvpnNvoExist` starts false (`fdbsync.h:87-90`). Main dumps GETLINK and GETNEXTHOP before adding/servicing CONFIG NVO (`fdbsyncd.cpp:77-115`). `onMsgNhg` returns immediately while NVO is false (`fdbsync.cpp:1138-1144`). NVO SET changes the Boolean and local MAC projection but does not redump/replay NHGs (`111-136`).
- **Consequence**: kernel L2 NH/NHG state present at startup is absent from APP_DB and therefore from Orch/ASIC until a new kernel event happens; stale APP L2-NHG rows are not warm-reconciled either.
- **Compensators checked**: no delayed dump, saved netlink buffer, or NVO-triggered enumeration. Open #4538 carries the same feature code but does not identify the ordering bug; merged #4615 discussion confirms ignored-while-no-NVO behavior.
- **Verification bucket**: startup integration test and restart model.

#### F23 — batched NVO events compare against one stale baseline

- **Severity / status**: Medium; confirmed current defect.
- **Trace**: `processCfgEvpnNvo` captures `lastNvoState` once before iterating a batch and never updates it (`fdbsync.cpp:111-137`). For initial false, SET→DEL invokes add transition work but misses delete transition work; for initial true, DEL→SET invokes delete transition work but misses re-add transition work.
- **Consequence**: local MAC projection/L2-NHG cleanup does not correspond to the final config transition.
- **Compensators checked**: Redis `pops` can return multiple entries; no final-state reconciliation is called after the loop.
- **Verification bucket**: deterministic batch unit test.

#### F24 — VXLAN interface generation is never retired

- **Severity / status**: High; confirmed stale-generation bug.
- **Trace**: fdbsyncd registers only `RTM_NEWLINK` (`fdbsyncd.cpp:27-31`); `onMsg` rejects every other link message (`fdbsync.cpp:1128-1136`). `onMsgLink` inserts/updates VXLAN `m_intf_info` but never erases (`1098-1125`). Neighbor classification treats any mapped ifindex as VXLAN (`967-1007`). Even a NEWLINK for a reused non-VXLAN ifindex returns without clearing the old entry.
- **Consequence**: after delete and ifindex reuse, physical neighbor/FDB events can be parsed as VXLAN and published under a stale VNI/interface.
- **Compensators checked**: process restart clears the volatile map; no in-run generation or DELLINK path exists.
- **Verification bucket**: netlink DELLINK/reuse test.

#### F25 — IMET delete without destination cannot clean APP remote-VNI state

- **Severity / status**: Medium/High; confirmed limitation whose external cleanup owner is unproven.
- **Trace**: IMET events always try to extract `NDA_DST`; absence returns at `fdbsync.cpp:1029-1037`. The later comment says realistic RTM_DELNEIGH lacks the attribute and intends to skip/delete “through other means” (`1055-1078`), but that branch is unreachable after the earlier return. No DELLINK-driven IMET purge or NVO-table scan was found.
- **Consequence**: stale `VXLAN_REMOTE_VNI_TABLE` state can survive the kernel route deletion until restart or an unrelated producer event.
- **Compensators checked**: none within fdbsyncd; an external manager may emit a separate DEL, which needs ownership confirmation.
- **Verification bucket**: integration test and code-owner review.

#### F26 — `macAddVxlan` always emits DEL before SET

- **Severity / status**: Medium; confirmed behavior, intent uncertain.
- **Trace**: the function populates `m_mac[key]` before every `m_mac.find(key)` check, so all destination branches see the key and call `m_fdbTable.del` (`fdbsync.cpp:787-857`). During warm restart the DEL is inserted into warm cache after the volatile map mutation.
- **Potential consequence**: first add and updates create a delete/set gap; crash/restart or independently scheduled consumers can observe transient absence. It may be an intentional way to clear stale ProducerStateTable fields because SET merges fields.
- **Compensators checked**: subsequent SET occurs in the same handler absent crash; Redis pipeline/order may preserve sequence but does not make cross-consumer side effects atomic.
- **Verification bucket**: code-review-only intent check; model only if the DEL/SET gap is externally observable in scope.

## Historical corrective-lineage ledger

This ledger records all 66 significant corrective lineages found by diff review. Severity is the historical defect's impact. Multiple hashes in one row are one logical fix/backport lineage. These are **reference evidence, not current model-check targets**.

### H01–H18: event ordering, deferred work, and readiness

| ID | Severity | Commit / discussion | Corrective mechanism |
|---|---|---|---|
| H01 | High | `5a4b76f`, [#4739](https://github.com/sonic-net/sonic-swss/pull/4739) | Neighbor-first remote MAC was undone by unconditional FDB delete; deletion is now gated on a real prior-local update. |
| H02 | High | `80c742c`, `864b225`, [#3937](https://github.com/sonic-net/sonic-swss/pull/3937)/#3838 | Route-before-neighbor mux flow lacked FDB port identity/ref transition and could blackhole standby traffic. |
| H03 | High | `da18966`, [#3524](https://github.com/sonic-net/sonic-swss/pull/3524) | Port-down bulk flush raced ICCPd's per-entry move; ordinary flush is skipped for MCLAG interfaces. |
| H04 | High | `4a321f0`, `c2b01ba`, `ceea558`, `c98b9f0`, #2657/#2658 | SAI state could advance before queued Orch notification; lookup moved to the consistent `m_entries` snapshot. |
| H05 | High | `4f304bc`, `8de52bf`, [#2642](https://github.com/sonic-net/sonic-swss/pull/2642) | Remote VNI before local VNI/VLAN map is retained for retry. |
| H06 | High, unresolved after revert | `a484ab8`, `750e064`, #2757/#2756; reverted by `0c7ed8d`, `867e355`, [#2773](https://github.com/sonic-net/sonic-swss/pull/2773) | Missing-source-NVO retry conflicted with warm workaround #2626; HEAD again consumes the event and the revert requests a proper solution. |
| H07 | High | `a3ac275`, `168bd3b`, #2404 | VRF-VNI-first create-only tunnel lacked VLAN mappers; first creation now supplies both mapper families. |
| H08 | High | `47586e8`, `4a6f940`, [#2388](https://github.com/sonic-net/sonic-swss/pull/2388) | P2MP membership omitted the observer wakeup needed to replay saved FDB entries. |
| H09 | High | `2447754`, `c646607`, `baa302e`, #2669 | Bridge-port creation now waits for pending router-interface deletion. |
| H10 | High | `163b43c`, `1f2269b`, #4798/#4654 | VLAN-member SET now defers while the physical port is still a LAG member; stale missing-VLAN delete is consumed. |
| H11 | Medium | `a9061a1`, #4415 | Coalesced SET/DEL for a VLAN never created is consumed rather than retried forever. |
| H12 | High | `d83b727`, #4387 | LAG add waits while fixed-priority VLAN membership cleanup remains. |
| H13 | Critical | `05b2f55`, `3831785`, [#3630](https://github.com/sonic-net/sonic-swss/pull/3630) | FDB callback enablement moved after default bridge-port cleanup to prevent learned references from aborting startup. |
| H14 | High | `4730653`, #540 | VLAN-member SET with a not-yet-created port is retained for retry. |
| H15 | High | `bab7b93`, `a26a7d9`, #1103/#1116 | Warm bake now populates the pending-port set before `allPortsReady` can succeed. |
| H16 | High | `770e617`, `1eac91e`, #1108 | Explicit PORT→LAG→LAG_MEMBER→VLAN→VLAN_MEMBER processing order was introduced. |
| H17 | High | `4f1d726`, `e83e544`, `a67d8af`, #1797/#1819 | LAG-to-LAG TeamSync moves validate existing type/membership and defer conflicts instead of asserting. |
| H18 | High | `41caa74`, [#406](https://github.com/sonic-net/sonic-swss/pull/406) | FDB arriving before port/BP is saved and retried on VLAN-member notification. |

### H19–H29: flush scope, acknowledgement, and counters

| ID | Severity | Commit / discussion | Corrective mechanism |
|---|---|---|---|
| H19 | High | `cd11762`, [#4734](https://github.com/sonic-net/sonic-swss/pull/4734) | Reverted lifecycle flush from ALL to dynamic-only after static config deletion/vendor rejection; EVPN-MH requirements remain disputed. |
| H20 | High | `fa4ca60`, [#4430](https://github.com/sonic-net/sonic-swss/pull/4430) | VLAN flush input now gains the `Vlan` prefix instead of falsely reporting success. |
| H21 | High | `8386242`, [#4527](https://github.com/sonic-net/sonic-swss/pull/4527) | FDB type is reset inside each batched-notification iteration to prevent type bleed. |
| H22 | High | `980a45b`, `ebe8de7`, `804e5ac`, [#2673](https://github.com/sonic-net/sonic-swss/pull/2673) | Cache now stores SAI type so consolidated flush cleanup distinguishes remote/static/dynamic entries. |
| H23 | High | `bbbd5f4`, `ebdc242`, `aa7b546`, #2254/#2401 | Added complete consolidated/VLAN/port+VLAN cleanup even after bridge-port removal, including state/counters/observers. |
| H24 | High | `8dae356`, [#2136](https://github.com/sonic-net/sonic-swss/pull/2136) | Added per-entry pending marker so delayed flush cannot blindly remove a relearned entry. |
| H25 | High | `d82874d`, `0549f3c`, `455547e`, #2332/#2374 | Flush gained dynamic type filtering to avoid configured-static deletion and crash. |
| H26 | High | `26e1723`, [#1369](https://github.com/sonic-net/sonic-swss/pull/1369) | Iterator is advanced before state cleanup erases `m_entries`. |
| H27 | High | `2127fb9`, [#1242](https://github.com/sonic-net/sonic-swss/pull/1242) | Added port/LAG-down and VLAN-member flush hooks plus entry port identity. |
| H28 | Medium | `7c41537` | Port-down path now guards null bridge-port OID before flush. |
| H29 | High | `23be627`, `756dd9c`, `ab785d8`, #1451/#1516 | Bridge-port deletion gained preceding FDB flush; only an old release branch later reverted it. |

### H30–H41: move, origin, type, and identity consistency

| ID | Severity | Commit / discussion | Corrective mechanism |
|---|---|---|---|
| H30 | Low | `15454e0`, #4674 | Idempotent duplicate VXLAN delete log was demoted from ERROR to DEBUG. |
| H31 | High | `7fe76e0`, [#2811](https://github.com/sonic-net/sonic-swss/pull/2811) | MCLAG remote-static→local MOVE now updates SAI type, BP, and `ALLOW_MAC_MOVE` together. |
| H32 | High | `7e274a4`, `dca78d8`, [#2521](https://github.com/sonic-net/sonic-swss/pull/2521) | Kernel local replace now precedes remote VXLAN delete, preventing FRR from reinstalling remote state. |
| H33 | Medium | `1723aac`, #2261 | `oldFdbData.origin` now initializes to INVALID. |
| H34 | High | `74e9b9f`, `5b7c949`, #2201/#2200 | MOVE populates `entry.port_name` so downstream state/observer identity changes with destination. |
| H35 | High | `62e2a20`, `8f06b89`, [#759](https://github.com/sonic-net/sonic-swss/pull/759) | State VLAN derives from event BV instead of physical-port PVID. |
| H36 | High | `98c084a`, #466 | SAI FDB get/remove structs now include `switch_id`. |
| H37 | Medium | `4365bb8`, #1553 | Fixed nonterminated MAC/port buffers in kernel command construction by using strings. |
| H38 | High | `868db24`, `a2c9a61`, #2670 | Remote-VNI add distinguishes L3 VNI and avoids L2/IMR programming. |
| H39 | High | `63c0234`, `a443945`, #2538 | Shared VRF/VLAN VNI explicitly removes/restores L2 mapping around L3 mapping. |
| H40 | Medium | `e181e3c`, #3383 | Tunnel-port oper state and tunnel-ID↔alias cache are initialized and erased consistently. |
| H41 | High | `9143018`, #877 | Existing provisioned MAC SET now performs remove/recreate update. |

### H42–H56: bridge/tunnel lifecycle and failure atomicity

| ID | Severity | Commit / discussion | Corrective mechanism |
|---|---|---|---|
| H42 | High | `9b237a2`, `1339028`, dev `86ceacb`, `e0dc2b1`, #3908/#4188 | Tunnel/map/NH failures now propagate and roll back partial mapper/tunnel/flex state instead of storing null-created state/throwing. |
| H43 | High | `6bafea4`, `a8e238a`, #2352 | Missing remote-endpoint ref is checked before decrement/dereference. |
| H44 | Medium | `ec6c8af`, `a9b6b47`, `680c539`, #2150/#2208 | VNET tunnel removal uses unified hardware deletion to remove mapper objects too. |
| H45 | High | `a5e6bea`, #995 | Tunnel/term IDs initialize to null and removal guards null IDs. |
| H46 | High | `0fbb711`, #1052 | Tunnel deletion now waits for/removes associated maps. |
| H47 | Medium | `7d0c551`, #880 | Missing tunnel in `removeNextHopTunnel` now returns false instead of false success. |
| H48 | High | `7841930`, `9d3a5c5`, [#2378](https://github.com/sonic-net/sonic-swss/pull/2378) | P2MP flood-group add/remove paths now update VLAN-member caches across partial/final branches. |
| H49 | High | `4f606f5`, #263 | Default bridge cleanup filters PORT type and preserves router bridge ports. |
| H50 | Medium | `92533e3`, #256 | Bridge-port list capacity includes extra CPU/router object. |
| H51 | High | `61ad2d1` | Asynchronous missing BP lookup uses checked lookup instead of `.at()` throw. |
| H52 | High | `1a59ad1` | Default VLAN member is removed before its bridge port. |
| H53 | High | `ffb1c16` | Initialization retains existing default bridge-port mappings. |
| H54 | High | `822fc0a`, #97 | Default VLAN cleanup iterates returned object-list count rather than `m_portCount`. |
| H55 | High | `b9cf86d`, corrected by `8d214e4` | Follow-up fixed an inverted membership predicate introduced by an assertion-removal patch. |
| H56 | High | `731395a` | Bridge-list GET now allocates backing storage and filters object type. |

### H57–H61: warm-restart snapshot/replay

| ID | Severity | Commit / discussion | Corrective mechanism |
|---|---|---|---|
| H57 | High | `a4f29c1`, `1bbf725`, `0704f78`, #2626 | Warm workaround moved missing-source-VTEP check earlier and consumed work; it later conflicted with H06's retry attempt. |
| H58 | High | `e892dda`, `7d16f69`, #1866 | Warm restoration uses `dynamic && remote-origin` for `ALLOW_MAC_MOVE`, not `dynamic || remote-origin`. |
| H59 | High | `17adc13`, `fcb6c9d`, #1498 | `registerAppTable` clears producer state only during warm start. |
| H60 | Medium | `31a67ad`, `f3d0279`, #921 | Warm field-vector comparison became order-insensitive. |
| H61 | High | `c41a1b7`, `cd95972`, #2619 | A restored NEW change remains NEW when an identical later value arrives, preserving reconciliation. |

Preventive references, not counted as corrective lineages: `721f47d`/#1556 waits for dependent interface managers before FdbSync warm replay; `f13aaed`/[#628](https://github.com/sonic-net/sonic-swss/pull/628) disables bridge-port learning and flushes before planned restart.

### H62–H66: ownership, memory, and control flow

| ID | Severity | Commit / discussion | Corrective mechanism |
|---|---|---|---|
| H62 | Medium | `d322f66`, `4d47059`, #3017 | Constructor DB connectors became persistent smart-pointer members. |
| H63 | Critical | `d9e9ba8`, `84e9b07`, [#2353](https://github.com/sonic-net/sonic-swss/pull/2353) | `clearFdbEntry` copies entry/data before state cleanup erases the referenced map element. |
| H64 | Critical | `9ae47db`, `27b29e3`, [#525](https://github.com/sonic-net/sonic-swss/pull/525) | Batch deserialization memory is freed after the event loop, not once per event. |
| H65 | High | `39523aa`, #478 | SAI callbacks moved from callback thread/global DB mutex into the ASIC_DB notification event loop. |
| H66 | High | `b641aee`, #372 | Corrected inverted ports-ready guard that ran FDB work before readiness and stopped afterward. |

### Recurring regression chains

- **Flush scope**: H25 dynamic-only → #4615 changed lifecycle flush to ALL → H19 restored dynamic-only; #4734 comments still identify an EVPN-MH requirements conflict.
- **Flush acknowledgement**: H23 complete async cleanup → H24 pending flag → H21 batch-local type repair; current F01/F02 show the protocol still lacks epochs/uniform marking.
- **Deferred dependencies**: H18 saved-FDB replay → H08 missing P2MP wakeup repair; current F11 shows append/latest-intent gaps.
- **NVO ordering**: H57 warm workaround consumes absent-NVO work → H06 retained it → reverts restore consumption and explicitly leave the design unresolved.
- **Ports scheduling**: H16 fixed table order → H12 and H10 add guards for valid producer orders that violate that priority.
- **Notification architecture**: H65 moved callbacks to the event loop → H64 fixed the induced batch lifetime defect.
- **Port-down flush**: H27 added cache-erasing behavior → H26 repaired iterator invalidation → H03 exempted MCLAG to avoid move/flush race.

## GitHub discussion audit

### Deep-read classification ledger

Classification counts treat linked issue, fix PR, and backport threads separately:

| Classification | Count | IDs |
|---|---:|---|
| Confirmed bug/fix | 65 | #284, #304, #389, #461, #466, #477, #525, #758, #759, #909, #929, #964, #998, #1001, #1110, #1242, #1294, #1295, #1369, #1451, #1470, #1516, #1534, #1827, #1924, #1932, #2076, #2136, #2353, #2374, #2521, #2539, #2610, #2623, #2625, #2636, #2675, #2676, #2696, #2886, #2913, #2961, #2985, #3149, #3211, #3524, #3630, #3645, #3838, #3937, #4430, #4458, #4459, #4507, #4527, #4572, #4604, #4605, #4715, #4736, #4739, #4771, #4773, #4782, #4801 |
| Design defect | 12 | #290, #827, #1145, #1716, #2535, #2624, #2673, #3205, #4262, #4586, #4602, #4734 |
| Disputed/false claim | 5 | #886, #1134, #1834, #3210, #4533 |
| User error | 0 | — |
| Uncertain | 3 | #293, #824, #2413 |
| Non-defect/context | 21 | #250, #259, #348, #558, #572, #595, #615, #628, #634, #877, #1014, #1595, #1904, #2543, #3222, #3671, #4538, #4615, #4713, #4792, #4806 |
| **Total** | **106** | 77 confirmed/design evidence; 26 excluded; 3 uncertain |

### All 31 open PRs with plausible FDB bug-fix intent

This table records disposition as of 2026-08-01. “Stale” means the PR is still open but its underlying behavior was superseded or repaired elsewhere.

| PR | Audit verdict |
|---|---|
| [#4801](https://github.com/sonic-net/sonic-swss/pull/4801) | Confirmed: warm restart repeats default VLAN/BP cleanup against preserved ASIC state and fails reference validation. |
| [#4782](https://github.com/sonic-net/sonic-swss/pull/4782) | Confirmed: runtime-created NPU ports remain in the default VLAN/1Q bridge because cleanup was VOQ-only. |
| [#4773](https://github.com/sonic-net/sonic-swss/pull/4773) | Confirmed draft: reused BP can remain admin-disabled with stale hostif tag state after incomplete deletion. |
| [#4771](https://github.com/sonic-net/sonic-swss/pull/4771) | Confirmed draft: duplicate VLAN-member processing loses tagging-mode changes; warm replay can preserve the wrong mode. |
| [#4715](https://github.com/sonic-net/sonic-swss/pull/4715) | Confirmed: stale `PortConfigDone count=0` makes `PortsOrch::bake()` destructively clear real replay rows. Claimed folding into #4713 did not occur. |
| [#4605](https://github.com/sonic-net/sonic-swss/pull/4605) | Confirmed: retryable pending work can starve forever without a new ring-buffer/selectable event; proposes timeout sweeps. |
| [#4604](https://github.com/sonic-net/sonic-swss/pull/4604) | Confirmed bug intent: FDB notification storms caused queue/RSS growth and OOM; #4586 handles duplicate volume, while batch draining remains proposed. |
| [#4533](https://github.com/sonic-net/sonic-swss/pull/4533) | Disputed/redundant: key collapse can discard semantically distinct transitions; #4586 instead deduplicates byte-identical notifications. |
| [#4458](https://github.com/sonic-net/sonic-swss/pull/4458) | Confirmed: invalid BP IDs during LAG transition silently drop notifications and leave stale `m_entries`; proposed scans raised performance concerns. |
| [#3645](https://github.com/sonic-net/sonic-swss/pull/3645) | Confirmed: remote-to-local EVPN MOVE outside MCLAG omits required SAI type, allow-move, and BP changes. |
| [#3211](https://github.com/sonic-net/sonic-swss/pull/3211) | Confirmed: static MAC references cause `OBJECT_IN_USE` on BP removal and orchagent termination. |
| [#3210](https://github.com/sonic-net/sonic-swss/pull/3210) | Disputed: blanket default-bridge cleanup was rejected as vendor-specific/unsafe; #4782 is narrower and tested. |
| [#2961](https://github.com/sonic-net/sonic-swss/pull/2961) | Confirmed: retain BP deletion in `m_toSync` and retry until references drain. |
| [#2886](https://github.com/sonic-net/sonic-swss/pull/2886) | Confirmed: stale VLAN `m_fdb_count` can remain nonzero and block VLAN deletion permanently. |
| [#2625](https://github.com/sonic-net/sonic-swss/pull/2625) | Confirmed draft: Broadcom AGE+LEARN move encoding diverges MCLAG static/allow-move state across peer/DB/ASIC. |
| [#2624](https://github.com/sonic-net/sonic-swss/pull/2624) | Design defect: incomplete lifecycle for SAI-created default VLAN/default 1Q bridge. |
| [#2623](https://github.com/sonic-net/sonic-swss/pull/2623) | Confirmed: Broadcom emits AGED, not FLUSHED, after BP deletion; cache cleanup must recognize deleted BP. |
| [#2610](https://github.com/sonic-net/sonic-swss/pull/2610) | Confirmed: MCLAG VLAN-member removal leaves synchronized static MACs in hardware/saved restore state. |
| [#2539](https://github.com/sonic-net/sonic-swss/pull/2539) | Stale/superseded: #3524 fixed the async flush/MCLAG-move crash via a different policy. |
| [#2535](https://github.com/sonic-net/sonic-swss/pull/2535) | Design defect: isolation-group refs must precede BP delete; generic observer reordering was rejected because it misstates deletion completion. |
| [#2413](https://github.com/sonic-net/sonic-swss/pull/2413) | Uncertain: claims an uninitialized FdbOrch variable without identifying it, reproduction, or useful review. |
| [#1932](https://github.com/sonic-net/sonic-swss/pull/1932) | Confirmed: dynamic local MCLAG FDB absent from State DB prevents flush propagation to ICCPd/peer. |
| [#1924](https://github.com/sonic-net/sonic-swss/pull/1924) | Confirmed: remote MCLAG DEL removes ASIC/State state but leaves the kernel bridge FDB entry. |
| [#1834](https://github.com/sonic-net/sonic-swss/pull/1834) | Disputed: reviewer assigns VLAN/LAG membership removal before RIF creation to CLI/config sequencing. |
| [#1827](https://github.com/sonic-net/sonic-swss/pull/1827) | Confirmed: APP/warm replay loses `port_name`, so port-down flush misses mirror/neighbor observers. |
| [#1470](https://github.com/sonic-net/sonic-swss/pull/1470) | Stale: #2136 superseded blind notification counting; review explained consolidated/missed notifications make counts brittle. |
| [#964](https://github.com/sonic-net/sonic-swss/pull/964) | Stale: old port/LAG-down flush proposal superseded by later observer/flush machinery. |
| [#929](https://github.com/sonic-net/sonic-swss/pull/929) | Confirmed default-VLAN design gap overlapping later #2624 lifecycle work. |
| [#909](https://github.com/sonic-net/sonic-swss/pull/909) | Stale: old interface-down flush proposal superseded by later PortsOrch/FdbOrch integration. |
| [#886](https://github.com/sonic-net/sonic-swss/pull/886) | Disputed/obsolete: reviewer reports the old kernel behavior no longer reproduces and its dependency was closed. |
| [#824](https://github.com/sonic-net/sonic-swss/pull/824) | Uncertain: metadata-race proposal depends on external sairedis changes and has no local reproduction/discussion. |

### Broad open-PR false positives

The 28 broad lexical open-PR matches excluded from bug-fix intent were:

- Feature/architecture additions: #4806, #4780, #4206, #3375, #3226, #3167, #1700, #1259, #867.
- Documentation, tests, or mechanical changes: #4742, #3671, #3570.
- Unrelated PFC, VNET, LAG, or generic warm-restart changes: #4743, #4735, #4725, #4597, #4552, #4499, #4487, #4418, #4412, #2963, #2471, #2085, #2084, #1810, #1548.
- #3222: cleanup only; review requested the warm behavior be separated and the author removed it.

Two exact-code search hits were also excluded: #4538 is a large EVPN-MH feature rebase, not a bug-fix PR; #4792 mechanically removes dormant consumer priorities and touches MacMoveGuard only at a call site.

### Current-finding novelty map

| Finding | GitHub result |
|---|---|
| F01 STP missing pending | No exact hit or open tracker. |
| F08 timed-recovery loss | #4602 fixed analogous `clearAllState`/restart paths but did not discuss `releaseBadMac`; no open tracker. |
| F09 threshold 1 | No `port_old`/`ports_seen`/threshold-1 discussion in #4602; no open tracker. |
| F14/F15 L2-NHG VTEP move | Explicitly identified during closed #4262 review; claimed fixed, still present after feature split; no open tracker. |
| F22 NHG dump before NVO | #4538 contains the same feature, and #4615 confirms filter behavior; neither recognizes the startup loss; no direct tracker. |
| F12 late NVO | Known unresolved revert lineage #2756/#2757→#2772/#2773; retain as current scenario evidence, not a “new” report. |

## Test audit and concrete gaps

### Focused test inventory

| File | Test declarations | Relevant gaps |
|---|---:|---|
| `tests/mock_tests/fdbsyncd/fdbsyncd_ut.cpp` | 63 | 42 tests contain vacuous assertions; remote MCLAG test exercises SET only; no NVO/dump order, parent-before-member, DELLINK reuse, or IMET realistic DEL |
| `tests/mock_tests/fdborch/fdborch_vxlan_ut.cpp` | 85 | STP helper does not assert pending/ack cleanup; same-port MOVE does not assert count; stale AGE deletion is encoded as expected; saved-FDB only single-intent coverage |
| `tests/mock_tests/fdborch/flush_syncd_notif_ut.cpp` | 10 | Tests manually seed pending, bypassing request-side marker correctness and overlapping epochs |
| `tests/mock_tests/macmoveguard/macmoveguard_ut.cpp` | 16 | Thresholds 2/3 only; re-enable mock succeeds; no mixed native/synthesized platform behavior |
| **Total** | **174** | No direct L2-NHG VTEP replacement/refcount test; the FdbOrch NHG test fixture is disabled |

### Recommended test order

1. F01 STP flush request→matching `FLUSHED` with cache/STATE/CRM/port/VLAN assertions.
2. F14 wrong endpoint ref and F15 multi-group create failure/retry.
3. F18 add/remove PVID failure and retry assertion safety.
4. F08 failed re-enable persistence and F09 threshold 1.
5. F22 initial dump before NVO plus F13 parent-before-member.
6. F11 SET(A)→SET(B)→DEL dependency permutations.
7. F02 mixed static/dynamic scoped flush and F05 same-BP duplicate MOVE counts.
8. F24 DELLINK/ifindex reuse and F25 realistic IMET DEL.
9. F19–F21 tunnel/P2P/P2MP failure injection at every external step.

## Explicit exclusions and rejected hypotheses

### History/search exclusions

- Feature-introduction commits `fb6c2a5` (#4602), `88a8adbf` (#4608), and `f0c53b9` (#4615) are introduction evidence for current findings, not historical fixes.
- #3402 changes an erroneous tunnel PVID log without behavior; #1669 changes flush log severity only.
- #2931 concerns shutdown-request notification synchronization, not the FDB lifecycle.
- `17a2f93` is unrelated array-delete/header cleanup.
- #3076 concerns generic tunnel flex-counter ordering; it does not update FDB lifecycle counters.
- #3343 is hostif/subport tag-mode logic with only an incidental bridge condition.
- Generic PortsOrch port speed, serdes, PFC, ACL, and unrelated counters do not enter the BP/VLAN/FDB/tunnel state graph.
- Off-main “fix errors” development commits such as `1ff1694` and `c9be749` were superseded and not counted separately.
- Cherry-picks and release-branch twins are grouped, never double-counted.

### Deep-analysis exclusions/nuance

- `m_entries_by_port` accumulates duplicates and is incompletely cleared, but no production reader was found; it is maintenance debt, not a current model target.
- The bridge-port post-create hostif failure F17 cannot affect TUNNEL/NHG port types because the helper explicitly bypasses them.
- Remote VNI correctly retries missing VLAN and missing VNI/VLAN-map dependencies; only missing source NVO and ignored mutation returns are in scope.
- P2MP correctly retries its initial VLAN-member removal failure; F20 concerns later BP cleanup that is consumed.
- L2-NHG add has explicit partial cleanup when new BP creation fails (`l2nhgorch.cpp:432-485`); no blanket “all NHG failures leak” claim is made.
- VXLAN endpoint decrement checks absent refs; this prevents a crash but does not compensate F14's wrong ref attribution.
- The unconditional DEL-before-SET in F26 may intentionally clear stale merged fields. It remains review-only until producer semantics/intent are confirmed.
- Stale AGE deletion F04 and run-global native-MOVE suppression F10 require platform event-contract assumptions and are phrased as model/review questions, not confirmed upstream defects.
- Notification LRU dedup is byte-identical only and preserves distinct event types/ports; no claim is made that it itself collapses MOVE into AGE/LEARN.
- Queue/RSS OOM in #4604 is operational/performance behavior; it informs event multiplicity but is not a formal safety target after #4586's dedup.
- Raw memory bugs H63/H64, buffer termination H37, object-list sizing H50/H54/H56, logging H30, and DB-connector leaks H62 are historical implementation evidence only, not TLA+ extensions.
- BFT, elections, log matching, quorum behavior, and shared-memory data races do not apply.

## Phase 4 handoff decisions

### Model-checkable forward questions

The selected model questions are deliberately not reproductions of fixed history:

1. Can two overlapping flush scopes and reordered/consolidated acknowledgements delete a re-learned incarnation?
2. Under permitted SAI event ordering, can delayed AGE(A) after MOVE A→B delete B?
3. Can old SET, new SET, DEL, and dependency-ready interleavings violate latest desired state?
4. Can multi-group VTEP replacement plus partial SAI failure leave a fair-retry execution with empty/partial active forwarding state?
5. Can a warm restart converge when kernel NHG state changed while down and the one-shot dump preceded NVO readiness?
6. Can BP removal/recreation plus failed/delayed flush attach an old entry or ack to the new topology generation?

Each question has an externally observable failure conclusion—wrong forwarding destination, absent/present hardware contrary to intent, dangling reference, stale database state, or incorrect counters. Defense-in-depth-only questions were excluded under the skill's output-value litmus.

### Test-verifiable findings

F01, F02, F05, F08, F09, F13–F15, F17–F25 have concrete unit/integration failure injection or event-sequence tests. The modeling brief selects the highest-value subset so Spec Generation is not burdened with low-level parsing/SAI mechanics.

### Code-review-only findings

F06 requires a clear identity/value representation decision; F07 and F19–F21 require transaction/retry ownership review; F10 requires platform capability semantics; F25 needs external cleanup-owner confirmation; F26 needs ProducerStateTable merge-intent confirmation.

## Source and discussion pointers

- Modeling handoff: `modeling-brief.md`.
- Core source: `orchagent/fdborch.cpp`, `fdbsyncd/fdbsync.cpp`, `fdbsyncd/fdbsyncd.cpp`, `orchagent/l2nhgorch.cpp`, `orchagent/macmoveguard.cpp`, `orchagent/portsorch.cpp`, `orchagent/vxlanorch.cpp`, `orchagent/stporch.cpp`.
- Strong flush evidence: [#1242](https://github.com/sonic-net/sonic-swss/pull/1242), [#1369](https://github.com/sonic-net/sonic-swss/pull/1369), [#2136](https://github.com/sonic-net/sonic-swss/pull/2136), [#2254](https://github.com/sonic-net/sonic-swss/pull/2254), [#2673](https://github.com/sonic-net/sonic-swss/pull/2673), [#4527](https://github.com/sonic-net/sonic-swss/pull/4527), [#4734](https://github.com/sonic-net/sonic-swss/pull/4734).
- Strong lifecycle/order evidence: [#406](https://github.com/sonic-net/sonic-swss/pull/406), [#1716](https://github.com/sonic-net/sonic-swss/pull/1716), [#2388](https://github.com/sonic-net/sonic-swss/pull/2388), [#2521](https://github.com/sonic-net/sonic-swss/pull/2521), [#3524](https://github.com/sonic-net/sonic-swss/pull/3524), [#3630](https://github.com/sonic-net/sonic-swss/pull/3630), [#3937](https://github.com/sonic-net/sonic-swss/pull/3937), [#4739](https://github.com/sonic-net/sonic-swss/pull/4739).
- L2-NHG retained defect evidence: [#4262 inline review](https://github.com/sonic-net/sonic-swss/pull/4262#discussion_r3143391702), [author response](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135).
- Current lifecycle/warm work: [#2886](https://github.com/sonic-net/sonic-swss/pull/2886), [#2961](https://github.com/sonic-net/sonic-swss/pull/2961), [#3211](https://github.com/sonic-net/sonic-swss/pull/3211), [#4458](https://github.com/sonic-net/sonic-swss/pull/4458), [#4605](https://github.com/sonic-net/sonic-swss/pull/4605), [#4715](https://github.com/sonic-net/sonic-swss/pull/4715), [#4771](https://github.com/sonic-net/sonic-swss/pull/4771), [#4773](https://github.com/sonic-net/sonic-swss/pull/4773), [#4801](https://github.com/sonic-net/sonic-swss/pull/4801).

## Final audit status

- All required skill phases completed.
- Category A carried into the modeling brief.
- All 442 history candidates diff-reviewed; all 66 significant lineages documented.
- 106 full GitHub discussions deeply read; all 455 open PRs screened; all 31 plausible open bug-fix PRs dispositioned.
- Current findings checked against callers, compensators, tests, blame, and GitHub novelty.
- Fixed historical bugs retained only as scenario/reference evidence.
- Modeling brief is 199 lines and contains all seven required sections, explicit model/do-not-model guidance, extensions, invariants, and Category A verification buckets.
