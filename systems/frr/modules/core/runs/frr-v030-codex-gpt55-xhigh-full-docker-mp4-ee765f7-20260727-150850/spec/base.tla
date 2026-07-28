---------------------------- MODULE base ----------------------------
\* TLA+ specification for FRRouting Zebra route realization.
\*
\* Category A (Distributed / Message-Passing): protocol-daemon ZAPI messages,
\* Zebra RIB state, asynchronous dataplane/provider queues, owner route
\* notifications, and NHT updates.
\*
\* Scenario mapping:
\*   S1: dataplane result generation vs speculative selected_fib state.
\*   S2: owner/ZAPI notifications and BGP FIB_INSTALL_PENDING correlation.
\*   S3: NHT/RNH reduced snapshots and stale resolution.
\*   S4: MetaQ/startup/reconnect queue ordering and reconciliation.
\*   S5: provider/NHG boundary and partial dataplane pipelines.

EXTENDS Naturals, FiniteSets, TLC

----
\* Constants
----

CONSTANT Prefix
CONSTANT Owner
CONSTANT MaxGen
CONSTANT MaxSeq
CONSTANT MaxCtx
CONSTANT MaxNotify
CONSTANT MaxTableId
CONSTANT MaxInstance

ASSUME Prefix /= {}
ASSUME Owner /= {}
ASSUME MaxGen \in Nat \ {0}
ASSUME MaxSeq \in Nat \ {0}
ASSUME MaxCtx \in Nat \ {0}
ASSUME MaxNotify \in Nat \ {0}
ASSUME MaxTableId \in Nat
ASSUME MaxInstance \in Nat

DefaultPrefix == CHOOSE p \in Prefix : TRUE
DefaultOwner == CHOOSE o \in Owner : TRUE

TableId == 0..MaxTableId
Instance == 0..MaxInstance
RouteType == {"bgp", "static", "kernel", "connected", "other"}
RouteOp == {"install", "update", "delete", "route_notify", "none"}
DplaneStatus == {"pending", "success", "failure", "none"}
NotifyNote == {"installed", "fail_install", "removed", "remove_fail", "better_admin_won", "none"}
AttrValue == 0..1

\* zebra/rib.h:189-204 defines 12 MetaQ subqueues.
QueueKind == 0..11

\* zebra/rib.h:262-264 hard-codes RIB_ROUTE_ANY_QUEUED to 0x3F, so only
\* subqueues 0..5 are visible to paths that use that mask.
AnyQueuedMask == 0..5

----
\* Record domains
----

RouteRecSet ==
    [ present  : BOOLEAN,
      owner    : Owner,
      table    : TableId,
      gen      : 0..MaxGen,
      selected : BOOLEAN,
      queued   : BOOLEAN,
      installed: BOOLEAN,
      failed   : BOOLEAN,
      removed  : BOOLEAN,
      replacing: BOOLEAN,
      activeNH : BOOLEAN,
      fibNH    : BOOLEAN,
      attrs    : AttrValue,
      routeType: RouteType,
      instance : Instance ]

KernelRecSet ==
    [ installed : BOOLEAN,
      gen       : 0..MaxGen,
      attrs     : AttrValue,
      fibNH     : BOOLEAN,
      nhg       : 0..MaxGen ]

CtxRecSet ==
    [ id            : 0..MaxCtx,
      prefix        : Prefix,
      owner         : Owner,
      table         : TableId,
      op            : RouteOp,
      seq           : 0..MaxSeq,
      oldSeq        : 0..MaxSeq,
      gen           : 0..MaxGen,
      status        : DplaneStatus,
      attrs         : AttrValue,
      stale         : BOOLEAN,
      kernelTouched : BOOLEAN ]

NotifyRecSet ==
    [ id       : 0..MaxNotify,
      prefix   : Prefix,
      owner    : Owner,
      table    : TableId,
      note     : NotifyNote,
      causeGen : 0..MaxGen ]

RNHRecSet ==
    [ resolved  : BOOLEAN,
      gen       : 0..MaxGen,
      installed : BOOLEAN,
      activeNH  : BOOLEAN,
      fibNH     : BOOLEAN,
      attrs     : AttrValue,
      routeType : RouteType,
      instance  : Instance ]

----
\* Default records
----

NoRoute ==
    [ present  |-> FALSE,
      owner    |-> DefaultOwner,
      table    |-> 0,
      gen      |-> 0,
      selected |-> FALSE,
      queued   |-> FALSE,
      installed|-> FALSE,
      failed   |-> FALSE,
      removed  |-> FALSE,
      replacing|-> FALSE,
      activeNH |-> FALSE,
      fibNH    |-> FALSE,
      attrs    |-> 0,
      routeType|-> "bgp",
      instance |-> 0 ]

NoKernelRoute ==
    [ installed |-> FALSE,
      gen       |-> 0,
      attrs     |-> 0,
      fibNH     |-> FALSE,
      nhg       |-> 0 ]

NoCtx ==
    [ id            |-> 0,
      prefix        |-> DefaultPrefix,
      owner         |-> DefaultOwner,
      table         |-> 0,
      op            |-> "none",
      seq           |-> 0,
      oldSeq        |-> 0,
      gen           |-> 0,
      status        |-> "none",
      attrs         |-> 0,
      stale         |-> FALSE,
      kernelTouched |-> FALSE ]

NoRNH ==
    [ resolved  |-> FALSE,
      gen       |-> 0,
      installed |-> FALSE,
      activeNH  |-> FALSE,
      fibNH     |-> FALSE,
      attrs     |-> 0,
      routeType |-> "bgp",
      instance  |-> 0 ]

----
\* Variables
----

\* Zebra RIB / FIB-visible state. S1/S4.
VARIABLE ribRoute            \* [Prefix -> RouteRecSet]
VARIABLE selectedFib         \* [Prefix -> 0..MaxGen]; 0 means no selected_fib
VARIABLE routeGen            \* [Prefix -> 0..MaxGen]
VARIABLE routeDplaneSeq      \* [Prefix -> 0..MaxSeq]

\* Kernel/provider realization oracle. S1/S5.
VARIABLE kernelRoute         \* [Prefix -> KernelRecSet]
VARIABLE nhgInstalled        \* [Prefix -> BOOLEAN]

\* Dataplane submit and asynchronous queues. S1/S5.
VARIABLE submitReady         \* [Prefix -> BOOLEAN]
VARIABLE submitGen           \* [Prefix -> 0..MaxGen]
VARIABLE ctxDraft            \* [Prefix -> CtxRecSet]
VARIABLE nextSeq             \* 1..MaxSeq+1
VARIABLE nextCtxId           \* 1..MaxCtx+1
VARIABLE ctxQueue            \* SUBSET CtxRecSet
VARIABLE providerIn          \* SUBSET CtxRecSet
VARIABLE providerOut         \* SUBSET CtxRecSet
VARIABLE providerPrivate     \* SUBSET CtxRecSet
VARIABLE resultQueue         \* SUBSET CtxRecSet
VARIABLE providerAlive       \* BOOLEAN
VARIABLE shutdownStarted     \* BOOLEAN

\* Owner/ZAPI notification and BGP local state. S2/S4.
VARIABLE ownerSubscribed     \* [Owner -> BOOLEAN]
VARIABLE zapiConn            \* [Owner -> BOOLEAN]
VARIABLE bgpPending          \* [Prefix -> BOOLEAN]
VARIABLE bgpInstalled        \* [Prefix -> BOOLEAN]
VARIABLE bgpInstalledGen     \* [Prefix -> 0..MaxGen]
VARIABLE bgpSelectedGen      \* [Prefix -> 0..MaxGen]
VARIABLE zapiAddInFlight     \* [Prefix -> BOOLEAN]
VARIABLE zapiToZebra         \* [Prefix -> BOOLEAN]; sent by BGP but not yet admitted by Zebra
VARIABLE ownerNotifyObligation \* SUBSET NotifyRecSet
VARIABLE notifyQueue         \* SUBSET NotifyRecSet

\* RNH/NHT reduced resolution snapshot. S3.
VARIABLE rnhRegistered       \* [Prefix -> [Owner -> BOOLEAN]]
VARIABLE rnhAttachedDest     \* [Prefix -> BOOLEAN]
VARIABLE rnhSnapshot         \* [Prefix -> RNHRecSet]
VARIABLE nhtEvalNeeded       \* [Prefix -> BOOLEAN]
VARIABLE nhtQueue            \* SUBSET NotifyRecSet
VARIABLE nhtSuppressed       \* [Prefix -> BOOLEAN]

\* MetaQ, startup, reconnect reconciliation. S4.
VARIABLE metaQ               \* SUBSET [prefix : Prefix, q : QueueKind]
VARIABLE queuedBits          \* [Prefix -> SUBSET QueueKind]
VARIABLE ribProcessReady     \* [Prefix -> BOOLEAN]
VARIABLE zebraKnownRoutes    \* [Prefix -> BOOLEAN]
VARIABLE ownerLocalRoutes    \* [Prefix -> BOOLEAN]
VARIABLE zebraRestarted      \* BOOLEAN

\* History/diagnostic flags used by Scenario invariants.
VARIABLE enqueueFailed       \* [Prefix -> BOOLEAN]; explicit terminal state, absent in current code path
VARIABLE lostNotifications   \* Nat
VARIABLE reconnects          \* Nat
VARIABLE staleResultApplied
VARIABLE staleDplaneNotifyApplied
VARIABLE staleOwnerNotifyApplied

routeVars ==
    <<ribRoute, selectedFib, routeGen, routeDplaneSeq, kernelRoute,
      nhgInstalled, submitReady, submitGen, ctxDraft, nextSeq, nextCtxId>>

dplaneVars ==
    <<ctxQueue, providerIn, providerOut, providerPrivate, resultQueue,
      providerAlive, shutdownStarted>>

ownerVars ==
    <<ownerSubscribed, zapiConn, bgpPending, bgpInstalled, bgpInstalledGen,
      bgpSelectedGen, zapiAddInFlight, zapiToZebra, ownerNotifyObligation,
      notifyQueue>>

nhtVars ==
    <<rnhRegistered, rnhAttachedDest, rnhSnapshot, nhtEvalNeeded,
      nhtQueue, nhtSuppressed>>

metaVars ==
    <<metaQ, queuedBits, ribProcessReady, zebraKnownRoutes, ownerLocalRoutes,
      zebraRestarted>>

historyVars ==
    <<enqueueFailed, lostNotifications, reconnects, staleResultApplied,
      staleDplaneNotifyApplied, staleOwnerNotifyApplied>>

vars == <<routeVars, dplaneVars, ownerVars, nhtVars, metaVars, historyVars>>

----
\* Helpers
----

CtxWithPrefix(S, p) == {c \in S : c.prefix = p}
HasCtx(S, p) == CtxWithPrefix(S, p) /= {}

PendingCtx(c) ==
    [c EXCEPT !.status = "pending", !.kernelTouched = FALSE]

CtxWithoutKernelTouched(c) ==
    [c EXCEPT !.kernelTouched = FALSE]

CtxMatchesEvent(q, e) ==
    CtxWithoutKernelTouched(q) = CtxWithoutKernelTouched(e)

ChooseCtxByEvent(S, e) ==
    CHOOSE q \in S : CtxMatchesEvent(q, e)

NotifyWithPrefix(S, p) == {n \in S : n.prefix = p}
HasNotify(S, p) == NotifyWithPrefix(S, p) /= {}

NotifyWithoutTable(n) ==
    [n EXCEPT !.table = 0]

NotifyMatchesBgpEvent(q, e) ==
    NotifyWithoutTable(q) = NotifyWithoutTable(e)

ChooseNotifyByBgpEvent(S, e) ==
    CHOOSE q \in S : NotifyMatchesBgpEvent(q, e)

VisibleQueued(p) == queuedBits[p] \cap AnyQueuedMask /= {}

HasOutstandingDplane(p) ==
    \/ submitReady[p]
    \/ ctxDraft[p].id # 0
    \/ HasCtx(ctxQueue, p)
    \/ HasCtx(providerIn, p)
    \/ HasCtx(providerOut, p)
    \/ HasCtx(providerPrivate, p)
    \/ HasCtx(resultQueue, p)

HasOwnerNotificationWork(p) ==
    \/ zapiToZebra[p]
    \/ HasNotify(ownerNotifyObligation, p)
    \/ HasNotify(notifyQueue, p)

RNHResolvedFromRoute(p) ==
    /\ selectedFib[p] # 0
    /\ ribRoute[p].present
    /\ ribRoute[p].installed
    /\ ribRoute[p].activeNH
    /\ kernelRoute[p].installed
    /\ kernelRoute[p].gen = selectedFib[p]
    /\ kernelRoute[p].fibNH

SnapshotFromRoute(p) ==
    [ resolved  |-> RNHResolvedFromRoute(p),
      gen       |-> selectedFib[p],
      installed |-> ribRoute[p].installed,
      activeNH  |-> ribRoute[p].activeNH,
      fibNH     |-> kernelRoute[p].fibNH,
      attrs     |-> ribRoute[p].attrs,
      routeType |-> ribRoute[p].routeType,
      instance  |-> ribRoute[p].instance ]

ReducedRNHStateEqual(p) ==
    /\ rnhSnapshot[p].routeType = ribRoute[p].routeType
    /\ rnhSnapshot[p].installed = ribRoute[p].installed
    /\ rnhSnapshot[p].activeNH = ribRoute[p].activeNH
    /\ rnhSnapshot[p].fibNH = kernelRoute[p].fibNH

----
\* Initialization
----

Init ==
    /\ ribRoute = [p \in Prefix |-> NoRoute]
    /\ selectedFib = [p \in Prefix |-> 0]
    /\ routeGen = [p \in Prefix |-> 0]
    /\ routeDplaneSeq = [p \in Prefix |-> 0]
    /\ kernelRoute = [p \in Prefix |-> NoKernelRoute]
    /\ nhgInstalled = [p \in Prefix |-> TRUE]
    /\ submitReady = [p \in Prefix |-> FALSE]
    /\ submitGen = [p \in Prefix |-> 0]
    /\ ctxDraft = [p \in Prefix |-> NoCtx]
    /\ nextSeq = 1
    /\ nextCtxId = 1
    /\ ctxQueue = {}
    /\ providerIn = {}
    /\ providerOut = {}
    /\ providerPrivate = {}
    /\ resultQueue = {}
    /\ providerAlive = TRUE
    /\ shutdownStarted = FALSE
    /\ ownerSubscribed = [o \in Owner |-> FALSE]
    /\ zapiConn = [o \in Owner |-> TRUE]
    /\ bgpPending = [p \in Prefix |-> FALSE]
    /\ bgpInstalled = [p \in Prefix |-> FALSE]
    /\ bgpInstalledGen = [p \in Prefix |-> 0]
    /\ bgpSelectedGen = [p \in Prefix |-> 0]
    /\ zapiAddInFlight = [p \in Prefix |-> FALSE]
    /\ zapiToZebra = [p \in Prefix |-> FALSE]
    /\ ownerNotifyObligation = {}
    /\ notifyQueue = {}
    /\ rnhRegistered = [p \in Prefix |-> [o \in Owner |-> FALSE]]
    /\ rnhAttachedDest = [p \in Prefix |-> FALSE]
    /\ rnhSnapshot = [p \in Prefix |-> NoRNH]
    /\ nhtEvalNeeded = [p \in Prefix |-> FALSE]
    /\ nhtQueue = {}
    /\ nhtSuppressed = [p \in Prefix |-> FALSE]
    /\ metaQ = {}
    /\ queuedBits = [p \in Prefix |-> {}]
    /\ ribProcessReady = [p \in Prefix |-> FALSE]
    /\ zebraKnownRoutes = [p \in Prefix |-> FALSE]
    /\ ownerLocalRoutes = [p \in Prefix |-> FALSE]
    /\ zebraRestarted = FALSE
    /\ enqueueFailed = [p \in Prefix |-> FALSE]
    /\ lostNotifications = 0
    /\ reconnects = 0
    /\ staleResultApplied = FALSE
    /\ staleDplaneNotifyApplied = FALSE
    /\ staleOwnerNotifyApplied = FALSE

----
\* BGP/ZAPI owner boundary actions (Scenario 2, Scenario 4)
----

bgp_zebra_route_install(o, p) ==
    \* bgpd/bgp_zebra.c:2051-2072 sets FIB_INSTALL_PENDING before Zebra usability.
    \* bgpd/bgp_zebra.c:2082-2087 returns if Zebra cannot receive the route.
    /\ routeGen[p] < MaxGen
    /\ bgpSelectedGen[p] < MaxGen
    /\ bgpSelectedGen' = [bgpSelectedGen EXCEPT ![p] = @ + 1]
    /\ ownerLocalRoutes' = [ownerLocalRoutes EXCEPT ![p] = TRUE]
    /\ bgpPending' = [bgpPending EXCEPT ![p] = TRUE]
    /\ bgpInstalled' = [bgpInstalled EXCEPT ![p] = FALSE]
    /\ bgpInstalledGen' = [bgpInstalledGen EXCEPT ![p] = 0]
    /\ zapiAddInFlight' =
        IF zapiConn[o]
        THEN [zapiAddInFlight EXCEPT ![p] = TRUE]
        ELSE zapiAddInFlight
    /\ UNCHANGED <<routeVars, dplaneVars, ownerSubscribed, zapiConn,
                  zapiToZebra,
                  ownerNotifyObligation, notifyQueue, nhtVars, metaQ,
                  queuedBits, ribProcessReady, zebraKnownRoutes,
                  zebraRestarted, historyVars>>

bgp_handle_route_announcements_to_zebra(o, p) ==
    \* bgpd/bgp_zebra.c:1894-1935 pops a queued route announcement and sends it.
    \* bgpd/bgp_zebra.c:1936 clears SCHEDULE_FOR_INSTALL after the send attempt.
    /\ zapiConn[o]
    /\ zapiAddInFlight[p]
    /\ zapiAddInFlight' = [zapiAddInFlight EXCEPT ![p] = FALSE]
    /\ zapiToZebra' = [zapiToZebra EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<routeVars, dplaneVars, ownerSubscribed, zapiConn,
                  bgpPending, bgpInstalled, bgpInstalledGen, bgpSelectedGen,
                  ownerNotifyObligation, notifyQueue, nhtVars, metaVars,
                  historyVars>>

ZapiSendFail(o, p) ==
    \* bgpd/bgp_zebra.c:1952-1961 logs send failure for some paths; the
    \* pending owner state was already set before this boundary.
    /\ zapiConn[o]
    /\ zapiAddInFlight[p]
    /\ zapiAddInFlight' = [zapiAddInFlight EXCEPT ![p] = FALSE]
    /\ zapiToZebra' = [zapiToZebra EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<routeVars, dplaneVars, ownerSubscribed, zapiConn,
                  bgpPending, bgpInstalled, bgpInstalledGen, bgpSelectedGen,
                  ownerNotifyObligation, notifyQueue, nhtVars, metaVars,
                  historyVars>>

zread_route_notify_request(o) ==
    \* zebra/zapi_msg.c:850-855 decodes a boolean and stores client->notify_owner.
    /\ ownerSubscribed' = [ownerSubscribed EXCEPT ![o] = TRUE]
    /\ UNCHANGED <<routeVars, dplaneVars, zapiConn, bgpPending, bgpInstalled,
                  bgpInstalledGen, bgpSelectedGen, zapiAddInFlight,
                  zapiToZebra,
                  ownerNotifyObligation, notifyQueue, nhtVars, metaVars,
                  historyVars>>

bgp_zebra_connected(o) ==
    \* zebra/zserv.c:799-807 creates a zeroed client; zserv.h:135 stores
    \* notify_owner per connection.
    \* bgpd/bgp_zebra.c:3299-3325 reconnect registers the instance and has a
    \* TODO for kick-starting configured routes.
    /\ ~zapiConn[o] \/ zebraRestarted
    /\ zapiConn' = [zapiConn EXCEPT ![o] = TRUE]
    /\ ownerSubscribed' = [ownerSubscribed EXCEPT ![o] = FALSE]
    /\ reconnects' = reconnects + 1
    /\ UNCHANGED <<routeVars, dplaneVars, bgpPending, bgpInstalled,
                  bgpInstalledGen, bgpSelectedGen, zapiAddInFlight,
                  zapiToZebra,
                  ownerNotifyObligation, notifyQueue, nhtVars, metaQ,
                  queuedBits, ribProcessReady, zebraKnownRoutes,
                  ownerLocalRoutes, zebraRestarted, enqueueFailed,
                  lostNotifications, staleResultApplied,
                  staleDplaneNotifyApplied, staleOwnerNotifyApplied>>

bgp_zebra_announce_table(o, p) ==
    \* bgpd/bgp_zebra.c:3322-3324 notes that reconnect does not necessarily
    \* kick-start configured routes; this action models an explicit replay path.
    /\ zapiConn[o]
    /\ ownerLocalRoutes[p]
    /\ zebraRestarted
    /\ zapiAddInFlight' = [zapiAddInFlight EXCEPT ![p] = TRUE]
    /\ zebraRestarted' = FALSE
    /\ UNCHANGED <<routeVars, dplaneVars, ownerSubscribed, zapiConn,
                  bgpPending, bgpInstalled, bgpInstalledGen, bgpSelectedGen,
                  zapiToZebra,
                  ownerNotifyObligation, notifyQueue, nhtVars, metaQ,
                  queuedBits, ribProcessReady, zebraKnownRoutes,
                  ownerLocalRoutes, historyVars>>

----
\* RIB admission and MetaQ actions (Scenario 4)
----

rib_link(p, o, t) ==
    \* zebra/zebra_rib.c:4056-4072 creates/uses rib_dest, adds the route entry,
    \* and queues the route node for later best-path processing.
    /\ routeGen[p] < MaxGen
    /\ ribRoute' =
        [ribRoute EXCEPT
            ![p].present  = TRUE,
            ![p].owner    = o,
            ![p].table    = t,
            ![p].gen      = routeGen[p] + 1,
            ![p].selected = FALSE,
            ![p].queued   = FALSE,
            ![p].installed= FALSE,
            ![p].failed   = FALSE,
            ![p].removed  = FALSE,
            ![p].replacing= selectedFib[p] # 0,
            ![p].activeNH = TRUE,
            ![p].fibNH    = FALSE,
            ![p].attrs    = (ribRoute[p].attrs + 1) % 2,
            ![p].routeType= "bgp",
            ![p].instance = 0]
    /\ routeGen' = [routeGen EXCEPT ![p] = @ + 1]
    /\ zebraKnownRoutes' = [zebraKnownRoutes EXCEPT ![p] = TRUE]
    /\ zapiToZebra' = [zapiToZebra EXCEPT ![p] = FALSE]
    /\ nhtEvalNeeded' =
        IF \E oo \in Owner : rnhRegistered[p][oo]
        THEN [nhtEvalNeeded EXCEPT ![p] = TRUE]
        ELSE nhtEvalNeeded
    /\ UNCHANGED <<selectedFib, routeDplaneSeq, kernelRoute, nhgInstalled,
                  submitReady, submitGen, ctxDraft, nextSeq, nextCtxId,
                  dplaneVars, ownerSubscribed, zapiConn, bgpPending,
                  bgpInstalled, bgpInstalledGen, bgpSelectedGen,
                  zapiAddInFlight, ownerNotifyObligation, notifyQueue,
                  rnhRegistered, rnhAttachedDest,
                  rnhSnapshot, nhtQueue, nhtSuppressed, metaQ, queuedBits,
                  ribProcessReady, ownerLocalRoutes, zebraRestarted, historyVars>>

rib_addnode(p, o, t) ==
    \* zebra/zebra_rib.c:4075-4088 either un-removes an existing RE or calls
    \* rib_link for a fresh route.
    \/ /\ ribRoute[p].present
       /\ ribRoute[p].removed
       /\ ribRoute' =
            [ribRoute EXCEPT
                ![p].removed = FALSE,
                ![p].queued = FALSE]
       /\ zapiToZebra' = [zapiToZebra EXCEPT ![p] = FALSE]
       /\ UNCHANGED <<selectedFib, routeGen, routeDplaneSeq, kernelRoute,
                     nhgInstalled, submitReady, submitGen, ctxDraft, nextSeq,
                     nextCtxId, dplaneVars, ownerSubscribed, zapiConn,
                     bgpPending, bgpInstalled, bgpInstalledGen, bgpSelectedGen,
                     zapiAddInFlight, ownerNotifyObligation, notifyQueue,
                     nhtVars, metaQ,
                     queuedBits, ribProcessReady, zebraKnownRoutes,
                     ownerLocalRoutes, zebraRestarted, historyVars>>
    \/ rib_link(p, o, t)

rib_delnode(p) ==
    \* zebra/zebra_rib.c:4122-4133 marks ROUTE_ENTRY_REMOVED and queues rn.
    /\ ribRoute[p].present
    /\ ribRoute' =
        [ribRoute EXCEPT
            ![p].removed = TRUE,
            ![p].selected = FALSE,
            ![p].queued = FALSE]
    /\ ribProcessReady' = [ribProcessReady EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<selectedFib, routeGen, routeDplaneSeq, kernelRoute,
                  nhgInstalled, submitReady, submitGen, ctxDraft, nextSeq,
                  nextCtxId, dplaneVars, ownerVars, nhtVars, metaQ,
                  queuedBits, zebraKnownRoutes, ownerLocalRoutes,
                  zebraRestarted, historyVars>>

rib_meta_queue_add(p, q) ==
    \* zebra/zebra_rib.c:3262-3281 chooses the highest-priority route
    \* subqueue; zebra/zebra_rib.c:3283-3305 rejects if MQ_BIT_MASK is set.
    \* zebra/zebra_rib.c:3307-3310 sets RIB_ROUTE_QUEUED(qindex) and adds rn.
    /\ ribRoute[p].present
    /\ queuedBits[p] = {}
    /\ metaQ' = metaQ \cup {[prefix |-> p, q |-> q]}
    /\ queuedBits' = [queuedBits EXCEPT ![p] = {q}]
    /\ UNCHANGED <<routeVars, dplaneVars, ownerVars, nhtVars,
                  ribProcessReady, zebraKnownRoutes, ownerLocalRoutes,
                  zebraRestarted, historyVars>>

meta_queue_process(p, q) ==
    \* zebra/zebra_rib.c:3218-3231 blocks if the dataplane input queue is over
    \* limit; zebra/zebra_rib.c:3234-3239 processes one subqueue item.
    \* zebra/zebra_rib.c:2548-2581 calls rib_process and clears the queue bit.
    /\ [prefix |-> p, q |-> q] \in metaQ
    /\ metaQ' = metaQ \ {[prefix |-> p, q |-> q]}
    /\ queuedBits' = [queuedBits EXCEPT ![p] = @ \ {q}]
    /\ ribProcessReady' = [ribProcessReady EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<routeVars, dplaneVars, ownerVars, nhtVars,
                  zebraKnownRoutes, ownerLocalRoutes, zebraRestarted,
                  historyVars>>

rib_process(p) ==
    \* zebra/zebra_rib.c:1341-1453 remembers old_fib, skips removed entries,
    \* and chooses new_selected/new_fib.
    \* zebra/zebra_rib.c:1489-1497 sets ZEBRA_FLAG_SELECTED.
    \* zebra/zebra_rib.c:1549-1555 delegates FIB update to add/update/delete.
    /\ ribProcessReady[p]
    /\ ribRoute[p].present
    /\ ~ribRoute[p].removed
    /\ ribRoute[p].activeNH
    /\ ribRoute' =
        [ribRoute EXCEPT
            ![p].selected = TRUE,
            ![p].failed = FALSE]
    /\ ribProcessReady' = [ribProcessReady EXCEPT ![p] = FALSE]
    /\ submitReady' = [submitReady EXCEPT ![p] = TRUE]
    /\ submitGen' = [submitGen EXCEPT ![p] = routeGen[p]]
    /\ UNCHANGED <<selectedFib, routeGen, routeDplaneSeq, kernelRoute,
                  nhgInstalled, ctxDraft, nextSeq, nextCtxId, dplaneVars,
                  ownerVars, nhtVars, metaQ, queuedBits, zebraKnownRoutes,
                  ownerLocalRoutes, zebraRestarted, historyVars>>

rib_install_kernel(p) ==
    \* zebra/zebra_rib.c:693-696 installs/resolves NHG first.
    \* zebra/zebra_rib.c:706-713 speculatively assigns dest->selected_fib and
    \* calls rib_update before dataplane completion.
    \* zebra/zebra_rib.c:716-719 sends add/update to the dataplane.
    /\ submitReady[p]
    /\ ribRoute[p].present
    /\ ribRoute[p].selected
    /\ nhgInstalled[p]
    /\ selectedFib' = [selectedFib EXCEPT ![p] = submitGen[p]]
    /\ UNCHANGED <<ribRoute, routeGen, routeDplaneSeq, kernelRoute,
                  nhgInstalled, submitReady, submitGen, ctxDraft, nextSeq,
                  nextCtxId, dplaneVars, ownerVars, nhtVars, metaVars,
                  historyVars>>

rib_uninstall_kernel(p) ==
    \* zebra/zebra_rib.c:750-762 calls dplane_route_delete after FPM hook.
    \* zebra/zebra_rib.c:767-781 only accounts enqueue status.
    /\ ribRoute[p].present
    /\ selectedFib[p] # 0
    /\ submitReady' = [submitReady EXCEPT ![p] = TRUE]
    /\ submitGen' = [submitGen EXCEPT ![p] = selectedFib[p]]
    /\ ribRoute' = [ribRoute EXCEPT ![p].removed = TRUE]
    /\ UNCHANGED <<selectedFib, routeGen, routeDplaneSeq, kernelRoute,
                  nhgInstalled, ctxDraft, nextSeq, nextCtxId, dplaneVars,
                  ownerVars, nhtVars, metaVars, historyVars>>

----
\* Dataplane context, provider, and result actions (Scenario 1, Scenario 5)
----

dplane_ctx_route_init(p) ==
    \* zebra/zebra_dplane.c:4014-4057 copies route/prefix/nexthops.
    \* zebra/zebra_dplane.c:4145-4149 assigns dplane_sequence/ctx->zd_seq.
    \* The caller is rib_install_kernel()/rib_uninstall_kernel(), after the
    \* selected_fib precommit for add/update paths.
    /\ submitReady[p]
    /\ selectedFib[p] = submitGen[p]
    /\ ctxDraft[p].id = 0
    /\ nextSeq <= MaxSeq
    /\ nextCtxId <= MaxCtx
    /\ ctxDraft' =
        [ctxDraft EXCEPT ![p] =
            [ id            |-> nextCtxId,
              prefix        |-> p,
              owner         |-> ribRoute[p].owner,
              table         |-> ribRoute[p].table,
              op            |-> IF ribRoute[p].removed THEN "delete"
                               ELSE IF selectedFib[p] # 0 /\ selectedFib[p] # submitGen[p]
                                    THEN "update" ELSE "install",
              seq           |-> nextSeq,
              oldSeq        |-> routeDplaneSeq[p],
              gen           |-> submitGen[p],
              status        |-> "pending",
              attrs         |-> ribRoute[p].attrs,
              stale         |-> FALSE,
              kernelTouched |-> FALSE ]]
    /\ routeDplaneSeq' = [routeDplaneSeq EXCEPT ![p] = nextSeq]
    /\ nextSeq' = nextSeq + 1
    /\ nextCtxId' = nextCtxId + 1
    /\ UNCHANGED <<ribRoute, selectedFib, routeGen, kernelRoute,
                  nhgInstalled, submitReady, submitGen, dplaneVars,
                  ownerVars, nhtVars, metaVars, historyVars>>

dplane_update_enqueue(c) ==
    \* zebra/zebra_dplane.c:4777-4815 adds ctx to dg_update_list and wakes the
    \* dataplane pthread.
    \* zebra/zebra_dplane.c:4873-4882 returns ZEBRA_DPLANE_REQUEST_QUEUED.
    /\ c = ctxDraft[c.prefix]
    /\ c.id # 0
    /\ Cardinality(ctxQueue) < MaxCtx
    /\ ctxQueue' = ctxQueue \cup {c}
    /\ ctxDraft' = [ctxDraft EXCEPT ![c.prefix] = NoCtx]
    /\ submitReady' = [submitReady EXCEPT ![c.prefix] = FALSE]
    /\ ribRoute' =
        [ribRoute EXCEPT
            ![c.prefix].queued = TRUE,
            ![c.prefix].replacing = c.op = "update"]
    /\ UNCHANGED <<selectedFib, routeGen, routeDplaneSeq, kernelRoute,
                  nhgInstalled, submitGen, nextSeq, nextCtxId, providerIn,
                  providerOut, providerPrivate, resultQueue, providerAlive,
                  shutdownStarted, ownerVars, nhtVars, metaVars, historyVars>>

dplane_update_enqueue_failure(c) ==
    \* Case B repair: after dplane_ctx_route_init() succeeds and a ctx exists,
    \* zebra/zebra_dplane.c:4811-4850 calls dplane_provider_work_ready(), which
    \* unconditionally returns AOK at zebra/zebra_dplane.c:7254-7267. Failure
    \* before ctx creation is a separate route-init failure path, not this action.
    /\ FALSE
    /\ UNCHANGED vars

dplane_thread_loop_to_provider(c) ==
    \* zebra/zebra_dplane.c:8111-8122 describes the dataplane pthread moving
    \* incoming work through providers.
    /\ providerAlive
    /\ c \in ctxQueue
    /\ ctxQueue' = ctxQueue \ {c}
    /\ providerIn' = providerIn \cup {c}
    /\ UNCHANGED <<routeVars, providerOut, providerPrivate, resultQueue,
                  providerAlive, shutdownStarted, ownerVars, nhtVars,
                  metaVars, historyVars>>

kernel_dplane_process_func_success(c) ==
    \* zebra/zebra_dplane.c:7716-7733 dequeues provider input.
    \* Normal kernel success realizes route attrs and FIB nexthops.
    LET pre == PendingCtx(c)
        out == [pre EXCEPT !.status = "success", !.kernelTouched = TRUE]
    IN
    /\ providerAlive
    /\ pre \in providerIn
    /\ pre.op \in {"install", "update"}
    /\ providerIn' = providerIn \ {pre}
    /\ providerOut' = providerOut \cup {out}
    /\ kernelRoute' =
        [kernelRoute EXCEPT ![pre.prefix] =
            [ installed |-> TRUE,
              gen       |-> pre.gen,
              attrs     |-> pre.attrs,
              fibNH     |-> TRUE,
              nhg       |-> pre.gen ]]
    /\ UNCHANGED <<ribRoute, selectedFib, routeGen, routeDplaneSeq,
                  nhgInstalled, submitReady, submitGen, ctxDraft, nextSeq,
                  nextCtxId, ctxQueue, providerPrivate, resultQueue,
                  providerAlive, shutdownStarted, ownerVars, nhtVars,
                  metaVars, historyVars>>

kernel_dplane_process_func_failure(c) ==
    \* zebra/zebra_dplane.c:7716-7733 provider callback can return a failed
    \* status that later drives rib_process_result failure handling.
    LET pre == PendingCtx(c)
        out == [pre EXCEPT !.status = "failure", !.kernelTouched = FALSE]
    IN
    /\ providerAlive
    /\ pre \in providerIn
    /\ pre.op \in {"install", "update", "delete"}
    /\ providerIn' = providerIn \ {pre}
    /\ providerOut' = providerOut \cup {out}
    /\ UNCHANGED <<routeVars, ctxQueue, providerPrivate, resultQueue,
                  providerAlive, shutdownStarted, ownerVars, nhtVars,
                  metaVars, historyVars>>

kernel_dplane_process_func_skip_kernel(c) ==
    \* zebra/zebra_dplane.c:7747-7758 marks same old/new NHG/type updates as
    \* success without performing a kernel route update.
    LET pre == PendingCtx(c)
        out == [pre EXCEPT !.status = "success", !.kernelTouched = FALSE]
    IN
    /\ providerAlive
    /\ pre \in providerIn
    /\ pre.op = "update"
    /\ providerIn' = providerIn \ {pre}
    /\ providerOut' = providerOut \cup {out}
    /\ UNCHANGED <<routeVars, ctxQueue, providerPrivate, resultQueue,
                  providerAlive, shutdownStarted, ownerVars, nhtVars,
                  metaVars, historyVars>>

fpm_nl_process_private(c) ==
    \* zebra/dplane_fpm_nl.c:1801-1809 moves route contexts into an FPM
    \* provider-private queue.
    /\ providerAlive
    /\ c \in providerIn
    /\ providerIn' = providerIn \ {c}
    /\ providerPrivate' = providerPrivate \cup {c}
    /\ UNCHANGED <<routeVars, ctxQueue, providerOut, resultQueue,
                  providerAlive, shutdownStarted, ownerVars, nhtVars,
                  metaVars, historyVars>>

fpm_process_queue(c) ==
    \* zebra/dplane_fpm_nl.c:1550-1568 drains the provider-private queue and
    \* enqueues output; zebra/dplane_fpm_nl.c:1587-1594 wakes dataplane work.
    LET pre == PendingCtx(c)
        out == [pre EXCEPT !.status = "success", !.kernelTouched = TRUE]
    IN
    /\ providerAlive
    /\ pre \in providerPrivate
    /\ providerPrivate' = providerPrivate \ {pre}
    /\ providerOut' = providerOut \cup {out}
    /\ kernelRoute' =
        [kernelRoute EXCEPT ![pre.prefix] =
            [ installed |-> pre.op # "delete",
              gen       |-> pre.gen,
              attrs     |-> pre.attrs,
              fibNH     |-> pre.op # "delete",
              nhg       |-> pre.gen ]]
    /\ UNCHANGED <<ribRoute, selectedFib, routeGen, routeDplaneSeq,
                  nhgInstalled, submitReady, submitGen, ctxDraft, nextSeq,
                  nextCtxId, ctxQueue, providerIn, resultQueue, providerAlive,
                  shutdownStarted, ownerVars, nhtVars, metaVars, historyVars>>

dplane_thread_loop_result(c) ==
    \* zebra/zebra_dplane.c:8111-8122 takes provider output for return to the
    \* Zebra main thread; zebra/zebra_rib.c:5221-5225 dispatches by op.
    LET q == ChooseCtxByEvent(providerOut, c)
    IN
    /\ q \in providerOut
    /\ CtxMatchesEvent(q, c)
    /\ providerOut' = providerOut \ {q}
    /\ resultQueue' = resultQueue \cup {q}
    /\ UNCHANGED <<routeVars, ctxQueue, providerIn, providerPrivate,
                  providerAlive, shutdownStarted, ownerVars, nhtVars,
                  metaVars, historyVars>>

dplane_result_lost(c) ==
    \* Scenario 1 fault: provider completion/result is lost before Zebra main
    \* thread observes it.
    /\ c \in providerOut \cup resultQueue
    /\ providerOut' = providerOut \ {c}
    /\ resultQueue' = resultQueue \ {c}
    /\ UNCHANGED <<routeVars, ctxQueue, providerIn, providerPrivate,
                  providerAlive, shutdownStarted, ownerVars, nhtVars,
                  metaVars, historyVars>>

DPLANE_OP_ROUTE_NOTIFY(p, g) ==
    \* zebra/zebra_rib.c:2250-2254 handles asynchronous route notifications;
    \* the notify path is not sequence gated like normal results.
    /\ g \in 0..MaxGen
    /\ g <= routeGen[p]
    /\ nextCtxId <= MaxCtx
    /\ Cardinality(resultQueue) < MaxCtx
    /\ resultQueue' =
        resultQueue \cup
        {[ id            |-> nextCtxId,
           prefix        |-> p,
           owner         |-> ribRoute[p].owner,
           table         |-> ribRoute[p].table,
           op            |-> "route_notify",
           seq           |-> 0,
           oldSeq        |-> 0,
           gen           |-> g,
           status        |-> "success",
           attrs         |-> ribRoute[p].attrs,
           stale         |-> g # routeGen[p],
           kernelTouched |-> FALSE ]}
    /\ nextCtxId' = nextCtxId + 1
    /\ UNCHANGED <<ribRoute, selectedFib, routeGen, routeDplaneSeq,
                  kernelRoute, nhgInstalled, submitReady, submitGen, ctxDraft,
                  nextSeq, ctxQueue, providerIn, providerOut, providerPrivate,
                  providerAlive, shutdownStarted, ownerVars, nhtVars,
                  metaVars, historyVars>>

rib_process_result(c) ==
    \* zebra/zebra_rib.c:1994-2047 locates re/old_re and reads ctx seq.
    \* zebra/zebra_rib.c:2048-2090 logs stale seq mismatches but continues.
    \* zebra/zebra_rib.c:2093-2181 mutates install success state and notifies.
    \* zebra/zebra_rib.c:2181-2195 mutates install failure state and notifies.
    \* zebra/zebra_rib.c:2238 evaluates RNH after the result.
    LET q == ChooseCtxByEvent(resultQueue, c)
    IN
    /\ q \in resultQueue
    /\ CtxMatchesEvent(q, c)
    /\ q.op \in {"install", "update", "delete"}
    /\ LET p == q.prefix
           matching == /\ q.gen = routeGen[p]
                       /\ q.seq = routeDplaneSeq[p]
           note == IF q.op = "delete"
                   THEN IF q.status = "success" THEN "removed" ELSE "remove_fail"
                   ELSE IF q.status = "success" THEN "installed" ELSE "fail_install"
       IN
       /\ resultQueue' = resultQueue \ {q}
       /\ ribRoute' =
            [ribRoute EXCEPT
                ![p].installed =
                    IF q.op = "delete" THEN FALSE ELSE q.status = "success",
                ![p].failed = q.status = "failure",
                ![p].queued = IF matching THEN FALSE ELSE @,
                ![p].replacing = IF matching THEN FALSE ELSE @,
                ![p].fibNH = IF q.status = "success" THEN TRUE ELSE @]
       /\ ownerNotifyObligation' =
            ownerNotifyObligation \cup
            {[ id       |-> q.id,
               prefix   |-> p,
               owner    |-> q.owner,
               table    |-> q.table,
               note     |-> note,
               causeGen |-> q.gen ]}
       /\ nhtEvalNeeded' = [nhtEvalNeeded EXCEPT ![p] = TRUE]
       /\ staleResultApplied' =
            IF ~matching /\ q.status \in {"success", "failure"}
            THEN TRUE
            ELSE staleResultApplied
       /\ UNCHANGED <<selectedFib, routeGen, routeDplaneSeq, kernelRoute,
                     nhgInstalled, submitReady, submitGen, ctxDraft, nextSeq,
                     nextCtxId, ctxQueue, providerIn, providerOut,
                     providerPrivate, providerAlive, shutdownStarted,
                     ownerSubscribed, zapiConn, bgpPending, bgpInstalled,
                     bgpInstalledGen, bgpSelectedGen, zapiAddInFlight,
                     zapiToZebra,
                     notifyQueue, rnhRegistered, rnhAttachedDest, rnhSnapshot,
                     nhtQueue, nhtSuppressed, metaVars, enqueueFailed,
                     lostNotifications, reconnects, staleDplaneNotifyApplied,
                     staleOwnerNotifyApplied>>

rib_process_dplane_notify(c) ==
    \* zebra/zebra_rib.c:2266-2294 matches an async notify by prefix/type.
    \* zebra/zebra_rib.c:2305-2308 clears QUEUED/ROUTE_REPLACING.
    \* zebra/zebra_rib.c:2335-2371 ignores non-selected entries after cleanup.
    \* zebra/zebra_rib.c:2387-2409 updates selected FIB/offload state, but does
    \* not set ROUTE_ENTRY_INSTALLED; normal dataplane results do that.
    /\ c \in resultQueue
    /\ c.op = "route_notify"
    /\ LET p == c.prefix
           selectedNotify == selectedFib[p] # 0
       IN
       /\ resultQueue' = resultQueue \ {c}
       /\ ribRoute' =
            [ribRoute EXCEPT
                ![p].queued = FALSE,
                ![p].replacing = FALSE,
                ![p].fibNH =
                    IF selectedNotify /\ c.status = "success" THEN TRUE ELSE @,
                ![p].failed =
                    IF selectedNotify /\ c.status = "failure" THEN TRUE ELSE @]
       /\ ownerNotifyObligation' =
            IF selectedNotify /\ ribRoute[p].installed
            THEN ownerNotifyObligation \cup
                 {[ id       |-> c.id,
                    prefix   |-> p,
                    owner    |-> c.owner,
                    table    |-> c.table,
                    note     |-> IF c.status = "success" THEN "installed" ELSE "fail_install",
                    causeGen |-> c.gen ]}
            ELSE ownerNotifyObligation
       /\ nhtEvalNeeded' =
            IF selectedNotify THEN [nhtEvalNeeded EXCEPT ![p] = TRUE]
            ELSE nhtEvalNeeded
       /\ staleDplaneNotifyApplied' =
            IF selectedNotify /\ c.gen # selectedFib[p]
            THEN TRUE
            ELSE staleDplaneNotifyApplied
       /\ UNCHANGED <<selectedFib, routeGen, routeDplaneSeq, kernelRoute,
                     nhgInstalled, submitReady, submitGen, ctxDraft, nextSeq,
                     nextCtxId, ctxQueue, providerIn, providerOut,
                     providerPrivate, providerAlive, shutdownStarted,
                     ownerSubscribed, zapiConn, bgpPending, bgpInstalled,
                     bgpInstalledGen, bgpSelectedGen, zapiAddInFlight,
                     zapiToZebra,
                     notifyQueue, rnhRegistered, rnhAttachedDest, rnhSnapshot,
                     nhtQueue, nhtSuppressed, metaVars, enqueueFailed,
                     lostNotifications, reconnects, staleResultApplied,
                     staleOwnerNotifyApplied>>

----
\* Owner notification delivery and BGP apply (Scenario 2)
----

route_notify_internal(n) ==
    \* zebra/zapi_msg.c:751-772 looks up the owner client and drops if missing
    \* or notify_owner is false.
    \* zebra/zapi_msg.c:786-807 encodes note, prefix, table, AFI/SAFI, but no
    \* route generation or BGP path identity.
    /\ n \in ownerNotifyObligation
    /\ ownerNotifyObligation' = ownerNotifyObligation \ {n}
    /\ notifyQueue' =
        IF zapiConn[n.owner] /\ ownerSubscribed[n.owner]
        THEN notifyQueue \cup {n}
        ELSE notifyQueue
    /\ UNCHANGED <<routeVars, dplaneVars, ownerSubscribed, zapiConn,
                  bgpPending, bgpInstalled, bgpInstalledGen, bgpSelectedGen,
                  zapiAddInFlight, zapiToZebra, nhtVars, metaVars, historyVars>>

OwnerNotifyDrop(n) ==
    \* Scenario 2 fault: ZAPI notification is lost after Zebra produced it.
    /\ n \in notifyQueue
    /\ notifyQueue' = notifyQueue \ {n}
    /\ lostNotifications' = lostNotifications + 1
    /\ UNCHANGED <<routeVars, dplaneVars, ownerSubscribed, zapiConn,
                  bgpPending, bgpInstalled, bgpInstalledGen, bgpSelectedGen,
                  zapiAddInFlight, zapiToZebra, ownerNotifyObligation, nhtVars, metaVars,
                  enqueueFailed, reconnects, staleResultApplied,
                  staleDplaneNotifyApplied, staleOwnerNotifyApplied>>

bgp_zebra_route_notify_owner(n) ==
    \* bgpd/bgp_zebra.c:3059-3075 decodes prefix/table and looks up the current
    \* BGP destination.
    \* bgpd/bgp_zebra.c:3086-3091 clears pending and marks installed on
    \* ZAPI_ROUTE_INSTALLED.
    \* bgpd/bgp_zebra.c:3124-3131 clears pending/installed on install failure.
    LET q == ChooseNotifyByBgpEvent(notifyQueue, n)
    IN
    /\ q \in notifyQueue
    /\ NotifyMatchesBgpEvent(q, n)
    /\ notifyQueue' = notifyQueue \ {q}
    /\ bgpPending' =
        IF q.note \in {"installed", "fail_install", "better_admin_won"}
        THEN [bgpPending EXCEPT ![q.prefix] = FALSE]
        ELSE bgpPending
    /\ bgpInstalled' =
        IF q.note = "installed"
        THEN [bgpInstalled EXCEPT ![q.prefix] = TRUE]
        ELSE IF q.note \in {"fail_install", "removed", "remove_fail", "better_admin_won"}
             THEN [bgpInstalled EXCEPT ![q.prefix] = FALSE]
             ELSE bgpInstalled
    /\ bgpInstalledGen' =
        IF q.note = "installed"
        THEN [bgpInstalledGen EXCEPT ![q.prefix] = bgpSelectedGen[q.prefix]]
        ELSE IF q.note \in {"fail_install", "removed", "remove_fail", "better_admin_won"}
             THEN [bgpInstalledGen EXCEPT ![q.prefix] = 0]
             ELSE bgpInstalledGen
    /\ staleOwnerNotifyApplied' =
        IF q.causeGen # bgpSelectedGen[q.prefix] /\ q.note # "none"
        THEN TRUE
        ELSE staleOwnerNotifyApplied
    /\ UNCHANGED <<routeVars, dplaneVars, ownerSubscribed, zapiConn,
                  bgpSelectedGen, zapiAddInFlight, zapiToZebra, ownerNotifyObligation,
                  nhtVars, metaVars, enqueueFailed, lostNotifications,
                  reconnects, staleResultApplied, staleDplaneNotifyApplied>>

----
\* RNH/NHT actions (Scenario 3)
----

zebra_add_rnh(p, o) ==
    \* zebra/zebra_rnh.c:167-245 creates an RNH entry and tries to store it on
    \* a covering route node.
    \* zebra/zebra_rnh.c:139-155 returns without attaching when route_node_match
    \* finds no current route node with info.
    /\ rnhRegistered[p][o] = FALSE
    /\ rnhRegistered' = [rnhRegistered EXCEPT ![p][o] = TRUE]
    /\ rnhAttachedDest' =
        IF selectedFib[p] # 0 THEN [rnhAttachedDest EXCEPT ![p] = TRUE]
        ELSE rnhAttachedDest
    /\ UNCHANGED <<routeVars, dplaneVars, ownerVars, rnhSnapshot,
                  nhtEvalNeeded, nhtQueue, nhtSuppressed, metaVars,
                  historyVars>>

zebra_rnh_store_in_routing_table(p) ==
    \* zebra/zebra_rnh.c:153-164 attaches RNH to a covering RIB dest when one
    \* exists.
    /\ \E o \in Owner : rnhRegistered[p][o]
    /\ selectedFib[p] # 0
    /\ rnhAttachedDest' = [rnhAttachedDest EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<routeVars, dplaneVars, ownerVars, rnhRegistered,
                  rnhSnapshot, nhtEvalNeeded, nhtQueue, nhtSuppressed,
                  metaVars, historyVars>>

zebra_rnh_resolve_nexthop_entry(p) ==
    \* zebra/zebra_rnh.c:692-694 requires route_node_match.
    \* zebra/zebra_rnh.c:723-748 skips removed entries and queued-but-not-
    \* installed routes.
    \* zebra/zebra_rnh.c:750-754 requires installed/usable nexthops.
    /\ nhtEvalNeeded[p]
    /\ rnhAttachedDest[p]
    /\ RNHResolvedFromRoute(p)
    /\ rnhSnapshot' = [rnhSnapshot EXCEPT ![p] = SnapshotFromRoute(p)]
    /\ nhtEvalNeeded' = [nhtEvalNeeded EXCEPT ![p] = FALSE]
    /\ nhtSuppressed' = [nhtSuppressed EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<routeVars, dplaneVars, ownerVars, rnhRegistered,
                  rnhAttachedDest, nhtQueue, metaVars, historyVars>>

compare_state_suppress(p) ==
    \* zebra/zebra_rnh.c:1020-1042 copies a reduced route_entry snapshot.
    \* zebra/zebra_rnh.c:1127-1148 compares type/distance/metric and valid
    \* primary nexthops, omitting route generation/path identity.
    /\ nhtEvalNeeded[p]
    /\ rnhAttachedDest[p]
    /\ rnhSnapshot[p].resolved
    /\ selectedFib[p] # rnhSnapshot[p].gen
    /\ ReducedRNHStateEqual(p)
    /\ nhtEvalNeeded' = [nhtEvalNeeded EXCEPT ![p] = FALSE]
    /\ nhtSuppressed' = [nhtSuppressed EXCEPT ![p] = TRUE]
    /\ UNCHANGED <<routeVars, dplaneVars, ownerVars, rnhRegistered,
                  rnhAttachedDest, rnhSnapshot, nhtQueue, metaVars,
                  historyVars>>

zebra_send_rnh_update(p) ==
    \* zebra/zebra_rnh.c:821-834 notifies clients when state_changed/force or
    \* SEND_NHT_REMOVAL is set.
    \* zebra/zebra_rnh.c:1218-1248 encodes reduced route type/instance/
    \* distance/metric/nexthops into ZEBRA_NEXTHOP_UPDATE.
    /\ rnhAttachedDest[p]
    /\ rnhSnapshot[p].resolved
    /\ Cardinality(nhtQueue) < MaxNotify
    /\ nhtQueue' =
        nhtQueue \cup
        {[ id       |-> 0,
           prefix   |-> p,
           owner    |-> DefaultOwner,
           table    |-> ribRoute[p].table,
           note     |-> "installed",
           causeGen |-> rnhSnapshot[p].gen ]}
    /\ UNCHANGED <<routeVars, dplaneVars, ownerVars, rnhRegistered,
                  rnhAttachedDest, rnhSnapshot, nhtEvalNeeded,
                  nhtSuppressed, metaVars, historyVars>>

----
\* Startup, reconnect, and shutdown actions (Scenario 4, Scenario 5)
----

ZebraRestart ==
    \* Scenario 4 reconnect fault: Zebra loses local route state while owners
    \* retain ownerLocalRoutes.
    /\ ~zebraRestarted
    /\ zebraRestarted' = TRUE
    /\ zapiConn' = [o \in Owner |-> FALSE]
    /\ ownerSubscribed' = [o \in Owner |-> FALSE]
    /\ ribRoute' = [p \in Prefix |-> NoRoute]
    /\ selectedFib' = [p \in Prefix |-> 0]
    /\ routeDplaneSeq' = [p \in Prefix |-> 0]
    /\ submitReady' = [p \in Prefix |-> FALSE]
    /\ submitGen' = [p \in Prefix |-> 0]
    /\ ctxDraft' = [p \in Prefix |-> NoCtx]
    /\ ctxQueue' = {}
    /\ providerIn' = {}
    /\ providerOut' = {}
    /\ resultQueue' = {}
    /\ ownerNotifyObligation' = {}
    /\ notifyQueue' = {}
    /\ zapiToZebra' = [p \in Prefix |-> FALSE]
    /\ zebraKnownRoutes' = [p \in Prefix |-> FALSE]
    /\ ribProcessReady' = [p \in Prefix |-> FALSE]
    /\ metaQ' = {}
    /\ queuedBits' = [p \in Prefix |-> {}]
    /\ UNCHANGED <<routeGen, kernelRoute, nhgInstalled, nextSeq, nextCtxId,
                  providerPrivate, providerAlive, shutdownStarted, bgpPending,
                  bgpInstalled, bgpInstalledGen, bgpSelectedGen,
                  zapiAddInFlight, rnhRegistered, rnhAttachedDest,
                  rnhSnapshot, nhtEvalNeeded, nhtQueue, nhtSuppressed,
                  ownerLocalRoutes, historyVars>>

rib_sweep_table(p) ==
    \* zebra/zebra_rib.c:4898-4955 marks old self-routes installed/FIB and then
    \* uninstalls/deletes them during startup sweep.
    /\ zebraRestarted
    /\ kernelRoute[p].installed
    /\ ribRoute' =
        [ribRoute EXCEPT
            ![p].present = TRUE,
            ![p].removed = TRUE,
            ![p].installed = TRUE,
            ![p].fibNH = TRUE]
    /\ submitReady' = [submitReady EXCEPT ![p] = TRUE]
    /\ submitGen' = [submitGen EXCEPT ![p] = kernelRoute[p].gen]
    /\ UNCHANGED <<selectedFib, routeGen, routeDplaneSeq, kernelRoute,
                  nhgInstalled, ctxDraft, nextSeq, nextCtxId, dplaneVars,
                  ownerVars, nhtVars, metaVars, historyVars>>

ProviderRestart ==
    \* Scenario 5 / zebra/zebra_dplane.c:8009-8032 shutdown pending checks only
    \* global/provider-visible queues, not provider-private queues.
    /\ providerPrivate /= {}
    /\ providerPrivate' = {}
    /\ providerAlive' = TRUE
    /\ UNCHANGED <<routeVars, ctxQueue, providerIn, providerOut, resultQueue,
                  shutdownStarted, ownerVars, nhtVars, metaVars, historyVars>>

zebra_dplane_shutdown ==
    \* zebra/zebra_dplane.c:8009-8047 checks incoming/provider in/out queues.
    \* zebra/zebra_dplane.c:8076-8088 finalizes when no visible work remains.
    /\ ~shutdownStarted
    /\ ctxQueue = {}
    /\ providerIn = {}
    /\ providerOut = {}
    /\ resultQueue = {}
    /\ shutdownStarted' = TRUE
    /\ providerAlive' = FALSE
    /\ UNCHANGED <<routeVars, ctxQueue, providerIn, providerOut,
                  providerPrivate, resultQueue, ownerVars, nhtVars,
                  metaVars, historyVars>>

----
\* Next-state relation
----

Next ==
    \/ \E o \in Owner, p \in Prefix : bgp_zebra_route_install(o, p)
    \/ \E o \in Owner, p \in Prefix : bgp_handle_route_announcements_to_zebra(o, p)
    \/ \E o \in Owner, p \in Prefix : ZapiSendFail(o, p)
    \/ \E o \in Owner : zread_route_notify_request(o)
    \/ \E o \in Owner : bgp_zebra_connected(o)
    \/ \E o \in Owner, p \in Prefix : bgp_zebra_announce_table(o, p)
    \/ \E o \in Owner, p \in Prefix, t \in TableId : rib_addnode(p, o, t)
    \/ \E p \in Prefix : rib_delnode(p)
    \/ \E p \in Prefix, q \in QueueKind : rib_meta_queue_add(p, q)
    \/ \E p \in Prefix, q \in QueueKind : meta_queue_process(p, q)
    \/ \E p \in Prefix : rib_process(p)
    \/ \E p \in Prefix : rib_install_kernel(p)
    \/ \E p \in Prefix : rib_uninstall_kernel(p)
    \/ \E p \in Prefix : dplane_ctx_route_init(p)
    \/ \E p \in Prefix : dplane_update_enqueue(ctxDraft[p])
    \/ \E p \in Prefix : dplane_update_enqueue_failure(ctxDraft[p])
    \/ \E c \in ctxQueue : dplane_thread_loop_to_provider(c)
    \/ \E c \in providerIn : kernel_dplane_process_func_success(c)
    \/ \E c \in providerIn : kernel_dplane_process_func_failure(c)
    \/ \E c \in providerIn : kernel_dplane_process_func_skip_kernel(c)
    \/ \E c \in providerIn : fpm_nl_process_private(c)
    \/ \E c \in providerPrivate : fpm_process_queue(c)
    \/ \E c \in providerOut : dplane_thread_loop_result(c)
    \/ \E c \in providerOut \cup resultQueue : dplane_result_lost(c)
    \/ \E p \in Prefix, g \in 0..MaxGen : DPLANE_OP_ROUTE_NOTIFY(p, g)
    \/ \E c \in resultQueue : rib_process_result(c)
    \/ \E c \in resultQueue : rib_process_dplane_notify(c)
    \/ \E n \in ownerNotifyObligation : route_notify_internal(n)
    \/ \E n \in notifyQueue : OwnerNotifyDrop(n)
    \/ \E n \in notifyQueue : bgp_zebra_route_notify_owner(n)
    \/ \E o \in Owner, p \in Prefix : zebra_add_rnh(p, o)
    \/ \E p \in Prefix : zebra_rnh_store_in_routing_table(p)
    \/ \E p \in Prefix : zebra_rnh_resolve_nexthop_entry(p)
    \/ \E p \in Prefix : compare_state_suppress(p)
    \/ \E p \in Prefix : zebra_send_rnh_update(p)
    \/ ZebraRestart
    \/ \E p \in Prefix : rib_sweep_table(p)
    \/ ProviderRestart
    \/ zebra_dplane_shutdown

Spec == Init /\ [][Next]_vars

----
\* Type and structural invariants
----

TypeOK ==
    /\ ribRoute \in [Prefix -> RouteRecSet]
    /\ selectedFib \in [Prefix -> 0..MaxGen]
    /\ routeGen \in [Prefix -> 0..MaxGen]
    /\ routeDplaneSeq \in [Prefix -> 0..MaxSeq]
    /\ kernelRoute \in [Prefix -> KernelRecSet]
    /\ nhgInstalled \in [Prefix -> BOOLEAN]
    /\ submitReady \in [Prefix -> BOOLEAN]
    /\ submitGen \in [Prefix -> 0..MaxGen]
    /\ ctxDraft \in [Prefix -> CtxRecSet]
    /\ nextSeq \in 1..(MaxSeq + 1)
    /\ nextCtxId \in 1..(MaxCtx + 1)
    /\ ctxQueue \subseteq CtxRecSet
    /\ providerIn \subseteq CtxRecSet
    /\ providerOut \subseteq CtxRecSet
    /\ providerPrivate \subseteq CtxRecSet
    /\ resultQueue \subseteq CtxRecSet
    /\ providerAlive \in BOOLEAN
    /\ shutdownStarted \in BOOLEAN
    /\ ownerSubscribed \in [Owner -> BOOLEAN]
    /\ zapiConn \in [Owner -> BOOLEAN]
    /\ bgpPending \in [Prefix -> BOOLEAN]
    /\ bgpInstalled \in [Prefix -> BOOLEAN]
    /\ bgpInstalledGen \in [Prefix -> 0..MaxGen]
    /\ bgpSelectedGen \in [Prefix -> 0..MaxGen]
    /\ zapiAddInFlight \in [Prefix -> BOOLEAN]
    /\ zapiToZebra \in [Prefix -> BOOLEAN]
    /\ ownerNotifyObligation \subseteq NotifyRecSet
    /\ notifyQueue \subseteq NotifyRecSet
    /\ rnhRegistered \in [Prefix -> [Owner -> BOOLEAN]]
    /\ rnhAttachedDest \in [Prefix -> BOOLEAN]
    /\ rnhSnapshot \in [Prefix -> RNHRecSet]
    /\ nhtEvalNeeded \in [Prefix -> BOOLEAN]
    /\ nhtQueue \subseteq NotifyRecSet
    /\ nhtSuppressed \in [Prefix -> BOOLEAN]
    /\ metaQ \subseteq [prefix : Prefix, q : QueueKind]
    /\ queuedBits \in [Prefix -> SUBSET QueueKind]
    /\ ribProcessReady \in [Prefix -> BOOLEAN]
    /\ zebraKnownRoutes \in [Prefix -> BOOLEAN]
    /\ ownerLocalRoutes \in [Prefix -> BOOLEAN]
    /\ zebraRestarted \in BOOLEAN
    /\ enqueueFailed \in [Prefix -> BOOLEAN]
    /\ lostNotifications \in Nat
    /\ reconnects \in Nat
    /\ staleResultApplied \in BOOLEAN
    /\ staleDplaneNotifyApplied \in BOOLEAN
    /\ staleOwnerNotifyApplied \in BOOLEAN

CtxIdsUnique ==
    \A S \in {ctxQueue, providerIn, providerOut, providerPrivate, resultQueue} :
        \A c1, c2 \in S : c1.id = c2.id => c1 = c2

DraftsMatchPrefix ==
    \A p \in Prefix :
        ctxDraft[p].id = 0 \/ ctxDraft[p].prefix = p

SelectedFibReferencesRoute ==
    \A p \in Prefix :
        selectedFib[p] = 0 \/
        /\ ribRoute[p].present
        /\ selectedFib[p] <= routeGen[p]

----
\* Scenario invariants
----

OwnerInstalledImpliesCurrentFib ==
    \* Brief §5, Scenario 2.
    \A p \in Prefix :
        bgpInstalled[p] =>
            /\ selectedFib[p] = bgpInstalledGen[p]
            /\ ribRoute[p].present
            /\ ribRoute[p].installed
            /\ kernelRoute[p].installed
            /\ kernelRoute[p].gen = selectedFib[p]
            /\ kernelRoute[p].attrs = ribRoute[p].attrs

NoStaleDplaneMutation ==
    \* Brief §5, Scenario 1.
    /\ ~staleResultApplied
    /\ ~staleDplaneNotifyApplied

SelectedFibNeedsTerminalResult ==
    \* Brief §5, Scenario 1 safety projection of the terminal-result liveness:
    \* selected_fib must have terminal state, explicit enqueue-failed state, or
    \* outstanding dataplane/owner work unless shutdown has started.
    \A p \in Prefix :
        selectedFib[p] # 0 =>
            \/ ribRoute[p].installed
            \/ ribRoute[p].failed
            \/ enqueueFailed[p]
            \/ HasOutstandingDplane(p)
            \/ HasOwnerNotificationWork(p)
            \/ shutdownStarted

PendingImpliesOutstandingWork ==
    \* Brief §5, Scenario 2.
    \A p \in Prefix :
        bgpPending[p] =>
            /\ ownerLocalRoutes[p]
            /\ \E o \in Owner : zapiConn[o]
            /\ (zapiAddInFlight[p] \/ HasOutstandingDplane(p) \/ HasOwnerNotificationWork(p))

NotifyAppliesToMatchingGeneration ==
    \* Brief §5, Scenario 2.
    ~staleOwnerNotifyApplied

NHTResolvedImpliesConfirmedRoute ==
    \* Brief §5, Scenario 3.
    \A p \in Prefix :
        /\ rnhSnapshot[p].resolved
        /\ ~nhtEvalNeeded[p]
        =>
            /\ selectedFib[p] = rnhSnapshot[p].gen
            /\ ribRoute[p].present
            /\ ribRoute[p].installed
            /\ ribRoute[p].activeNH
            /\ kernelRoute[p].installed
            /\ kernelRoute[p].gen = selectedFib[p]
            /\ kernelRoute[p].fibNH
            /\ ~nhtSuppressed[p]

MetaQSingleVisibleMembership ==
    \* Brief §5, Scenario 4.
    \A p \in Prefix :
        queuedBits[p] # {} =>
            /\ Cardinality(queuedBits[p]) <= 1
            /\ VisibleQueued(p)
            /\ \E q \in queuedBits[p] : [prefix |-> p, q |-> q] \in metaQ

ProviderSuccessImpliesRealizedAttrs ==
    \* Scenario 5 extension: provider success must correspond to realized
    \* kernel route attributes, not only Zebra RIB success state.
    \A p \in Prefix :
        ribRoute[p].installed =>
            /\ kernelRoute[p].installed
            /\ kernelRoute[p].gen = selectedFib[p]
            /\ kernelRoute[p].attrs = ribRoute[p].attrs

----
\* Temporal properties from brief §5
----

RNHRegistrationEventuallyAttached ==
    \* Brief §5, Scenario 3 liveness.
    \A p \in Prefix, o \in Owner :
        []( (rnhRegistered[p][o] /\ selectedFib[p] # 0 /\ ribRoute[p].present)
            => <>rnhAttachedDest[p] )

ReconnectEventuallyReplays ==
    \* Brief §5, Scenario 4 liveness.
    []( (zebraRestarted /\ \E p \in Prefix : ownerLocalRoutes[p])
        => <>(\A p \in Prefix : ownerLocalRoutes[p] => (zebraKnownRoutes[p] \/ ~bgpPending[p])) )

SafetyInvariants ==
    /\ OwnerInstalledImpliesCurrentFib
    /\ NoStaleDplaneMutation
    /\ SelectedFibNeedsTerminalResult
    /\ PendingImpliesOutstandingWork
    /\ NotifyAppliesToMatchingGeneration
    /\ NHTResolvedImpliesConfirmedRoute
    /\ MetaQSingleVisibleMembership
    /\ ProviderSuccessImpliesRealizedAttrs

=====================================================================
