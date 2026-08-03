------------------------------ MODULE Trace ------------------------------
(*
 * Linear trace replay for the Category-A SONiC FDB model.
 *
 * Every observable base action has one event name and calls the full base
 * action.  Validators compare the primed model state with the captured
 * post-state.  There is no unconstrained silent action: the instrumentation
 * contract emits the SAI, cache, counter, observer, retry, graph, and restart
 * stages separately.
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* -------------------------------------------------------------------------
\* Trace loading
\* -------------------------------------------------------------------------

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0
ASSUME Cardinality(Keys) = 1
ASSUME Cardinality(Groups) = 1

VARIABLE l

traceVars == <<l>>
traceAllVars == <<vars, traceVars>>

logline == TraceLog[l]
ev == logline.event

OnlyKey == CHOOSE k \in Keys : TRUE
OnlyGroup == CHOOSE g \in Groups : TRUE

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ ev.name = name

HasEventId(id) == \E e \in eventQueue : e.id = id
EventById(id) == CHOOSE e \in eventQueue : e.id = id

HasAckId(id) == \E a \in ackQueue : a.id = id
AckById(id) == CHOOSE a \in ackQueue : a.id = id

\* -------------------------------------------------------------------------
\* Mandatory post-state validators
\* -------------------------------------------------------------------------

FdbFields ==
    {"generation", "kernel", "cache", "stateDb", "asic", "observer",
     "txn", "eventQueueSize", "crmCount", "portCounts", "vlanCount",
     "pendingEpoch", "lastFlushCleanup", "lastDeletion",
     "fdbFailure", "fdbRetry", "fdbCompensated"}

ValidateFdbPost(k) ==
    \* The FDB snapshot is emitted after each split implementation stage.
    \* fdborch.cpp:124-368,370-930,1401-1503,1753-1789,1827-2308
    /\ "state" \in DOMAIN ev
    /\ "fdb" \in DOMAIN ev.state
    /\ FdbFields \subseteq DOMAIN ev.state.fdb
    /\ LET s == ev.state.fdb
       IN /\ generation'[k] = s.generation
          /\ kernel'[k] = s.kernel
          /\ cache'[k] = s.cache
          /\ stateDb'[k] = s.stateDb
          /\ asic'[k] = s.asic
          /\ observer'[k] = s.observer
          /\ fdbTxn' = s.txn
          /\ Cardinality(eventQueue') = s.eventQueueSize
          /\ crmCount' = s.crmCount
          /\ portCount' = s.portCounts
          /\ vlanCount' = s.vlanCount
          /\ pendingEpoch'[k] = s.pendingEpoch
          /\ lastFlushCleanup'[k] = s.lastFlushCleanup
          /\ lastDeletion'[k] = s.lastDeletion
          /\ fdbFailure'[k] = s.fdbFailure
          /\ fdbRetry'[k] = s.fdbRetry
          /\ fdbCompensated'[k] = s.fdbCompensated

FlushFields ==
    {"flushEpoch", "scope", "port", "kind", "path", "status",
     "snapshot", "ackCreated", "ackQueueSize", "pendingEpoch",
     "asic", "lastFlushCleanup", "lastDeletion"}

ValidateFlushPost(k, e) ==
    \* Flush shadow fields are captured after the SAI call/notification stage.
    \* fdborch.cpp:294-368,1298-1399,1443-1503,1661-1688
    /\ "state" \in DOMAIN ev
    /\ "flush" \in DOMAIN ev.state
    /\ FlushFields \subseteq DOMAIN ev.state.flush
    /\ LET s == ev.state.flush
       IN /\ flushEpoch' = s.flushEpoch
          /\ flushScope'[e] = s.scope
          /\ flushPort'[e] = s.port
          /\ flushType'[e] = s.kind
          /\ flushPath'[e] = s.path
          /\ flushStatus'[e] = s.status
          /\ flushSnapshot'[e][k] = s.snapshot
          /\ flushAckCreated'[e] = s.ackCreated
          /\ Cardinality(ackQueue') = s.ackQueueSize
          /\ pendingEpoch'[k] = s.pendingEpoch
          /\ asic'[k] = s.asic
          /\ lastFlushCleanup'[k] = s.lastFlushCleanup
          /\ lastDeletion'[k] = s.lastDeletion

TopologyFields ==
    {"bpGeneration", "bpPresent", "vlanMember", "removalPhase",
     "removalFlushEpoch", "lastRemovedGeneration", "portCount"}

ValidateTopologyPost(p) ==
    \* Capture after each SAI/member/BP publication boundary.
    \* portsorch.cpp:7441-7531,7744-7778,8060-8114
    /\ "state" \in DOMAIN ev
    /\ "topology" \in DOMAIN ev.state
    /\ TopologyFields \subseteq DOMAIN ev.state.topology
    /\ LET s == ev.state.topology
       IN /\ bpGeneration'[p] = s.bpGeneration
          /\ bpPresent'[p] = s.bpPresent
          /\ vlanMember'[p] = s.vlanMember
          /\ removalPhase'[p] = s.removalPhase
          /\ removalFlushEpoch'[p] = s.removalFlushEpoch
          /\ lastRemovedGeneration'[p] = s.lastRemovedGeneration
          /\ portCount'[p] = s.portCount

DeferredFields ==
    {"desiredGen", "desiredOp", "desiredDest", "saved",
     "dependencyReady", "wakeup", "appliedIntent", "acknowledgedGen"}

ValidateDeferredPost(k) ==
    \* Generation shadows make append/replay ordering observable.
    \* fdborch.cpp:1753-1789,1827-1872,2324-2331,2444-2489
    /\ "state" \in DOMAIN ev
    /\ "deferred" \in DOMAIN ev.state
    /\ DeferredFields \subseteq DOMAIN ev.state.deferred
    /\ LET s == ev.state.deferred
       IN /\ desiredGen'[k] = s.desiredGen
          /\ desiredOp'[k] = s.desiredOp
          /\ desiredDest'[k] = s.desiredDest
          /\ saved'[k] = s.saved
          /\ dependencyReady'[k] = s.dependencyReady
          /\ wakeup'[k] = s.wakeup
          /\ appliedIntent'[k] = s.appliedIntent
          /\ acknowledgedGen'[k] = s.acknowledgedGen

GraphFields ==
    {"members", "active", "bridgePort", "phase", "desiredEndpoint",
     "replacement", "tunnelRefs", "failure", "retry", "compensated"}

ValidateGraphPost(g) ==
    \* Member arrays are serialized in sorted order and converted back to sets.
    \* l2nhgorch.cpp:285-517,581-654
    /\ "state" \in DOMAIN ev
    /\ "graph" \in DOMAIN ev.state
    /\ GraphFields \subseteq DOMAIN ev.state.graph
    /\ LET s == ev.state.graph
       IN /\ nhgMembers'[g] = SeqToSet(s.members)
          /\ nhgActive'[g] = s.active
          /\ nhgBridgePort'[g] = s.bridgePort
          /\ graphPhase'[g] = s.phase
          /\ graphDesiredEndpoint'[g] = s.desiredEndpoint
          /\ replacement' = s.replacement
          /\ tunnelRefs' = s.tunnelRefs
          /\ graphFailure'[g] = s.failure
          /\ graphRetry'[g] = s.retry
          /\ graphCompensated'[g] = s.compensated

RestartFields ==
    {"phase", "nvoReady", "kernelNhg", "appNhg", "dumpSeen",
     "missedDump", "warmReplayDone", "settled"}

ValidateRestartPost(g) ==
    \* Capture the startup phase immediately after each dump/config/replay step.
    \* fdbsyncd.cpp:45-130; fdbsync.cpp:40-45,111-136,1138-1297
    /\ "state" \in DOMAIN ev
    /\ "restart" \in DOMAIN ev.state
    /\ RestartFields \subseteq DOMAIN ev.state.restart
    /\ LET s == ev.state.restart
       IN /\ restartPhase' = s.phase
          /\ nvoReady' = s.nvoReady
          /\ kernelNhg'[g] = s.kernelNhg
          /\ appNhg'[g] = s.appNhg
          /\ dumpSeen'[g] = s.dumpSeen
          /\ missedDump'[g] = s.missedDump
          /\ warmReplayDone' = s.warmReplayDone
          /\ restartSettled' = s.settled

\* -------------------------------------------------------------------------
\* One-to-one event dispatch. Each branch calls the full base action.
\* -------------------------------------------------------------------------

MatchEvent ==
    \* SAI event production: fdborch.cpp:1401-1425,370-930
    \/ /\ IsEvent("SaiLearnEvent")
       /\ SaiLearnEvent(ev.key, ev.port, ev.eventId)
       /\ ValidateFdbPost(ev.key)
    \/ /\ IsEvent("SaiMoveEvent")
       /\ SaiMoveEvent(ev.key, ev.port, ev.eventId)
       /\ ValidateFdbPost(ev.key)
    \/ /\ IsEvent("SaiAgeEvent")
       /\ SaiAgeEvent(ev.key, ev.eventId)
       /\ ValidateFdbPost(ev.key)
    \/ /\ IsEvent("SaiDuplicateEvent")
       /\ HasEventId(ev.sourceEventId)
       /\ SaiDuplicateEvent(EventById(ev.sourceEventId), ev.eventId)
       /\ ValidateFdbPost(ev.key)

    \* Split FdbOrch handler: fdborch.cpp:124-368,370-930
    \/ /\ IsEvent("FdbOrchUpdateStart")
       /\ HasEventId(ev.eventId)
       /\ FdbOrchUpdateStart(EventById(ev.eventId))
       /\ ValidateFdbPost(ev.key)
    \/ /\ IsEvent("FdbOrchIgnoreAgedEvent")
       /\ HasEventId(ev.eventId)
       /\ FdbOrchIgnoreAgedEvent(EventById(ev.eventId))
       /\ ValidateFdbPost(ev.key)
    \/ /\ IsEvent("FdbOrchNotificationRepairComplete")
       /\ HasEventId(ev.eventId)
       /\ FdbOrchNotificationRepairComplete(EventById(ev.eventId))
       /\ ValidateFdbPost(ev.key)
    \/ /\ IsEvent("FdbOrchUpdateCounters")
       /\ FdbOrchUpdateCounters
       /\ ValidateFdbPost(ev.key)
    \/ /\ IsEvent("FdbOrchStoreFdbEntryState")
       /\ FdbOrchStoreFdbEntryState
       /\ ValidateFdbPost(ev.key)
    \/ /\ IsEvent("FdbOrchNotifyObservers")
       /\ FdbOrchNotifyObservers
       /\ ValidateFdbPost(ev.key)
    \/ /\ IsEvent("FdbOrchNotificationRepairFailure")
       /\ HasEventId(ev.eventId)
       /\ FdbOrchNotificationRepairFailure(EventById(ev.eventId))
       /\ ValidateFdbPost(ev.key)

    \* Flush protocol: fdborch.cpp:294-368,1298-1503,1661-1688
    \/ /\ IsEvent("FdbOrchFlushFDBEntriesRequest")
       /\ FdbOrchFlushFDBEntriesRequest(ev.scope, ev.port)
       /\ ValidateFlushPost(ev.key, ev.epoch)
    \/ /\ IsEvent("FdbOrchFlushFdbByVlanRequest")
       /\ FdbOrchFlushFdbByVlanRequest(ev.port)
       /\ ValidateFlushPost(ev.key, ev.epoch)
    \/ /\ IsEvent("SaiFlushSuccess")
       /\ SaiFlushSuccess(ev.epoch)
       /\ ValidateFlushPost(ev.key, ev.epoch)
    \/ /\ IsEvent("SaiFlushFailure")
       /\ SaiFlushFailure(ev.epoch)
       /\ ValidateFlushPost(ev.key, ev.epoch)
    \/ /\ IsEvent("SaiEnqueueFlushAck")
       /\ SaiEnqueueFlushAck(ev.epoch, ev.ackId)
       /\ ValidateFlushPost(ev.key, ev.epoch)
    \/ /\ IsEvent("SaiDuplicateFlushAck")
       /\ HasAckId(ev.sourceAckId)
       /\ SaiDuplicateFlushAck(AckById(ev.sourceAckId), ev.ackId)
       /\ ValidateFlushPost(ev.key, ev.epoch)
    \/ /\ IsEvent("FdbOrchHandleSyncdFlushNotif")
       /\ HasAckId(ev.ackId)
       /\ FdbOrchHandleSyncdFlushNotif(AckById(ev.ackId), ev.key)
       /\ ValidateFdbPost(ev.key)
       /\ ValidateFlushPost(ev.key, ev.epoch)
    \/ /\ IsEvent("FdbOrchIgnoreSyncdFlushNotif")
       /\ HasAckId(ev.ackId)
       /\ FdbOrchIgnoreSyncdFlushNotif(AckById(ev.ackId), ev.key)
       /\ ValidateFlushPost(ev.key, ev.epoch)

    \* Topology lifecycle: portsorch.cpp:7441-7531,8060-8114
    \/ /\ IsEvent("PortsOrchRemoveVlanMember")
       /\ PortsOrchRemoveVlanMember(ev.port)
       /\ ValidateTopologyPost(ev.port)
    \/ /\ IsEvent("PortsOrchRemoveBridgePortBegin")
       /\ PortsOrchRemoveBridgePortBegin(ev.port)
       /\ ValidateTopologyPost(ev.port)
    \/ /\ IsEvent("PortsOrchRemoveBridgePortFlushFDBEntries")
       /\ PortsOrchRemoveBridgePortFlushFDBEntries(ev.port)
       /\ ValidateTopologyPost(ev.port)
       /\ ValidateFlushPost(ev.key, ev.epoch)
    \/ /\ IsEvent("PortsOrchRemoveBridgePortSaiRemove")
       /\ PortsOrchRemoveBridgePortSaiRemove(ev.port)
       /\ ValidateTopologyPost(ev.port)
    \/ /\ IsEvent("PortsOrchRecreateBridgePort")
       /\ PortsOrchRecreateBridgePort(ev.port)
       /\ ValidateTopologyPost(ev.port)

    \* Deferred intent/replay: fdborch.cpp:1753-1789,1827-1872,2444-2489
    \/ /\ IsEvent("FdbOrchSubmitSet")
       /\ FdbOrchSubmitSet(ev.key, ev.port)
       /\ ValidateDeferredPost(ev.key)
    \/ /\ IsEvent("FdbOrchSubmitDelete")
       /\ FdbOrchSubmitDelete(ev.key)
       /\ ValidateDeferredPost(ev.key)
    \/ /\ IsEvent("FdbOrchUpdateVlanMemberDependencyAppears")
       /\ FdbOrchUpdateVlanMemberDependencyAppears(ev.key)
       /\ ValidateDeferredPost(ev.key)
    \/ /\ IsEvent("FdbOrchUpdateVlanMemberReplay")
       /\ FdbOrchUpdateVlanMemberReplay(ev.key)
       /\ ValidateFdbPost(ev.key)
       /\ ValidateDeferredPost(ev.key)
    \/ /\ IsEvent("FdbOrchAddFdbEntrySaiCreateSuccess")
       /\ FdbOrchAddFdbEntrySaiCreateSuccess
       /\ ValidateFdbPost(ev.key)
       /\ ValidateDeferredPost(ev.key)
    \/ /\ IsEvent("FdbOrchAddFdbEntrySaiCreateFailure")
       /\ FdbOrchAddFdbEntrySaiCreateFailure
       /\ ValidateFdbPost(ev.key)
       /\ ValidateDeferredPost(ev.key)
    \/ /\ IsEvent("EvpnRemoteVnip2pOrchAddOperationConsumeWithoutApply")
       /\ EvpnRemoteVnip2pOrchAddOperationConsumeWithoutApply(ev.key)
       /\ ValidateFdbPost(ev.key)
       /\ ValidateDeferredPost(ev.key)

    \* NHG/tunnel graph: l2nhgorch.cpp:285-517,581-654
    \/ /\ IsEvent("L2NhgAddL2NextHopGroupBegin")
       /\ L2NhgAddL2NextHopGroupBegin(ev.group, ev.endpoint)
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("L2NhgAddL2NextHopGroupMember")
       /\ L2NhgAddL2NextHopGroupMember(ev.group)
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("PortsOrchAddBridgePortL2Nhg")
       /\ PortsOrchAddBridgePortL2Nhg(ev.group)
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("FdbOrchAddNhgReference")
       /\ FdbOrchAddNhgReference(ev.key, ev.group)
       /\ ValidateFdbPost(ev.key)
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("L2NhgUpdateVtepIpBegin")
       /\ L2NhgUpdateVtepIpBegin(ev.oldEndpoint, ev.newEndpoint)
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("L2NhgUpdateVtepIpRemoveOld")
       /\ L2NhgUpdateVtepIpRemoveOld(ev.group)
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("L2NhgUpdateVtepIpCreateNew")
       /\ L2NhgUpdateVtepIpCreateNew(ev.group)
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("L2NhgUpdateVtepIpCreateFailure")
       /\ L2NhgUpdateVtepIpCreateFailure(ev.group)
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("L2NhgUpdateVtepIpRetryAfterFailure")
       /\ L2NhgUpdateVtepIpRetryAfterFailure(ev.group)
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("L2NhgUpdateVtepIpFinish")
       /\ L2NhgUpdateVtepIpFinish
       /\ ValidateGraphPost(ev.group)
    \/ /\ IsEvent("EvpnRemoteVnip2pOrchIgnoredSaiFailure")
       /\ EvpnRemoteVnip2pOrchIgnoredSaiFailure(ev.group)
       /\ ValidateGraphPost(ev.group)

    \* Restart reconstruction: fdbsyncd.cpp:45-130; fdbsync.cpp:40-45,111-136,1138-1297
    \/ /\ IsEvent("FdbSyncCrash")
       /\ FdbSyncCrash
       /\ ValidateRestartPost(ev.group)
    \/ /\ IsEvent("KernelNhgChangeWhileDown")
       /\ KernelNhgChangeWhileDown(ev.group)
       /\ ValidateRestartPost(ev.group)
    \/ /\ IsEvent("FdbSyncStart")
       /\ FdbSyncStart
       /\ ValidateRestartPost(ev.group)
    \/ /\ IsEvent("FdbSyncDumpKernelNhg")
       /\ FdbSyncDumpKernelNhg(ev.group)
       /\ ValidateRestartPost(ev.group)
    \/ /\ IsEvent("FdbSyncProcessCfgEvpnNvo")
       /\ FdbSyncProcessCfgEvpnNvo
       /\ ValidateRestartPost(ev.group)
    \/ /\ IsEvent("FdbSyncWarmReplay")
       /\ FdbSyncWarmReplay
       /\ ValidateRestartPost(ev.group)
    \/ /\ IsEvent("FdbSyncBake")
       /\ FdbSyncBake
       /\ ValidateRestartPost(ev.group)
    \/ /\ IsEvent("FdbSyncReconcile")
       /\ FdbSyncReconcile
       /\ ValidateRestartPost(ev.group)
    \/ /\ IsEvent("FdbSyncLiveNhgEvent")
       /\ FdbSyncLiveNhgEvent(ev.group)
       /\ ValidateRestartPost(ev.group)

\* -------------------------------------------------------------------------
\* Trace init/next/completion
\* -------------------------------------------------------------------------

TraceInit ==
    /\ Init
    /\ l = 1

ConsumeNext ==
    /\ l <= Len(TraceLog)
    /\ MatchEvent
    /\ l' = l + 1

TraceDone ==
    /\ l > Len(TraceLog)
    /\ UNCHANGED traceAllVars

TraceNext == ConsumeNext \/ TraceDone

\* Weak fairness prevents the bracketed spec from stuttering forever while a
\* matching trace event remains enabled. If no wrapper matches, TraceMatched
\* fails instead of producing a false positive.
TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_traceAllVars
    /\ WF_traceAllVars(ConsumeNext)

TraceMatched == <>(l > Len(TraceLog))

TraceTypeOK == TypeOK /\ l \in 1..(Len(TraceLog) + 1)

TraceView == <<l, fdbTxn, flushEpoch, restartPhase>>

=============================================================================
