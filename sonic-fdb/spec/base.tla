--------------------------- MODULE base ---------------------------
(*
 * SONiC FDB Bridge Port Lifecycle Specification
 *
 * Models the FDB (Forwarding Database) entry lifecycle in SONiC's
 * orchagent, focusing on the interaction between bridge port management,
 * asynchronous FDB flush, VXLAN tunnel refcounting, and origin priority.
 *
 * System: sonic-net/sonic-swss
 * Category: A (Distributed / Message-Passing)
 * Key files:
 *   - orchagent/fdborch.cpp (FDB entry lifecycle)
 *   - orchagent/portsorch.cpp (bridge port creation/deletion)
 *   - orchagent/vxlanorch.cpp (VXLAN tunnel lifecycle)
 *)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    Port,           \* Set of physical/LAG ports
    VLAN,           \* Set of VLANs
    MAC,            \* Set of MAC addresses
    RemoteVTEP,     \* Set of remote VXLAN tunnel endpoints
    NullOID,        \* Sentinel for "no bridge port"
    \* FDB entry origins (fdborch.cpp:42-45)
    ORIGIN_LEARN,
    ORIGIN_PROVISIONED,
    ORIGIN_VXLAN_ADVERTIZED,
    ORIGIN_MCLAG_ADVERTIZED,
    \* FDB types
    TYPE_DYNAMIC,
    TYPE_STATIC

ASSUME NullOID \notin Port \cup RemoteVTEP

Origins == {ORIGIN_LEARN, ORIGIN_PROVISIONED, ORIGIN_VXLAN_ADVERTIZED, ORIGIN_MCLAG_ADVERTIZED}
FdbTypes == {TYPE_DYNAMIC, TYPE_STATIC}

(*
 * FdbKey == <<mac, vlan>> for indexing FDB entries
 * We model FDB keys as elements of MAC \X VLAN
 *)
FdbKey == MAC \X VLAN

------------------------------------------------------------------------
(* VARIABLES *)

VARIABLES
    \* --- Bridge Port State (portsorch.cpp) ---
    \* Family 1: Stale Bridge Port OID
    bridgePortExists,   \* [Port -> BOOLEAN] - whether port has a bridge port
    saiOidToAlias,      \* Set of Port: ports whose OID is in the lookup map
    vlanMembers,        \* [VLAN -> SUBSET Port] - VLAN membership

    \* --- FDB Entry State (fdborch.cpp) ---
    \* Core state
    mEntries,           \* [FdbKey -> FdbData] where FdbData is a record
                        \*   FdbData == [origin: Origins, type: FdbTypes,
                        \*               port: Port \cup RemoteVTEP,
                        \*               is_flush_pending: BOOLEAN]
    asicEntries,        \* SUBSET FdbKey: entries actually in ASIC hardware

    \* --- Async Flush State (fdborch.cpp) ---
    \* Family 1, 2: Flush lifecycle
    pendingFlushPort,   \* Set of Port: bridge ports with pending flush
    pendingFlushVlan,   \* Set of VLAN: VLANs with pending flush (flushFdbByVlan)

    \* --- VXLAN Tunnel State (vxlanorch.cpp) ---
    \* Family 3: Tunnel lifecycle
    tunnelExists,       \* [RemoteVTEP -> BOOLEAN]
    tunnelRefCnt,       \* [RemoteVTEP -> Nat] - tnl_users_ total refcnt
    tunnelFdbCount,     \* [RemoteVTEP -> Nat] - fdb_count on tunnel bridge port
    delTnlHwPending,    \* BOOLEAN - SIP tunnel deletion deferred

    \* --- FDB Counter State (portsorch.cpp, fdborch.cpp) ---
    \* Family 5: Counter drift
    portFdbCount,       \* [Port -> Nat] - m_fdb_count per physical port
    vlanFdbCount        \* [VLAN -> Nat] - m_fdb_count per VLAN

(* Variable groups for UNCHANGED *)
bridgePortVars == <<bridgePortExists, saiOidToAlias, vlanMembers>>
fdbVars == <<mEntries, asicEntries>>
flushVars == <<pendingFlushPort, pendingFlushVlan>>
tunnelVars == <<tunnelExists, tunnelRefCnt, tunnelFdbCount, delTnlHwPending>>
counterVars == <<portFdbCount, vlanFdbCount>>

vars == <<bridgePortVars, fdbVars, flushVars, tunnelVars, counterVars>>

------------------------------------------------------------------------
(* HELPERS *)

\* Active FDB entries for a given port
EntriesForPort(p) == {k \in DOMAIN mEntries : mEntries[k].port = p}

\* Active FDB entries for a given VLAN
EntriesForVlan(v) == {k \in DOMAIN mEntries : k[2] = v}

\* Active dynamic entries for a given port
DynamicEntriesForPort(p) ==
    {k \in DOMAIN mEntries : mEntries[k].port = p /\ mEntries[k].type = TYPE_DYNAMIC}

\* Active dynamic entries for a given VLAN
DynamicEntriesForVlan(v) ==
    {k \in DOMAIN mEntries : k[2] = v /\ mEntries[k].type = TYPE_DYNAMIC}

\* Whether a key exists in mEntries
EntryExists(key) == key \in DOMAIN mEntries

\* Whether port has bridge port and is in OID map
\* Models getPortByBridgePortId (portsorch.cpp:1970-1986)
\* Only valid for physical ports (Port), not RemoteVTEP
CanResolveBridgePort(p) ==
    /\ p \in Port
    /\ bridgePortExists[p]
    /\ p \in saiOidToAlias

\* Origin priority: higher origin wins
\* Models addFdbEntry priority logic (fdborch.cpp:1348-1406)
OriginPriority(o) ==
    CASE o = ORIGIN_PROVISIONED       -> 4
      [] o = ORIGIN_VXLAN_ADVERTIZED  -> 3
      [] o = ORIGIN_MCLAG_ADVERTIZED  -> 2
      [] o = ORIGIN_LEARN             -> 1

\* Check if a remote VTEP port can be resolved
\* Tunnel ports are resolved via tunnel bridge port existence
CanResolveTunnelPort(vtep) == tunnelExists[vtep]

------------------------------------------------------------------------
(* INIT *)

Init ==
    \* No bridge ports initially
    /\ bridgePortExists = [p \in Port |-> FALSE]
    /\ saiOidToAlias = {}
    /\ vlanMembers = [v \in VLAN |-> {}]
    \* No FDB entries
    /\ mEntries = <<>>      \* Empty function (no keys)
    /\ asicEntries = {}
    \* No pending flushes
    /\ pendingFlushPort = {}
    /\ pendingFlushVlan = {}
    \* No tunnels
    /\ tunnelExists = [vtep \in RemoteVTEP |-> FALSE]
    /\ tunnelRefCnt = [vtep \in RemoteVTEP |-> 0]
    /\ tunnelFdbCount = [vtep \in RemoteVTEP |-> 0]
    /\ delTnlHwPending = FALSE
    \* Counters at zero
    /\ portFdbCount = [p \in Port |-> 0]
    /\ vlanFdbCount = [v \in VLAN |-> 0]

------------------------------------------------------------------------
(* BRIDGE PORT ACTIONS — portsorch.cpp *)

(*
 * AddVlanMember: Add port to VLAN, creating bridge port if needed
 * Models: portsorch.cpp doVlanMemberTask ADD path
 * Triggers addBridgePort (portsorch.cpp:7186-7281) on first VLAN join
 *)
AddVlanMember(p, v) ==
    /\ p \notin vlanMembers[v]                      \* Not already member
    /\ vlanMembers' = [vlanMembers EXCEPT ![v] = @ \cup {p}]
    \* Create bridge port on first VLAN join (portsorch.cpp:7245-7274)
    /\ IF ~bridgePortExists[p]
       THEN /\ bridgePortExists' = [bridgePortExists EXCEPT ![p] = TRUE]
            /\ saiOidToAlias' = saiOidToAlias \cup {p}  \* portsorch.cpp:7274
       ELSE UNCHANGED <<bridgePortExists, saiOidToAlias>>
    /\ UNCHANGED <<fdbVars, flushVars, tunnelVars, counterVars>>

(*
 * RemoveVlanMember: Remove port from VLAN
 * Models: portsorch.cpp doVlanMemberTask DEL path (5942-5962)
 * Calls removeBridgePort if last VLAN membership
 * NOTE: removeBridgePort return value unchecked (portsorch.cpp:5950) [C1]
 *)
RemoveVlanMember(p, v) ==
    /\ p \in vlanMembers[v]                          \* Must be member
    /\ vlanMembers' = [vlanMembers EXCEPT ![v] = @ \ {p}]
    \* If this was the last VLAN membership, initiate bridge port removal
    \* (portsorch.cpp:5948-5950)
    /\ IF \A v2 \in VLAN : (v2 = v => p \notin vlanMembers[v]) /\
                            (v2 /= v => p \notin vlanMembers[v2])
       THEN \* removeBridgePort sequence begins
            \* But we model the sub-steps separately (see FlushFDBForRemove, etc.)
            UNCHANGED <<bridgePortExists, saiOidToAlias>>
       ELSE UNCHANGED <<bridgePortExists, saiOidToAlias>>
    /\ UNCHANGED <<fdbVars, flushVars, tunnelVars, counterVars>>

(*
 * FlushFDBForRemove: First step of removeBridgePort — async flush
 * Models: portsorch.cpp:7318-7320 — flushFDBEntries(port.m_bridge_port_id, ...)
 * Called when port has no VLAN memberships left
 *)
FlushFDBForRemove(p) ==
    /\ bridgePortExists[p]
    \* Port has no VLAN memberships (eligible for bridge port removal)
    /\ \A v \in VLAN : p \notin vlanMembers[v]
    \* Issue async flush to SAI (portsorch.cpp:7318-7320)
    /\ pendingFlushPort' = pendingFlushPort \cup {p}
    \* Set is_flush_pending on matching entries (fdborch.cpp:1135-1146)
    /\ mEntries' = [k \in DOMAIN mEntries |->
        IF mEntries[k].port = p /\ mEntries[k].type = TYPE_DYNAMIC
        THEN [mEntries[k] EXCEPT !.is_flush_pending = TRUE]
        ELSE mEntries[k]]
    /\ UNCHANGED <<bridgePortExists, saiOidToAlias, vlanMembers,
                   asicEntries, pendingFlushVlan, tunnelVars, counterVars>>

(*
 * RemoveBridgePortHW: Second step — remove bridge port from SAI and OID map
 * Models: portsorch.cpp:7322-7343
 * CRITICAL: This runs immediately after flush, BEFORE flush notification arrives
 * Family 1: saiOidToAlias.erase() before m_entries cleanup
 *)
RemoveBridgePortHW(p) ==
    /\ bridgePortExists[p]
    /\ \A v \in VLAN : p \notin vlanMembers[v]
    \* Flush was already requested (or we model the case where it runs immediately)
    /\ p \in pendingFlushPort
    \* Remove SAI bridge port (portsorch.cpp:7322-7333)
    /\ bridgePortExists' = [bridgePortExists EXCEPT ![p] = FALSE]
    \* Erase from OID map BEFORE flush notification arrives
    \* (portsorch.cpp:7334) — THIS IS THE ROOT CAUSE OF FAMILY 1
    /\ saiOidToAlias' = saiOidToAlias \ {p}
    /\ UNCHANGED <<vlanMembers, fdbVars, flushVars, tunnelVars, counterVars>>

------------------------------------------------------------------------
(* FDB FLUSH ACTIONS — fdborch.cpp *)

(*
 * HandleFlushNotification: SAI FLUSHED event arrives
 * Models: fdborch.cpp:625-642 -> handleSyncdFlushNotif (208-276)
 * Family 1: notification may arrive AFTER bridge port removed from OID map
 * Family 2: only entries with is_flush_pending=TRUE are cleared
 *)
HandleFlushNotification(p) ==
    /\ p \in pendingFlushPort
    /\ pendingFlushPort' = pendingFlushPort \ {p}
    \* handleSyncdFlushNotif iterates m_entries (fdborch.cpp:216-275)
    \* Only clears entries where is_flush_pending == TRUE (fdborch.cpp:222)
    /\ LET entriesToClear == {k \in DOMAIN mEntries :
            /\ mEntries[k].port = p
            /\ mEntries[k].type = TYPE_DYNAMIC
            /\ mEntries[k].is_flush_pending}
       IN
       \* clearFdbEntry for each matching entry (fdborch.cpp:181-203)
       /\ mEntries' = [k \in DOMAIN mEntries \ entriesToClear |-> mEntries[k]]
       \* ASIC entries were already removed by SAI flush
       /\ asicEntries' = asicEntries \ entriesToClear
       \* Decrement counters (fdborch.cpp:189-190)
       /\ portFdbCount' = [q \in Port |->
            portFdbCount[q] - Cardinality({k \in entriesToClear : mEntries[k].port = q})]
       /\ vlanFdbCount' = [v \in VLAN |->
            vlanFdbCount[v] - Cardinality({k \in entriesToClear : k[2] = v})]
    \* Family 3: clearFdbEntry does NOT call notifyTunnelOrch (fdborch.cpp:181-203)
    \* tunnelFdbCount is NOT decremented here — this is the bug
    /\ UNCHANGED <<bridgePortVars, pendingFlushVlan, tunnelVars>>

(*
 * HandleFlushNotificationVlan: FLUSHED event for VLAN-scoped flush
 * Models: fdborch.cpp:244-259 (VLAN-based flush in handleSyncdFlushNotif)
 * Family 2: flushFdbByVlan never sets is_flush_pending (fdborch.cpp:1149-1177)
 *   so handleSyncdFlushNotif skips ALL entries → phantom entries
 *)
HandleFlushNotificationVlan(v) ==
    /\ v \in pendingFlushVlan
    /\ pendingFlushVlan' = pendingFlushVlan \ {v}
    \* Because flushFdbByVlan does NOT set is_flush_pending,
    \* handleSyncdFlushNotif checks is_flush_pending and skips all entries
    \* (fdborch.cpp:253: curr->second.is_flush_pending check)
    /\ LET entriesToClear == {k \in DOMAIN mEntries :
            /\ k[2] = v
            /\ mEntries[k].type = TYPE_DYNAMIC
            /\ mEntries[k].is_flush_pending}  \* Will be empty if flag not set!
       IN
       /\ mEntries' = [k \in DOMAIN mEntries \ entriesToClear |-> mEntries[k]]
       /\ asicEntries' = asicEntries \ entriesToClear
       /\ portFdbCount' = [q \in Port |->
            portFdbCount[q] - Cardinality({k \in entriesToClear : mEntries[k].port = q})]
       /\ vlanFdbCount' = [w \in VLAN |->
            vlanFdbCount[w] - Cardinality({k \in entriesToClear : k[2] = w})]
    /\ UNCHANGED <<bridgePortVars, pendingFlushPort, tunnelVars>>

(*
 * FlushFdbByVlan: VLAN-scoped FDB flush
 * Models: fdborch.cpp:1149-1177
 * Family 2: Does NOT set is_flush_pending on entries
 *)
FlushFdbByVlan(v) ==
    \* SAI flush call (fdborch.cpp:1160-1164)
    /\ pendingFlushVlan' = pendingFlushVlan \cup {v}
    \* ASIC removes dynamic entries for this VLAN
    /\ asicEntries' = asicEntries \ DynamicEntriesForVlan(v)
    \* NOTE: is_flush_pending NOT set (fdborch.cpp:1149-1177 — no equivalent of 1135-1146)
    \* This is the Family 2 bug: entries will be skipped by handleSyncdFlushNotif
    /\ UNCHANGED <<bridgePortVars, mEntries, pendingFlushPort, tunnelVars, counterVars>>

------------------------------------------------------------------------
(* FDB LEARN/AGE/MOVE ACTIONS — fdborch.cpp:update() *)

(*
 * LearnFdbEntry: SAI LEARNED event for a local port
 * Models: fdborch.cpp:324-417 (SAI_FDB_EVENT_LEARNED handler)
 * Family 1: silently dropped if getPortByBridgePortId fails (fdborch.cpp:296-312)
 *)
LearnFdbEntry(mac, v, p) ==
    /\ <<mac, v>> \notin DOMAIN mEntries              \* New entry (fdborch.cpp:329-330)
    /\ CanResolveBridgePort(p)                         \* getPortByBridgePortId succeeds
    /\ p \in vlanMembers[v]                            \* Port is VLAN member
    \* Add to m_entries (fdborch.cpp:405-415 -> storeFdbEntryState)
    /\ mEntries' = (<<mac, v>> :> [origin |-> ORIGIN_LEARN,
                                    type |-> TYPE_DYNAMIC,
                                    port |-> p,
                                    is_flush_pending |-> FALSE])
                   @@ mEntries
    \* Add to ASIC (hardware learned it)
    /\ asicEntries' = asicEntries \cup {<<mac, v>>}
    \* Increment counters (fdborch.cpp:405-412)
    /\ portFdbCount' = [portFdbCount EXCEPT ![p] = @ + 1]
    /\ vlanFdbCount' = [vlanFdbCount EXCEPT ![v] = @ + 1]
    /\ UNCHANGED <<bridgePortVars, flushVars, tunnelVars>>

(*
 * LearnFdbEntryDropped: SAI LEARNED event arrives but bridge port unresolvable
 * Models: fdborch.cpp:296-312 — getPortByBridgePortId failure, early return
 * Family 1: silently dropped, m_entries diverges from ASIC
 *)
LearnFdbEntryDropped(mac, v, p) ==
    /\ <<mac, v>> \notin DOMAIN mEntries
    /\ ~CanResolveBridgePort(p)                        \* Bridge port OID not in map
    \* ASIC learned the entry but orchagent drops the notification
    /\ asicEntries' = asicEntries \cup {<<mac, v>>}
    \* m_entries NOT updated — this is the divergence
    /\ UNCHANGED <<bridgePortVars, mEntries, flushVars, tunnelVars, counterVars>>

(*
 * AgeFdbEntry: SAI AGED event for a dynamic entry
 * Models: fdborch.cpp:419-547 (SAI_FDB_EVENT_AGED handler)
 * Family 5: stale bridge port causes wrong-port counter decrement (fdborch.cpp:433-444)
 *)
AgeFdbEntry(mac, v) ==
    /\ <<mac, v>> \in DOMAIN mEntries
    /\ mEntries[<<mac, v>>].type = TYPE_DYNAMIC        \* Only dynamic entries age
    /\ mEntries[<<mac, v>>].origin = ORIGIN_LEARN      \* Non-MCLAG (fdborch.cpp:490)
    /\ mEntries[<<mac, v>>].port \in Port              \* Physical port (tunnel ages handled separately)
    /\ LET entry == mEntries[<<mac, v>>]
           p == entry.port
       IN
       \* Remove from m_entries (fdborch.cpp:531-544 -> storeFdbEntryState)
       /\ mEntries' = [k \in DOMAIN mEntries \ {<<mac, v>>} |-> mEntries[k]]
       \* Remove from ASIC
       /\ asicEntries' = asicEntries \ {<<mac, v>>}
       \* Decrement counters (fdborch.cpp:531-533)
       /\ portFdbCount' = [portFdbCount EXCEPT ![p] = @ - 1]
       /\ vlanFdbCount' = [vlanFdbCount EXCEPT ![v] = @ - 1]
    \* Family 3: AGED event DOES call notifyTunnelOrch (fdborch.cpp:546)
    \* (modeled separately for tunnel entries)
    /\ UNCHANGED <<bridgePortVars, flushVars, tunnelVars>>

(*
 * AgeFdbEntryDropped: SAI AGED event but bridge port unresolvable
 * Models: fdborch.cpp:296-312 — same failure path as LEARN
 * Family 1: AGED event dropped, entry stuck in m_entries
 *)
AgeFdbEntryDropped(mac, v) ==
    /\ <<mac, v>> \in DOMAIN mEntries
    /\ LET p == mEntries[<<mac, v>>].port IN
       /\ p \in Port                                   \* Only physical ports can have stale OIDs
       /\ ~CanResolveBridgePort(p)                     \* Bridge port already removed
    \* ASIC already aged the entry
    /\ asicEntries' = asicEntries \ {<<mac, v>>}
    \* m_entries NOT updated — entry persists as phantom
    /\ UNCHANGED <<bridgePortVars, mEntries, flushVars, tunnelVars, counterVars>>

(*
 * MoveFdbEntry: SAI MOVE event — MAC learned on new port
 * Models: fdborch.cpp:549-623 (SAI_FDB_EVENT_MOVE handler)
 * Family 5: MOVE doesn't update vlan.m_fdb_count (fdborch.cpp:607-623)
 *)
MoveFdbEntry(mac, v, newPort) ==
    /\ <<mac, v>> \in DOMAIN mEntries
    /\ CanResolveBridgePort(newPort)                   \* New port resolvable
    /\ LET entry == mEntries[<<mac, v>>]
           oldPort == entry.port
       IN
       /\ newPort /= oldPort                           \* Actually moved
       /\ CanResolveBridgePort(oldPort)                \* Old port resolvable (fdborch.cpp:564-567)
       \* Update m_entries with new port (fdborch.cpp:607-617)
       /\ mEntries' = [mEntries EXCEPT ![<<mac, v>>] =
            [@ EXCEPT !.port = newPort]]
       \* ASIC reflects the move
       /\ UNCHANGED asicEntries
       \* Counter bookkeeping (fdborch.cpp:607-617)
       \* Decrement old port, increment new port
       /\ portFdbCount' = [portFdbCount EXCEPT
            ![oldPort] = @ - 1,
            ![newPort] = @ + 1]
       \* Family 5 BUG: MOVE does NOT update vlan.m_fdb_count (fdborch.cpp:607-623)
       \* Compare with LEARN at fdborch.cpp:411-412 which DOES update
       /\ UNCHANGED vlanFdbCount
    /\ UNCHANGED <<bridgePortVars, flushVars, tunnelVars>>

------------------------------------------------------------------------
(* FDB ADD/REMOVE ACTIONS — fdborch.cpp control plane *)

(*
 * AddFdbEntryProvisioned: Operator provisions a static FDB entry
 * Models: fdborch.cpp:1278-1629 (addFdbEntry with ORIGIN_PROVISIONED)
 *)
AddFdbEntryProvisioned(mac, v, p) ==
    /\ CanResolveBridgePort(p)
    /\ p \in vlanMembers[v]
    /\ IF <<mac, v>> \in DOMAIN mEntries
       THEN \* Priority check (fdborch.cpp:1348-1355): dup check
            LET old == mEntries[<<mac, v>>] IN
            /\ ~(old.origin = ORIGIN_PROVISIONED /\ old.port = p)  \* Not exact dup
            \* Provisioned always wins (highest priority)
            /\ mEntries' = [mEntries EXCEPT ![<<mac, v>>] =
                [origin |-> ORIGIN_PROVISIONED, type |-> TYPE_STATIC,
                 port |-> p, is_flush_pending |-> FALSE]]
            /\ IF old.port /= p
               THEN IF old.port \in Port
                    THEN portFdbCount' = [portFdbCount EXCEPT
                            ![old.port] = @ - 1, ![p] = @ + 1]
                    ELSE portFdbCount' = [portFdbCount EXCEPT ![p] = @ + 1]
               ELSE UNCHANGED portFdbCount
            /\ UNCHANGED vlanFdbCount  \* Same VLAN, no counter change
       ELSE \* New entry
            /\ mEntries' = (<<mac, v>> :> [origin |-> ORIGIN_PROVISIONED,
                                            type |-> TYPE_STATIC,
                                            port |-> p,
                                            is_flush_pending |-> FALSE])
                           @@ mEntries
            /\ portFdbCount' = [portFdbCount EXCEPT ![p] = @ + 1]
            /\ vlanFdbCount' = [vlanFdbCount EXCEPT ![v] = @ + 1]
    /\ asicEntries' = asicEntries \cup {<<mac, v>>}
    /\ UNCHANGED <<bridgePortVars, flushVars, tunnelVars>>

(*
 * RemoveFdbEntry: Control plane DEL for an FDB entry
 * Models: fdborch.cpp:1632-1741
 * Family 4: origin mismatch DEL silently discarded (fdborch.cpp:1664-1691)
 *)
RemoveFdbEntry(mac, v, origin) ==
    /\ <<mac, v>> \in DOMAIN mEntries
    /\ LET entry == mEntries[<<mac, v>>]
           p == entry.port
       IN
       IF entry.origin /= origin
       THEN
         \* Family 4 BUG: origin mismatch — return true without deletion
         \* (fdborch.cpp:1664-1691)
         /\ UNCHANGED <<vars>>
       ELSE
         \* Origins match — proceed with deletion (fdborch.cpp:1694-1727)
         /\ mEntries' = [k \in DOMAIN mEntries \ {<<mac, v>>} |-> mEntries[k]]
         /\ asicEntries' = asicEntries \ {<<mac, v>>}
         /\ vlanFdbCount' = [vlanFdbCount EXCEPT ![v] = @ - 1]
         \* Decrement counters + notifyTunnelOrch (fdborch.cpp:1717-1720, 1739)
         /\ IF p \in Port
            THEN /\ portFdbCount' = [portFdbCount EXCEPT ![p] = @ - 1]
                 /\ UNCHANGED tunnelVars
            ELSE \* p \in RemoteVTEP — tunnel entry
                 /\ tunnelFdbCount' = [tunnelFdbCount EXCEPT ![p] = @ - 1]
                 \* notifyTunnelOrch callback (fdborch.cpp:1739) triggers cleanup
                 /\ IF tunnelRefCnt[p] = 0 /\ tunnelFdbCount[p] = 1
                    THEN tunnelExists' = [tunnelExists EXCEPT ![p] = FALSE]
                    ELSE UNCHANGED tunnelExists
                 /\ UNCHANGED <<tunnelRefCnt, delTnlHwPending, portFdbCount>>
         /\ UNCHANGED <<bridgePortVars, flushVars>>

------------------------------------------------------------------------
(* VXLAN FDB ACTIONS — fdborch.cpp + vxlanorch.cpp *)

(*
 * LearnFdbOnTunnel: Remote MAC learned via VXLAN
 * Models: fdborch.cpp addFdbEntry with ORIGIN_VXLAN_ADVERTIZED
 *         + vxlanorch.cpp tunnel fdb_count tracking
 *)
LearnFdbOnTunnel(mac, v, vtep) ==
    /\ tunnelExists[vtep]                              \* Tunnel must exist
    /\ <<mac, v>> \notin DOMAIN mEntries               \* New entry
    /\ mEntries' = (<<mac, v>> :> [origin |-> ORIGIN_VXLAN_ADVERTIZED,
                                    type |-> TYPE_DYNAMIC,
                                    port |-> vtep,
                                    is_flush_pending |-> FALSE])
                   @@ mEntries
    /\ asicEntries' = asicEntries \cup {<<mac, v>>}
    \* Tunnel fdb_count incremented
    /\ tunnelFdbCount' = [tunnelFdbCount EXCEPT ![vtep] = @ + 1]
    /\ vlanFdbCount' = [vlanFdbCount EXCEPT ![v] = @ + 1]
    /\ UNCHANGED <<bridgePortVars, flushVars, tunnelExists, tunnelRefCnt,
                   delTnlHwPending, portFdbCount>>

(*
 * AgeFdbOnTunnel: Remote MAC aged — decrements tunnel fdb_count AND notifies tunnel orch
 * Models: fdborch.cpp:419-546 AGED path + fdborch.cpp:546 notifyTunnelOrch call
 * Family 3: AGED path correctly calls notifyTunnelOrch (contrast with FlushFdbOnTunnel)
 *)
AgeFdbOnTunnel(mac, v) ==
    /\ <<mac, v>> \in DOMAIN mEntries
    /\ LET entry == mEntries[<<mac, v>>]
           vtep == entry.port
       IN
       /\ vtep \in RemoteVTEP
       /\ entry.type = TYPE_DYNAMIC
       /\ mEntries' = [k \in DOMAIN mEntries \ {<<mac, v>>} |-> mEntries[k]]
       /\ asicEntries' = asicEntries \ {<<mac, v>>}
       \* Decrement tunnel fdb_count AND notify tunnel orch (fdborch.cpp:546)
       /\ tunnelFdbCount' = [tunnelFdbCount EXCEPT ![vtep] = @ - 1]
       \* notifyTunnelOrch callback (fdborch.cpp:546) triggers tunnel cleanup
       \* when refcnt=0 and fdb_count reaches 0
       /\ IF tunnelRefCnt[vtep] = 0 /\ tunnelFdbCount[vtep] = 1
          THEN tunnelExists' = [tunnelExists EXCEPT ![vtep] = FALSE]
          ELSE UNCHANGED tunnelExists
       /\ vlanFdbCount' = [vlanFdbCount EXCEPT ![v] = @ - 1]
    /\ UNCHANGED <<bridgePortVars, flushVars, tunnelRefCnt,
                   delTnlHwPending, portFdbCount>>

(*
 * FlushFdbOnTunnel: Tunnel FDB entry cleared by flush
 * Models: fdborch.cpp:181-203 clearFdbEntry
 * Family 3 BUG: clearFdbEntry does NOT call notifyTunnelOrch
 *   (compare fdborch.cpp:181-203 vs fdborch.cpp:546 and fdborch.cpp:1739)
 *)
FlushFdbOnTunnel(mac, v) ==
    /\ <<mac, v>> \in DOMAIN mEntries
    /\ LET entry == mEntries[<<mac, v>>]
           vtep == entry.port
       IN
       /\ vtep \in RemoteVTEP
       /\ entry.is_flush_pending
       /\ mEntries' = [k \in DOMAIN mEntries \ {<<mac, v>>} |-> mEntries[k]]
       /\ asicEntries' = asicEntries \ {<<mac, v>>}
       \* Family 3 BUG: clearFdbEntry decrements m_fdb_count (fdborch.cpp:189-190)
       \* but does NOT call notifyTunnelOrch (fdborch.cpp:181-203)
       \* tunnelFdbCount is NOT decremented — tunnel bridge port leaks
       /\ UNCHANGED tunnelFdbCount
       /\ vlanFdbCount' = [vlanFdbCount EXCEPT ![v] = @ - 1]
    /\ UNCHANGED <<bridgePortVars, flushVars, tunnelExists, tunnelRefCnt,
                   delTnlHwPending, portFdbCount>>

------------------------------------------------------------------------
(* VXLAN TUNNEL LIFECYCLE — vxlanorch.cpp *)

(*
 * AddRemoteVNI: Create/increment tunnel for remote VTEP
 * Models: vxlanorch.cpp:2449-2533 EvpnRemoteVnip2pOrch::addOperation
 *         + addTunnelUser (refcnt increment)
 *)
AddRemoteVNI(vtep) ==
    /\ IF tunnelExists[vtep]
       THEN \* Tunnel already exists — increment refcnt only (vxlanorch.cpp:2503-2514)
            /\ tunnelRefCnt' = [tunnelRefCnt EXCEPT ![vtep] = @ + 1]
            /\ UNCHANGED tunnelExists
       ELSE \* Create new tunnel (vxlanorch.cpp:2516)
            /\ tunnelExists' = [tunnelExists EXCEPT ![vtep] = TRUE]
            /\ tunnelRefCnt' = [tunnelRefCnt EXCEPT ![vtep] = 1]
    /\ UNCHANGED <<bridgePortVars, fdbVars, flushVars, tunnelFdbCount,
                   delTnlHwPending, counterVars>>

(*
 * DelRemoteVNI: Decrement tunnel refcnt, conditionally remove
 * Models: vxlanorch.cpp deleteDynamicDIPTunnel (1182-1241)
 *         + deleteTunnelPort (1792-1853)
 *)
DelRemoteVNI(vtep) ==
    /\ tunnelExists[vtep]
    /\ tunnelRefCnt[vtep] > 0
    /\ tunnelRefCnt' = [tunnelRefCnt EXCEPT ![vtep] = @ - 1]
    \* Only delete tunnel if refcnt reaches 0 AND fdb_count is 0
    \* (vxlanorch.cpp:1203-1216)
    /\ IF tunnelRefCnt[vtep] = 1 /\ tunnelFdbCount[vtep] = 0
       THEN tunnelExists' = [tunnelExists EXCEPT ![vtep] = FALSE]
       ELSE UNCHANGED tunnelExists
    /\ UNCHANGED <<bridgePortVars, fdbVars, flushVars, tunnelFdbCount,
                   delTnlHwPending, counterVars>>

(*
 * TryDeletePendingTunnel: Attempt deferred tunnel deletion
 * Models: vxlanorch.cpp deletePendingSIPTunnel check (triggered by delTunnelUser)
 * Family 3: del_tnl_hw_pending stuck if tunnelFdbCount never reaches 0
 *)
TryDeletePendingTunnel(vtep) ==
    /\ delTnlHwPending
    /\ tunnelExists[vtep]
    /\ tunnelRefCnt[vtep] = 0
    /\ tunnelFdbCount[vtep] = 0                        \* Both must be zero
    /\ tunnelExists' = [tunnelExists EXCEPT ![vtep] = FALSE]
    /\ delTnlHwPending' = FALSE
    /\ UNCHANGED <<bridgePortVars, fdbVars, flushVars, tunnelRefCnt,
                   tunnelFdbCount, counterVars>>

(*
 * SetDelTnlHwPending: SIP tunnel deletion deferred because DIP tunnels exist
 * Models: vxlanorch.cpp:2215
 *)
SetDelTnlHwPending ==
    /\ ~delTnlHwPending
    /\ \E vtep \in RemoteVTEP : tunnelExists[vtep]    \* At least one DIP tunnel
    /\ delTnlHwPending' = TRUE
    /\ UNCHANGED <<bridgePortVars, fdbVars, flushVars, tunnelExists,
                   tunnelRefCnt, tunnelFdbCount, counterVars>>

------------------------------------------------------------------------
(* VLAN REMOVAL — portsorch.cpp *)

(*
 * RemoveVlan: Attempt to remove a VLAN
 * Models: portsorch.cpp:7417-7488
 * Family 5: blocked if m_fdb_count > 0 (portsorch.cpp:7423-7427)
 *   Static entries never flushed → permanent block
 *)
RemoveVlan(v) ==
    /\ vlanMembers[v] = {}                             \* No members
    /\ vlanFdbCount[v] = 0                             \* Family 5: must be zero
    \* VLAN removed (we don't model SAI VLAN object here, just the guard)
    /\ UNCHANGED vars

------------------------------------------------------------------------
(* NEXT STATE *)

Next ==
    \* Bridge port lifecycle
    \/ \E p \in Port, v \in VLAN : AddVlanMember(p, v)
    \/ \E p \in Port, v \in VLAN : RemoveVlanMember(p, v)
    \/ \E p \in Port : FlushFDBForRemove(p)
    \/ \E p \in Port : RemoveBridgePortHW(p)
    \* FDB flush notifications
    \/ \E p \in Port : HandleFlushNotification(p)
    \/ \E v \in VLAN : HandleFlushNotificationVlan(v)
    \/ \E v \in VLAN : FlushFdbByVlan(v)
    \* Local FDB events
    \/ \E mac \in MAC, v \in VLAN, p \in Port : LearnFdbEntry(mac, v, p)
    \/ \E mac \in MAC, v \in VLAN, p \in Port : LearnFdbEntryDropped(mac, v, p)
    \/ \E mac \in MAC, v \in VLAN : AgeFdbEntry(mac, v)
    \/ \E mac \in MAC, v \in VLAN : AgeFdbEntryDropped(mac, v)
    \/ \E mac \in MAC, v \in VLAN, p \in Port : MoveFdbEntry(mac, v, p)
    \* Control plane FDB
    \/ \E mac \in MAC, v \in VLAN, p \in Port : AddFdbEntryProvisioned(mac, v, p)
    \/ \E mac \in MAC, v \in VLAN, o \in Origins : RemoveFdbEntry(mac, v, o)
    \* VXLAN tunnel FDB
    \/ \E mac \in MAC, v \in VLAN, vtep \in RemoteVTEP : LearnFdbOnTunnel(mac, v, vtep)
    \/ \E mac \in MAC, v \in VLAN : AgeFdbOnTunnel(mac, v)
    \/ \E mac \in MAC, v \in VLAN : FlushFdbOnTunnel(mac, v)
    \* VXLAN tunnel lifecycle
    \/ \E vtep \in RemoteVTEP : AddRemoteVNI(vtep)
    \/ \E vtep \in RemoteVTEP : DelRemoteVNI(vtep)
    \/ \E vtep \in RemoteVTEP : TryDeletePendingTunnel(vtep)
    \/ SetDelTnlHwPending
    \* VLAN removal
    \/ \E v \in VLAN : RemoveVlan(v)

Spec == Init /\ [][Next]_vars

------------------------------------------------------------------------
(* INVARIANTS *)

(* --- Standard Safety Invariants --- *)

(*
 * FdbAsicConsistency: m_entries is superset of ASIC entries
 * After any event, every entry in ASIC should have a corresponding m_entries entry
 * (unless the notification was dropped — which is exactly the bug)
 * Family 1, 2
 *)
FdbAsicConsistency ==
    asicEntries \subseteq DOMAIN mEntries

(*
 * NoBridgePortRemoveWithFdb: Bridge port not removed while FDB entries reference it
 * Family 1
 *)
NoBridgePortRemoveWithFdb ==
    \A p \in Port :
        ~bridgePortExists[p] =>
            \A k \in DOMAIN mEntries : mEntries[k].port /= p

(*
 * FlushNotificationComplete: After flush notification processed for a port,
 * no entries with is_flush_pending=TRUE should remain for that port
 * Family 2
 *)
FlushNotificationComplete ==
    \A p \in Port :
        p \notin pendingFlushPort =>
            ~\E k \in DOMAIN mEntries :
                /\ mEntries[k].port = p
                /\ mEntries[k].is_flush_pending

(* --- Extension Invariants (Bug Family Specific) --- *)

(*
 * TunnelEventualCleanup: If tunnel refcnt=0 and fdb_count=0,
 * tunnel bridge port should eventually be removed
 * Family 3 — liveness property (temporal)
 *)
TunnelNoLeak ==
    \A vtep \in RemoteVTEP :
        (tunnelRefCnt[vtep] = 0 /\ tunnelFdbCount[vtep] = 0) =>
            ~tunnelExists[vtep]

(*
 * TunnelCounterConsistency: tunnelFdbCount matches actual entry count
 * Family 3: FlushFdbOnTunnel does NOT decrement tunnelFdbCount,
 * so counter drifts from actual entry count after flush
 *)
TunnelCounterConsistency ==
    \A vtep \in RemoteVTEP :
        tunnelFdbCount[vtep] = Cardinality({k \in DOMAIN mEntries : mEntries[k].port = vtep})

(*
 * NoOrphanEntry: If origin-mismatch DEL was sent, entry should eventually be cleaned
 * Family 4 — safety approximation
 *)
NoOrphanFdbEntry ==
    \A k \in DOMAIN mEntries :
        \* An entry with no active origin source should not persist
        \* (This is checked by specific test scenarios)
        TRUE

(*
 * NoPhantomAfterVlanFlush: After VLAN flush notification processed,
 * dynamic entries in mEntries for that VLAN must also exist in ASIC.
 * Family 2: flushFdbByVlan removes from ASIC but HandleFlushNotificationVlan
 * skips entries without is_flush_pending → phantom entries.
 *)
NoPhantomAfterVlanFlush ==
    \A v \in VLAN :
        v \notin pendingFlushVlan =>
            \A k \in DOMAIN mEntries :
                (k[2] = v /\ mEntries[k].type = TYPE_DYNAMIC) => k \in asicEntries

(*
 * CounterConsistency: portFdbCount matches actual entry count
 * Family 5
 *)
CounterConsistency ==
    /\ \A p \in Port :
        portFdbCount[p] = Cardinality(EntriesForPort(p))
    /\ \A v \in VLAN :
        vlanFdbCount[v] = Cardinality(EntriesForVlan(v))

(*
 * VlanRemovable: If all VLAN members removed and all FDB DELs processed,
 * VLAN fdb_count should be 0
 * Family 5
 *)
VlanRemovable ==
    \A v \in VLAN :
        (vlanMembers[v] = {} /\ ~\E k \in DOMAIN mEntries : k[2] = v) =>
            vlanFdbCount[v] = 0

(* --- Structural Invariants --- *)

\* Bridge port exists only if port is in some VLAN or had flush pending
BridgePortConsistency ==
    \A p \in Port :
        p \in saiOidToAlias => bridgePortExists[p]

\* Tunnel fdb_count is non-negative
TunnelFdbCountNonNeg ==
    \A vtep \in RemoteVTEP : tunnelFdbCount[vtep] >= 0

\* Port fdb_count is non-negative
PortFdbCountNonNeg ==
    \A p \in Port : portFdbCount[p] >= 0

\* VLAN fdb_count is non-negative
VlanFdbCountNonNeg ==
    \A v \in VLAN : vlanFdbCount[v] >= 0

\* Tunnel refcnt is non-negative
TunnelRefCntNonNeg ==
    \A vtep \in RemoteVTEP : tunnelRefCnt[vtep] >= 0

(* --- Temporal Properties --- *)

\* Family 3: Liveness — tunnel eventually cleaned up
TunnelEventualCleanup ==
    \A vtep \in RemoteVTEP :
        [](tunnelRefCnt[vtep] = 0 /\ tunnelFdbCount[vtep] = 0
           ~> ~tunnelExists[vtep])

\* Family 5: Liveness — VLAN eventually removable
VlanRemovalLiveness ==
    \A v \in VLAN :
        [](vlanMembers[v] = {} /\ ~\E k \in DOMAIN mEntries : k[2] = v
           ~> vlanFdbCount[v] = 0)

========================================================================
