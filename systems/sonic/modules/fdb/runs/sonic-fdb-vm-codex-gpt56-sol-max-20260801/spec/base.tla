------------------------------ MODULE base ------------------------------
(*
 * Scenario-driven model of the SONiC swss FDB subsystem at revision
 * 4f3dda156e52ed7647b1dbf900d54d87efaea455.
 *
 * Category A: Redis rows, netlink events, SAI notifications, and restart
 * snapshots are independently ordered message streams.  The model keeps the
 * implementation's missing generation/epoch checks visible; generation data
 * is carried as ghost state but the implementation actions deliberately do
 * not consult it where the C++ does not.
 *
 * Scenario 1: multi-stage flush and topology teardown
 * Scenario 2: generation-less LEARN/AGE/MOVE delivery
 * Scenario 3: append/replay deferred work rather than latest intent
 * Scenario 4: non-atomic tunnel/NHG graph replacement
 * Scenario 5: one-shot restart inputs before NVO readiness
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Keys,                 \* abstract (MAC, BV) identities
    Ports,                \* bridge-port aliases
    Endpoints,            \* tunnel endpoint IP identities
    Groups,               \* L2 next-hop groups
    EventIds,             \* finite notification identities
    AckIds,               \* finite flush-ack identities
    MaxGeneration,
    MaxFlushEpoch

ASSUME
    /\ Keys /= {}
    /\ Ports /= {}
    /\ Endpoints /= {}
    /\ Groups /= {}
    /\ EventIds /= {}
    /\ AckIds /= {}
    /\ MaxGeneration \in Nat \ {0}
    /\ MaxFlushEpoch \in Nat \ {0}
    /\ Keys \cap Ports = {}
    /\ Ports \cap Endpoints = {}
    /\ Endpoints \cap Groups = {}

Epochs == 1..MaxFlushEpoch
Destinations == Ports \cup Groups

EntryKinds == {"dynamic", "static"}
FdbOrigins == {"none", "learn", "mclag", "vxlan", "provisioned"}
EventKinds == {"learn", "aged", "move"}
IntentOps == {"none", "set", "del"}
FlushScopes == {"all", "port", "vlan", "portvlan"}
FlushPaths == {"none", "flushFDBEntries", "flushFdbByVlan"}
FlushStatuses == {"unused", "requested", "asicDone", "failed", "acked"}
TxnPhases == {"idle", "sai", "counter", "store", "observer"}
TxnOps == {"none", "learn", "aged", "move", "flush", "replay", "nhgFdb"}
RemovalPhases == {"active", "memberRemoved", "adminDown", "awaitFlush", "removed"}
GraphPhases == {"empty", "groupCreated", "memberCreated", "stable",
                "oldRemoved", "replaced", "retry"}
RestartPhases == {"running", "down", "starting", "configReady",
                  "warmReplayed", "baked"}

EmptyEntry ==
    [present |-> FALSE,
     gen     |-> 0,
     dest    |-> "none",
     bpGen   |-> 0,
     kind    |-> "dynamic"]

MakeEntry(g, d, b, t) ==
    [present |-> TRUE,
     gen     |-> g,
     dest    |-> d,
     bpGen   |-> b,
     kind    |-> t]

EntryType ==
    [present : BOOLEAN,
     gen     : 0..MaxGeneration,
     dest    : Destinations \cup {"none"},
     bpGen   : 0..MaxGeneration,
     kind    : EntryKinds]

IntentType ==
    [gen  : 1..MaxGeneration,
     op   : {"set"},
     dest : Ports]

EmptyTxn ==
    [phase        |-> "idle",
     op           |-> "none",
     key          |-> "none",
     eventGen     |-> 0,
     newDest      |-> "none",
     newBpGen     |-> 0,
     entryKind    |-> "dynamic",
     oldPresent   |-> FALSE,
     oldGen       |-> 0,
     oldDest      |-> "none",
     oldBpGen     |-> 0,
     ackEpoch     |-> 0,
     markedEpoch  |-> 0]

EmptyFlushAudit ==
    [valid        |-> FALSE,
     ackEpoch     |-> 0,
     markedEpoch  |-> 0,
     ackGen       |-> 0,
     removedGen   |-> 0,
     kindMatched  |-> TRUE,
     scopeMatched |-> TRUE]

EmptyDeletionAudit ==
    [valid      |-> FALSE,
     cause      |-> "none",
     eventGen   |-> 0,
     removedGen |-> 0]

EmptyReplacement ==
    [active |-> FALSE,
     old    |-> "none",
     new    |-> "none"]

VARIABLES
    \* Desired intent and independently advancing truth planes (Scenarios 1,2,5)
    desiredGen, desiredOp, desiredDest,
    generation, kernel, cache, cacheOrigin, stateDb, asic, observer,

    \* SAI event delivery and split FdbOrch handler (Scenario 2)
    eventQueue, fdbTxn,
    crmCount, portCount, vlanCount,

    \* Flush protocol and audit ghost state (Scenario 1)
    flushEpoch, flushScope, flushPort, flushType, flushPath, flushStatus,
    flushSnapshot, flushRemoved, flushAckCreated, ackQueue, pendingEpoch,
    lastFlushCleanup, lastDeletion,

    \* Bridge-port/VLAN-member generation lifecycle (Scenarios 1,4)
    bpGeneration, bpPresent, vlanMember, removalPhase,
    removalFlushEpoch, lastRemovedGeneration,

    \* Deferred/latest-intent state (Scenario 3)
    saved, dependencyReady, wakeup, appliedIntent, acknowledgedGen,

    \* Tunnel/NHG graph (Scenario 4)
    nhgMembers, nhgActive, nhgBridgePort, tunnelRefs,
    graphPhase, graphDesiredEndpoint, replacement,

    \* Failure ownership (Scenarios 2,3,4)
    fdbFailure, fdbRetry, fdbCompensated,
    graphFailure, graphRetry, graphCompensated,

    \* Restart reconstruction (Scenario 5)
    restartPhase, nvoReady, kernelNhg, appNhg,
    dumpSeen, missedDump, warmReplayDone, restartSettled

intentVars == <<desiredGen, desiredOp, desiredDest>>
hardwareVars == <<generation, kernel, asic>>
softwareVars == <<cache, cacheOrigin, stateDb, observer>>
eventVars == <<eventQueue, fdbTxn>>
counterVars == <<crmCount, portCount, vlanCount>>
flushRequestVars == <<flushEpoch, flushScope, flushPort, flushType, flushPath,
                      flushStatus, flushSnapshot, flushRemoved,
                      flushAckCreated, ackQueue>>
flushAuditVars == <<lastFlushCleanup, lastDeletion>>
flushVars == <<flushRequestVars, pendingEpoch, flushAuditVars>>
topologyVars == <<bpGeneration, bpPresent, vlanMember, removalPhase,
                  removalFlushEpoch, lastRemovedGeneration>>
savedVars == <<saved, dependencyReady, wakeup, acknowledgedGen>>
deferredVars == <<savedVars, appliedIntent>>
graphCoreVars == <<nhgMembers, nhgActive, nhgBridgePort, tunnelRefs,
                   graphPhase, graphDesiredEndpoint, replacement>>
failureVars == <<fdbFailure, fdbRetry, fdbCompensated,
                 graphFailure, graphRetry, graphCompensated>>
restartVars == <<restartPhase, nvoReady, kernelNhg, appNhg,
                 dumpSeen, missedDump, warmReplayDone, restartSettled>>

vars == <<intentVars, hardwareVars, softwareVars, eventVars, counterVars,
          flushVars, topologyVars, deferredVars, graphCoreVars,
          failureVars, restartVars>>

\* -------------------------------------------------------------------------
\* Helpers
\* -------------------------------------------------------------------------

UsedEventIds == {e.id : e \in eventQueue}
UsedAckIds == {a.id : a \in ackQueue}

ScopeMatchesValues(scope, port, en) ==
    CASE scope = "all"      -> TRUE
      [] scope = "vlan"     -> TRUE       \* one abstract BV in the model
      [] scope = "port"     -> en.dest = port
      [] scope = "portvlan" -> en.dest = port
      [] OTHER               -> FALSE

ScopeMatchesEpoch(e, en) ==
    ScopeMatchesValues(flushScope[e], flushPort[e], en)

ScopeMatchesAck(a, en) ==
    ScopeMatchesValues(a.scope, a.port, en)

InstalledKindFor(origin, logicalKind) ==
    IF origin \in {"mclag", "vxlan"} /\ logicalKind = "dynamic"
    THEN "static"
    ELSE logicalKind

AsicSatisfiesCache(k) ==
    /\ cache[k].present
    /\ asic[k].present
    \* Generation is audit-only ghost state; the implementation and SAI FDB
    \* key cannot distinguish otherwise identical incarnations.
    /\ asic[k].dest = cache[k].dest
    /\ asic[k].bpGen = cache[k].bpGen
    /\ asic[k].kind = InstalledKindFor(cacheOrigin[k], cache[k].kind)

HardwareContinuationPending(k, skipped) ==
    \E q \in eventQueue \ {skipped} :
        /\ q.key = k
        /\ q.kind \in {"learn", "move"}
        /\ asic[k].present
        /\ q.dest = asic[k].dest
        /\ q.bpGen = asic[k].bpGen

AgeRecreateRequired(e) ==
    /\ e.kind = "aged"
    /\ cache[e.key].present
    /\ \/ cacheOrigin[e.key] \in {"mclag", "vxlan"}
       \/ /\ cache[e.key].kind = "static"
          /\ \E p \in Ports :
                /\ cache[e.key].dest = p
                /\ vlanMember[p]

AckQueueAfterKey(a, k) ==
    LET remaining == a.keys \ {k}
    IN (ackQueue \ {a}) \cup
       (IF remaining = {}
        THEN {}
        ELSE {[a EXCEPT !.keys = remaining]})

PortCountsAfterAdd(oldPresent, oldDest, newDest) ==
    [p \in Ports |->
        portCount[p]
        + IF ~oldPresent
          THEN IF p = newDest THEN 1 ELSE 0
          ELSE IF oldDest = newDest
               THEN 0
               ELSE (IF p = newDest THEN 1 ELSE 0)
                    - (IF p = oldDest THEN 1 ELSE 0)]

PortCountsAfterDelete(oldPresent, oldDest) ==
    [p \in Ports |->
        portCount[p] - IF oldPresent /\ p = oldDest THEN 1 ELSE 0]

EventsFor(k) == {e \in eventQueue : e.key = k}

PlaneTuples(k) ==
    (IF cache[k].present
     THEN {<<cache[k].gen, cache[k].dest, cache[k].bpGen>>}
     ELSE {})
    \cup
    (IF stateDb[k].present
     THEN {<<stateDb[k].gen, stateDb[k].dest, stateDb[k].bpGen>>}
     ELSE {})
    \cup
    (IF asic[k].present
     THEN {<<asic[k].gen, asic[k].dest, asic[k].bpGen>>}
     ELSE {})

FdbQuiescent(k) == fdbTxn.key /= k /\ EventsFor(k) = {}

CacheKeys == {k \in Keys : cache[k].present}
CacheKeysAtPort(p) == {k \in Keys : cache[k].present /\ cache[k].dest = p}

EntryReferencesLiveDependency(en) ==
    /\ en.present
    /\ CASE en.dest \in Ports ->
              /\ bpPresent[en.dest]
              /\ vlanMember[en.dest]
              /\ en.bpGen = bpGeneration[en.dest]
          [] en.dest \in Groups ->
              /\ nhgActive[en.dest]
              /\ nhgBridgePort[en.dest]
              /\ nhgMembers[en.dest] /= {}
          [] OTHER -> FALSE

EntryHasIncarnation(en, old) ==
    en.present /\ old.present /\ en.gen = old.gen

OldFlushGone(e) ==
    \A k \in Keys :
        LET old == flushSnapshot[e][k]
        IN ~old.present
           \/ ~ScopeMatchesEpoch(e, old)
           \/ old.kind /= flushType[e]
           \/ /\ ~EntryHasIncarnation(cache[k], old)
              /\ ~EntryHasIncarnation(stateDb[k], old)
              /\ ~EntryHasIncarnation(asic[k], old)

SuccessfulFlushCovered(k, g) ==
    \E e \in Epochs :
        /\ flushStatus[e] \in {"asicDone", "acked"}
        /\ flushRemoved[e][k].present
        \* Removing a newer ASIC incarnation also proves that an older cached
        \* incarnation was already superseded; only a post-flush generation
        \* lies outside the successful call's coverage.
        /\ flushRemoved[e][k].gen >= g
        /\ flushRemoved[e][k].kind = flushType[e]
        /\ ScopeMatchesEpoch(e, flushRemoved[e][k])

RestartReconstructed == \A g \in Groups : appNhg[g] = kernelNhg[g]

\* -------------------------------------------------------------------------
\* Initialization
\* -------------------------------------------------------------------------

Init ==
    /\ desiredGen = [k \in Keys |-> 0]
    /\ desiredOp = [k \in Keys |-> "none"]
    /\ desiredDest = [k \in Keys |-> "none"]
    /\ generation = [k \in Keys |-> 0]
    /\ kernel = [k \in Keys |-> EmptyEntry]
    /\ cache = [k \in Keys |-> EmptyEntry]
    /\ cacheOrigin = [k \in Keys |-> "none"]
    /\ stateDb = [k \in Keys |-> EmptyEntry]
    /\ asic = [k \in Keys |-> EmptyEntry]
    /\ observer = [k \in Keys |-> EmptyEntry]
    /\ eventQueue = {}
    /\ fdbTxn = EmptyTxn
    /\ crmCount = 0
    /\ portCount = [p \in Ports |-> 0]
    /\ vlanCount = 0
    /\ flushEpoch = 0
    /\ flushScope = [e \in Epochs |-> "all"]
    /\ flushPort = [e \in Epochs |-> "none"]
    /\ flushType = [e \in Epochs |-> "dynamic"]
    /\ flushPath = [e \in Epochs |-> "none"]
    /\ flushStatus = [e \in Epochs |-> "unused"]
    /\ flushSnapshot = [e \in Epochs |-> [k \in Keys |-> EmptyEntry]]
    /\ flushRemoved = [e \in Epochs |-> [k \in Keys |-> EmptyEntry]]
    /\ flushAckCreated = [e \in Epochs |-> FALSE]
    /\ ackQueue = {}
    /\ pendingEpoch = [k \in Keys |-> 0]
    /\ lastFlushCleanup = [k \in Keys |-> EmptyFlushAudit]
    /\ lastDeletion = [k \in Keys |-> EmptyDeletionAudit]
    /\ bpGeneration = [p \in Ports |-> 1]
    /\ bpPresent = [p \in Ports |-> TRUE]
    /\ vlanMember = [p \in Ports |-> TRUE]
    /\ removalPhase = [p \in Ports |-> "active"]
    /\ removalFlushEpoch = [p \in Ports |-> 0]
    /\ lastRemovedGeneration = [p \in Ports |-> 0]
    /\ saved = [k \in Keys |-> <<>>]
    /\ dependencyReady = [k \in Keys |-> FALSE]
    /\ wakeup = [k \in Keys |-> FALSE]
    /\ appliedIntent = [k \in Keys |-> EmptyEntry]
    /\ acknowledgedGen = [k \in Keys |-> 0]
    /\ nhgMembers = [g \in Groups |-> {}]
    /\ nhgActive = [g \in Groups |-> FALSE]
    /\ nhgBridgePort = [g \in Groups |-> FALSE]
    /\ tunnelRefs = [ep \in Endpoints |-> 0]
    /\ graphPhase = [g \in Groups |-> "empty"]
    /\ graphDesiredEndpoint = [g \in Groups |-> "none"]
    /\ replacement = EmptyReplacement
    /\ fdbFailure = [k \in Keys |-> FALSE]
    /\ fdbRetry = [k \in Keys |-> FALSE]
    /\ fdbCompensated = [k \in Keys |-> FALSE]
    /\ graphFailure = [g \in Groups |-> FALSE]
    /\ graphRetry = [g \in Groups |-> FALSE]
    /\ graphCompensated = [g \in Groups |-> FALSE]
    /\ restartPhase = "running"
    /\ nvoReady = TRUE
    /\ kernelNhg = [g \in Groups |-> FALSE]
    /\ appNhg = [g \in Groups |-> FALSE]
    /\ dumpSeen = [g \in Groups |-> FALSE]
    /\ missedDump = [g \in Groups |-> FALSE]
    /\ warmReplayDone = FALSE
    /\ restartSettled = FALSE

\* -------------------------------------------------------------------------
\* Scenario 2: independently delivered LEARN / AGE / MOVE events
\* -------------------------------------------------------------------------

FdbOrchMclagAdvertise(k, p) ==
    \* A ready MCLAG_FDB_TABLE SET creates a remote-owned cache row before a
    \* later native MOVE can enter the MCLAG-only attribute-repair loop.
    \* The row remains logically dynamic in software, but addFdbEntry installs
    \* it as SAI static with MAC moves allowed so ordinary aging cannot remove
    \* it.  orchagent/fdborch.cpp:1042-1256,2035-2058,2222-2283
    /\ fdbTxn.phase = "idle"
    /\ generation[k] < MaxGeneration
    /\ ~cache[k].present
    /\ ~asic[k].present
    /\ bpPresent[p] /\ vlanMember[p]
    /\ LET g == generation[k] + 1
           logicalEn == MakeEntry(g, p, bpGeneration[p], "dynamic")
           saiEn == MakeEntry(g, p, bpGeneration[p],
                              InstalledKindFor("mclag", "dynamic"))
       IN /\ generation' = [generation EXCEPT ![k] = g]
          /\ kernel' = [kernel EXCEPT ![k] = logicalEn]
          /\ asic' = [asic EXCEPT ![k] = saiEn]
          /\ cache' = [cache EXCEPT ![k] = logicalEn]
          /\ cacheOrigin' = [cacheOrigin EXCEPT ![k] = "mclag"]
          /\ stateDb' = [stateDb EXCEPT ![k] = logicalEn]
          /\ observer' = [observer EXCEPT ![k] = logicalEn]
          /\ crmCount' = crmCount + 1
          /\ portCount' = PortCountsAfterAdd(FALSE, "none", p)
          /\ vlanCount' = vlanCount + 1
          /\ pendingEpoch' = [pendingEpoch EXCEPT ![k] = 0]
    /\ UNCHANGED <<intentVars, eventQueue, fdbTxn, flushRequestVars,
                    flushAuditVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

SaiLearnEvent(k, p, id) ==
    \* SAI_FDB_EVENT_LEARNED payload is decoded before FdbOrch::update.
    \* orchagent/fdborch.cpp:1401-1425,370-386
    /\ generation[k] < MaxGeneration
    /\ id \in EventIds \ UsedEventIds
    /\ bpPresent[p] /\ vlanMember[p]
    \* A different-port transition of an installed static allow-move row is a
    \* SAI MOVE, not a fresh LEARN.  Same-port delayed LEARN is still admitted.
    /\ \/ ~asic[k].present
       \/ asic[k].kind = "dynamic"
       \/ /\ asic[k].dest = p
          /\ asic[k].bpGen = bpGeneration[p]
    \* Hardware has already learned the new destination when the event arrives.
    \* An existing static MCLAG row retains its installed type until the
    \* same-port LEARN handler explicitly converts it.  fdborch.cpp:416-503
    /\ LET g == generation[k] + 1
           logicalEn == MakeEntry(g, p, bpGeneration[p], "dynamic")
           saiEn == MakeEntry(g, p, bpGeneration[p],
                              IF asic[k].present
                              THEN asic[k].kind
                              ELSE "dynamic")
       IN /\ generation' = [generation EXCEPT ![k] = g]
          /\ kernel' = [kernel EXCEPT ![k] = logicalEn]
          /\ asic' = [asic EXCEPT ![k] = saiEn]
          /\ eventQueue' = eventQueue \cup
                {[id |-> id, kind |-> "learn", key |-> k, gen |-> g,
                  dest |-> p, bpGen |-> bpGeneration[p],
                  entryKind |-> "dynamic"]}
    /\ UNCHANGED <<intentVars, softwareVars, fdbTxn, counterVars, flushVars,
                    topologyVars, deferredVars, graphCoreVars, failureVars,
                    restartVars>>

SaiMoveEvent(k, p, id) ==
    \* Native MOVE supplies the new bridge port, while identity remains (MAC,BV).
    \* orchagent/fdborch.cpp:793-821,860-880
    /\ generation[k] < MaxGeneration
    /\ id \in EventIds \ UsedEventIds
    /\ bpPresent[p] /\ vlanMember[p]
    \* SAI has already installed the moved destination before notification,
    \* but a static allow-move entry remains static until FdbOrch's guarded
    \* MCLAG MOVE repair changes its type.  orchagent/fdborch.cpp:823-880
    /\ LET g == generation[k] + 1
           logicalEn == MakeEntry(g, p, bpGeneration[p], "dynamic")
           saiEn == MakeEntry(g, p, bpGeneration[p],
                              IF asic[k].present
                              THEN asic[k].kind
                              ELSE "dynamic")
       IN /\ generation' = [generation EXCEPT ![k] = g]
          /\ kernel' = [kernel EXCEPT ![k] = logicalEn]
          /\ asic' = [asic EXCEPT ![k] = saiEn]
          /\ eventQueue' = eventQueue \cup
                {[id |-> id, kind |-> "move", key |-> k, gen |-> g,
                  dest |-> p, bpGen |-> bpGeneration[p],
                  entryKind |-> "dynamic"]}
    /\ UNCHANGED <<intentVars, softwareVars, fdbTxn, counterVars, flushVars,
                    topologyVars, deferredVars, graphCoreVars, failureVars,
                    restartVars>>

SaiAgeEvent(k, id) ==
    \* Ordinary switch aging applies only to an installed SAI dynamic entry;
    \* static-plus-allow-move MCLAG/remote entries are not age eligible.
    \* orchagent/fdborch.cpp:604-612,2035-2058; saiswitch.h:1524-1533
    /\ asic[k].present
    /\ asic[k].kind = "dynamic"
    /\ id \in EventIds \ UsedEventIds
    \* Capture ghost generation/destination in the event; the handler omits both
    \* generation validation and the stale-port early return.
    \* orchagent/fdborch.cpp:621-631
    /\ LET old == asic[k]
       IN /\ kernel' = [kernel EXCEPT ![k] = EmptyEntry]
          /\ asic' = [asic EXCEPT ![k] = EmptyEntry]
          /\ eventQueue' = eventQueue \cup
                {[id |-> id, kind |-> "aged", key |-> k, gen |-> old.gen,
                  dest |-> old.dest, bpGen |-> old.bpGen,
                  entryKind |-> old.kind]}
    /\ UNCHANGED <<intentVars, generation, softwareVars, fdbTxn, counterVars,
                    flushVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

SaiDuplicateEvent(e, id) ==
    \* NotificationConsumer iterates delivered notifications without an
    \* incarnation/deduplication key.  orchagent/fdborch.cpp:1401-1425
    /\ e \in eventQueue
    /\ id \in EventIds \ UsedEventIds
    /\ eventQueue' = eventQueue \cup {[e EXCEPT !.id = id]}
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, fdbTxn, counterVars,
                    flushVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

FdbOrchUpdateStart(e) ==
    \* FdbOrch::update dispatches one queued SAI event in the serialized loop.
    \* orchagent/fdborch.cpp:370-414,416,604,793
    /\ e \in eventQueue
    /\ fdbTxn.phase = "idle"
    /\ e.kind /= "aged" \/ cache[e.key].present
    \* Static/remote AGE takes the implementation's recreate-and-return branch,
    \* never the destructive cache cleanup below.  fdborch.cpp:634-720
    /\ ~AgeRecreateRequired(e)
    \* For stale AGE, the implementation logs the port mismatch but continues
    \* using the current cached entry.  orchagent/fdborch.cpp:612-631
    /\ LET old == cache[e.key]
           mclagTypeRepair ==
               /\ cacheOrigin[e.key] = "mclag"
               /\ asic[e.key].present
               /\ \/ /\ e.kind = "move"
                     /\ \/ cache[e.key].dest /= e.dest
                        \/ cache[e.key].bpGen /= e.bpGen
                  \/ /\ e.kind = "learn"
                     /\ cache[e.key].dest = e.dest
                     /\ cache[e.key].bpGen = e.bpGen
       IN /\ fdbTxn' =
                [phase        |-> "counter",
                 op           |-> e.kind,
                 key          |-> e.key,
                 eventGen     |-> e.gen,
                 newDest      |-> e.dest,
                 newBpGen     |-> e.bpGen,
                 entryKind    |-> e.entryKind,
                 oldPresent   |-> old.present,
                 oldGen       |-> old.gen,
                 oldDest      |-> old.dest,
                 oldBpGen     |-> old.bpGen,
                 ackEpoch     |-> 0,
                 markedEpoch  |-> pendingEpoch[e.key]]
          \* The successful repair loop sets TYPE=DYNAMIC before software
          \* counters/cache advance.  fdborch.cpp:823-880
          /\ asic' =
                IF mclagTypeRepair
                THEN [asic EXCEPT ![e.key].kind = "dynamic"]
                ELSE asic
    /\ eventQueue' = eventQueue \ {e}
    /\ UNCHANGED <<intentVars, generation, kernel, softwareVars, counterVars,
                    flushVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

FdbOrchIgnoreAgedEvent(e) ==
    \* Missing cache entry makes AGE a logged no-op.  orchagent/fdborch.cpp:612-619
    /\ e \in eventQueue
    /\ e.kind = "aged"
    /\ ~cache[e.key].present
    /\ eventQueue' = eventQueue \ {e}
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, fdbTxn, counterVars,
                    flushVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

FdbOrchNotificationRepairComplete(e) ==
    \* A successful remote/static AGE recreate returns without changing the
    \* software row.  A delayed AGE whose replacement is already installed has
    \* the same logical disposition.  fdborch.cpp:634-720
    /\ e \in eventQueue
    /\ fdbTxn.phase = "idle"
    /\ AgeRecreateRequired(e)
    /\ \/ ~asic[e.key].present
       \/ AsicSatisfiesCache(e.key)
    /\ LET installed ==
               MakeEntry(cache[e.key].gen,
                         cache[e.key].dest,
                         cache[e.key].bpGen,
                         InstalledKindFor(cacheOrigin[e.key],
                                          cache[e.key].kind))
       IN asic' =
            IF asic[e.key].present
            THEN asic
            ELSE [asic EXCEPT ![e.key] = installed]
    /\ eventQueue' = eventQueue \ {e}
    /\ UNCHANGED <<intentVars, generation, kernel, softwareVars, fdbTxn,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, restartVars>>

FdbOrchUpdateCounters ==
    \* LEARN/MOVE update port and VLAN counters before storeFdbEntryState.
    \* orchagent/fdborch.cpp:561-581,860-880
    /\ fdbTxn.phase = "counter"
    /\ IF fdbTxn.op \in {"learn", "move", "replay", "nhgFdb"}
       THEN /\ portCount' = PortCountsAfterAdd(
                                fdbTxn.oldPresent,
                                fdbTxn.oldDest,
                                fdbTxn.newDest)
            /\ vlanCount' = vlanCount + IF fdbTxn.oldPresent THEN 0 ELSE 1
       \* AGE/flush decrement the currently cached port/VLAN, not the event's
       \* old destination/incarnation.  orchagent/fdborch.cpp:250-279,766-779
       ELSE /\ fdbTxn.op \in {"aged", "flush"}
            /\ portCount' = PortCountsAfterDelete(
                                fdbTxn.oldPresent,
                                fdbTxn.oldDest)
            /\ vlanCount' = vlanCount - IF fdbTxn.oldPresent THEN 1 ELSE 0
    /\ fdbTxn' = [fdbTxn EXCEPT !.phase = "store"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, crmCount,
                    flushVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars, eventQueue>>

FdbOrchStoreFdbEntryState ==
    \* storeFdbEntryState owns cache, STATE_DB, and CRM commit.
    \* orchagent/fdborch.cpp:124-235
    /\ fdbTxn.phase = "store"
    /\ LET k == fdbTxn.key
           isAdd == fdbTxn.op \in {"learn", "move", "replay", "nhgFdb"}
           en == MakeEntry(fdbTxn.eventGen, fdbTxn.newDest,
                           fdbTxn.newBpGen, fdbTxn.entryKind)
           duplicateLocal ==
               /\ isAdd
               /\ fdbTxn.op \in {"learn", "move"}
               /\ fdbTxn.oldPresent
               /\ fdbTxn.oldDest = fdbTxn.newDest
               /\ fdbTxn.oldBpGen = fdbTxn.newBpGen
               /\ cacheOrigin[k] /= "mclag"
       IN /\ cache' = [cache EXCEPT ![k] = IF isAdd THEN en ELSE EmptyEntry]
          /\ cacheOrigin' = [cacheOrigin EXCEPT ![k] =
                IF ~isAdd
                THEN "none"
                ELSE IF duplicateLocal
                     THEN cacheOrigin[k]
                     ELSE IF fdbTxn.op = "nhgFdb" THEN "vxlan" ELSE "learn"]
          /\ stateDb' = [stateDb EXCEPT ![k] = IF isAdd THEN en ELSE EmptyEntry]
          \* A new add increments CRM; a delete decrements the removed cache row.
          \* orchagent/fdborch.cpp:197-200,211-234
          /\ crmCount' = crmCount
                + IF isAdd
                  THEN IF fdbTxn.oldPresent THEN 0 ELSE 1
                  ELSE IF fdbTxn.oldPresent THEN -1 ELSE 0
          \* A normal replacement creates fresh FdbData with pending=false.
          \* Same-port non-MCLAG LEARN/MOVE returns as a duplicate before the
          \* FdbData replacement, so the real boolean marker survives even
          \* though the ghost incarnation advances.  fdborch.cpp:145-178
          /\ pendingEpoch' =
                IF duplicateLocal
                THEN pendingEpoch
                ELSE [pendingEpoch EXCEPT ![k] = 0]
          \* Ghost audit records exactly which generation a destructive event
          \* removed; no such comparison exists in C++.  fdborch.cpp:621-631,766-779
          /\ lastDeletion' =
                IF ~isAdd /\ fdbTxn.oldPresent
                THEN [lastDeletion EXCEPT ![k] =
                        [valid      |-> TRUE,
                         cause      |-> fdbTxn.op,
                         eventGen   |-> fdbTxn.eventGen,
                         removedGen |-> fdbTxn.oldGen]]
                ELSE lastDeletion
          \* Flush handler checks type/scope/pending boolean, but not epoch or
          \* incarnation.  orchagent/fdborch.cpp:302-358
          /\ lastFlushCleanup' =
                IF fdbTxn.op = "flush" /\ fdbTxn.oldPresent
                THEN [lastFlushCleanup EXCEPT ![k] =
                        [valid        |-> TRUE,
                         ackEpoch     |-> fdbTxn.ackEpoch,
                         markedEpoch  |-> fdbTxn.markedEpoch,
                         ackGen       |-> fdbTxn.eventGen,
                         removedGen   |-> fdbTxn.oldGen,
                         kindMatched  |-> fdbTxn.entryKind = cache[k].kind,
                         scopeMatched |-> TRUE]]
                ELSE lastFlushCleanup
          \* Replay commits the popped saved generation even if desired intent
          \* has advanced.  orchagent/fdborch.cpp:1766-1787
          /\ appliedIntent' =
                IF fdbTxn.op = "replay"
                THEN [appliedIntent EXCEPT ![k] = en]
                ELSE appliedIntent
          /\ fdbTxn' = [fdbTxn EXCEPT !.phase = "observer"]
    /\ UNCHANGED <<intentVars, hardwareVars, observer, portCount, vlanCount,
                    flushRequestVars, topologyVars, savedVars, graphCoreVars,
                    failureVars, restartVars, eventQueue>>

FdbOrchNotifyObservers ==
    \* Observer delivery follows cache/STATE_DB commit.
    \* orchagent/fdborch.cpp:286-288,581-582,788-790,880-905
    /\ fdbTxn.phase = "observer"
    /\ LET k == fdbTxn.key
           completedMoveRepair ==
               fdbTxn.op = "move" /\ fdbFailure[k] /\ fdbRetry[k]
       IN /\ observer' = [observer EXCEPT ![k] = cache[k]]
          /\ fdbRetry' =
                IF completedMoveRepair
                THEN [fdbRetry EXCEPT ![k] = FALSE]
                ELSE fdbRetry
          /\ fdbCompensated' =
                IF completedMoveRepair
                THEN [fdbCompensated EXCEPT ![k] = TRUE]
                ELSE fdbCompensated
          /\ fdbTxn' = EmptyTxn
    /\ UNCHANGED <<intentVars, hardwareVars, cache, stateDb, eventQueue,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, cacheOrigin, fdbFailure,
                    graphFailure, graphRetry, graphCompensated, restartVars>>

FdbOrchNotificationRepairFailure(e) ==
    \* Remote/static AGE re-create failure returns without retaining work.
    \* The MOVE attribute-repair loop is MCLAG-only, requires a changed bridge
    \* port, and logs failures while the same event continues through normal
    \* cache/state/observer handling.  fdborch.cpp:634-720,823-882
    /\ e \in eventQueue
    /\ fdbTxn.phase = "idle"
    /\ cache[e.key].present
    /\ \/ /\ AgeRecreateRequired(e)
           /\ eventQueue' = eventQueue \ {e}
           /\ fdbFailure' = [fdbFailure EXCEPT ![e.key] = TRUE]
           /\ fdbRetry' =
                 [fdbRetry EXCEPT
                    ![e.key] = HardwareContinuationPending(e.key, e)]
           \* A delayed AGE can race with installation of a newer incarnation.
           \* Its duplicate create may fail with the current ASIC row already
           \* satisfying cache intent; that failure is compensated, not lost
           \* work.  fdborch.cpp:612-720
           /\ fdbCompensated' =
                 [fdbCompensated EXCEPT
                    ![e.key] = AsicSatisfiesCache(e.key)]
       \/ /\ e.kind = "move"
           /\ cacheOrigin[e.key] = "mclag"
           /\ \/ cache[e.key].dest /= e.dest
              \/ cache[e.key].bpGen /= e.bpGen
           \* The queued MOVE is the continuation owner after a logged set
           \* failure; it is not consumed by the repair loop.
           /\ eventQueue' = eventQueue
           /\ fdbFailure' = [fdbFailure EXCEPT ![e.key] = TRUE]
           /\ fdbRetry' = [fdbRetry EXCEPT ![e.key] = TRUE]
           /\ fdbCompensated' = [fdbCompensated EXCEPT ![e.key] = FALSE]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, fdbTxn, counterVars,
                    flushVars, topologyVars, deferredVars, graphCoreVars,
                    graphFailure, graphRetry, graphCompensated, restartVars>>

\* -------------------------------------------------------------------------
\* Scenario 1: flush request -> SAI -> delayed/consolidated ack -> cleanup
\* -------------------------------------------------------------------------

FdbOrchFlushFDBEntriesRequest(scope, p) ==
    \* flushFDBEntries builds port/BV filters and always asks SAI for dynamic.
    \* orchagent/fdborch.cpp:1443-1486
    /\ flushEpoch < MaxFlushEpoch
    /\ fdbTxn.phase = "idle"
    /\ scope \in FlushScopes
    /\ p \in Ports
    /\ LET e == flushEpoch + 1
       IN /\ flushEpoch' = e
          /\ flushScope' = [flushScope EXCEPT ![e] = scope]
          /\ flushPort' = [flushPort EXCEPT ![e] = p]
          /\ flushType' = [flushType EXCEPT ![e] = "dynamic"]
          /\ flushPath' = [flushPath EXCEPT ![e] = "flushFDBEntries"]
          /\ flushStatus' = [flushStatus EXCEPT ![e] = "requested"]
          /\ flushSnapshot' = [flushSnapshot EXCEPT ![e] = cache]
          /\ flushAckCreated' = [flushAckCreated EXCEPT ![e] = FALSE]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushRemoved, ackQueue, pendingEpoch,
                    flushAuditVars,
                    topologyVars, deferredVars, graphCoreVars, failureVars,
                    restartVars>>

FdbOrchFlushFdbByVlanRequest(p) ==
    \* STP's flushFdbByVlan performs the same dynamic SAI call but never marks
    \* cache entries pending.  orchagent/fdborch.cpp:1661-1688;
    \* orchagent/stporch.cpp:363-377
    /\ flushEpoch < MaxFlushEpoch
    /\ fdbTxn.phase = "idle"
    /\ p \in Ports
    /\ LET e == flushEpoch + 1
       IN /\ flushEpoch' = e
          /\ flushScope' = [flushScope EXCEPT ![e] = "vlan"]
          /\ flushPort' = [flushPort EXCEPT ![e] = p]
          /\ flushType' = [flushType EXCEPT ![e] = "dynamic"]
          /\ flushPath' = [flushPath EXCEPT ![e] = "flushFdbByVlan"]
          /\ flushStatus' = [flushStatus EXCEPT ![e] = "requested"]
          /\ flushSnapshot' = [flushSnapshot EXCEPT ![e] = cache]
          /\ flushAckCreated' = [flushAckCreated EXCEPT ![e] = FALSE]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushRemoved, ackQueue, pendingEpoch,
                    flushAuditVars,
                    topologyVars, deferredVars, graphCoreVars, failureVars,
                    restartVars>>

SaiFlushSuccess(e) ==
    \* The synchronous SAI call removes only entries matching dynamic type.
    \* orchagent/fdborch.cpp:1479-1489
    /\ e \in Epochs
    /\ flushStatus[e] = "requested"
    \* Record the execution-time ASIC incarnations actually removed.  The
    \* request snapshot can be older when hardware changes during the call.
    /\ flushRemoved' = [flushRemoved EXCEPT ![e] =
          [k \in Keys |->
              IF asic[k].present
                 /\ ScopeMatchesEpoch(e, asic[k])
                 /\ asic[k].kind = flushType[e]
              THEN asic[k]
              ELSE EmptyEntry]]
    /\ asic' = [k \in Keys |->
          IF asic[k].present
             /\ ScopeMatchesEpoch(e, asic[k])
             /\ asic[k].kind = flushType[e]
          THEN EmptyEntry
          ELSE asic[k]]
    \* On the standard path, every scoped cache row is marked pending even
    \* when its type is static.  The STP path marks none.
    \* orchagent/fdborch.cpp:1298-1317,1492-1501,1661-1688
    /\ pendingEpoch' = [k \in Keys |->
          IF flushPath[e] = "flushFDBEntries"
             /\ cache[k].present
             /\ ScopeMatchesEpoch(e, cache[k])
          THEN e
          ELSE pendingEpoch[k]]
    /\ flushStatus' = [flushStatus EXCEPT ![e] = "asicDone"]
    /\ UNCHANGED <<intentVars, generation, kernel, softwareVars, eventVars,
                    counterVars, flushEpoch, flushScope, flushPort, flushType,
                    flushPath, flushSnapshot, flushAckCreated, ackQueue,
                    flushAuditVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

SaiFlushFailure(e) ==
    \* flushFDBEntries logs failure and returns void to topology callers.
    \* orchagent/fdborch.cpp:1484-1490; portsorch.cpp:7505-7510
    /\ e \in Epochs
    /\ flushStatus[e] = "requested"
    /\ flushStatus' = [flushStatus EXCEPT ![e] = "failed"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushEpoch, flushScope, flushPort, flushType,
                    flushPath, flushSnapshot, flushRemoved, flushAckCreated,
                    ackQueue,
                    pendingEpoch, flushAuditVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, restartVars>>

SaiEnqueueFlushAck(e, id) ==
    \* syncd may emit one consolidated FLUSHED notification; its ghost snapshot
    \* records the request's old incarnations.  fdborch.cpp:299-310,1407-1425
    /\ e \in Epochs
    /\ flushStatus[e] = "asicDone"
    /\ ~flushAckCreated[e]
    /\ id \in AckIds \ UsedAckIds
    /\ LET ks == {k \in Keys :
                    flushSnapshot[e][k].present
                    /\ ScopeMatchesEpoch(e, flushSnapshot[e][k])
                    /\ flushSnapshot[e][k].kind = flushType[e]}
       IN /\ ks /= {}
          /\ ackQueue' = ackQueue \cup
                {[id       |-> id,
                  epoch    |-> e,
                  keys     |-> ks,
                  kind     |-> flushType[e],
                  scope    |-> flushScope[e],
                  port     |-> flushPort[e],
                  snapshot |-> flushSnapshot[e]]}
    /\ flushAckCreated' = [flushAckCreated EXCEPT ![e] = TRUE]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushEpoch, flushScope, flushPort, flushType,
                    flushPath, flushStatus, flushSnapshot, flushRemoved,
                    pendingEpoch,
                    flushAuditVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

SaiDuplicateFlushAck(a, id) ==
    \* Duplicate delivery has no implementation-level epoch/deduplication key.
    \* orchagent/fdborch.cpp:294-368,909-925
    /\ a \in ackQueue
    /\ id \in AckIds \ UsedAckIds
    /\ ackQueue' = ackQueue \cup {[a EXCEPT !.id = id]}
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushEpoch, flushScope, flushPort, flushType,
                    flushPath, flushStatus, flushSnapshot, flushRemoved,
                    flushAckCreated,
                    pendingEpoch, flushAuditVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, restartVars>>

FdbOrchHandleSyncdFlushNotif(a, k) ==
    \* Handler matches key/scope/type plus the current boolean pending marker.
    \* It deliberately does not compare request epoch or incarnation.
    \* orchagent/fdborch.cpp:294-358
    /\ a \in ackQueue
    /\ k \in a.keys
    /\ fdbTxn.phase = "idle"
    /\ cache[k].present
    /\ cache[k].kind = a.kind
    /\ ScopeMatchesAck(a, cache[k])
    /\ pendingEpoch[k] > 0
    \* clearFdbEntry runs counter, cache/STATE_DB/CRM, and observer steps.
    \* orchagent/fdborch.cpp:241-288
    /\ LET old == cache[k]
       IN fdbTxn' =
            [phase        |-> "counter",
             op           |-> "flush",
             key          |-> k,
             eventGen     |-> a.snapshot[k].gen,
             newDest      |-> "none",
             newBpGen     |-> 0,
             entryKind    |-> a.kind,
             oldPresent   |-> old.present,
             oldGen       |-> old.gen,
             oldDest      |-> old.dest,
             oldBpGen     |-> old.bpGen,
             ackEpoch     |-> a.epoch,
             markedEpoch  |-> pendingEpoch[k]]
    /\ ackQueue' = AckQueueAfterKey(a, k)
    /\ flushStatus' =
          IF a.keys = {k}
          THEN [flushStatus EXCEPT ![a.epoch] = "acked"]
          ELSE flushStatus
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventQueue,
                    counterVars, flushEpoch, flushScope, flushPort, flushType,
                    flushPath, flushSnapshot, flushRemoved, flushAckCreated,
                    pendingEpoch,
                    flushAuditVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

FdbOrchIgnoreSyncdFlushNotif(a, k) ==
    \* Nonmatching type/scope/pending entries are skipped by the flush loops.
    \* orchagent/fdborch.cpp:307-309,322-324,338-340,352-364
    /\ a \in ackQueue
    /\ k \in a.keys
    /\ fdbTxn.phase = "idle"
    /\ \/ ~cache[k].present
       \/ cache[k].kind /= a.kind
       \/ ~ScopeMatchesAck(a, cache[k])
       \/ pendingEpoch[k] = 0
    /\ ackQueue' = AckQueueAfterKey(a, k)
    /\ flushStatus' =
          IF a.keys = {k}
          THEN [flushStatus EXCEPT ![a.epoch] = "acked"]
          ELSE flushStatus
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushEpoch, flushScope, flushPort, flushType,
                    flushPath, flushSnapshot, flushRemoved, flushAckCreated,
                    pendingEpoch,
                    flushAuditVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

\* -------------------------------------------------------------------------
\* Scenarios 1/4: VLAN-member and bridge-port teardown/recreation
\* -------------------------------------------------------------------------

PortsOrchRemoveVlanMember(p) ==
    \* SAI VLAN-member removal precedes cache/refcount update and notification.
    \* orchagent/portsorch.cpp:8060-8114
    /\ vlanMember[p]
    /\ removalPhase[p] = "active"
    /\ vlanMember' = [vlanMember EXCEPT ![p] = FALSE]
    /\ removalPhase' = [removalPhase EXCEPT ![p] = "memberRemoved"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, bpGeneration, bpPresent,
                    removalFlushEpoch, lastRemovedGeneration, deferredVars,
                    graphCoreVars, failureVars, restartVars>>

PortsOrchRemoveBridgePortBegin(p) ==
    \* removeBridgePort first sets admin down, hostif mode, and removes STP.
    \* orchagent/portsorch.cpp:7470-7504
    /\ bpPresent[p]
    /\ removalPhase[p] \in {"active", "memberRemoved"}
    /\ removalPhase' = [removalPhase EXCEPT ![p] = "adminDown"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, bpGeneration, bpPresent,
                    vlanMember, removalFlushEpoch, lastRemovedGeneration,
                    deferredVars, graphCoreVars, failureVars, restartVars>>

PortsOrchRemoveBridgePortFlushFDBEntries(p) ==
    \* removeBridgePort calls the void flushFDBEntries before removing the BP.
    \* orchagent/portsorch.cpp:7505-7510; fdborch.cpp:1443-1503
    /\ removalPhase[p] = "adminDown"
    /\ flushEpoch < MaxFlushEpoch
    /\ LET e == flushEpoch + 1
       IN /\ flushEpoch' = e
          /\ flushScope' = [flushScope EXCEPT ![e] = "port"]
          /\ flushPort' = [flushPort EXCEPT ![e] = p]
          /\ flushType' = [flushType EXCEPT ![e] = "dynamic"]
          /\ flushPath' = [flushPath EXCEPT ![e] = "flushFDBEntries"]
          /\ flushStatus' = [flushStatus EXCEPT ![e] = "requested"]
          /\ flushSnapshot' = [flushSnapshot EXCEPT ![e] = cache]
          /\ flushAckCreated' = [flushAckCreated EXCEPT ![e] = FALSE]
          /\ removalFlushEpoch' = [removalFlushEpoch EXCEPT ![p] = e]
    /\ removalPhase' = [removalPhase EXCEPT ![p] = "awaitFlush"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushRemoved, ackQueue, pendingEpoch,
                    flushAuditVars,
                    bpGeneration, bpPresent, vlanMember,
                    lastRemovedGeneration, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

PortsOrchRemoveBridgePortSaiRemove(p) ==
    \* The caller cannot observe flush failure; after the synchronous call
    \* returns, it removes the bridge port without waiting for FLUSHED cleanup.
    \* orchagent/portsorch.cpp:7505-7531
    /\ removalPhase[p] = "awaitFlush"
    /\ removalFlushEpoch[p] > 0
    /\ flushStatus[removalFlushEpoch[p]] \in {"asicDone", "failed", "acked"}
    /\ bpPresent' = [bpPresent EXCEPT ![p] = FALSE]
    /\ vlanMember' = [vlanMember EXCEPT ![p] = FALSE]
    /\ lastRemovedGeneration' =
          [lastRemovedGeneration EXCEPT ![p] = bpGeneration[p]]
    /\ removalPhase' = [removalPhase EXCEPT ![p] = "removed"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, bpGeneration, removalFlushEpoch,
                    deferredVars, graphCoreVars, failureVars, restartVars>>

PortsOrchRecreateBridgePort(p) ==
    \* addBridgePort publishes a new SAI bridge-port object and observer update.
    \* A newly created tunnel Port begins with a fresh FDB counter.
    \* orchagent/portsorch.cpp:7441-7467
    /\ removalPhase[p] = "removed"
    /\ bpGeneration[p] < MaxGeneration
    /\ bpGeneration' = [bpGeneration EXCEPT ![p] = @ + 1]
    /\ bpPresent' = [bpPresent EXCEPT ![p] = TRUE]
    /\ vlanMember' = [vlanMember EXCEPT ![p] = TRUE]
    /\ removalPhase' = [removalPhase EXCEPT ![p] = "active"]
    /\ portCount' = [portCount EXCEPT ![p] = 0]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    crmCount, vlanCount, flushVars, removalFlushEpoch,
                    lastRemovedGeneration, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

\* -------------------------------------------------------------------------
\* Scenario 3: append-only saved work and consume-without-apply
\* -------------------------------------------------------------------------

FdbOrchSubmitSet(k, p) ==
    \* Missing port/BP/VLAN membership appends a SavedFdbEntry and returns true.
    \* orchagent/fdborch.cpp:1842-1871
    /\ ~dependencyReady[k]
    /\ desiredGen[k] < MaxGeneration
    /\ LET g == desiredGen[k] + 1
       IN /\ desiredGen' = [desiredGen EXCEPT ![k] = g]
          /\ desiredOp' = [desiredOp EXCEPT ![k] = "set"]
          /\ desiredDest' = [desiredDest EXCEPT ![k] = p]
          \* SavedFdbEntry equality excludes destination/value generation, so
          \* successive SETs append independent copies.  fdborch.h:96-105
          /\ saved' = [saved EXCEPT ![k] =
                Append(@, [gen |-> g, op |-> "set", dest |-> p])]
    /\ UNCHANGED <<hardwareVars, softwareVars, eventVars, counterVars,
                    flushVars, topologyVars, dependencyReady, wakeup,
                    acknowledgedGen, appliedIntent, graphCoreVars,
                    failureVars, restartVars>>

FdbOrchSubmitDelete(k) ==
    \* When the live cache misses, removeFdbEntry calls
    \* deleteFdbEntryFromSavedFDB.  orchagent/fdborch.cpp:2324-2331
    /\ ~cache[k].present
    /\ desiredGen[k] < MaxGeneration
    /\ LET g == desiredGen[k] + 1
       IN /\ desiredGen' = [desiredGen EXCEPT ![k] = g]
          /\ desiredOp' = [desiredOp EXCEPT ![k] = "del"]
          /\ desiredDest' = [desiredDest EXCEPT ![k] = "none"]
    \* The delete loop erases one matching vector element and breaks, leaving
    \* any later saved SET for replay.  fdborch.cpp:2455-2489
    /\ saved' = [saved EXCEPT ![k] =
                    IF Len(@) > 0 THEN Tail(@) ELSE @]
    /\ UNCHANGED <<hardwareVars, softwareVars, eventVars, counterVars,
                    flushVars, topologyVars, dependencyReady, wakeup,
                    acknowledgedGen, appliedIntent, graphCoreVars,
                    failureVars, restartVars>>

FdbOrchUpdateVlanMemberDependencyAppears(k) ==
    \* VLAN-member add notification is the wakeup that replays saved entries.
    \* orchagent/fdborch.cpp:1753-1787
    /\ ~dependencyReady[k]
    /\ dependencyReady' = [dependencyReady EXCEPT ![k] = TRUE]
    /\ wakeup' = [wakeup EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, saved,
                    acknowledgedGen, appliedIntent, graphCoreVars,
                    failureVars, restartVars>>

FdbOrchUpdateVlanMemberReplay(k) ==
    \* updateVlanMember moves the vector, clears it, and invokes addFdbEntry
    \* for each saved item in original order.  fdborch.cpp:1766-1787
    /\ dependencyReady[k]
    /\ wakeup[k]
    /\ Len(saved[k]) > 0
    /\ fdbTxn.phase = "idle"
    /\ LET item == Head(saved[k])
           old == cache[k]
       IN fdbTxn' =
            [phase        |-> "sai",
             op           |-> "replay",
             key          |-> k,
             eventGen     |-> item.gen,
             newDest      |-> item.dest,
             newBpGen     |-> bpGeneration[item.dest],
             entryKind    |-> "dynamic",
             oldPresent   |-> old.present,
             oldGen       |-> old.gen,
             oldDest      |-> old.dest,
             oldBpGen     |-> old.bpGen,
             ackEpoch     |-> 0,
             markedEpoch  |-> pendingEpoch[k]]
    /\ saved' = [saved EXCEPT ![k] = Tail(@)]
    /\ wakeup' = [wakeup EXCEPT ![k] = Len(saved[k]) > 1]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventQueue,
                    counterVars, flushVars, topologyVars, dependencyReady,
                    acknowledgedGen, appliedIntent, graphCoreVars,
                    failureVars, restartVars>>

FdbOrchAddFdbEntrySaiCreateSuccess ==
    \* addFdbEntry performs the SAI create before cache/counter/state commits.
    \* orchagent/fdborch.cpp:2195-2223
    /\ fdbTxn.phase = "sai"
    /\ fdbTxn.op = "replay"
    /\ LET k == fdbTxn.key
           en == MakeEntry(fdbTxn.eventGen, fdbTxn.newDest,
                           fdbTxn.newBpGen, fdbTxn.entryKind)
       IN /\ generation' = [generation EXCEPT ![k] =
                              IF generation[k] < fdbTxn.eventGen
                              THEN fdbTxn.eventGen ELSE generation[k]]
          /\ asic' = [asic EXCEPT ![k] = en]
    /\ fdbTxn' = [fdbTxn EXCEPT !.phase = "counter"]
    /\ UNCHANGED <<intentVars, kernel, softwareVars, eventQueue, counterVars,
                    flushVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

FdbOrchAddFdbEntrySaiCreateFailure ==
    \* A ready-dependency SAI create failure returns false; updateVlanMember
    \* ignores the return and the moved saved item is not restored.
    \* orchagent/fdborch.cpp:1766-1787,2195-2208
    /\ fdbTxn.phase = "sai"
    /\ fdbTxn.op = "replay"
    /\ fdbFailure' = [fdbFailure EXCEPT ![fdbTxn.key] = TRUE]
    /\ fdbRetry' = [fdbRetry EXCEPT ![fdbTxn.key] = FALSE]
    /\ fdbCompensated' = [fdbCompensated EXCEPT ![fdbTxn.key] = FALSE]
    /\ fdbTxn' = EmptyTxn
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventQueue,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, graphFailure, graphRetry, graphCompensated,
                    restartVars>>

EvpnRemoteVnip2pOrchAddOperationConsumeWithoutApply(k) ==
    \* Missing source VTEP returns true, so Orch acknowledges and erases the
    \* remote-VNI SET instead of retaining retry ownership.
    \* orchagent/vxlanorch.cpp:2503-2528,2665-2697
    /\ desiredGen[k] > 0
    /\ desiredOp[k] = "set"
    /\ ~dependencyReady[k]
    /\ acknowledgedGen' = [acknowledgedGen EXCEPT ![k] = desiredGen[k]]
    /\ fdbFailure' = [fdbFailure EXCEPT ![k] = TRUE]
    /\ fdbRetry' = [fdbRetry EXCEPT ![k] = FALSE]
    /\ fdbCompensated' = [fdbCompensated EXCEPT ![k] = FALSE]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, saved,
                    dependencyReady, wakeup, appliedIntent, graphCoreVars,
                    graphFailure, graphRetry, graphCompensated, restartVars>>

\* -------------------------------------------------------------------------
\* Scenario 4: one-member-at-a-time NHG creation and VTEP replacement
\* -------------------------------------------------------------------------

L2NhgAddL2NextHopGroupBegin(g, ep) ==
    \* New group SAI object is cached before any member is created.
    \* orchagent/l2nhgorch.cpp:285-312
    /\ graphPhase[g] = "empty"
    /\ nhgMembers[g] = {}
    /\ graphDesiredEndpoint' = [graphDesiredEndpoint EXCEPT ![g] = ep]
    /\ graphPhase' = [graphPhase EXCEPT ![g] = "groupCreated"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    nhgMembers, nhgActive, nhgBridgePort, tunnelRefs,
                    replacement, failureVars, restartVars>>

L2NhgAddL2NextHopGroupMember(g) ==
    \* createSaiNextHop returns both member/NH OIDs, then the cache and endpoint
    \* reference count commit.  orchagent/l2nhgorch.cpp:385-422
    /\ graphPhase[g] = "groupCreated"
    /\ graphDesiredEndpoint[g] \in Endpoints
    /\ LET ep == graphDesiredEndpoint[g]
       IN /\ nhgMembers' = [nhgMembers EXCEPT ![g] = @ \cup {ep}]
          /\ tunnelRefs' = [tunnelRefs EXCEPT ![ep] = @ + 1]
    /\ graphPhase' = [graphPhase EXCEPT ![g] = "memberCreated"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    nhgActive, nhgBridgePort, graphDesiredEndpoint,
                    replacement, failureVars, restartVars>>

PortsOrchAddBridgePortL2Nhg(g) ==
    \* A nonempty group receives a bridge port and is then marked active.
    \* orchagent/l2nhgorch.cpp:432-495
    /\ graphPhase[g] = "memberCreated"
    /\ nhgMembers[g] /= {}
    /\ nhgBridgePort' = [nhgBridgePort EXCEPT ![g] = TRUE]
    /\ nhgActive' = [nhgActive EXCEPT ![g] = TRUE]
    /\ graphPhase' = [graphPhase EXCEPT ![g] = "stable"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    nhgMembers, tunnelRefs, graphDesiredEndpoint, replacement,
                    failureVars, restartVars>>

FdbOrchAddNhgReference(k, g) ==
    \* FdbOrch accepts a destination once hasActiveL2Nhg is true; it does not
    \* re-check member completeness.  fdborch.cpp:1176-1185
    /\ nhgActive[g]
    \* L2NhgOrch finishes its synchronous VTEP replacement call before the
    \* serialized orchagent loop can dispatch another consumer item.
    /\ ~replacement.active
    /\ fdbTxn.phase = "idle"
    /\ generation[k] < MaxGeneration
    /\ LET ng == generation[k] + 1
           old == cache[k]
           en == MakeEntry(ng, g, 0, "static")
       IN /\ generation' = [generation EXCEPT ![k] = ng]
          \* SAI create precedes cache/counter commit.  fdborch.cpp:2195-2223
          /\ asic' = [asic EXCEPT ![k] = en]
          /\ fdbTxn' =
                [phase        |-> "counter",
                 op           |-> "nhgFdb",
                 key          |-> k,
                 eventGen     |-> ng,
                 newDest      |-> g,
                 newBpGen     |-> 0,
                 entryKind    |-> "static",
                 oldPresent   |-> old.present,
                 oldGen       |-> old.gen,
                 oldDest      |-> old.dest,
                 oldBpGen     |-> old.bpGen,
                 ackEpoch     |-> 0,
                 markedEpoch  |-> pendingEpoch[k]]
    /\ UNCHANGED <<intentVars, kernel, softwareVars, eventQueue, counterVars,
                    flushVars, topologyVars, deferredVars, graphCoreVars,
                    failureVars, restartVars>>

L2NhgUpdateVtepIpBegin(oldEp, newEp) ==
    \* updateL2NhgVtepIp enumerates every group containing the logical NH.
    \* orchagent/l2nhgorch.cpp:581-605
    /\ ~replacement.active
    /\ fdbTxn.phase = "idle"
    /\ oldEp /= newEp
    /\ \E g \in Groups : oldEp \in nhgMembers[g]
    \* addL2NextHopGroupEntry creates members, the bridge port, and active
    \* publication synchronously before another consumer item is dispatched.
    /\ \A g \in Groups : oldEp \in nhgMembers[g] => graphPhase[g] = "stable"
    /\ replacement' = [active |-> TRUE, old |-> oldEp, new |-> newEp]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    nhgMembers, nhgActive, nhgBridgePort, tunnelRefs,
                    graphPhase, graphDesiredEndpoint, failureVars, restartVars>>

L2NhgUpdateVtepIpRemoveOld(g) ==
    \* Old SAI NH/member is removed and erased before new creation.
    \* orchagent/l2nhgorch.cpp:596-623
    /\ replacement.active
    /\ replacement.old \in nhgMembers[g]
    /\ graphPhase[g] = "stable"
    /\ nhgMembers' = [nhgMembers EXCEPT ![g] = @ \ {replacement.old}]
    /\ tunnelRefs' = [tunnelRefs EXCEPT ![replacement.old] = @ - 1]
    /\ graphPhase' = [graphPhase EXCEPT ![g] = "oldRemoved"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    nhgActive, nhgBridgePort, graphDesiredEndpoint, replacement,
                    failureVars, restartVars>>

L2NhgUpdateVtepIpCreateNew(g) ==
    \* New member is cached, but the implementation increments
    \* m_nhg_vtep[nh_id].ip before line 653 changes it; therefore the old
    \* endpoint receives the increment.  l2nhgorch.cpp:625-635,653-654
    /\ replacement.active
    /\ graphPhase[g] = "oldRemoved"
    /\ nhgMembers' = [nhgMembers EXCEPT ![g] = @ \cup {replacement.new}]
    /\ tunnelRefs' = [tunnelRefs EXCEPT ![replacement.old] = @ + 1]
    /\ graphPhase' = [graphPhase EXCEPT ![g] = "replaced"]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    nhgActive, nhgBridgePort, graphDesiredEndpoint, replacement,
                    failureVars, restartVars>>

L2NhgUpdateVtepIpCreateFailure(g) ==
    \* Failure returns after old membership/ref removal; the caller retains its
    \* consumer item for retry.  l2nhgorch.cpp:625-647,726-734
    /\ replacement.active
    /\ graphPhase[g] = "oldRemoved"
    /\ graphPhase' = [graphPhase EXCEPT ![g] = "retry"]
    /\ graphFailure' = [graphFailure EXCEPT ![g] = TRUE]
    /\ graphRetry' = [graphRetry EXCEPT ![g] = TRUE]
    /\ graphCompensated' = [graphCompensated EXCEPT ![g] = FALSE]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    nhgMembers, nhgActive, nhgBridgePort, tunnelRefs,
                    graphDesiredEndpoint, replacement, fdbFailure, fdbRetry,
                    fdbCompensated, restartVars>>

L2NhgUpdateVtepIpRetryAfterFailure(g) ==
    \* On retry, has_next_hop no longer finds the erased membership, so the loop
    \* can finish by updating only the cached endpoint IP.  l2nhgorch.cpp:596-600,648-654
    /\ graphPhase[g] = "retry"
    /\ graphRetry[g]
    /\ graphPhase' = [graphPhase EXCEPT ![g] = "stable"]
    /\ graphFailure' = [graphFailure EXCEPT ![g] = FALSE]
    /\ graphRetry' = [graphRetry EXCEPT ![g] = FALSE]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    nhgMembers, nhgActive, nhgBridgePort, tunnelRefs,
                    graphDesiredEndpoint, replacement,
                    fdbFailure, fdbRetry, fdbCompensated,
                    graphCompensated, restartVars>>

L2NhgUpdateVtepIpFinish ==
    \* The function updates the logical endpoint only after all per-group work.
    \* orchagent/l2nhgorch.cpp:648-654
    /\ replacement.active
    /\ \A g \in Groups : replacement.old \notin nhgMembers[g]
    /\ replacement' = EmptyReplacement
    /\ graphPhase' = [g \in Groups |->
          IF graphPhase[g] = "replaced" THEN "stable" ELSE graphPhase[g]]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    nhgMembers, nhgActive, nhgBridgePort, tunnelRefs,
                    graphDesiredEndpoint, failureVars, restartVars>>

EvpnRemoteVnip2pOrchIgnoredSaiFailure(g) ==
    \* addOperation ignores addTunnelUser/addVlanMember return values and then
    \* acknowledges success.  orchagent/vxlanorch.cpp:2570-2586,2741-2746
    /\ graphPhase[g] \in {"groupCreated", "memberCreated", "stable"}
    /\ graphFailure' = [graphFailure EXCEPT ![g] = TRUE]
    /\ graphRetry' = [graphRetry EXCEPT ![g] = FALSE]
    /\ graphCompensated' = [graphCompensated EXCEPT ![g] = FALSE]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, fdbFailure, fdbRetry, fdbCompensated,
                    restartVars>>

\* -------------------------------------------------------------------------
\* Scenario 5: restart ordering and one-shot NHG dump loss
\* -------------------------------------------------------------------------

KernelNhgChangeWhileDown(g) ==
    \* Kernel objects can change while fdbsyncd is not consuming netlink.
    \* The next startup dump is the only reconstruction stimulus.
    \* fdbsyncd/fdbsyncd.cpp:27-31,77-96
    /\ restartPhase = "down"
    /\ kernelNhg' = [kernelNhg EXCEPT ![g] = ~@]
    /\ restartSettled' = FALSE
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, restartPhase, nvoReady, appNhg,
                    dumpSeen, missedDump, warmReplayDone>>

FdbSyncCrash ==
    \* Process crash loses in-memory readiness/map state while Redis/kernel
    \* planes continue independently.  fdbsyncd/fdbsync.cpp:35-45
    /\ restartPhase = "running"
    /\ restartPhase' = "down"
    /\ nvoReady' = FALSE
    /\ dumpSeen' = [g \in Groups |-> FALSE]
    /\ missedDump' = [g \in Groups |-> FALSE]
    /\ warmReplayDone' = FALSE
    /\ restartSettled' = FALSE
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, kernelNhg, appNhg>>

FdbSyncStart ==
    \* main registers groups and begins link/NHG dumps before CONFIG_DB is
    \* selected in the steady loop.  fdbsyncd/fdbsyncd.cpp:77-115
    /\ restartPhase = "down"
    /\ restartPhase' = "starting"
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, nvoReady, kernelNhg, appNhg,
                    dumpSeen, missedDump, warmReplayDone, restartSettled>>

FdbSyncDumpKernelNhg(g) ==
    \* onMsgNhg returns immediately when NVO is absent; no queue or warm-assist
    \* entry retains this one-shot dump item.  fdbsync.cpp:1138-1144;
    \* fdbsyncd/fdbsync.cpp:40-45
    /\ restartPhase = "starting"
    /\ ~nvoReady
    /\ ~dumpSeen[g]
    /\ dumpSeen' = [dumpSeen EXCEPT ![g] = TRUE]
    /\ missedDump' = [missedDump EXCEPT ![g] = kernelNhg[g]]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, restartPhase, nvoReady,
                    kernelNhg, appNhg, warmReplayDone, restartSettled>>

FdbSyncProcessCfgEvpnNvo ==
    \* CONFIG NVO toggles readiness and updates local MAC state, but it does not
    \* replay skipped NHG messages.  fdbsync.cpp:111-136
    /\ restartPhase = "starting"
    \* The startup path issues and selects the GETNEXTHOP dump before adding the
    \* CONFIG_DB table to the steady-state loop.  fdbsyncd.cpp:77-100
    /\ \A g \in Groups : dumpSeen[g]
    /\ nvoReady' = TRUE
    /\ restartPhase' = "configReady"
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, kernelNhg, appNhg, dumpSeen,
                    missedDump, warmReplayDone, restartSettled>>

FdbSyncWarmReplay ==
    \* AppRestartAssist registers VXLAN_FDB and REMOTE_VNI, not the L2 NHG
    \* table, so replay leaves appNhg untouched.  fdbsync.cpp:40-45;
    \* fdbsyncd.cpp:45-74,117-130
    /\ restartPhase = "configReady"
    /\ warmReplayDone' = TRUE
    /\ restartPhase' = "warmReplayed"
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, nvoReady, kernelNhg, appNhg,
                    dumpSeen, missedDump, restartSettled>>

FdbSyncBake ==
    \* Warm replay completion/bake is a separate stage from snapshot enumeration.
    \* orchagent/fdborch.cpp:107-120; fdbsyncd/fdbsyncd.cpp:117-130
    /\ restartPhase = "warmReplayed"
    /\ warmReplayDone
    /\ restartPhase' = "baked"
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, nvoReady, kernelNhg, appNhg,
                    dumpSeen, missedDump, warmReplayDone, restartSettled>>

FdbSyncReconcile ==
    \* Final reconciliation has no retained NHG delta to replay.
    \* fdbsyncd/fdbsyncd.cpp:117-130; fdbsync.cpp:1138-1144
    /\ restartPhase = "baked"
    /\ restartPhase' = "running"
    /\ restartSettled' = TRUE
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, nvoReady, kernelNhg, appNhg,
                    dumpSeen, missedDump, warmReplayDone>>

FdbSyncLiveNhgEvent(g) ==
    \* A later live event can repair the lost startup state, but no such event is
    \* guaranteed.  fdbsync.cpp:1138-1297
    /\ restartPhase = "running"
    /\ nvoReady
    /\ appNhg[g] /= kernelNhg[g]
    /\ appNhg' = [appNhg EXCEPT ![g] = kernelNhg[g]]
    /\ UNCHANGED <<intentVars, hardwareVars, softwareVars, eventVars,
                    counterVars, flushVars, topologyVars, deferredVars,
                    graphCoreVars, failureVars, restartPhase, nvoReady,
                    kernelNhg, dumpSeen, missedDump, warmReplayDone,
                    restartSettled>>

\* -------------------------------------------------------------------------
\* Next-state relation
\* -------------------------------------------------------------------------

Next ==
    \/ \E k \in Keys, p \in Ports, id \in EventIds : SaiLearnEvent(k, p, id)
    \/ \E k \in Keys, p \in Ports, id \in EventIds : SaiMoveEvent(k, p, id)
    \/ \E k \in Keys, id \in EventIds : SaiAgeEvent(k, id)
    \/ \E e \in eventQueue, id \in EventIds : SaiDuplicateEvent(e, id)
    \/ \E e \in eventQueue : FdbOrchUpdateStart(e)
    \/ \E e \in eventQueue : FdbOrchIgnoreAgedEvent(e)
    \/ \E e \in eventQueue : FdbOrchNotificationRepairComplete(e)
    \/ FdbOrchUpdateCounters
    \/ FdbOrchStoreFdbEntryState
    \/ FdbOrchNotifyObservers
    \/ \E e \in eventQueue : FdbOrchNotificationRepairFailure(e)
    \/ \E scope \in FlushScopes, p \in Ports :
           FdbOrchFlushFDBEntriesRequest(scope, p)
    \/ \E p \in Ports : FdbOrchFlushFdbByVlanRequest(p)
    \/ \E e \in Epochs : SaiFlushSuccess(e)
    \/ \E e \in Epochs : SaiFlushFailure(e)
    \/ \E e \in Epochs, id \in AckIds : SaiEnqueueFlushAck(e, id)
    \/ \E a \in ackQueue, id \in AckIds : SaiDuplicateFlushAck(a, id)
    \/ \E a \in ackQueue, k \in Keys : FdbOrchHandleSyncdFlushNotif(a, k)
    \/ \E a \in ackQueue, k \in Keys : FdbOrchIgnoreSyncdFlushNotif(a, k)
    \/ \E p \in Ports : PortsOrchRemoveVlanMember(p)
    \/ \E p \in Ports : PortsOrchRemoveBridgePortBegin(p)
    \/ \E p \in Ports : PortsOrchRemoveBridgePortFlushFDBEntries(p)
    \/ \E p \in Ports : PortsOrchRemoveBridgePortSaiRemove(p)
    \/ \E p \in Ports : PortsOrchRecreateBridgePort(p)
    \/ \E k \in Keys, p \in Ports : FdbOrchSubmitSet(k, p)
    \/ \E k \in Keys : FdbOrchSubmitDelete(k)
    \/ \E k \in Keys : FdbOrchUpdateVlanMemberDependencyAppears(k)
    \/ \E k \in Keys : FdbOrchUpdateVlanMemberReplay(k)
    \/ FdbOrchAddFdbEntrySaiCreateSuccess
    \/ FdbOrchAddFdbEntrySaiCreateFailure
    \/ \E k \in Keys : EvpnRemoteVnip2pOrchAddOperationConsumeWithoutApply(k)
    \/ \E g \in Groups, ep \in Endpoints : L2NhgAddL2NextHopGroupBegin(g, ep)
    \/ \E g \in Groups : L2NhgAddL2NextHopGroupMember(g)
    \/ \E g \in Groups : PortsOrchAddBridgePortL2Nhg(g)
    \/ \E k \in Keys, g \in Groups : FdbOrchAddNhgReference(k, g)
    \/ \E oldEp, newEp \in Endpoints : L2NhgUpdateVtepIpBegin(oldEp, newEp)
    \/ \E g \in Groups : L2NhgUpdateVtepIpRemoveOld(g)
    \/ \E g \in Groups : L2NhgUpdateVtepIpCreateNew(g)
    \/ \E g \in Groups : L2NhgUpdateVtepIpCreateFailure(g)
    \/ \E g \in Groups : L2NhgUpdateVtepIpRetryAfterFailure(g)
    \/ L2NhgUpdateVtepIpFinish
    \/ \E g \in Groups : EvpnRemoteVnip2pOrchIgnoredSaiFailure(g)
    \/ FdbSyncCrash
    \/ \E g \in Groups : KernelNhgChangeWhileDown(g)
    \/ FdbSyncStart
    \/ \E g \in Groups : FdbSyncDumpKernelNhg(g)
    \/ FdbSyncProcessCfgEvpnNvo
    \/ FdbSyncWarmReplay
    \/ FdbSyncBake
    \/ FdbSyncReconcile
    \/ \E g \in Groups : FdbSyncLiveNhgEvent(g)

Spec == Init /\ [][Next]_vars

\* -------------------------------------------------------------------------
\* Structural and standard safety invariants
\* -------------------------------------------------------------------------

TypeOK ==
    /\ desiredGen \in [Keys -> 0..MaxGeneration]
    /\ desiredOp \in [Keys -> IntentOps]
    /\ desiredDest \in [Keys -> Ports \cup {"none"}]
    /\ generation \in [Keys -> 0..MaxGeneration]
    /\ kernel \in [Keys -> EntryType]
    /\ cache \in [Keys -> EntryType]
    /\ cacheOrigin \in [Keys -> FdbOrigins]
    /\ stateDb \in [Keys -> EntryType]
    /\ asic \in [Keys -> EntryType]
    /\ observer \in [Keys -> EntryType]
    /\ eventQueue \subseteq
         [id        : EventIds,
          kind      : EventKinds,
          key       : Keys,
          gen       : 1..MaxGeneration,
          dest      : Destinations,
          bpGen     : 0..MaxGeneration,
          entryKind : EntryKinds]
    /\ fdbTxn \in
         [phase       : TxnPhases,
          op          : TxnOps,
          key         : Keys \cup {"none"},
          eventGen    : 0..MaxGeneration,
          newDest     : Destinations \cup {"none"},
          newBpGen    : 0..MaxGeneration,
          entryKind   : EntryKinds,
          oldPresent  : BOOLEAN,
          oldGen      : 0..MaxGeneration,
          oldDest     : Destinations \cup {"none"},
          oldBpGen    : 0..MaxGeneration,
          ackEpoch    : 0..MaxFlushEpoch,
          markedEpoch : 0..MaxFlushEpoch]
    /\ crmCount \in Int
    /\ portCount \in [Ports -> Int]
    /\ vlanCount \in Int
    /\ flushEpoch \in 0..MaxFlushEpoch
    /\ flushScope \in [Epochs -> FlushScopes]
    /\ flushPort \in [Epochs -> Ports \cup {"none"}]
    /\ flushType \in [Epochs -> EntryKinds]
    /\ flushPath \in [Epochs -> FlushPaths]
    /\ flushStatus \in [Epochs -> FlushStatuses]
    /\ flushSnapshot \in [Epochs -> [Keys -> EntryType]]
    /\ flushRemoved \in [Epochs -> [Keys -> EntryType]]
    /\ flushAckCreated \in [Epochs -> BOOLEAN]
    /\ ackQueue \subseteq
         [id       : AckIds,
          epoch    : Epochs,
          keys     : SUBSET Keys,
          kind     : EntryKinds,
          scope    : FlushScopes,
          port     : Ports \cup {"none"},
          snapshot : [Keys -> EntryType]]
    /\ pendingEpoch \in [Keys -> 0..MaxFlushEpoch]
    /\ bpGeneration \in [Ports -> 1..MaxGeneration]
    /\ bpPresent \in [Ports -> BOOLEAN]
    /\ vlanMember \in [Ports -> BOOLEAN]
    /\ removalPhase \in [Ports -> RemovalPhases]
    /\ removalFlushEpoch \in [Ports -> 0..MaxFlushEpoch]
    /\ lastRemovedGeneration \in [Ports -> 0..MaxGeneration]
    /\ saved \in [Keys -> Seq(IntentType)]
    /\ dependencyReady \in [Keys -> BOOLEAN]
    /\ wakeup \in [Keys -> BOOLEAN]
    /\ appliedIntent \in [Keys -> EntryType]
    /\ acknowledgedGen \in [Keys -> 0..MaxGeneration]
    /\ nhgMembers \in [Groups -> SUBSET Endpoints]
    /\ nhgActive \in [Groups -> BOOLEAN]
    /\ nhgBridgePort \in [Groups -> BOOLEAN]
    /\ tunnelRefs \in [Endpoints -> Int]
    /\ graphPhase \in [Groups -> GraphPhases]
    /\ graphDesiredEndpoint \in [Groups -> Endpoints \cup {"none"}]
    /\ replacement \in
         [active : BOOLEAN,
          old    : Endpoints \cup {"none"},
          new    : Endpoints \cup {"none"}]
    /\ fdbFailure \in [Keys -> BOOLEAN]
    /\ fdbRetry \in [Keys -> BOOLEAN]
    /\ fdbCompensated \in [Keys -> BOOLEAN]
    /\ graphFailure \in [Groups -> BOOLEAN]
    /\ graphRetry \in [Groups -> BOOLEAN]
    /\ graphCompensated \in [Groups -> BOOLEAN]
    /\ restartPhase \in RestartPhases
    /\ nvoReady \in BOOLEAN
    /\ kernelNhg \in [Groups -> BOOLEAN]
    /\ appNhg \in [Groups -> BOOLEAN]
    /\ dumpSeen \in [Groups -> BOOLEAN]
    /\ missedDump \in [Groups -> BOOLEAN]
    /\ warmReplayDone \in BOOLEAN
    /\ restartSettled \in BOOLEAN

PlaneRecordSafety ==
    \A k \in Keys :
        /\ cache[k].present => cache[k].gen > 0 /\ cache[k].dest \in Destinations
        /\ cache[k].present = (cacheOrigin[k] /= "none")
        /\ asic[k].present => asic[k].gen > 0 /\ asic[k].dest \in Destinations
        /\ stateDb[k].present => stateDb[k].gen > 0 /\ stateDb[k].dest \in Destinations

PendingEpochIsIssued ==
    \A k \in Keys : pendingEpoch[k] = 0 \/ pendingEpoch[k] <= flushEpoch

TransactionShape ==
    /\ (fdbTxn.phase = "idle") = (fdbTxn.op = "none")
    /\ fdbTxn.phase /= "idle" => fdbTxn.key \in Keys

GraphShape ==
    /\ \A g \in Groups : nhgMembers[g] \subseteq Endpoints
    /\ replacement.active => replacement.old \in Endpoints /\ replacement.new \in Endpoints

RestartShape ==
    /\ restartPhase = "down" => ~nvoReady
    /\ restartSettled => restartPhase = "running"

\* -------------------------------------------------------------------------
\* Scenario extension invariants from Modeling Brief section 5
\* -------------------------------------------------------------------------

UniqueEffectiveDestination ==
    \A k \in Keys : FdbQuiescent(k) => Cardinality(PlaneTuples(k)) <= 1

DependencyBeforeReference ==
    \A k \in Keys :
        /\ cache[k].present => EntryReferencesLiveDependency(cache[k])
        /\ asic[k].present => EntryReferencesLiveDependency(asic[k])

StaleEventCannotDeleteNewer ==
    \A k \in Keys :
        \* FLUSHED callbacks have no incarnation token; their safety is owned
        \* by FlushAckMatchesRequest's execution-time coverage check.
        /\ lastDeletion[k].valid
        /\ lastDeletion[k].cause /= "flush"
        =>
            lastDeletion[k].eventGen >= lastDeletion[k].removedGen

FlushAckMatchesRequest ==
    \A k \in Keys :
        lastFlushCleanup[k].valid =>
            /\ SuccessfulFlushCovered(k, lastFlushCleanup[k].removedGen)
            /\ lastFlushCleanup[k].kindMatched
            /\ lastFlushCleanup[k].scopeMatched

CounterAgreement ==
    /\ crmCount >= 0
    /\ vlanCount >= 0
    /\ \A p \in Ports : portCount[p] >= 0
    /\ fdbTxn.phase /= "idle"
       \/ /\ crmCount = Cardinality(CacheKeys)
          /\ vlanCount = Cardinality(CacheKeys)
          /\ \A p \in Ports : portCount[p] = Cardinality(CacheKeysAtPort(p))

LatestDesiredWins ==
    \A k \in Keys :
        appliedIntent[k].present =>
            /\ desiredOp[k] = "set"
            /\ appliedIntent[k].dest = desiredDest[k]

ActiveNhgHasMember ==
    \A g \in Groups :
        (nhgActive[g] /\ graphPhase[g] \in {"stable", "empty"}) =>
            nhgBridgePort[g] /\ nhgMembers[g] /= {}

TunnelRefExact ==
    \A ep \in Endpoints :
        /\ tunnelRefs[ep] >= 0
        /\ tunnelRefs[ep] = Cardinality({g \in Groups : ep \in nhgMembers[g]})

NoDanglingTopologyReference ==
    \A p \in Ports :
        lastRemovedGeneration[p] > 0 =>
            /\ \A k \in Keys :
                  ~(cache[k].present
                    /\ cache[k].dest = p
                    /\ cache[k].bpGen = lastRemovedGeneration[p])
            /\ \A k \in Keys :
                  ~(asic[k].present
                    /\ asic[k].dest = p
                    /\ asic[k].bpGen = lastRemovedGeneration[p])

FailedWorkRetainsRetryIntent ==
    /\ \A k \in Keys :
          fdbFailure[k] => fdbRetry[k] \/ fdbCompensated[k]
    /\ \A g \in Groups :
          graphFailure[g] => graphRetry[g] \/ graphCompensated[g]

\* Liveness properties. Hunting configs add the relevant property explicitly.
RestartConverges == [] (restartSettled => <> RestartReconstructed)

CompletedFlushConverges ==
    \A e \in Epochs : [] (flushStatus[e] = "acked" => <> OldFlushGone(e))

=============================================================================
