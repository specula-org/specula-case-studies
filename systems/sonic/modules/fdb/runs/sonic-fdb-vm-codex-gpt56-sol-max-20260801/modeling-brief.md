# Modeling Brief: SONiC FDB

## 1. System Overview

- **System**: `sonic-swss` FDB subsystem, C++, revision `4f3dda156e52ed7647b1dbf900d54d87efaea455`.
- **Scale**: 24,478 lines across the analyzed FDB, FdbSync, L2-NHG, MacMoveGuard, warm-restart, VXLAN, Ports, and STP modules; about 7.7 KLOC is direct FDB/warm logic.
- **Category**: **Category A (Distributed / Message-Passing)** because Redis tables, netlink dumps/events, and queued SAI notifications form independently ordered message streams across processes and the ASIC boundary.
- **Algorithm**: reconcile local/remote MAC intent with Linux bridge state, SONiC databases, bridge ports/VLAN members, SAI FDB objects, tunnel endpoints, and per-object counters.
- **Reference deviations**: desired, kernel, Orch cache, STATE_DB, and ASIC state advance separately; SAI flush is synchronous but cleanup acknowledgement is asynchronous.
- **Concurrency**: each daemon is primarily a serialized select loop, but cross-loop message ordering, duplicate/coalesced notifications, crashes, and SAI failures create the relevant concurrency.

## 2. Scenarios

### Scenario 1: Flush Is a Multi-Stage Protocol

**Mechanism**: request, ASIC deletion, delayed acknowledgement, cache/counter cleanup, and bridge-port teardown are separate steps without a shared epoch.

**Evidence**:

- Historical [#2136](https://github.com/sonic-net/sonic-swss/pull/2136), [#2254](https://github.com/sonic-net/sonic-swss/pull/2254), [#2673](https://github.com/sonic-net/sonic-swss/pull/2673), [#4527](https://github.com/sonic-net/sonic-swss/pull/4527), and [#4734](https://github.com/sonic-net/sonic-swss/pull/4734) show repeated pending/scope/type regressions; currently STP never marks pending (`stporch.cpp:363-377`, `fdborch.cpp:1661-1688`) although ack cleanup requires it (`294-368`), dynamic flush marks static entries (`1298-1317,1479-1502`), and topology removal cannot observe flush failure (`portsorch.cpp:7470-7531,8060-8114`).

**Affected code paths**: `flushFdbByVlan`, `flushFDBEntries`, `handleSyncdFlushNotif`, `clearFdbEntry`, `updateVlanMember`, `removeBridgePort`, `removeVlanMember`.

**Suggested modeling approach**:

- Variables: `flushReq[scope] = [epoch, type, status]`, per-entry `incarnation`, `pendingEpoch`, topology generation, cache/ASIC presence, counters.
- Actions: split `RequestFlush`, `AsicFlush`, `DeliverFlushAck`, `Relearn`, and `RemoveBridgePort`.
- Granularity: make every external call and acknowledgement a distinct action; permit duplicate, delayed, and consolidated acks.

**Priority**: High — **Rationale**: eleven historical corrective lineages, current missing/type-mismatched markers, and direct safety/counter consequences.

### Scenario 2: Events Lack an Entry Incarnation

**Mechanism**: LEARN, AGE, MOVE, and observer state are keyed mainly by `(MAC, BV)` and apply to mutable destinations without a generation check.

**Evidence**:

- Historical [#461](https://github.com/sonic-net/sonic-swss/pull/461), [#759](https://github.com/sonic-net/sonic-swss/pull/759), [#2201](https://github.com/sonic-net/sonic-swss/pull/2201), and [#2811](https://github.com/sonic-net/sonic-swss/pull/2811) repaired counter/identity drift; currently stale AGE deletes the current destination (`fdborch.cpp:604-790`), same-BP MOVE mutates independent copies (`793-900`), comparison ignores observer-read `port_name` (`fdborch.h:22-36`; `fdborch.cpp:1691-1713,2222-2244`), and notification repair failures lack retry (`472-590,679-762,823-882`).

**Affected code paths**: `FdbOrch::update`, `storeFdbEntryState`, `notifyObserversFDBFlush`, notification queueing, CRM/port/VLAN counter updates.

**Suggested modeling approach**:

- Variables: per-key incarnation, destination/origin/type in each plane, event payload generation, port/VLAN counters.
- Actions: distinguish native MOVE from AGE+LEARN; allow stale, duplicate, and reordered events and injected attribute/create failures.
- Granularity: split hardware mutation, cache commit, counter commit, and observer delivery.

**Priority**: High — **Rationale**: externally visible stale deletion and counter drift are small-state interleavings well suited to exhaustive exploration.

### Scenario 3: Deferred Work Is Not Latest-Intent State

**Mechanism**: missing dependencies cause either lossy acknowledgement or append-only replay, so later intent does not supersede earlier work.

**Evidence**:

- Historical [#406](https://github.com/sonic-net/sonic-swss/pull/406), [#2388](https://github.com/sonic-net/sonic-swss/pull/2388), and [#2642](https://github.com/sonic-net/sonic-swss/pull/2642) repaired retry/wakeup gaps, while [#2756](https://github.com/sonic-net/sonic-swss/pull/2756) was reverted by [#2773](https://github.com/sonic-net/sonic-swss/pull/2773); currently remote VNI is consumed without NVO (`vxlanorch.cpp:2521-2528,2691-2697`), saved SETs append/replay blindly and DEL removes one (`fdborch.cpp:1766-1787,1842-1872,2444-2489`), parent NHG can be dropped (`fdbsync.cpp:1254-1265`), and pending work can starve ([#4605](https://github.com/sonic-net/sonic-swss/pull/4605)).

**Affected code paths**: `addFdbEntry`, `updateVlanMember`, `deleteFdbEntryFromSavedFDB`, `EvpnRemoteVni*::addOperation`, `FdbSync::onMsgNhg`, consumer retry loops.

**Suggested modeling approach**:

- Variables: `desired[key] = [generation, op, value]`, dependency readiness, retry queue, wakeup tokens.
- Actions: `SubmitIntent`, `DependencyAppears`, `ReplayLatest`, `ConsumerWake`, and `ConsumeWithoutApply`.
- Granularity: model coalescing/overwrite separately from dependency replay; stale generations must be discardable.

**Priority**: High — **Rationale**: eighteen historical ordering/readiness lineages and several current resurrection or permanent-loss paths.

### Scenario 4: Tunnel/NHG Graph Mutations Are Non-Atomic

**Mechanism**: SAI next-hop, member, bridge-port, tunnel, and reference-count mutations commit incrementally, while failures often retry from an already-mutated cache.

**Evidence**:

- Historical [#2352](https://github.com/sonic-net/sonic-swss/pull/2352), [#2378](https://github.com/sonic-net/sonic-swss/pull/2378), [#3908](https://github.com/sonic-net/sonic-swss/pull/3908), and [#4188](https://github.com/sonic-net/sonic-swss/pull/4188) repaired ref/flood/rollback failures; currently VTEP replacement deletes first and increments the old IP (`l2nhgorch.cpp:581-654`), active groups can be partial (`353-517,875-877`; `fdborch.cpp:1176-1185`), and BP/VLAN/P2P/P2MP paths have ignored post-mutation failures (`portsorch.cpp:7441-7465,7744-7778,7955-8055`; `vxlanorch.cpp:2570-2586,2643-2649,2741-2746,2794-2819`).

**Affected code paths**: `updateL2NhgVtepIp`, `createL2NextHopGroup`, `add/removeBridgePort`, `add/removeVlanMember`, `add/delTunnelUser`, P2P/P2MP remote-VNI operations.

**Suggested modeling approach**:

- Variables: tunnel/NH/NHG/member/BP graph, old/new endpoint refs, active flag, operation phase, retry intent.
- Actions: split remove-old, decrement-ref, create-new, increment-ref, activate, rollback, and retry; inject failure at every boundary.
- Granularity: model one member at a time so multi-group partial conversion is reachable.

**Priority**: High — **Rationale**: dangling forwarding references, leaked hardware, empty active groups, and an assertion-retry path are externally consequential.

### Scenario 5: Restart Reconstruction Misses One-Shot Inputs

**Mechanism**: warm and cold startup rebuild planes from different snapshots, but one-shot kernel events can be filtered before their enabling configuration is processed.

**Evidence**:

- Historical [#759](https://github.com/sonic-net/sonic-swss/pull/759), [#921](https://github.com/sonic-net/sonic-swss/pull/921), [#1498](https://github.com/sonic-net/sonic-swss/pull/1498), and [#2619](https://github.com/sonic-net/sonic-swss/pull/2619) repaired warm reconciliation, while open [#4715](https://github.com/sonic-net/sonic-swss/pull/4715)/[#4801](https://github.com/sonic-net/sonic-swss/pull/4801) cover cleanup; currently GETNEXTHOP precedes NVO and filtered NHGs are not warm-assisted (`fdbsyncd.cpp:77-115`; `fdbsync.cpp:40-45,1138-1144`), and VXLAN ifindex generations are never erased (`fdbsyncd.cpp:27-31`; `fdbsync.cpp:967-1007,1098-1136`).

**Affected code paths**: `fdbsyncd::main`, `processCfgEvpnNvo`, `onMsgNhg`, `onMsgLink`, `AppRestartAssist`, PortsOrch bake/default-object cleanup.

**Suggested modeling approach**:

- Variables: restart phase, persisted APP rows, live kernel objects, dump completion, NVO readiness, rebuilt cache/ASIC state.
- Actions: `Crash`, `Start`, `DumpKernel`, `ProcessConfig`, `WarmReplay`, `Bake`, and `Reconcile`; vary dump/config order and missing deltas.
- Granularity: separate snapshot enumeration from live events and final reconciliation.

**Priority**: High — **Rationale**: a single missed startup message can leave persistent APP/ASIC divergence with no later stimulus.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **Cross-plane FDB incarnations**: model desired, kernel, cache, STATE_DB, and ASIC values separately; Scenarios 1-2 show that equality by `(MAC, BV)` is insufficient.
- **Flush epochs and overlapping scope/type**: model request/ack as a protocol, not one atomic action; Scenario 1 contains current missing and overbroad pending markers.
- **Latest-intent retry queues**: retain generations and explicit wakeups; Scenario 3 contains loss, starvation, and resurrection behavior.
- **SAI object graph transactions**: expose each graph/refcount step and injected failure; Scenario 4 depends on partial mutation.
- **Restart snapshots and reconciliation**: model both planned warm restart and process crash with one-shot kernel dumps; Scenario 5 is not equivalent to ordinary steady-state retry.

### 3.2 Do Not Model (with rationale)

- CLI/string parsing, fixed-buffer termination, raw SAI list allocation, and iterator lifetime bugs: implementation defects are better handled by tests, sanitizers, or review.
- Exact SAI attribute encodings, ACL object internals, log severity, queue memory consumption, and `m_entries_by_port`'s unused index: they do not change the selected state-machine questions.
- Route ring-buffer internals: the `-R` shared-memory path carries APP_ROUTE, not FDB state.
- Byzantine actors, consensus, or shared-memory data races: neither the architecture nor the reference lifecycle uses them.
- Reproduction of already-fixed PRs: historical bugs are scenario evidence only, not model-check targets.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| MultiPlaneFdb | `desired`, `kernel`, `cache`, `stateDb`, `asic` | Represent independent truth planes | 1, 2, 5 |
| EntryIncarnation | `generation[key]`, `eventGen` | Reject stale AGE/MOVE/flush effects | 1, 2 |
| FlushProtocol | `flushEpoch`, `flushScope`, `flushType`, `ackQueue` | Represent asynchronous and consolidated flushes | 1 |
| TopologyLifecycle | `bpGen`, `vlanMember`, `removalPhase` | Couple FDB cleanup to BP/VLAN teardown | 1, 4 |
| DesiredRetry | `desiredGen`, `pending`, `ready`, `wakeups` | Enforce latest-intent replay and liveness | 3 |
| NhgGraph | `nhgMembers`, `nhgActive`, `tunnelRefs`, `graphPhase` | Model partial group/tunnel mutations | 4 |
| FailureCarrier | `saiOutcome`, `retryOwnedBy` | Require failed external work to remain retryable | 2, 4 |
| RestartRebuild | `restartPhase`, `persisted`, `dumpSeen`, `nvoReady` | Compare live kernel state with replayed intent | 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| UniqueEffectiveDestination | Safety | Each `(MAC, BV)` has at most one effective destination/incarnation | 2, 3 |
| DependencyBeforeReference | Safety | No FDB references an absent BP, VLAN member, tunnel, or active-member set | 3, 4 |
| StaleEventCannotDeleteNewer | Safety | An older AGE/MOVE/flush ack cannot remove a newer incarnation | 1, 2 |
| FlushAckMatchesRequest | Safety | Cleanup matches request epoch, scope, entry type, and incarnation | 1 |
| CounterAgreement | Safety | CRM, port, and VLAN counts equal modeled live entries and never underflow | 1, 2 |
| LatestDesiredWins | Safety | Replayed work cannot overwrite or resurrect intent from a later generation | 3 |
| ActiveNhgHasMember | Safety | Every active NHG has at least one fully created member and bridge port | 4 |
| TunnelRefExact | Safety | Endpoint references equal graph edges and remain nonnegative | 4 |
| NoDanglingTopologyReference | Safety | Completed topology removal leaves no cache/ASIC FDB reference to that generation | 1, 4 |
| FailedWorkRetainsRetryIntent | Safety | A failed external mutation is owned by a retry or compensated before acknowledgement | 2, 4 |
| RestartConverges | Liveness | After inputs stabilize and fair retries run, all reconstructed planes converge | 3, 5 |
| CompletedFlushConverges | Liveness | A successful flush eventually removes every matching old incarnation from all planes | 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC1 | If two overlapping flushes bracket a re-learn and their consolidated acks reorder, can an ack remove the new incarnation? | `StaleEventCannotDeleteNewer`, `FlushAckMatchesRequest` | 1 |
| MC2 | If MOVE A→B is followed by a delayed AGE carrying A, is there any valid SAI ordering in which deleting B is unsafe? | `StaleEventCannotDeleteNewer` | 2 |
| MC3 | If old SET(A), new SET(B), DEL, and dependency-ready events interleave, can append/replay semantics restore A or B after DEL? | `LatestDesiredWins` | 3 |
| MC4 | During one VTEP replacement referenced by multiple groups, can a partial SAI failure leave an FDB pointing to an empty/partly converted active group after fair retries? | `ActiveNhgHasMember`, `TunnelRefExact` | 4 |
| MC5 | If kernel NHG state changes while fdbsyncd is down and the initial dump precedes NVO readiness, can warm replay still converge without a new kernel event? | `RestartConverges` | 5 |
| MC6 | If VLAN/BP removal, a failed or delayed flush, and BP recreation overlap, can an old ack or cache row attach to the new BP generation? | `NoDanglingTopologyReference`, `CounterAgreement` | 1, 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV1 | STP VLAN flush does not set pending, so `FLUSHED` leaves cache/state/counters present. | Invoke `stpVlanFdbFlush`, inject matching ack, assert every plane and count is cleared. |
| TV2 | MCLAG remote-only DEL checks `m_fdb_mac` instead of `m_mclag_remote_fdb_mac`. | Seed only remote cache, process DEL, assert kernel command/cache deletion. |
| TV3 | VTEP replacement attributes the wrong endpoint ref and loses membership on create failure. | Replace an in-use VTEP, inject first/middle SAI failure, retry, and assert exact graph/refcounts. |
| TV4 | Startup NHG dump is discarded before CONFIG NVO and is not replayed. | Feed dump before NVO, then enable NVO; assert APP L2-NHG reconstruction. |
| TV5 | Batched NVO SET→DEL or DEL→SET compares every event to one stale baseline. | Queue both orders and count `updateAllLocalMac`/final L2-NHG cleanup. |
| TV6 | MacMoveGuard recovery erases persistence after port re-enable fails. | Inject `setPortAdminStatusByAlias(false result)`, expire action, assert retry state remains. |
| TV7 | Threshold 1 records only the new port and disables no port. | Send one native move with distinct old/new aliases and assert configured mitigation. |
| TV8 | BP/VLAN-member post-create or post-remove failures leak objects or reach an assertion on retry. | Fail hostif/PVID calls at each boundary and assert rollback plus retry safety. |
| TV9 | Deleted/reused VXLAN ifindex remains classified as the old VXLAN interface. | Deliver NEWLINK, DELLINK, reuse, then neighbor event; assert physical classification. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | `FdbEntry` ordering ignores `port_name`, while observer code reads the retained key's port. | Make identity/value ownership explicit; erase/reinsert on every destination change. |
| CR2 | P2P/P2MP add/delete paths ignore critical tunnel, bridge-port, and member return values. | Define transaction ownership and propagate every retryable failure. |
| CR3 | P2MP endpoint teardown erases membership before later flood-group steps that can fail. | Add rollback or a resumable phase record. |
| CR4 | remote AGE and MOVE repair paths commit/log through failed SAI mutations without a queued retry. | Establish a notification-repair retry owner. |
| CR5 | dynamic flush marks static entries pending although matching acks are type-filtered. | Mark only entries matching the requested SAI type and epoch. |

## 7. Reference Pointers

- Full audit: `analysis-report.md` beside this brief.
- Primary implementation: `orchagent/fdborch.cpp`, `fdbsyncd/fdbsync.cpp`, `orchagent/l2nhgorch.cpp`, `orchagent/portsorch.cpp`, `orchagent/vxlanorch.cpp`, `orchagent/macmoveguard.cpp`.
- History anchors: flush [#1242](https://github.com/sonic-net/sonic-swss/pull/1242), [#2136](https://github.com/sonic-net/sonic-swss/pull/2136), [#2673](https://github.com/sonic-net/sonic-swss/pull/2673), [#4527](https://github.com/sonic-net/sonic-swss/pull/4527), [#4734](https://github.com/sonic-net/sonic-swss/pull/4734); ordering [#406](https://github.com/sonic-net/sonic-swss/pull/406), [#2388](https://github.com/sonic-net/sonic-swss/pull/2388), [#3524](https://github.com/sonic-net/sonic-swss/pull/3524), [#3937](https://github.com/sonic-net/sonic-swss/pull/3937), [#4739](https://github.com/sonic-net/sonic-swss/pull/4739).
- Current NHG review evidence: [#4262 inline discussion](https://github.com/sonic-net/sonic-swss/pull/4262#discussion_r3143391702) and [author follow-up](https://github.com/sonic-net/sonic-swss/pull/4262#issuecomment-4347971135).
- Current open lifecycle work: [#2886](https://github.com/sonic-net/sonic-swss/pull/2886), [#2961](https://github.com/sonic-net/sonic-swss/pull/2961), [#3211](https://github.com/sonic-net/sonic-swss/pull/3211), [#4458](https://github.com/sonic-net/sonic-swss/pull/4458), [#4715](https://github.com/sonic-net/sonic-swss/pull/4715), [#4771](https://github.com/sonic-net/sonic-swss/pull/4771), [#4773](https://github.com/sonic-net/sonic-swss/pull/4773), [#4801](https://github.com/sonic-net/sonic-swss/pull/4801).
