# Instrumentation Specification: SONiC FDB

This document is the trace-harness handoff for `Trace.tla`. Event names and
field names are normative. Every row corresponds to exactly one base-spec
action, and every event calls that full action during replay.

## 1. Trace event schema

### Event envelope

Emit newline-delimited JSON. A central collector must preserve each process's
program order and assign the final `seq` before writing the single Category-A
trace file.

```json
{
  "tag": "trace",
  "seq": 42,
  "timestamp_ns": 1942487830123,
  "process": "orchagent",
  "event": {
    "name": "FdbOrchStoreFdbEntryState",
    "key": "k1",
    "port": "p1",
    "group": "g1",
    "endpoint": "ep1",
    "oldEndpoint": "ep1",
    "newEndpoint": "ep2",
    "eventId": "ev1",
    "sourceEventId": "ev0",
    "ackId": "ack1",
    "sourceAckId": "ack0",
    "epoch": 1,
    "scope": "port",
    "state": {
      "fdb": {},
      "flush": {},
      "topology": {},
      "deferred": {},
      "graph": {},
      "restart": {}
    }
  }
}
```

Only the argument fields and state bundles named in the action table are
required for a given event. Within a required bundle, every field below is
mandatory; `Trace.tla` checks the bundle's domain before comparing primed
state.

### Identity and argument fields

| Trace field | TLA+ use | Source / derivation |
|---|---|---|
| `event.key` | member of `Keys`, abstract `(MAC,BV)` | Stable harness dictionary over `FdbEntry.mac` + `FdbEntry.bv_id` |
| `event.port` | member of `Ports` | `Port.m_alias`; never use the transient SAI OID as model identity |
| `event.group` | member of `Groups` | L2 NHG string key / kernel NH ID dictionary |
| endpoint fields | members of `Endpoints` | Canonical remote IP string dictionary |
| `eventId` / `sourceEventId` | `EventIds` | Monotonic shadow ID assigned when notification is received / duplicated |
| `ackId` / `sourceAckId` | `AckIds` | Monotonic shadow ID assigned to each FLUSHED delivery / duplicate |
| `epoch` | `1..MaxFlushEpoch` | Shadow counter incremented immediately before a flush SAI call |
| `scope` | `all`, `port`, `vlan`, or `portvlan` | Derived from populated SAI flush attributes |

### Entry object

All entry-valued fields use exactly this shape:

```json
{
  "present": true,
  "gen": 2,
  "dest": "p1",
  "bpGen": 1,
  "kind": "dynamic"
}
```

Use `{"present":false,"gen":0,"dest":"none","bpGen":0,"kind":"dynamic"}`
for `EmptyEntry`. `gen` and `bpGen` are harness shadow generations; the current
C++ structs do not provide them. `kind` is plane-relative: software-plane
records carry the logical FDB row type, while `asic.kind` carries the installed
SAI type. In particular, a logical MCLAG `dynamic` row is installed as ASIC
`static` with MAC moves allowed, remains static when hardware first reports a
LEARN or MOVE, and becomes dynamic only at the corresponding guarded FdbOrch
MCLAG handler step; the distinction is required to model hardware aging
eligibility faithfully.

### FDB bundle `F(k)` (`event.state.fdb`)

| Field | TLA+ post-state | Capture source |
|---|---|---|
| `generation` | `generation'[k]` | Per-key shadow generation |
| `kernel`, `asic` | `kernel'[k]`, `asic'[k]` | Shadow planes advanced at SAI/netlink event and SAI-call boundaries |
| `cache` | `cache'[k]` | `FdbOrch::m_entries` lookup |
| `stateDb` | `stateDb'[k]` | Shadow of successful `m_fdbStateTable.set/del` |
| `observer` | `observer'[k]` | Shadow advanced after `notify(...)` |
| `txn` | `fdbTxn'` | Harness record with the exact `Trace.tla` fields |
| `eventQueueSize` | `Cardinality(eventQueue')` | Notification shadow queue size |
| `crmCount` | `crmCount'` | CRM FDB used counter getter/shadow |
| `portCounts` | `portCount'` | JSON object from aliases to `Port.m_fdb_count` |
| `vlanCount` | `vlanCount'` | Current modeled VLAN's `m_fdb_count` |
| `pendingEpoch` | `pendingEpoch'[k]` | Shadow epoch; zero when C++ `is_flush_pending` is false |
| `lastFlushCleanup`, `lastDeletion` | audit records | Harness ghost records updated at cleanup commit |
| `fdbFailure`, `fdbRetry`, `fdbCompensated` | failure ownership flags | Shadow flags set at failure disposition |

### Flush bundle `Q(k,e)` (`event.state.flush`)

| Field | TLA+ post-state | Capture source |
|---|---|---|
| `flushEpoch` | `flushEpoch'` | Global shadow counter |
| `scope`, `port`, `kind`, `path`, `status` | selected epoch arrays | SAI attributes + call path + return/delivery state |
| `snapshot` | `flushSnapshot'[e][k]` | Entry snapshot immediately before the SAI call |
| `ackCreated` | `flushAckCreated'[e]` | Ack-delivery shadow |
| `ackQueueSize` | `Cardinality(ackQueue')` | Ack shadow queue size |
| `pendingEpoch` | `pendingEpoch'[k]` | Per-entry shadow described above |
| `asic` | `asic'[k]` | ASIC shadow after flush outcome |
| `lastFlushCleanup`, `lastDeletion` | audit records | Same exact record objects used in `F(k)` |

`flushRemoved[e][k]` is an internal audit ghost derived by `SaiFlushSuccess`
from the pre-transition ASIC entry. It records the execution-time incarnation
actually removed by the successful SAI call; the harness need not emit it.

### Topology bundle `T(p)` (`event.state.topology`)

`bpGeneration`, `bpPresent`, `vlanMember`, `removalPhase`,
`removalFlushEpoch`, `lastRemovedGeneration`, and `portCount` map directly to
the corresponding primed variables for `p`. Capture object presence from
`PortsOrch` caches; generation/phase fields are harness shadows.

### Deferred bundle `D(k)` (`event.state.deferred`)

`desiredGen`, `desiredOp`, `desiredDest`, `dependencyReady`, `wakeup`, and
`acknowledgedGen` are shadow fields. `saved` is the ordered JSON array of
`{"gen":n,"op":"set","dest":"p"}` records corresponding to
`saved_fdb_entries[port]`. `appliedIntent` is an entry object.

### Graph bundle `G(g)` (`event.state.graph`)

`members` is a sorted JSON array of endpoint IDs. `active`, `bridgePort`,
`phase`, and `desiredEndpoint` come from L2-NHG/Ports caches plus phase shadow.
`replacement` is `{"active":bool,"old":"ep-or-none","new":"ep-or-none"}`.
`tunnelRefs` is a JSON object for every modeled endpoint. `failure`, `retry`,
and `compensated` are the graph failure-ownership shadows.

### Restart bundle `R(g)` (`event.state.restart`)

`phase`, `nvoReady`, `kernelNhg`, `appNhg`, `dumpSeen`, `missedDump`,
`warmReplayDone`, and `settled` map directly to the selected restart state.
The kernel/app booleans come from the netlink dump shadow and
`m_l2NhgMap`/`L2_NEXTHOP_GROUP_TABLE`; the remaining fields are phase shadows.

## 2. Action-to-code mapping

The trigger is always a post-action capture unless explicitly stated. For a
split operation, update the trace shadow first, then serialize the named
bundle; this ensures the event represents the primed TLA+ state.

| Spec action / event name | Code location | Exact trigger point | Required arguments and bundles | Notes |
|---|---|---|---|---|
| `SaiLearnEvent` | `orchagent/fdborch.cpp:1401-1425,370-430` | Immediately after decoding a LEARN notification and before entering its handler branch | `key,port,eventId`; `F(k)` | Advance ASIC/kernel and per-key incarnation shadows first. |
| `SaiMoveEvent` | `orchagent/fdborch.cpp:1401-1425,793-821` | After MOVE decode, before handler mutation | `key,port,eventId`; `F(k)` | The new port is the payload destination. |
| `SaiAgeEvent` | `orchagent/fdborch.cpp:604-612,1401-1425` | After AGE decode and after marking the ASIC shadow absent | `key,eventId`; `F(k)` | Preserve the removed entry's generation in the queued-event shadow; ordinary aging requires the removed ASIC shadow to have SAI dynamic type. |
| `SaiDuplicateEvent` | `orchagent/fdborch.cpp:1401-1425` | In the harness delivery adapter when cloning an already queued notification | `key,sourceEventId,eventId`; `F(k)` | Injection-only event; do not alter payload generation. |
| `FdbOrchUpdateStart` | `orchagent/fdborch.cpp:370-414,416,604,793` | After common port/VLAN validation and case selection, before counter/cache work | `key,eventId`; `F(k)` | Create the exact `txn` record captured by the validator. |
| `FdbOrchIgnoreAgedEvent` | `orchagent/fdborch.cpp:612-619` | Just before the missing-cache AGE branch breaks | `key,eventId`; `F(k)` | Removes the event shadow without other mutations. |
| `FdbOrchNotificationRepairComplete` | `orchagent/fdborch.cpp:634-720` | Immediately before return after a successful remote/static AGE recreate, or after determining the matching ASIC row is already present | `key,eventId`; `F(k)` | Preserve software planes; install the translated SAI type only when the ASIC shadow is absent. |
| `FdbOrchUpdateCounters` | `orchagent/fdborch.cpp:561-579,766-777,860-877`; `241-279` | After all port/VLAN counter writes for the selected branch, before `storeFdbEntryState` | `key`; `F(k)` | Emit once per handler, not once per individual counter write. |
| `FdbOrchStoreFdbEntryState` | `orchagent/fdborch.cpp:124-235,263,581,779,880` | Immediately after `storeFdbEntryState` returns and before observer notify | `key`; `F(k)` | Update cache, STATE_DB, CRM, pending, and deletion-audit shadows. |
| `FdbOrchNotifyObservers` | `orchagent/fdborch.cpp:286-288,582,788,882` | Immediately after the corresponding `notify(...)` call | `key`; `F(k)` | Advance observer shadow and clear transaction shadow. |
| `FdbOrchNotificationRepairFailure` | `orchagent/fdborch.cpp:472-503,679-720,823-882` | After SAI failure disposition, immediately before return or continued commit | `key,eventId`; `F(k)` | A matching installed row is compensation; a queued hardware LEARN/MOVE is the continuation owner. Leave both false only for genuinely absent/divergent unowned work. |
| `FdbOrchFlushFDBEntriesRequest` | `orchagent/fdborch.cpp:1298-1305,1443-1486` | Immediately before `flush_fdb_entries` | `key,port,scope,epoch`; `Q(k,e)` | Snapshot cache and allocate epoch before emitting. |
| `FdbOrchFlushFdbByVlanRequest` | `orchagent/fdborch.cpp:1661-1676`; `stporch.cpp:363-377` | Immediately before the STP/VLAN SAI flush call | `key,port,epoch`; `Q(k,e)` | `scope=vlan`, `path=flushFdbByVlan`. |
| `SaiFlushSuccess` | `orchagent/fdborch.cpp:1311-1317,1492-1502,1676-1688` | After successful call and after any pending-marker loop | `key,epoch`; `Q(k,e)` | STP path must leave `pendingEpoch=0`. |
| `SaiFlushFailure` | `orchagent/fdborch.cpp:1305-1309,1486-1490,1676-1681` | After return-code classification/logging | `key,epoch`; `Q(k,e)` | No pending marker is added. |
| `SaiEnqueueFlushAck` | `orchagent/fdborch.cpp:1401-1425,909-925` | When a FLUSHED notification is accepted by the notification adapter, before cleanup | `key,epoch,ackId`; `Q(k,e)` | Correlate to epoch using the harness SAI-call shadow; wire payload still lacks it. |
| `SaiDuplicateFlushAck` | `orchagent/fdborch.cpp:294-368,909-925` | In the harness adapter when cloning an outstanding ack | `key,epoch,sourceAckId,ackId`; `Q(k,e)` | Injection-only; copy original snapshot exactly. |
| `FdbOrchHandleSyncdFlushNotif` | `orchagent/fdborch.cpp:294-358` | Immediately before the matching `clearFdbEntry` call, after consuming that key from the ack shadow | `key,epoch,ackId`; `F(k),Q(k,e)` | Captures the current pending epoch separately from the ack epoch. |
| `FdbOrchIgnoreSyncdFlushNotif` | `orchagent/fdborch.cpp:302-364` | After one ack/key fails type, scope, presence, or pending checks | `key,epoch,ackId`; `Q(k,e)` | Emit one event per modeled key in a consolidated ack. |
| `PortsOrchRemoveVlanMember` | `orchagent/portsorch.cpp:8060-8114` | After VLAN-member cache/refcount update and observer notification | `port`; `T(p)` | For one-VLAN trace models, transition to `memberRemoved`. |
| `PortsOrchRemoveBridgePortBegin` | `orchagent/portsorch.cpp:7470-7504` | After admin-down, hostif mode, and STP removal; before FDB flush | `port`; `T(p)` | This is the teardown start boundary. |
| `PortsOrchRemoveBridgePortFlushFDBEntries` | `orchagent/portsorch.cpp:7505-7507`; `fdborch.cpp:1443-1503` | Immediately after the flush request shadow is created | `key,port,epoch`; `T(p),Q(k,e)` | The actual SAI outcome is a later event. |
| `PortsOrchRemoveBridgePortSaiRemove` | `orchagent/portsorch.cpp:7509-7531` | After SAI BP removal, OID erase/nulling, notification, and port-cache write | `port`; `T(p)` | Does not wait for async FLUSHED cleanup. |
| `PortsOrchRecreateBridgePort` | `orchagent/portsorch.cpp:7441-7467` | After new BP cache/OID publication and observer notification | `port`; `T(p)` | Increment `bpGeneration`; new tunnel Port count starts at zero. |
| `FdbOrchSubmitSet` | `orchagent/fdborch.cpp:1842-1871`; `fdborch.h:96-105` | Immediately after appending the missing-dependency SavedFdbEntry | `key,port`; `D(k)` | Allocate desired generation before append. |
| `FdbOrchSubmitDelete` | `orchagent/fdborch.cpp:2324-2331,2444-2489` | After the first matching saved entry is erased, or after the no-match scan | `key`; `D(k)` | Preserve any later duplicate/vector element. |
| `FdbOrchUpdateVlanMemberDependencyAppears` | `orchagent/portsorch.cpp:7770-7778`; `fdborch.cpp:1753-1766` | On add notification before moving the saved vector | `key`; `D(k)` | Set readiness and wakeup shadow. |
| `FdbOrchUpdateVlanMemberReplay` | `orchagent/fdborch.cpp:1766-1787` | After popping one saved item, immediately before `addFdbEntry` | `key`; `F(k),D(k)` | One trace event per replayed item. |
| `FdbOrchAddFdbEntrySaiCreateSuccess` | `orchagent/fdborch.cpp:2195-2223` | After successful `create_fdb_entry`, before counter/cache commit | `key`; `F(k),D(k)` | Advance ASIC/incarnation shadow and txn phase. |
| `FdbOrchAddFdbEntrySaiCreateFailure` | `orchagent/fdborch.cpp:2197-2208`; `1766-1787` | Immediately before failure return to the caller that ignores it | `key`; `F(k),D(k)` | Popped saved item is not restored; mark unowned failure. |
| `EvpnRemoteVnip2pOrchAddOperationConsumeWithoutApply` | `orchagent/vxlanorch.cpp:2503-2528,2665-2697` | Immediately before `return true` on missing VTEP | `key`; `F(k),D(k)` | Mark generation acknowledged with no retry owner. |
| `L2NhgAddL2NextHopGroupBegin` | `orchagent/l2nhgorch.cpp:285-312` | After new group OID is inserted into `m_nhg_nh` | `group,endpoint`; `G(g)` | No member/BP exists yet. |
| `L2NhgAddL2NextHopGroupMember` | `orchagent/l2nhgorch.cpp:385-422` | After member/NH OIDs, endpoint ref, and cache insertion | `group`; `G(g)` | Emit once per member. |
| `PortsOrchAddBridgePortL2Nhg` | `orchagent/l2nhgorch.cpp:432-495`; `portsorch.cpp:7441-7467` | After bridge-port success and `is_active=true` | `group`; `G(g)` | Capture both BP and active flags. |
| `FdbOrchAddNhgReference` | `orchagent/fdborch.cpp:1176-1185,2195-2223` | After successful SAI FDB create, before counter/cache commit | `key,group`; `F(k),G(g)` | The only production precondition is active-group lookup. |
| `L2NhgUpdateVtepIpBegin` | `orchagent/l2nhgorch.cpp:581-605` | Before entering the first matching-group replacement iteration | `group,oldEndpoint,newEndpoint`; `G(g)` | Populate replacement shadow. |
| `L2NhgUpdateVtepIpRemoveOld` | `orchagent/l2nhgorch.cpp:605-623` | After old member erase, ref decrement, and endpoint cleanup | `group`; `G(g)` | Occurs before any new create. |
| `L2NhgUpdateVtepIpCreateNew` | `orchagent/l2nhgorch.cpp:625-635` | After new OIDs/cache write and the current ref increment | `group`; `G(g)` | Record that the increment used the still-old cached IP. |
| `L2NhgUpdateVtepIpCreateFailure` | `orchagent/l2nhgorch.cpp:625-647,726-734` | Immediately before returning false after new create/tunnel failure | `group`; `G(g)` | Retained consumer item sets retry=true. |
| `L2NhgUpdateVtepIpRetryAfterFailure` | `orchagent/l2nhgorch.cpp:596-600,648-654` | On retry after the erased group membership is no longer found | `group`; `G(g)` | Capture stable-but-empty group before final replacement clear. |
| `L2NhgUpdateVtepIpFinish` | `orchagent/l2nhgorch.cpp:648-654` | Immediately after cached endpoint IP update and successful return path | `group`; `G(g)` | Clear replacement shadow. |
| `EvpnRemoteVnip2pOrchIgnoredSaiFailure` | `orchagent/vxlanorch.cpp:2570-2586,2738-2746` | After an ignored `addTunnelUser`/`addVlanMember` failure, before success return | `group`; `G(g)` | Mark graph failure with no retry/compensation owner. |
| `FdbSyncCrash` | `fdbsyncd/fdbsync.cpp:35-45`; external supervisor boundary | Supervisor observes process exit and resets trace shadows before restart | `group`; `R(g)` | Supervisor/collector emits because a dying process cannot reliably do so. |
| `KernelNhgChangeWhileDown` | `fdbsyncd/fdbsyncd.cpp:27-31,77-96` | Collector observes kernel NHG create/delete while fdbsyncd is down | `group`; `R(g)` | External environment event. |
| `FdbSyncStart` | `fdbsyncd/fdbsyncd.cpp:16-31,77-89` | After handler registration, before GETNEXTHOP dump processing | `group`; `R(g)` | NVO shadow must still be false. |
| `FdbSyncDumpKernelNhg` | `fdbsyncd/fdbsync.cpp:1138-1144` | Immediately before early return caused by absent NVO | `group`; `R(g)` | Mark dumpSeen and missedDump; do not update APP shadow. |
| `FdbSyncProcessCfgEvpnNvo` | `fdbsyncd/fdbsync.cpp:111-136` | After the CONFIG batch completes | `group`; `R(g)` | No skipped NHG replay is performed. |
| `FdbSyncWarmReplay` | `fdbsyncd/fdbsync.cpp:40-45`; `fdbsyncd.cpp:45-74,117-130` | After `appDataReplayed()` for the registered tables | `group`; `R(g)` | L2 NHG remains outside AppRestartAssist. |
| `FdbSyncBake` | `orchagent/fdborch.cpp:107-120`; `fdbsyncd/fdbsyncd.cpp:117-130` | After warm input refill/bake boundary | `group`; `R(g)` | Separate from final reconciliation. |
| `FdbSyncReconcile` | `fdbsyncd/fdbsyncd.cpp:117-130`; `fdbsync.cpp:1138-1144` | When restart assist reports reconciliation complete | `group`; `R(g)` | Set settled=true without synthesizing a lost NHG event. |
| `FdbSyncLiveNhgEvent` | `fdbsyncd/fdbsync.cpp:1138-1297` | After a post-NVO live NHG message updates table and `m_l2NhgMap` | `group`; `R(g)` | This is the only modeled later repair stimulus. |

## 3. Special considerations

### 3.1 Shadow state is required, but must not change control flow

Incarnations, flush epochs, transaction phases, retry ownership, and the
abstract plane records are intentionally absent from parts of the production
implementation. Add them only to the trace adapter. They may observe return
codes and cache operations, but they must never influence production branches,
retry decisions, or SAI attributes.

### 3.2 Single-file ordering across processes

`Trace.tla` uses a single cursor. Each producer should write to a nonblocking
local ring with a per-process sequence. The collector merges records using
message correlation (`eventId`, `ackId`, epoch) while preserving each
producer's order, then assigns the final `seq`. A receive/handler event must
never precede the corresponding enqueue event. Do not sort solely by wall
clock.

### 3.3 Capture timing and locks

FdbOrch and PortsOrch ordinarily run in serialized select loops, so capture
their cache/count fields before returning to the loop. L2-NHG and fdbsyncd
events must likewise be captured within their owning loop. If the trace writer
is asynchronous, copy the complete bundle into the local ring before the
next operation; do not leave pointers into mutable maps.

### 3.4 Consolidated and duplicate notifications

A consolidated FLUSHED notification is expanded into one
`FdbOrchHandleSyncdFlushNotif` or `FdbOrchIgnoreSyncdFlushNotif` event per
modeled key, all sharing the same `ackId`. The shadow ack's `keys` set shrinks
after each event. A duplicate uses a new `ackId` and retains the original
epoch/snapshot.

### 3.5 Set and map serialization

Serialize graph members as a deterministically sorted JSON array; the trace
spec converts it back to a set. Serialize all TLA+ functions keyed by `Ports`
or `Endpoints` as JSON objects containing every configured key. Never omit a
false/zero field: omission makes the strong validator reject the event.

### 3.6 Bootstrap

`TraceInit` is the base `Init`: empty FDB planes, live generation-1 bridge
ports, no groups, no saved work, and fdbsyncd running with NVO ready. Begin a
trace immediately after clean daemon/ASIC initialization. A trace from a
pre-populated switch requires a future explicit bootstrap action; do not
silently weaken `TraceInit` or skip initial state fields.

### 3.7 Trace size and model domains

The supplied `Trace.cfg` uses one FDB key and one NHG, two ports/endpoints, and
finite event/ack IDs. Rotate files before exhausting the configured shadow ID
sets, or run with a larger matching config. Keep traces short enough for replay
while preserving complete multi-stage operations.
