------------------------------- MODULE MC -------------------------------
(*
 * Counter-bounded model-checking wrapper for base.tla.
 *
 * Only inputs and implementation-specific fault mechanisms are bounded.
 * SAI completions, notification handlers, cache/counter/observer commits,
 * replay, retry completion, and restart reconciliation remain reactive and
 * unbounded once their enabling input exists.
 *)

EXTENDS base

\* Access the un-overridden base definitions from wrapper actions.
fdb == INSTANCE base

CONSTANTS
    MaxFdbEventLimit,
    MaxEventDuplicateLimit,
    MaxFlushRequestLimit,
    MaxFlushFailureLimit,
    MaxAckDuplicateLimit,
    MaxRepairFailureLimit,
    MaxMclagInputLimit,
    MaxIntentLimit,
    MaxDependencyLimit,
    MaxConsumeLimit,
    MaxTopologyLimit,
    MaxGraphCreateLimit,
    MaxFdbReferenceLimit,
    MaxGraphReplaceLimit,
    MaxGraphFailureLimit,
    MaxCrashLimit,
    MaxKernelChangeLimit,
    MaxLiveEventLimit,
    MaxEventBufferLimit,
    MaxAckBufferLimit,
    MaxTotalInputLimit

VARIABLE faultCounters

faultVars == <<faultCounters>>

ZeroFaultCounters ==
    [fdbEvent       |-> 0,
     eventDuplicate |-> 0,
     flushRequest   |-> 0,
     flushFailure   |-> 0,
     ackDuplicate   |-> 0,
     repairFailure  |-> 0,
     mclagInput     |-> 0,
     intent         |-> 0,
     dependency     |-> 0,
     consume         |-> 0,
     topology       |-> 0,
     graphCreate    |-> 0,
     fdbReference   |-> 0,
     graphReplace   |-> 0,
     graphFailure   |-> 0,
     crash          |-> 0,
     kernelChange   |-> 0,
     liveEvent      |-> 0]

\* -------------------------------------------------------------------------
\* Counter-bounded external inputs and concrete fault mechanisms
\* -------------------------------------------------------------------------

MCSaiLearnEvent(k, p, id) ==
    /\ faultCounters.fdbEvent < MaxFdbEventLimit
    /\ fdb!SaiLearnEvent(k, p, id)
    /\ faultCounters' = [faultCounters EXCEPT !.fdbEvent = @ + 1]

MCSaiMoveEvent(k, p, id) ==
    /\ faultCounters.fdbEvent < MaxFdbEventLimit
    /\ fdb!SaiMoveEvent(k, p, id)
    /\ faultCounters' = [faultCounters EXCEPT !.fdbEvent = @ + 1]

MCSaiAgeEvent(k, id) ==
    /\ faultCounters.fdbEvent < MaxFdbEventLimit
    /\ fdb!SaiAgeEvent(k, id)
    /\ faultCounters' = [faultCounters EXCEPT !.fdbEvent = @ + 1]

MCFdbOrchMclagAdvertise(k, p) ==
    /\ faultCounters.mclagInput < MaxMclagInputLimit
    /\ fdb!FdbOrchMclagAdvertise(k, p)
    /\ faultCounters' = [faultCounters EXCEPT !.mclagInput = @ + 1]

MCSaiDuplicateEvent(e, id) ==
    /\ faultCounters.eventDuplicate < MaxEventDuplicateLimit
    /\ fdb!SaiDuplicateEvent(e, id)
    /\ faultCounters' =
          [faultCounters EXCEPT !.eventDuplicate = @ + 1]

MCFdbOrchFlushFDBEntriesRequest(scope, p) ==
    /\ faultCounters.flushRequest < MaxFlushRequestLimit
    /\ fdb!FdbOrchFlushFDBEntriesRequest(scope, p)
    /\ faultCounters' = [faultCounters EXCEPT !.flushRequest = @ + 1]

MCFdbOrchFlushFdbByVlanRequest(p) ==
    /\ faultCounters.flushRequest < MaxFlushRequestLimit
    /\ fdb!FdbOrchFlushFdbByVlanRequest(p)
    /\ faultCounters' = [faultCounters EXCEPT !.flushRequest = @ + 1]

MCSaiFlushFailure(e) ==
    /\ faultCounters.flushFailure < MaxFlushFailureLimit
    /\ fdb!SaiFlushFailure(e)
    /\ faultCounters' = [faultCounters EXCEPT !.flushFailure = @ + 1]

MCSaiDuplicateFlushAck(a, id) ==
    /\ faultCounters.ackDuplicate < MaxAckDuplicateLimit
    /\ fdb!SaiDuplicateFlushAck(a, id)
    /\ faultCounters' = [faultCounters EXCEPT !.ackDuplicate = @ + 1]

MCFdbOrchNotificationRepairFailure(e) ==
    /\ faultCounters.repairFailure < MaxRepairFailureLimit
    /\ fdb!FdbOrchNotificationRepairFailure(e)
    /\ faultCounters' = [faultCounters EXCEPT !.repairFailure = @ + 1]

MCFdbOrchSubmitSet(k, p) ==
    /\ faultCounters.intent < MaxIntentLimit
    /\ fdb!FdbOrchSubmitSet(k, p)
    /\ faultCounters' = [faultCounters EXCEPT !.intent = @ + 1]

MCFdbOrchSubmitDelete(k) ==
    /\ faultCounters.intent < MaxIntentLimit
    /\ fdb!FdbOrchSubmitDelete(k)
    /\ faultCounters' = [faultCounters EXCEPT !.intent = @ + 1]

MCFdbOrchUpdateVlanMemberDependencyAppears(k) ==
    /\ faultCounters.dependency < MaxDependencyLimit
    /\ fdb!FdbOrchUpdateVlanMemberDependencyAppears(k)
    /\ faultCounters' = [faultCounters EXCEPT !.dependency = @ + 1]

MCEvpnRemoteVnip2pOrchAddOperationConsumeWithoutApply(k) ==
    /\ faultCounters.consume < MaxConsumeLimit
    /\ fdb!EvpnRemoteVnip2pOrchAddOperationConsumeWithoutApply(k)
    /\ faultCounters' = [faultCounters EXCEPT !.consume = @ + 1]

MCPortsOrchRemoveVlanMember(p) ==
    /\ faultCounters.topology < MaxTopologyLimit
    /\ fdb!PortsOrchRemoveVlanMember(p)
    /\ faultCounters' = [faultCounters EXCEPT !.topology = @ + 1]

MCPortsOrchRemoveBridgePortBegin(p) ==
    /\ faultCounters.topology < MaxTopologyLimit
    /\ fdb!PortsOrchRemoveBridgePortBegin(p)
    /\ faultCounters' = [faultCounters EXCEPT !.topology = @ + 1]

MCPortsOrchRecreateBridgePort(p) ==
    /\ faultCounters.topology < MaxTopologyLimit
    /\ fdb!PortsOrchRecreateBridgePort(p)
    /\ faultCounters' = [faultCounters EXCEPT !.topology = @ + 1]

MCL2NhgAddL2NextHopGroupBegin(g, ep) ==
    /\ faultCounters.graphCreate < MaxGraphCreateLimit
    /\ fdb!L2NhgAddL2NextHopGroupBegin(g, ep)
    /\ faultCounters' = [faultCounters EXCEPT !.graphCreate = @ + 1]

MCFdbOrchAddNhgReference(k, g) ==
    /\ faultCounters.fdbReference < MaxFdbReferenceLimit
    /\ fdb!FdbOrchAddNhgReference(k, g)
    /\ faultCounters' = [faultCounters EXCEPT !.fdbReference = @ + 1]

MCL2NhgUpdateVtepIpBegin(oldEp, newEp) ==
    /\ faultCounters.graphReplace < MaxGraphReplaceLimit
    /\ fdb!L2NhgUpdateVtepIpBegin(oldEp, newEp)
    /\ faultCounters' = [faultCounters EXCEPT !.graphReplace = @ + 1]

MCL2NhgUpdateVtepIpCreateFailure(g) ==
    /\ faultCounters.graphFailure < MaxGraphFailureLimit
    /\ fdb!L2NhgUpdateVtepIpCreateFailure(g)
    /\ faultCounters' = [faultCounters EXCEPT !.graphFailure = @ + 1]

MCEvpnRemoteVnip2pOrchIgnoredSaiFailure(g) ==
    /\ faultCounters.graphFailure < MaxGraphFailureLimit
    /\ fdb!EvpnRemoteVnip2pOrchIgnoredSaiFailure(g)
    /\ faultCounters' = [faultCounters EXCEPT !.graphFailure = @ + 1]

MCFdbSyncCrash ==
    /\ faultCounters.crash < MaxCrashLimit
    /\ fdb!FdbSyncCrash
    /\ faultCounters' = [faultCounters EXCEPT !.crash = @ + 1]

MCKernelNhgChangeWhileDown(g) ==
    /\ faultCounters.kernelChange < MaxKernelChangeLimit
    /\ fdb!KernelNhgChangeWhileDown(g)
    /\ faultCounters' = [faultCounters EXCEPT !.kernelChange = @ + 1]

MCFdbSyncLiveNhgEvent(g) ==
    /\ faultCounters.liveEvent < MaxLiveEventLimit
    /\ fdb!FdbSyncLiveNhgEvent(g)
    /\ faultCounters' = [faultCounters EXCEPT !.liveEvent = @ + 1]

\* -------------------------------------------------------------------------
\* Reactive actions: never counter-bounded
\* -------------------------------------------------------------------------

MCEventHandlers ==
    \/ \E e \in eventQueue :
          /\ fdb!FdbOrchUpdateStart(e)
          /\ UNCHANGED faultVars
    \/ \E e \in eventQueue :
          /\ fdb!FdbOrchIgnoreAgedEvent(e)
          /\ UNCHANGED faultVars
    \/ \E e \in eventQueue :
          /\ fdb!FdbOrchNotificationRepairComplete(e)
          /\ UNCHANGED faultVars
    \/ /\ fdb!FdbOrchUpdateCounters
       /\ UNCHANGED faultVars
    \/ /\ fdb!FdbOrchStoreFdbEntryState
       /\ UNCHANGED faultVars
    \/ /\ fdb!FdbOrchNotifyObservers
       /\ UNCHANGED faultVars

MCFlushReactive ==
    \/ \E e \in Epochs :
          /\ fdb!SaiFlushSuccess(e)
          /\ UNCHANGED faultVars
    \/ \E e \in Epochs, id \in AckIds :
          /\ fdb!SaiEnqueueFlushAck(e, id)
          /\ UNCHANGED faultVars
    \/ \E a \in ackQueue, k \in Keys :
          /\ fdb!FdbOrchHandleSyncdFlushNotif(a, k)
          /\ UNCHANGED faultVars
    \/ \E a \in ackQueue, k \in Keys :
          /\ fdb!FdbOrchIgnoreSyncdFlushNotif(a, k)
          /\ UNCHANGED faultVars

MCTopologyReactive ==
    \/ \E p \in Ports :
          /\ fdb!PortsOrchRemoveBridgePortFlushFDBEntries(p)
          /\ UNCHANGED faultVars
    \/ \E p \in Ports :
          /\ fdb!PortsOrchRemoveBridgePortSaiRemove(p)
          /\ UNCHANGED faultVars

MCDeferredReactive ==
    \/ \E k \in Keys :
          /\ fdb!FdbOrchUpdateVlanMemberReplay(k)
          /\ UNCHANGED faultVars
    \/ /\ fdb!FdbOrchAddFdbEntrySaiCreateSuccess
       /\ UNCHANGED faultVars
    \/ /\ fdb!FdbOrchAddFdbEntrySaiCreateFailure
       /\ UNCHANGED faultVars

MCGraphReactive ==
    \/ \E g \in Groups :
          /\ fdb!L2NhgAddL2NextHopGroupMember(g)
          /\ UNCHANGED faultVars
    \/ \E g \in Groups :
          /\ fdb!PortsOrchAddBridgePortL2Nhg(g)
          /\ UNCHANGED faultVars
    \/ \E g \in Groups :
          /\ fdb!L2NhgUpdateVtepIpRemoveOld(g)
          /\ UNCHANGED faultVars
    \/ \E g \in Groups :
          /\ fdb!L2NhgUpdateVtepIpCreateNew(g)
          /\ UNCHANGED faultVars
    \/ \E g \in Groups :
          /\ fdb!L2NhgUpdateVtepIpRetryAfterFailure(g)
          /\ UNCHANGED faultVars
    \/ /\ fdb!L2NhgUpdateVtepIpFinish
       /\ UNCHANGED faultVars

MCRestartReactive ==
    \/ /\ fdb!FdbSyncStart
       /\ UNCHANGED faultVars
    \/ \E g \in Groups :
          /\ fdb!FdbSyncDumpKernelNhg(g)
          /\ UNCHANGED faultVars
    \/ /\ fdb!FdbSyncProcessCfgEvpnNvo
       /\ UNCHANGED faultVars
    \/ /\ fdb!FdbSyncWarmReplay
       /\ UNCHANGED faultVars
    \/ /\ fdb!FdbSyncBake
       /\ UNCHANGED faultVars
    \/ /\ fdb!FdbSyncReconcile
       /\ UNCHANGED faultVars

\* -------------------------------------------------------------------------
\* MC initialization and next-state relation
\* -------------------------------------------------------------------------

MCInit ==
    /\ Init
    /\ faultCounters = ZeroFaultCounters

\* A real daemon may wait in its select loop after all modeled inputs drain.
\* Making this already-permitted bracketed stutter explicit lets TLC retain
\* deadlock checking for genuine blocked intermediate states.
MCIdle == UNCHANGED <<vars, faultVars>>

MCNext ==
    \* Bounded external FDB events and event duplication
    \/ \E k \in Keys, p \in Ports, id \in EventIds : MCSaiLearnEvent(k, p, id)
    \/ \E k \in Keys, p \in Ports, id \in EventIds : MCSaiMoveEvent(k, p, id)
    \/ \E k \in Keys, id \in EventIds : MCSaiAgeEvent(k, id)
    \/ \E k \in Keys, p \in Ports : MCFdbOrchMclagAdvertise(k, p)
    \/ \E e \in eventQueue, id \in EventIds : MCSaiDuplicateEvent(e, id)
    \* Bounded flush inputs/failures/duplicates
    \/ \E scope \in FlushScopes, p \in Ports :
           MCFdbOrchFlushFDBEntriesRequest(scope, p)
    \/ \E p \in Ports : MCFdbOrchFlushFdbByVlanRequest(p)
    \/ \E e \in Epochs : MCSaiFlushFailure(e)
    \/ \E a \in ackQueue, id \in AckIds : MCSaiDuplicateFlushAck(a, id)
    \* Bounded repair/deferred mechanisms
    \/ \E e \in eventQueue : MCFdbOrchNotificationRepairFailure(e)
    \/ \E k \in Keys, p \in Ports : MCFdbOrchSubmitSet(k, p)
    \/ \E k \in Keys : MCFdbOrchSubmitDelete(k)
    \/ \E k \in Keys : MCFdbOrchUpdateVlanMemberDependencyAppears(k)
    \/ \E k \in Keys : MCEvpnRemoteVnip2pOrchAddOperationConsumeWithoutApply(k)
    \* Bounded topology and graph inputs/failures
    \/ \E p \in Ports : MCPortsOrchRemoveVlanMember(p)
    \/ \E p \in Ports : MCPortsOrchRemoveBridgePortBegin(p)
    \/ \E p \in Ports : MCPortsOrchRecreateBridgePort(p)
    \/ \E g \in Groups, ep \in Endpoints : MCL2NhgAddL2NextHopGroupBegin(g, ep)
    \/ \E k \in Keys, g \in Groups : MCFdbOrchAddNhgReference(k, g)
    \/ \E oldEp, newEp \in Endpoints : MCL2NhgUpdateVtepIpBegin(oldEp, newEp)
    \/ \E g \in Groups : MCL2NhgUpdateVtepIpCreateFailure(g)
    \/ \E g \in Groups : MCEvpnRemoteVnip2pOrchIgnoredSaiFailure(g)
    \* Bounded restart stimuli
    \/ MCFdbSyncCrash
    \/ \E g \in Groups : MCKernelNhgChangeWhileDown(g)
    \/ \E g \in Groups : MCFdbSyncLiveNhgEvent(g)
    \* Unbounded deterministic/reactive progress
    \/ MCEventHandlers
    \/ MCFlushReactive
    \/ MCTopologyReactive
    \/ MCDeferredReactive
    \/ MCGraphReactive
    \/ MCRestartReactive
    \/ MCIdle

mcVars == <<vars, faultVars>>

MCSpec == MCInit /\ [][MCNext]_mcVars

\* MC1-focused relation: two learned incarnations and two standard all-scope
\* flushes, with only the reactive delivery/cleanup steps left enabled.  This
\* removes unrelated scope/path branches without shrinking the target mechanism.
MC1Next ==
    \/ \E k \in Keys, p \in Ports, id \in EventIds : MCSaiLearnEvent(k, p, id)
    \/ \E p \in Ports : MCFdbOrchFlushFDBEntriesRequest("all", p)
    \/ MCEventHandlers
    \/ MCFlushReactive
    \/ MCIdle

MCSpecMC1 == MCInit /\ [][MC1Next]_mcVars

\* -------------------------------------------------------------------------
\* Symmetry, view, and state-space constraints
\* -------------------------------------------------------------------------

Symmetry == Permutations(Ports)

ModelView == <<vars>>

TotalInputCount ==
    faultCounters.fdbEvent
    + faultCounters.eventDuplicate
    + faultCounters.flushRequest
    + faultCounters.flushFailure
    + faultCounters.ackDuplicate
    + faultCounters.repairFailure
    + faultCounters.mclagInput
    + faultCounters.intent
    + faultCounters.dependency
    + faultCounters.consume
    + faultCounters.topology
    + faultCounters.graphCreate
    + faultCounters.fdbReference
    + faultCounters.graphReplace
    + faultCounters.graphFailure
    + faultCounters.crash
    + faultCounters.kernelChange
    + faultCounters.liveEvent

StateSpaceConstraint ==
    /\ (MaxEventBufferLimit = 0
        \/ Cardinality(eventQueue) <= MaxEventBufferLimit)
    /\ (MaxAckBufferLimit = 0
        \/ Cardinality(ackQueue) <= MaxAckBufferLimit)
    /\ (MaxTotalInputLimit = 0
        \/ TotalInputCount <= MaxTotalInputLimit)

\* -------------------------------------------------------------------------
\* MC structural invariants
\* -------------------------------------------------------------------------

FaultCounterTypeOK ==
    faultCounters \in
      [fdbEvent       : Nat,
       eventDuplicate : Nat,
       flushRequest   : Nat,
       flushFailure   : Nat,
       ackDuplicate   : Nat,
       repairFailure  : Nat,
       mclagInput     : Nat,
       intent         : Nat,
       dependency     : Nat,
       consume         : Nat,
       topology       : Nat,
       graphCreate    : Nat,
       fdbReference   : Nat,
       graphReplace   : Nat,
       graphFailure   : Nat,
       crash          : Nat,
       kernelChange   : Nat,
       liveEvent      : Nat]

FaultCounterBounds ==
    /\ faultCounters.fdbEvent <= MaxFdbEventLimit
    /\ faultCounters.eventDuplicate <= MaxEventDuplicateLimit
    /\ faultCounters.flushRequest <= MaxFlushRequestLimit
    /\ faultCounters.flushFailure <= MaxFlushFailureLimit
    /\ faultCounters.ackDuplicate <= MaxAckDuplicateLimit
    /\ faultCounters.repairFailure <= MaxRepairFailureLimit
    /\ faultCounters.mclagInput <= MaxMclagInputLimit
    /\ faultCounters.intent <= MaxIntentLimit
    /\ faultCounters.dependency <= MaxDependencyLimit
    /\ faultCounters.consume <= MaxConsumeLimit
    /\ faultCounters.topology <= MaxTopologyLimit
    /\ faultCounters.graphCreate <= MaxGraphCreateLimit
    /\ faultCounters.fdbReference <= MaxFdbReferenceLimit
    /\ faultCounters.graphReplace <= MaxGraphReplaceLimit
    /\ faultCounters.graphFailure <= MaxGraphFailureLimit
    /\ faultCounters.crash <= MaxCrashLimit
    /\ faultCounters.kernelChange <= MaxKernelChangeLimit
    /\ faultCounters.liveEvent <= MaxLiveEventLimit

MCTypeOK == TypeOK /\ FaultCounterTypeOK

NotificationIdsUnique ==
    /\ Cardinality(UsedEventIds) = Cardinality(eventQueue)
    /\ Cardinality(UsedAckIds) = Cardinality(ackQueue)

FlushRequestPrefix ==
    \A e \in Epochs :
        (e <= flushEpoch) = (flushStatus[e] /= "unused")

SavedQueueBound ==
    \A k \in Keys : Len(saved[k]) <= MaxGeneration

\* -------------------------------------------------------------------------
\* Temporal structural properties
\* -------------------------------------------------------------------------

GenerationNeverDecreases ==
    [][\A k \in Keys : generation'[k] >= generation[k]]_mcVars

DesiredGenerationNeverDecreases ==
    [][\A k \in Keys : desiredGen'[k] >= desiredGen[k]]_mcVars

FlushEpochNeverDecreases ==
    [][flushEpoch' >= flushEpoch]_mcVars

=============================================================================
