# dash-ha Code Analysis Report

## Executive Summary

This audit analyzed `sonic-net/sonic-dash-ha` at `f53422a4b5f0de372714fd309d1975ce34445633` (`master`, 2026-07-28). The worktree was clean before and after analysis.

The system is **Category A (Distributed / Message-Passing)**. HAMgrD actors serialize their own callbacks, but database consumers, producer bridges, actor timers, peer NPUs, SWBus connections, Redis commits, and DPU/ASIC acknowledgement paths advance independently. No Byzantine-fault overlay applies.

The primary formal-verification targets are:

1. non-atomic ingress/commit/DB/ASIC completion boundaries;
2. stale at-least-once replay without generations;
3. missing peer-pairing epochs;
4. incomplete replay of persisted transition intent after crash;
5. actor deletion/recreation and volatile-registration epochs;
6. competing configuration- and failover-derived route writers; and
7. one retry counter shared by connection, election, and switchover protocols.

The strongest directly confirmed current defects outside the formal target are duplicate ConsumerBridge route teardown, unfiltered cross-scope DPU state, empty-field DPU deletion rejected before cleanup, multiple derived-resource cleanup leaks, and inline-counter underflow. These belong in deterministic tests or code review rather than TLA+.

## 1. Method and Coverage

The requested Specula `code-analysis` skill was used as the sole methodology. Its four phases, Category A distributed-analysis playbook, archaeology rules, deep-analysis rules, and Modeling Brief format were followed.

### 1.1 Phase 1 — Reconnaissance and classification

| Item | Result |
|---|---|
| Repository | `/users/Pial/targets/sonic-dash-ha` |
| Snapshot | `f53422a`, `master`; branch-only revert `4a5b8ed` is not an ancestor of this snapshot |
| Rust scale | 79 files, 25,482 lines |
| HAMgrD scale | 13,165 Rust lines including tests; approximately 7.1 KLOC production core |
| Category | A — distributed/message-passing; non-BFT |
| Core participants | DPU actor, vDPU actor, HA-set actor, DPU- or NPU-driven HA-scope actor, peer NPU scope |
| Transport/state | SWBus, Redis tables, ZMQ/Redis producer and consumer bridges |
| Concurrency | One callback at a time per actor; independent Tokio tasks for actors, bridges, timers, routing, and DB writes |

Files read completely or in full production/test sections included:

- `crates/hamgrd/src/main.rs`, `actors.rs`, `db_structs.rs`, and `ha_actor_messages.rs`;
- `actors/{dpu,vdpu,ha_set}.rs` and `actors/ha_scope/{mod,base,dpu,npu}.rs`;
- `crates/swbus-actor/src/{driver,runtime,actor_message,state}.rs` and all state-table modules;
- `crates/swss-common-bridge/src/{consumer,producer,lib}.rs`;
- the relevant SWBus edge/core routing, connection, and simple-client code; and
- the complete HAMgrD test corpus and directly relevant runtime/bridge tests.

### 1.2 Phase 2 — Bug archaeology

- Git history: all 165 commits reachable from all refs were title/path/keyword screened; 103 HA actor/runtime/bridge commits were inspected in the broad pass, and 44 substantive correctness changes were diff-reviewed in depth.
- GitHub issues: the repository has only 23 issues, below the skill's 30+ target, so all 23 bodies and every comment were read in three batches (100% coverage).
- Pull requests: 188 PRs were inventoried. The only open PR was [#182](https://github.com/sonic-net/sonic-dash-ha/pull/182), a CI trigger change; its body and two bot comments contain no runtime intent and it was excluded.
- For the significant correctness PRs, the body, conversation, reviews, inline review threads, linked issue discussion, commit body, and diff were inspected. Automated release backports were treated as duplicates, not independent evidence.
- `gh` and `jq` were unavailable. GitHub REST was used until its anonymous rate limit was exhausted, then public HTML/embedded discussion data was used. This changes tooling, not corpus coverage.

### 1.3 Phase 3 — Deep analysis

Five independent deep passes covered the runtime/transport, NPU protocol, HA-set/route logic, DPU/vDPU/base lifecycle, and full test corpus. The main analysis independently retraced high-priority sequences against current code and reconciled conflicting interpretations.

Findings were classified as:

- **Model-checkable** when concurrency, message scheduling, failure injection, or crash cuts determine the result;
- **Test-verifiable** when a deterministic implementation path proves the defect; or
- **Code-review-only** when deployment topology, API contract, or intended ownership must be confirmed.

Closed historical defects are scenario evidence and reference pointers, never §6.1 modeling targets. The one explicit issue false positive, #75, is retained as negative evidence.

### 1.4 Phase 4 — Synthesis criteria

The brief includes only mechanisms with an observable safety/liveness outcome and useful state-space exploration. Deterministic parsing, key selection, arithmetic, and task-ownership bugs are deliberately kept in the test/review lists. Forward-looking questions, rather than recreations of already-fixed PRs, populate the model-checkable section.

## 2. Architecture and Atomicity Map

### 2.1 Actor and state-propagation graph

The startup path initializes SWBus, a process-wide ActorRuntime, shared producer bridges, four ActorCreators, and table ConsumerBridges (`crates/hamgrd/src/main.rs:49-108,149-192`). The logical graph is:

```text
CONFIG/STATE tables -> ConsumerBridge -> ActorCreator / exact actor route
                                       DPU -> vDPU -> HA-set -> HA-scope
                                                        ^          |
                                                        | state    | peer protocol
                                                        +----------+<----> remote NPU scope

actor callback -> Redis Internal commit -> Outgoing queue -> SWBus/ProducerBridge
                                                       -> Redis/ZMQ table -> DPU/ASIC ACK
HA-scope logical state ---------------------------------> HA-set route selection
```

Registrations are ActorMessages retained only in the recipient's `Incoming` map. DPU broadcasts to registered vDPUs; vDPUs to registered HA sets/scopes; HA sets to registered scopes (`crates/hamgrd/src/ha_actor_messages.rs:267-279`). NPU scopes also exchange votes, state, heartbeat, shutdown, switchover, bulk-sync, and standalone-control messages.

### 2.2 Actual completion boundaries

| Boundary | Current semantics | Evidence | Consequence |
|---|---|---|---|
| Receive | Insert/merge into `Incoming` | `swbus-actor/src/driver.rs:100-113` | Logical key may already contain new data before business logic |
| Transport ACK | Sent immediately after Incoming accepts | `driver.rs:114-128` | Sender stops retrying even if callback later fails/crashes |
| Actor apply | Callback mutates struct, stages Internal/Outgoing | `driver.rs:146-164` | Struct mutations are outside rollback |
| Durable commit | Internal changes committed first | `driver.rs:147-153` | Crash afterward preserves phase but loses volatile outgoing intent |
| Outgoing send | Queued messages handed to independent router/tasks | `state/outgoing.rs:34-105` | Send is not recipient application |
| DB apply | Producer task applies then sends its transport response | `swss-common-bridge/src/producer.rs:28-70` | Actor logic cannot await this response |
| ASIC apply | Later DPU state carries role/term acknowledgement | `hamgrd/src/actors/ha_scope/npu.rs:590-632` | Logical CP state can lead hardware state |
| Route apply | HA-set writes from cached logical state | `actors/ha_set.rs:512-526,603-647,961-994` | Route may select a role that is not ASIC-acknowledged |

No transaction spans any two of these external stages. The reference model must not collapse them.

## 3. Trusted Reference Comparison

The trusted reference is the SONiC [SmartSwitch HA HLD](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md), supported by the [detailed table design](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-detailed-design.md), [HAMgrD actor design](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hamgrd.md), and [DPU-driven setup](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-dpu-scope-dpu-driven-setup.md).

| Reference requirement | Implementation/archaeology result | Disposition |
|---|---|---|
| Only one decision maker during transition (HLD §7.1) | Route eligibility uses logical state and drops ASIC ACK/term; initialization has a CP-only transition; old-peer messages are accepted | Core safety invariant for model |
| Term represents flow-history precedence (HLD §7.3) | Old state can regress term; ASIC ACK is not term-correlated; vote-request state is ignored | Model generation/term and code-review vote contract |
| Persist HA state and retry every idempotent transition action after crash (HLD §7.4) | Several phase-specific messages are not reconstructed; first-down edge and DPU pending-operation identity can be lost/duplicated | High-priority crash scenario |
| Standby shutdown waits until active owns all traffic (HLD §8.3.1) | Historical PR #203 corrected the order; current role ACK is still unbound to term/peer epoch | Fixed history plus current gate model |
| HA-set object exists before dependent HA-scope object (detailed design §2.3.1) | #205 prevents a cached-registration path but only orders enqueue; separate producer tasks can apply scope first | High-priority dependency model |
| State tables identify one HA scope and carry logical/ASIC/term fields | Scope bridges subscribe to all rows without key validation; DPU schema/test expect `ha_role` for ACK while #107 intentionally uses `ha_state` | Isolation test plus field-contract review |
| Leak detection/heartbeat state is refreshed | `last_heartbeat_time_in_ms` is reset to zero and no periodic connected heartbeat updates it | Review/test; external BFD partially compensates |

The model should preserve reference semantics as invariants while explicitly adding the implementation's staging, retry, actor, and epoch mechanisms.

## 4. Complete Issue Audit

All issue bodies and comments were read. “Uncertain” means the discussion lacks enough evidence to assert a current defect; it does not mean the report assumes correctness.

| Issue | State | Classification and discussion result | Current disposition |
|---|---|---|---|
| [#179](https://github.com/sonic-net/sonic-dash-ha/issues/179) Launch from no peer does not install VNET route | Closed | Substantiated core route defect; no substantive discussion | Fixed by #180; stale-priority follow-up #211 |
| [#172](https://github.com/sonic-net/sonic-dash-ha/issues/172) wait for state-transition ACK | Closed | Duplicate report | Duplicate of open #171 |
| [#171](https://github.com/sonic-net/sonic-dash-ha/issues/171) wait for state-transition ACK | Open | Substantiated core safety gap | #193/#199/#201/#203 partially gate transitions; current initialization/route/term gaps remain |
| [#166](https://github.com/sonic-net/sonic-dash-ha/issues/166) supporting NPU-driven HA | Open | Umbrella feature tracker, not one defect | Reference/context only |
| [#139](https://github.com/sonic-net/sonic-dash-ha/issues/139) global-config update reaches only one HA set | Open | Substantiated core propagation defect | Current duplicate service-path teardown confirmed; no fanout fix |
| [#124](https://github.com/sonic-net/sonic-dash-ha/issues/124) DPU-scope relaunch after planned shutdown | Closed | Sparse reproduction, manually closed, no linked fix sufficient to prove disposition | Uncertain; retain as DPU-mode test context |
| [#123](https://github.com/sonic-net/sonic-dash-ha/issues/123) stale DPU state after restart | Closed | Sparse operational report, manually closed | Uncertain; current deletion/staleness findings are independently evidenced |
| [#119](https://github.com/sonic-net/sonic-dash-ha/issues/119) route advertisement change detection | Closed | Substantiated SWBus routing defect, outside HA FSM | Fixed by route-announcement work (#130) |
| [#118](https://github.com/sonic-net/sonic-dash-ha/issues/118) route CLI broken | Closed | Substantiated diagnostics defect | Fixed by #122; not model-relevant |
| [#111](https://github.com/sonic-net/sonic-dash-ha/issues/111) ActorRuntime not shut down | Closed | Substantiated actor-lifecycle defect | Fixed exact-route unregister in #115; deletion/re-add residual differs |
| [#100](https://github.com/sonic-net/sonic-dash-ha/issues/100) config DELETE unhandled | Closed | Substantiated lifecycle/cleanup defect | Fixed broadly by #102 and route recreation by #115; later resources introduced new gaps |
| [#99](https://github.com/sonic-net/sonic-dash-ha/issues/99) scope before set | Open | Substantiated dependency-order defect | #205 partial; explicitly lacks end-to-end DPU APPL_DB confirmation |
| [#91](https://github.com/sonic-net/sonic-dash-ha/issues/91) use `ha_state` | Closed | Substantiated wrong-field defect | Fixed by #107 |
| [#88](https://github.com/sonic-net/sonic-dash-ha/issues/88) read VNET name | Closed | Substantiated config/state-propagation gap | Fixed by #92 |
| [#87](https://github.com/sonic-net/sonic-dash-ha/issues/87) pinned vDPU BFD state missing | Closed | Substantiated health-state gap | Implemented by #134 |
| [#79](https://github.com/sonic-net/sonic-dash-ha/issues/79) outgoing diagnostics key | Open | Substantiated diagnostics/schema limitation only | No protocol effect; exclude from model |
| [#78](https://github.com/sonic-net/sonic-dash-ha/issues/78) remove `fvs` in actor output | Closed | Substantiated diagnostics cleanup | Fixed by #85 |
| [#77](https://github.com/sonic-net/sonic-dash-ha/issues/77) exchange HA state/term | Open | Substantiated core gap | NPU-driven exchange added by #145; DPU-driven peer fields/term remain absent |
| [#76](https://github.com/sonic-net/sonic-dash-ha/issues/76) actor heartbeat timer | Open | Substantiated gap | Schema/TODO exists; no periodic connected heartbeat or timestamp update |
| [#75](https://github.com/sonic-net/sonic-dash-ha/issues/75) ZMQ producer reconnect | Closed | **False positive** | #84 test demonstrated configured ZMQ queue/reconnect behavior; do not model |
| [#54](https://github.com/sonic-net/sonic-dash-ha/issues/54) set MSRV | Open | Build-policy request | Out of correctness scope |
| [#25](https://github.com/sonic-net/sonic-dash-ha/issues/25) DashMap to RwLock | Open | Performance/design request | No correctness evidence; out of scope |
| [#10](https://github.com/sonic-net/sonic-dash-ha/issues/10) C API exceptions | Closed | Substantiated support-layer error-propagation problem | Fixed in early swss-common exception work; not HA model evidence |

Issue result totals: 12 substantiated core defect/gap reports, four substantiated non-core reports, two uncertain sparse reports, one duplicate, one umbrella tracker, one explicit false positive, and two build/performance requests.

## 5. Commit and PR Discussion Audit

The following 44 commits were the substantive correctness candidates. “Residual” records what remains at the analyzed snapshot, not a criticism of the narrower merged fix.

| Commit / PR | Root cause or intent | Review/disposition and residual |
|---|---|---|
| `f53422a` [#211](https://github.com/sonic-net/sonic-dash-ha/pull/211) | Stale peer Active outranked local Standalone in route selection | Merged with focused test; no substantive discussion. Same-source stale replay remains possible |
| `68f8cce` [#210](https://github.com/sonic-net/sonic-dash-ha/pull/210) | Producer dedup suppressed replay after external DPU state loss | Merged; consumer dedup remains and replay still depends on a new notification; no end-to-end apply ACK |
| `1ec418c` [#209](https://github.com/sonic-net/sonic-dash-ha/pull/209) | Half-open peer connection kept a stale next hop | Merged connection replacement; physical repeated reboot not rerun. Review/linked issue still require actor vote retry after silence |
| `1aa2ea8` [#205](https://github.com/sonic-net/sonic-dash-ha/pull/205) | Cached registration bypassed HA-set-before-scope ordering | Merged issue-time gate; review-requested focused test absent; PR explicitly concedes “issued,” not “applied” |
| `b5bab5c` [#206](https://github.com/sonic-net/sonic-dash-ha/pull/206) | DPU HA state DEL decoded as a full update | Merged DEL ignore; no substantive discussion. Stale cached state is retained by design |
| `8243bbc` [#203](https://github.com/sonic-net/sonic-dash-ha/pull/203) | Standby could enter Dead before active ACKed Standalone | Merged correct shutdown order; ACK has no term/epoch binding |
| `6c756ec` [#201](https://github.com/sonic-net/sonic-dash-ha/pull/201) | Restore CP-state conjunction to ASIC gates | Merged, verification blank/no substantive review; independent InitActive `next_state` path remains CP-only |
| `94f5e22` [#199](https://github.com/sonic-net/sonic-dash-ha/pull/199) | DPU ACK changes were not broadcast | Merged unconditional broadcast; review explicitly raised ACK term, which is still not propagated |
| `3a89149` [#193](https://github.com/sonic-net/sonic-dash-ha/pull/193) | Logical peer state could lead ASIC-committed role | Merged strict ACK-role gates; unresolved reviews note rolling-version fields can stall and dead is a valid role; no ACK term |
| `5df5d64` [#178](https://github.com/sonic-net/sonic-dash-ha/pull/178) | Model HA-set liveness as unknown/up/down and edge-trigger peer loss | Supersedes #174 reset. Current `None` handling fixed review concern; positive up still required to connect |
| `7391a7b` [#185](https://github.com/sonic-net/sonic-dash-ha/pull/185) | Failure decisions needed transitions in all nonterminal states | Review prevented revival of terminal states; stale/wrong-peer events still pass identity checks |
| `a8fbdf7` [#177](https://github.com/sonic-net/sonic-dash-ha/pull/177) | Repeated DPU up/down notifications caused repeated failure events | Merged edge triggering; review identified current restart-with-first-down event loss; repeated-down test absent |
| `0ae944c` [#180](https://github.com/sonic-net/sonic-dash-ha/pull/180) | Waiting for both scope reports suppressed no-peer route | Merged one-available-scope selection; unanswered review asked endpoint cardinality; later #211 changed priority |
| `33d17dd` [#175](https://github.com/sonic-net/sonic-dash-ha/pull/175) | Route construction needed combined scope state | Merged; unresolved reviews identify pinned ordering, primary/backup duplication, and untrimmed ID edge cases |
| `0f7a8e3` [#174](https://github.com/sonic-net/sonic-dash-ha/pull/174) | Optimistically reset channel up at Connecting | Later explicitly removed by #178; not current behavior |
| `0e8e827` [#170](https://github.com/sonic-net/sonic-dash-ha/pull/170) | Correct health strings/events including Standby local failure | Later fixes cover key/delete concerns; exact string parsing and missing failure-path coverage remain |
| `34cbd69` [#159](https://github.com/sonic-net/sonic-dash-ha/pull/159) | Persist/rehydrate NPU state after crash | Substantive review fixed some prerequisites/IDs; author acknowledged rare split brain; transitional replay and newer-config clobber residuals remain |
| `ef5da18` [#165](https://github.com/sonic-net/sonic-dash-ha/pull/165) | Gate bulk sync on Active ACK and handle failure | Merged; unresolved compatibility/string/error comments and no BulkSyncFailure test |
| `301af43` [#163](https://github.com/sonic-net/sonic-dash-ha/pull/163) | Maintenance loop did not return after queue became empty | Merged; review requested but did not receive dedicated regression test |
| `838a059` [#162](https://github.com/sonic-net/sonic-dash-ha/pull/162) | Wrong default and Active/bulk-sync ordering | Merged enqueue-order improvement; review correctly noted enqueue is not ASIC activation; #165 added ACK path |
| `d35cee1` [#161](https://github.com/sonic-net/sonic-dash-ha/pull/161) | One-hour unacked lifetime blocked deletion | Merged 15-second retry/60-second drop after review caught retry=drop timing; bounds but does not remove stale replay |
| `57bab90` [#160](https://github.com/sonic-net/sonic-dash-ha/pull/160) | Forced/planned shutdown transition gaps | Review added missing Standby branch; desired Dead outside Standby and restart intent remain weak |
| `25ceb3e` [#158](https://github.com/sonic-net/sonic-dash-ha/pull/158) | Invalid error conversion panicked and killed ActorCreator in production | Merged panic containment; task lifecycle/route ownership remain unsupervised |
| `36e3ff5` [#157](https://github.com/sonic-net/sonic-dash-ha/pull/157) | Support new DPU pairing in flight | Merged happy path; no epoch, source validation, cache purge, or old-message test |
| `5eba3c8` [#156](https://github.com/sonic-net/sonic-dash-ha/pull/156) | Add unplanned peer/local/inline-drop failure events | Foundation for current failover; ENI-map DEL leaves stale counter history and raw delta arithmetic can panic/wrap |
| `a50f1dd` [#155](https://github.com/sonic-net/sonic-dash-ha/pull/155) | Standalone launch had no path back to Active | Merged transition, but accepts only `PeerStateChanged`, not a fresh peer's first `PeerConnected`, and ignores Standalone pin |
| `90c10b6` [#149](https://github.com/sonic-net/sonic-dash-ha/pull/149) | IPv4 endianness mismatch | Merged deterministic encoding fix; test/reference only |
| `f531a66` [#147](https://github.com/sonic-net/sonic-dash-ha/pull/147) | Neighbor key lacked interface name | Merged creation change; cleanup/key migration was not added |
| `8f9893d` [#143](https://github.com/sonic-net/sonic-dash-ha/pull/143) | Limit BFD/route resources to participating HA sets | Merged ownership redesign; review says controller deletion/recreation, not PMON handler, removes/rebuilds BFD |
| `64022eb` [#142](https://github.com/sonic-net/sonic-dash-ha/pull/142) | Decode protobuf from binary DB value | Merged deterministic input fix; exclude from model |
| `2b6b37c` [#137](https://github.com/sonic-net/sonic-dash-ha/pull/137) | Record DPU reset on pmon/control-plane down | Merged; introduced current parse-before-DEL ordering and reset-entry lifecycle |
| `9b3c0bf` [#136](https://github.com/sonic-net/sonic-dash-ha/pull/136) | Rewrite BFD sessions on pmon edges | Merged; shows derived-resource lifecycle importance |
| `c2e8f44` [#121](https://github.com/sonic-net/sonic-dash-ha/pull/121) | First BFD update lost behind SubscriberStateTable snapshot | Merged correct rehydrate behavior; historical message/snapshot ordering evidence |
| `a9021cf` [#117](https://github.com/sonic-net/sonic-dash-ha/pull/117) | Route announcement bounced when direct queue was full | Merged SWBus routing correction; transport context, not direct HA model target |
| `f36ffdd` [#113](https://github.com/sonic-net/sonic-dash-ha/pull/113) | BFD parser rejected quoted/whitespace formats | Merged deterministic parser hardening |
| `0a719f6` [#114](https://github.com/sonic-net/sonic-dash-ha/pull/114) | Missing Incoming entry conflated with decode error | Merged state-access semantic fix |
| `2c589e7` [#115](https://github.com/sonic-net/sonic-dash-ha/pull/115) | Exact handler remained after actor termination | Merged unregister-on-Drop; deleting actor still owns route while draining |
| `8f2c89c` [#110](https://github.com/sonic-net/sonic-dash-ha/pull/110) | VNET route needed ProducerStateTable behavior | Moved route to asynchronous producer, creating an explicit apply boundary |
| `d14d54b` [#102](https://github.com/sonic-net/sonic-dash-ha/pull/102) | Actors did not clean resources on config deletion | Added broad cleanup; resources/features added later and reconfiguration edges remain incomplete |
| `4e3706a` [#107](https://github.com/sonic-net/sonic-dash-ha/pull/107) | Local logical state copied HA role instead of HA state | Fixed #91 and intentionally changed both logical and ACKed fields to `ha_state`; current schema/test oracle disagree, so treat as contract review |
| `e205d4d` [#97](https://github.com/sonic-net/sonic-dash-ha/pull/97) | Unspecified desired role needed DPU Standby translation | Merged mapping; persisted target and programmed role can still differ |
| `01a88ef` [#89](https://github.com/sonic-net/sonic-dash-ha/pull/89) | Suppress unchanged bridge writes | Consumer dedup remains; producer portion was removed by #210 after reset/replay failure |
| `4121247` [#92](https://github.com/sonic-net/sonic-dash-ha/pull/92) | Route used hard-coded VNET | Merged global-config dependency/retry; duplicate bridge fanout currently breaks propagation |
| `c3e8828` [#83](https://github.com/sonic-net/sonic-dash-ha/pull/83) | DPU DB access required container name | Merged deployment-specific DB correction |

Supporting/negative-control commits also inspected:

- `6b5884c` / [#145](https://github.com/sonic-net/sonic-dash-ha/pull/145): introduced NPU-driven infrastructure and peer exchange. Current review residuals include two `Input(NoRoute/non-input-code)` contract panics, temporary resolve-route leakage on send error, collision-prone per-call resolve IDs, and a missing `cp_data_channel_port` panic; feature baseline plus deterministic tests, not a closed bug.
- `17e2e0b` / [#134](https://github.com/sonic-net/sonic-dash-ha/pull/134): implemented pinned BFD state for #87; reference for health-state ownership.
- `cf03fe8` / [#84](https://github.com/sonic-net/sonic-dash-ha/pull/84): ZMQ reconnect test that refuted issue #75.

Automated release-branch backports (#207/#206, #204/#203, #202/#201, #200/#199, #198/#193, and similar “action” PRs) were inspected for ancestry but not double-counted. The all-ref commit `4a5b8ed` reverts #210 only on another branch; current `master` contains #210.

### 5.1 Material PR-review conclusions

- #159's author explicitly acknowledged rare NPU-driven split brain and scoped it outside rehydration; this strengthens the crash/ownership scenario.
- #201 claims CP+ASIC agreement, but its diff/review did not inspect the independent CP-only initialization transition.
- #199 review explicitly raised role **and term** changes, but the peer message still omits the ACKed term.
- #193 and #165 have unresolved rolling-version compatibility comments; absent/new required fields can stall or drop messages.
- #177 review identified the still-current “persisted Active, first observed DPU state already down” failure-edge loss.
- #205 explicitly documents the issued-versus-applied limitation and lacks the requested registration-before-programming regression test.
- #209 fixes physical route replacement, while its linked production issue also asks for outstanding-vote retry after silence; that actor-level recovery is still absent.
- No reviewed discussion introduced a pairing epoch, source/destination validation, message generation, or per-protocol retry budget.

## 6. Current Model-Relevant Findings

### F1. Completion stages are conflated

**Confidence**: Directly confirmed; high severity.

The driver ACKs an accepted incoming entry before callback execution (`crates/swbus-actor/src/driver.rs:100-129`). The sender deletes the retry on `Ok` (`state/outgoing.rs:118-140`). If the callback returns `Err` or the process crashes before apply/commit, no protocol-level negative response or replay remains. Internal staging rolls back, but actor struct-field mutations do not.

HA-set programming compounds this: `update_dash_ha_set_table` queues the set, flips `dash_ha_set_programmed`, and broadcasts to scopes in one callback (`crates/hamgrd/src/actors/ha_set.rs:180-225`). Outgoing only queues to the router; independent producer tasks later apply HA-set and HA-scope writes. PR #205 itself says “programmed” means issued, not applied. A scope write can therefore become visible before its parent.

For role activation, the FSM queues a DPU role, persists/broadcasts logical state, and later observes ASIC state. The HA-set cache discards `acked_asic_ha_state`, timestamp, and term (`ha_set.rs:74-78,512-526`), so it can route before hardware commits the role.

**Compensation**: #193/#201 gate many peer transitions, #199 rebroadcasts DPU ACK changes, #205 blocks one registration path, and #210 permits producer replay. None creates an end-to-end transaction or acknowledgement visible to actor logic.

### F2. `InitializingToActive` bypasses its intended ASIC gate

**Confidence**: Directly confirmed and enshrined by tests; high severity.

Entry side effects enqueue `EnterActive` only if peer CP state is `InitializingToStandby` and peer ASIC ACK is Standby (`crates/hamgrd/src/actors/ha_scope/npu.rs:1374-1383`). But `next_state` advances `InitializingToActive -> PendingActiveActivation` whenever the cached CP state matches, with no event or ACK check (`npu.rs:1685-1690`). Rehydration has the same CP-only check (`npu.rs:1285-1290`). SDN approval then reaches Active without rechecking the missing prerequisite.

Six integration flows send peer initialization state without the ACK and expect progression (`crates/hamgrd/src/actors/ha_scope/mod.rs:764,1170,1831,2236,2446,2924`). PR #201's stated purpose is combined CP/ASIC gating, making this a residual implementation deviation rather than deliberate documented behavior.

Further, local DPU state persists `local_acked_term`, but `HaScopeActorState` propagates only target term plus ACK role (`db_structs.rs:403-425`; `ha_actor_messages.rs:182-193`). No receiver can prove the ACK belongs to the advertised term.

### F3. Old at-least-once messages overwrite newer state

**Confidence**: Direct transport/state trace; safety consequence model-checkable.

Each send has a fixed request ID, and multiple values for one ActorMessage key coexist in the unacked map (`crates/swbus-actor/src/state/outgoing.rs:37-59,103-105`). Losing the response for old M1, accepting newer M2, and retrying M1 after 15 seconds is legal. Maintenance iterates a `HashMap`, and Incoming overwrites by logical key without request-ID deduplication or version comparison (`outgoing.rs:143-180`; `state/incoming.rs:49-72,147-154`).

NPU handling blindly overwrites peer CP state, timestamp, term, and ACK role; when target is Standby it can also copy a lower peer term into local target term (`crates/hamgrd/src/actors/ha_scope/npu.rs:708-746`). HA-set route cache likewise replaces the source's logical state and discards freshness metadata.

Wall-clock `timestamp` is not a valid sequence number: normal broadcasts use send time, while heartbeat replies reuse a persisted transition time (`npu.rs:345-371,1856-1883`). The model needs an explicit epoch/generation.

**Compensation**: unacked messages expire after 60 seconds; #211 prefers any separately cached Standalone over Active. Neither prevents same-source state regression within that window.

### F4. Re-pairing lacks identity and epoch isolation

**Confidence**: Directly confirmed; high severity.

On HA-set peer change, code replaces `peer_vdpu_id` and `peer_sp` but does not clear `peer_connected`, retry state, cached peer state/time/term/ACK, or old Incoming entries (`crates/hamgrd/src/actors/ha_scope/npu.rs:539-558`). Persisted NPU state contains peer facts but no peer identity/epoch (`db_structs.rs:463-501`); base refresh changes peer IP while cloning those facts (`ha_scope/base.rs:407-440`).

Message dispatch is prefix-only and source is discarded (`npu.rs:73-234`; `base.rs:125-136`). Payload destination/actor ID is not compared. Delayed old-peer traffic can overwrite state/term, complete votes, initiate shutdown, or drive switchover (`npu.rs:708-990`). Replies go to the **current** peer rather than the request source. Old remote HA-set service paths also remain in the broadcast list (`base.rs:286-294`; `npu.rs:1884-1889`).

The re-pair test sends no old-peer traffic and its new-peer state uses the generic fake test source (`ha_scope/mod.rs:2381-2694`; `actors/test.rs:23-45`). #209 replaces stale physical connections but does not establish actor-protocol identity.

There is also a liveness asymmetry: the first state from a genuinely fresh peer returns `PeerConnected` (`npu.rs:740-745`), but Standalone transitions only on `PeerStateChanged` (`npu.rs:1808-1817`). With no periodic connected heartbeat, a single unchanged new-peer state can leave the pair stalled; desired Standalone pin is not checked by that transition.

### F5. Persisted phases do not reconstruct required transition intent

**Confidence**: Direct crash-cut trace; high severity.

ActorDriver durably commits Internal state before sending queued actions (`crates/swbus-actor/src/driver.rs:146-153`). Reachable crash cuts include:

- `PendingActiveActivation -> Active`: loses `BulkSyncCompleted`; rehydrated Active sends heartbeat/DPU role only, while peer initialization advances only on that message (`npu.rs:1301-1305,1429-1433,1791-1794`).
- switchover SYN handling: persists `SwitchingToStandby` after queuing FIN; rehydration emits no FIN (`npu.rs:925-990,1340-1344`). The initiator retries on RST, not silence.
- ordinary failure into `SwitchingToStandalone`: loses self `EnterStandalone` or peer DPU request; rehydration replays only when config explicitly desires Standalone (`npu.rs:1316-1328,1395-1427`).
- stable Standby with desired Dead: a pre-crash ShutdownRequest is not reissued.
- forced disable: logical Dead may persist before DPU Dead is emitted; disabled+already-Dead restart need not repair an ASIC left Active (`npu.rs:455-480,1517-1527`).
- first post-restart vDPU observation already down: edge-trigger logic records `false` during rehydration and may never emit `LocalFailure` (PR #177 discussion/current handler).

DPU-driven rehydration has the converse identity problem: persisted pending operations survive, but volatile `dpu_ha_scope_state` resets; a still-true flag appears as a fresh rising edge and creates another UUID (`ha_scope/dpu.rs:158-173`; `base.rs:461-473`).

Only stable-Active rehydration is tested (`ha_scope/mod.rs:2710-2855`). HLD §7.4 explicitly requires retry of all idempotent actions.

### F6. Actor and configuration epochs can diverge

**Confidence**: Directly confirmed timing/lifecycle trace; high severity.

After DEL calls `Context::stop`, an exact actor route remains until cleanup unacked messages drain or expire. A SET during that window is routed to the dying actor, ACKed `Ok`, and deliberately ignored (`crates/swbus-actor/src/driver.rs:57-97`). Exact routing means ActorCreator never sees it; ConsumerBridge has already cached the SET and never retries (`swss-common-bridge/src/consumer.rs:75-80,119-121`). The old actor later exits, leaving the config row but no actor indefinitely.

Selective parent recreation also loses registrations because they live only in the parent's Incoming state:

- vDPU registers to DPU only on its config SET (`actors/vdpu.rs:68-82`);
- HA-set registers to vDPUs only on HA-set config (`actors/ha_set.rs:396-411,808-810`);
- scope registers to vDPU/HA-set only on first scope config (`actors/ha_scope/base.rs:55-69`).

Conversely, parent cleanup sends no tombstone/invalidation. A surviving scope retains old `HaSetActorState`; NPU and DPU gates check only its presence, so it can reprogram a scope against a deleted HA set (`ha_set.rs:1005-1026`; `ha_scope/npu.rs:1503-1511`; `ha_scope/dpu.rs:196-203`). Full-process rehydration may recreate all actors in a favorable order, but isolated actor recreation has no renewal protocol.

### F7. Config refresh can overwrite the failover-selected route

**Confidence**: Directly confirmed current code; high severity.

In Switch-owned mode, a non-preferred vDPU B can become the sole Active/Standalone scope and `handle_ha_scope_state_update` correctly routes to B (`crates/hamgrd/src/actors/ha_set.rs:961-994`). Any later HA-set config update, including a pinned-BFD-only change, unconditionally calls `get_vdpus_if_ready` and writes the route from preferred config order (`ha_set.rs:427-465,851-858`). That can restore preferred A while B still serves traffic. Global and vDPU handlers correctly guard config-based writes with `ha_owner == Dpu` (`ha_set.rs:863-889`); the HA-set config path does not.

The emitted HaSet state normally maps to `HaEvent::None` in already-initialized NPU scopes (`actors/ha_scope/npu.rs:567-585`), so no corrective scope broadcast is guaranteed. Tests cover in-order role changes and #211's separately cached stale Active, not a Switch-owned HA-set refresh after non-preferred failover.

### F8. Shared retry state couples independent protocols

**Confidence**: Direct shared-state trace; liveness consequence pending model/test.

One `retry_count` is used by connection checking, inbound vote/tie retries, and switchover RST handling (`crates/hamgrd/src/actors/ha_scope/npu.rs:27-54,818-881,925-955,1947-1978`). Under asymmetric delivery, a remote can begin voting while local remains Connecting; inbound vote requests increment the shared count, and the scheduled connection check can then declare `PeerLost` early. Connection or vote success can also reset/extend another workflow's budget, and re-pair does not reset it.

No historical review discussed protocol-local counters. This is a clean small-state liveness target.

### F9. DPU pending-operation edge can be consumed before prerequisites

**Confidence**: Direct ordering trace; model/test candidate.

On first config the DPU-driven scope registers with vDPU and HA-set independently (`crates/hamgrd/src/actors/ha_scope/base.rs:55-69`). If vDPU responds first, the DPU-state bridge starts. A pending flag snapshot can then:

1. detect a false-to-true edge and allocate a UUID (`ha_scope/dpu.rs:158-173`);
2. cache the DPU state;
3. fail to persist base/pending fields because HA-set state is absent (`dpu.rs:270-279`; `base.rs:381-405,457-460`); and
4. never be reconsidered when HA-set state later arrives, because the flag is now cached true.

The test suite enforces vDPU -> HA-set -> DPU state ordering (`ha_scope/mod.rs:310-339`). The property to check is eventual exactly-once representation of each pending-flag epoch.

## 7. Direct Test-Verifiable Findings

### T1. Duplicate bridge route teardown and no fanout (#139)

Every ConsumerBridge for one table uses the same source service path (`crates/hamgrd/src/actors.rs:321-340`; `main.rs:254-261`). `RouteMap::insert` silently replaces the prior sender (`crates/swbus-edge/src/message_router/route_map.rs:10-13`). The old bridge receiver closes, its loop exits, and its client's unconditional Drop removes the replacement route; the replacement receiver then closes and exits (`simple_client.rs:56-67,252-255`; `swss-common-bridge/src/consumer.rs:119-127`). Initial rehydration can race ahead before teardown, but stable fanout does not exist. This is stronger than last-writer-wins and directly confirms open #139.

An actor driver reacts differently to receiver closure: `recv() == None` loops with `continue`, producing a leaked hot task (`swbus-actor/src/driver.rs:48-54`).

### T2. Every HA scope accepts every DPU scope-state row

Both HA-scope variants create an unfiltered full-table `DpuDashHaScopeState` bridge with a fixed destination (`crates/hamgrd/src/actors/ha_scope/dpu.rs:113-123`; `npu.rs:406-417`). The base getter never checks `kfv.key == self.ha_scope_id` (`base.rs:153-174`). Scope S2 can therefore ingest S1's CP state, ASIC role/term, and pending flags.

HA-set has an analogous unfiltered subscription but explicitly rejects mismatched keys and has a regression test (`actors/ha_set.rs:941-952,2243-2337`); cross-set contamination is refuted. Scope tests use one actor and the table name rather than real scope ID as their fake KFV key, hiding the bug (`ha_scope/mod.rs:339,375,451,611,1076,3274`).

### T3. Normal local-DPU DEL fails before cleanup

`DpuActor::handle_dpu_message` decodes required `Dpu` fields before checking `KeyOperation::Del` (`crates/hamgrd/src/actors/dpu.rs:142-151`; schema `db_structs.rs:47-58`). Normal deletes have empty fields, so callback errors; the already-sent transport ACK prevents retry. The test masks this by attaching the original full `dpu_fvs` to DEL (`dpu.rs:609-611`).

### T4. Derived-resource cleanup/reconfiguration is incomplete

- DPU creates `NEIGH_RESOLVE_TABLE` only with SET; deletion removes only reset info. VLAN/PA changes and global-config DEL can leave old or malformed neighbor keys (`actors/dpu.rs:137-140,385-424,469-475`).
- HA-set managed -> all-remote reconfiguration overwrites config before deciding it no longer owns resources, then skips set/route/BFD cleanup (`actors/ha_set.rs:112-115,229-233,261-264,362-365,721-739,790-806`).
- Deleting after A/B -> A/C with missing C returns before every cleanup action but still stops the actor (`ha_set.rs:782,1005-1026`).
- Inactive scope registration is ignored, so deleted scope state can remain route primary (`ha_scope/base.rs:361-366`; `ha_set.rs:893-909`).
- VIP/VNET key changes write a new route and cleanup only the current key (`ha_set.rs:251-286,362-382`).
- vDPU and scope config replacement registers new parents but does not unregister removed DPU/HA-set parents; owner variant is chosen only on first scope config.

These are deterministic state-reconciliation tests. Abstract resource ownership/config epochs belong in the model; concrete keys do not.

### T5. Inline sync counter arithmetic underflows

`new - old` and then `tx_diff - rx_diff` use raw `u64` arithmetic (`crates/hamgrd/src/actors/ha_scope/npu.rs:1171-1174`). Counter reset/wrap or RX growth greater than TX growth panics with overflow checks or wraps to a huge value, can emit `HighInlineSyncDrops`, and can force Active into `SwitchingToStandalone` (`npu.rs:1721-1724`). Existing coverage is monotone positive-only.

### T6. DPU-driven ACK field has contradictory contracts

`DpuDashHaScopeState.ha_role` is documented as the ASIC-confirmed role and `ha_state` as logical lifecycle state (`crates/hamgrd/src/db_structs.rs:403-415`). The current test oracle copies `ha_role`, but production copies `ha_state` into `local_acked_asic_ha_state` (`actors/test.rs:716-759`; `actors/ha_scope/dpu.rs:289-306`). Archaeology is important negative evidence: PR #107 intentionally changed both logical and ACKed fields to `ha_state`, so the assignment is not an accidental typo. Fixtures set both fields equal and cannot establish which contract is deployed. Use a differing-field integration test and owner confirmation; do not assert a fix direction from static code alone.

### T7. DPU-state deletion and heartbeat retain stale facts

Scope-state DEL is intentionally ignored, leaving the last cached ACK/state/term (`ha_scope/base.rs:153-174`; `ha_scope/dpu.rs:149-155`). `last_heartbeat_time_in_ms` is documented for leak detection but every base refresh writes zero; heartbeat receive does not persist it and periodic checks stop after connection (`db_structs.rs:463-470`; `base.rs:407-412`; `ha_scope/npu.rs:345-374,1944-1995`). BFD/HA-set health is partial compensation, not implementation of this contract.

### T8. DPU-driven peer state/term exchange remains absent

DPU mode dispatches config, local vDPU, local HA-set, and local DPU state only (`actors/ha_scope/dpu.rs:20-36`). It never fills `peer_vdpu_id`/`peer_sp`, exchanges `HaScopeActorState`, or updates peer state/term/ACK fields exposed by the schema. This confirms the DPU-driven residual of open #77. Whether the DPU owns all peer coordination is a design question; test/review it rather than placing the full DPU algorithm in the NPU model.

### T9. Remaining SWBus error-class and resolve-lifecycle panics

PR #158 fixed one production `Input(NoRoute)` panic, but the same contract family remains in current support code. `SwbusMultiplexer::resolve_peer_sp` constructs `SwbusError::input(NoRoute)` even though `NoRoute` belongs to the route-error range (`crates/swbus-core/src/mux/multiplexer.rs:676-688`; precondition `crates/swbus-proto/src/result.rs:21-35`). Edge resolution likewise maps any non-OK response code through `SwbusError::input`, so a legitimate route error can panic (`crates/swbus-edge/src/edge_runtime.rs:185-198`).

The edge resolver registers a temporary route before `send()` but removes it only after send succeeds (`edge_runtime.rs:136-169`); send failure leaks the handler. Each call creates a fresh time-seeded ID generator for both route and message IDs, so concurrent calls need a collision test. NPU bulk-sync construction also `expect`s `cp_data_channel_port` (`crates/hamgrd/src/actors/ha_scope/npu.rs:2125-2143`). These are deterministic robustness tests, not formal HA scenarios.

## 8. Findings Requiring Contract or Topology Review

### R1. Unmanaged scope cleanup may delete the managed row

Base cleanup always deletes DPU `DASH_HA_SCOPE_TABLE[ha_scope_id]`, dropping the vDPU prefix (`crates/hamgrd/src/actors/ha_scope/base.rs:37-42,338-368`). An unmanaged dormant actor also executes this cleanup. If both paired scope config rows exist in one NPU APPL_DB and share `ha_scope_id`, deleting the remote actor deletes the managed actor's live local-DPU row. Repository fixtures do not establish that deployment precondition, so this remains conditional pending topology confirmation.

### R2. ACK and error contracts are underspecified

Transport `Ok` currently means Incoming cache acceptance, not successful actor business handling. Many actor handlers log an error and return success; HA-set config decoding unwraps. Before altering behavior, owners must decide whether senders require application ACK, durable acceptance, idempotent retry, or dead-letter/supervision semantics.

### R3. Protocol fields/events appear incomplete

- VoteRequest carries state but election handling ignores it, while HLD §7.3 compares current state.
- `FlowReconciliationApproved` is produced but has no NPU transition consumer.
- desired Dead outside Standby is often logged/ignored, with no durable shutdown intent.
- `ha_term="0"` is hardcoded in DPU-driven programming even after a nonzero DPU ACK term is persisted.
- owner/HA-set-ID changes after first config do not migrate implementation variant and registrations.

Each needs intended-contract confirmation before a formal invariant is asserted.

### R4. Rolling-version compatibility

PR #193 reviews warn that older peers omit optional ACK role and will stall strict gates; PR #165 added required fields without defaults. Message versions exist in state but are not used for negotiation. Add mixed-version pair tests and document compatibility before modeling upgrades.

### R5. Cleanup availability tradeoff

Unacknowledged outgoing cleanup is retried every 15 seconds and discarded after 60 seconds (`crates/swbus-actor/src/state/outgoing.rs:143-180,201-204`). This guarantees actor deletion can finish but can leave external state/registrations if recipients remain unavailable. Cleanup calls are immediate—an earlier suspicion that delayed cleanup messages were ignored is refuted—but the drop policy still needs an explicit ownership/reconciliation contract.

## 9. Test-Corpus Assessment

The review covered 13 HA-scope integration tests, 10 HA-set tests, DPU/vDPU/ActorCreator/main tests, 14 DB serialization tests, and shared bridge/runtime tests.

### 9.1 What is covered

- DPU-owned activation, pending approvals, brainsplit approval, and normal cleanup.
- NPU launch to Active/Standby, planned/forced shutdown, local/peer failure, inline drops, switchover, happy-path re-pair, stable-Active rehydration, and same-actor relaunch.
- HA-set creation, vDPU replacement, global update, remote-only operation, ordinary route selection, and mismatched HA-set-state filtering.
- ActorCreator panic survival, producer identical replay, ZMQ reconnect behavior, and stale physical SWBus connection replacement.

### 9.2 Harness assumptions that suppress faults

`run_commands` executes one command at a time; each Send waits for transport ACK and each Recv is immediately ACKed (`crates/hamgrd/src/actors/test.rs:159-280`). Default message source is a fabricated test service path (`test.rs:23-45`). Most runtimes contain one actor of the tested type.

Consequently the suite cannot naturally exercise:

- concurrent or out-of-order delivery, duplicate/resend after ACK loss, or mixed old/new peer traffic;
- crash between receive ACK, actor callback, Internal commit, and outgoing send;
- rapid delete/re-add while cleanup drains or isolated parent recreation;
- multiple scope actors sharing one DPU state table;
- separate producer-apply and ASIC-ack schedules; or
- cross-protocol retry-counter interference.

### 9.3 Priority regression tests

1. Two simultaneous HA scopes plus real DPU state keys; assert scope isolation.
2. Two HA sets/global-config subscribers; assert both tasks and routes remain live.
3. Empty-field DPU DEL followed by immediate same-key SET while cleanup ACK is withheld.
4. InitActive with missing/wrong-term ACK; assert no pending/active transition or route.
5. Old M1 ACK loss, newer M2 delivery, M1 retry; assert generation/term/route do not regress.
6. Re-pair while old vote/state/shutdown/switchover messages remain queued.
7. Crash every action-bearing transitional state immediately after durable commit.
8. DPU pending flag before HA-set prerequisite and restart with the flag still true.
9. Switch-owned failover to non-preferred B followed by a non-role HA-set config refresh.
10. Counter reset/wrap and RX delta greater than TX delta.
11. Managed-to-remote/missing-member cleanup plus VLAN/PA/VIP/VNET key changes.
12. Mixed-version peers for ACK role and bulk-sync message evolution.

## 10. Dynamic Validation and Environment Limitations

Static verification was completed against a clean snapshot. Dynamic commands were attempted in proportion to risk:

| Command | Result |
|---|---|
| `cargo test -p swbus-actor -p swbus-edge -p swss-common-bridge -p hamgrd --no-run` | Failed in `swss-common` build script: `libswsscommon-dev` is not installed and `SWSS_COMMON_REPO` does not point to a built checkout |
| `cargo test -p swbus-edge` / `--lib` | Same transitive `swss-common` prerequisite failure |
| Targeted HAMgrD/HA-set test attempt | Also blocked by uninitialized `crates/sonic-dash-api-proto/sonic-dash-api`; `protoc` cannot find `ha_set_config.proto` |
| `cargo fmt --all -- --check` | Toolchain reported the rustfmt component unavailable |
| `git diff --check` | Passed |

`git submodule status` shows the DASH API submodule with a leading `-`, confirming it is uninitialized. No dependency installation, submodule initialization, source modification, or destructive action was performed.

## 11. False Positives, Refutations, and Explicit Exclusions

- **Issue #75 is false**: #84 demonstrates ZMQ's configured reconnect/queue behavior. It is not a retry scenario.
- **Cross-HA-set state contamination is refuted**: the subscription is broad, but the HA-set handler checks payload key. The HA-scope path lacks that check and remains defective.
- **Delayed cleanup loss is refuted**: no cleanup caller uses `send_with_delay`; pre-existing delayed self timers can be canceled on deletion, but cleanup itself is immediate.
- **`EnterActive` is not simply dead code**: it acts as a wake-up causing cached state to be reevaluated; the problem is the independent CP-only transition, not absence of an event arm.
- **Wall-clock timestamp monotonicity is invalid as a proposed repair**: heartbeat replies legitimately reuse older persisted transition time. Use a generation/epoch.
- **The #210 revert is not current**: `4a5b8ed` is on another ref and is not an ancestor of analyzed `master`.
- **Malicious source spoofing is excluded**: response/source authentication gaps exist, but this non-BFT model covers legitimate stale/wrong-epoch messages only.
- **Schema, protobuf, endian, CLI, MSRV, diagnostics, and performance work are excluded from TLA+**: retain them only as archaeology context.
- **Concrete DB keys/resource deletion are not formal targets**: model abstract ownership/config epochs; verify key-specific bugs in integration tests.
- **Issues #123/#124 are not asserted as current defects** because their sparse discussions do not establish a root cause or fix; independent current findings are cited separately.

## 12. Handoff to Spec Generation

The companion `modeling-brief.md` contains seven scenarios, eight proposed model extensions, twelve invariants, and verification findings split into model-checkable, test-verifiable, and review-only categories. The recommended initial state space is two participants, one HA set, one scope, bounded messages/retries, and one crash; only then add configuration epochs/re-pair and DPU pending edges.

Suggested construction order:

1. encode the reference role pair, term/election, approvals, planned shutdown, and stable failover invariants;
2. split logical/DB/ASIC/route stages;
3. replace FIFO delivery with bounded at-least-once message bags and generations;
4. add pairing epochs and wrong-epoch delivery;
5. add durable phase/intent plus crash recovery;
6. add actor/config/registration epochs and competing route writers; and
7. compare shared versus protocol-local retry counters.

This order makes each new counterexample attributable to one implementation extension and keeps already-fixed historical bugs as context rather than targets.
