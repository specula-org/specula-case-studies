------------------------------ MODULE Trace ------------------------------
(*
 * Trace Validation spec for SONiC FDB Bridge Port Lifecycle
 *
 * Category A: Single-file linear trace with cursor l.
 * Replays implementation traces against the base spec.
 *)
EXTENDS base, Sequences, TLC, Integers, IOUtils, Naturals, Json

------------------------------------------------------------------------
(* TRACE LOADING *)

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only FDB-related events (if needed)
TraceLog == RawTraceLog

------------------------------------------------------------------------
(* TRACE CURSOR *)

VARIABLE l

traceVars == <<vars, l>>

------------------------------------------------------------------------
(* HELPERS *)

logline == TraceLog[l]

IsEvent(name) == logline.event = name

\* Map string names from trace to TLA+ model values
\* Uses deterministic CHOOSE for consistent mapping

LOCAL port1 == CHOOSE p \in Port : TRUE
LOCAL port2 == CHOOSE p \in Port : p /= port1
LOCAL mac1 == CHOOSE m \in MAC : TRUE
LOCAL mac2 == CHOOSE m \in MAC : m /= mac1

MapPort(name) ==
    CASE name = "Ethernet0" -> port1
      [] name = "Ethernet4" -> port2
      [] OTHER -> port1

MapVlan(name) ==
    CHOOSE v \in VLAN : TRUE

MapMac(name) ==
    CASE name = "00:11:22:33:44:55" -> mac1
      [] name = "00:11:22:33:44:66" -> mac2
      [] OTHER -> mac1

MapVtep(name) ==
    CHOOSE vtep \in RemoteVTEP : TRUE

MapOrigin(name) ==
    CASE name = "learn"             -> ORIGIN_LEARN
      [] name = "provisioned"       -> ORIGIN_PROVISIONED
      [] name = "vxlan_advertized"  -> ORIGIN_VXLAN_ADVERTIZED
      [] name = "mclag_advertized"  -> ORIGIN_MCLAG_ADVERTIZED

MapType(name) ==
    CASE name = "dynamic" -> TYPE_DYNAMIC
      [] name = "static"  -> TYPE_STATIC

------------------------------------------------------------------------
(* POST-STATE VALIDATION *)

(*
 * ValidatePostState: Check that spec state matches trace-captured state
 * Each action wrapper calls a specific validator.
 *)

\* Validate bridge port state after VLAN member operations
ValidateBridgePortState ==
    /\ IF "bridge_port_exists" \in DOMAIN logline
       THEN LET p == MapPort(logline.port) IN
            bridgePortExists'[p] = logline.bridge_port_exists
       ELSE TRUE
    /\ IF "in_oid_map" \in DOMAIN logline
       THEN LET p == MapPort(logline.port) IN
            (p \in saiOidToAlias') = logline.in_oid_map
       ELSE TRUE

\* Validate FDB entry state after learn/age/move
ValidateFdbState ==
    /\ IF "entry_exists" \in DOMAIN logline
       THEN LET key == <<MapMac(logline.mac), MapVlan(logline.vlan)>> IN
            (key \in DOMAIN mEntries') = logline.entry_exists
       ELSE TRUE
    /\ IF "entry_origin" \in DOMAIN logline
       THEN LET key == <<MapMac(logline.mac), MapVlan(logline.vlan)>> IN
            IF key \in DOMAIN mEntries'
            THEN mEntries'[key].origin = MapOrigin(logline.entry_origin)
            ELSE TRUE
       ELSE TRUE
    /\ IF "entry_port" \in DOMAIN logline
       THEN LET key == <<MapMac(logline.mac), MapVlan(logline.vlan)>> IN
            IF key \in DOMAIN mEntries'
            THEN mEntries'[key].port = MapPort(logline.entry_port)
            ELSE TRUE
       ELSE TRUE

\* Validate counter state
ValidateCounterState ==
    /\ IF "port_fdb_count" \in DOMAIN logline /\ "port" \in DOMAIN logline
       THEN LET p == MapPort(logline.port) IN
            portFdbCount'[p] = logline.port_fdb_count
       ELSE TRUE
    /\ IF "vlan_fdb_count" \in DOMAIN logline /\ "vlan" \in DOMAIN logline
       THEN LET v == MapVlan(logline.vlan) IN
            vlanFdbCount'[v] = logline.vlan_fdb_count
       ELSE TRUE

\* Validate flush pending state
ValidateFlushState ==
    /\ IF "is_flush_pending" \in DOMAIN logline
       THEN LET key == <<MapMac(logline.mac), MapVlan(logline.vlan)>> IN
            IF key \in DOMAIN mEntries'
            THEN mEntries'[key].is_flush_pending = logline.is_flush_pending
            ELSE TRUE
       ELSE TRUE

\* Validate tunnel state
ValidateTunnelState ==
    /\ IF "tunnel_exists" \in DOMAIN logline
       THEN LET vtep == MapVtep(logline.vtep) IN
            tunnelExists'[vtep] = logline.tunnel_exists
       ELSE TRUE
    /\ IF "tunnel_ref_cnt" \in DOMAIN logline
       THEN LET vtep == MapVtep(logline.vtep) IN
            tunnelRefCnt'[vtep] = logline.tunnel_ref_cnt
       ELSE TRUE
    /\ IF "tunnel_fdb_count" \in DOMAIN logline
       THEN LET vtep == MapVtep(logline.vtep) IN
            tunnelFdbCount'[vtep] = logline.tunnel_fdb_count
       ELSE TRUE

------------------------------------------------------------------------
(* ACTION WRAPPERS *)

\* --- Bridge Port Actions ---

TraceAddVlanMember ==
    /\ IsEvent("add_vlan_member")
    /\ LET p == MapPort(logline.port)
           v == MapVlan(logline.vlan)
       IN
       /\ AddVlanMember(p, v)
       /\ ValidateBridgePortState
    /\ l' = l + 1

TraceRemoveVlanMember ==
    /\ IsEvent("remove_vlan_member")
    /\ LET p == MapPort(logline.port)
           v == MapVlan(logline.vlan)
       IN
       /\ RemoveVlanMember(p, v)
       /\ ValidateBridgePortState
    /\ l' = l + 1

TraceFlushFDBForRemove ==
    /\ IsEvent("flush_fdb_for_remove")
    /\ LET p == MapPort(logline.port) IN
       /\ FlushFDBForRemove(p)
       /\ ValidateFlushState
    /\ l' = l + 1

TraceRemoveBridgePortHW ==
    /\ IsEvent("remove_bridge_port_hw")
    /\ LET p == MapPort(logline.port) IN
       /\ RemoveBridgePortHW(p)
       /\ ValidateBridgePortState
    /\ l' = l + 1

\* --- FDB Flush Actions ---

TraceHandleFlushNotification ==
    /\ IsEvent("handle_flush_notification")
    /\ LET p == MapPort(logline.port) IN
       /\ HandleFlushNotification(p)
       /\ ValidateCounterState
    /\ l' = l + 1

TraceHandleFlushNotificationVlan ==
    /\ IsEvent("handle_flush_notification_vlan")
    /\ LET v == MapVlan(logline.vlan) IN
       /\ HandleFlushNotificationVlan(v)
       /\ ValidateCounterState
    /\ l' = l + 1

TraceFlushFdbByVlan ==
    /\ IsEvent("flush_fdb_by_vlan")
    /\ LET v == MapVlan(logline.vlan) IN
       /\ FlushFdbByVlan(v)
    /\ l' = l + 1

\* --- FDB Event Actions ---

TraceLearnFdbEntry ==
    /\ IsEvent("learn_fdb_entry")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
           p == MapPort(logline.port)
       IN
       /\ LearnFdbEntry(mac, v, p)
       /\ ValidateFdbState
       /\ ValidateCounterState
    /\ l' = l + 1

TraceLearnFdbEntryDropped ==
    /\ IsEvent("learn_fdb_entry_dropped")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
           p == MapPort(logline.port)
       IN
       /\ LearnFdbEntryDropped(mac, v, p)
    /\ l' = l + 1

TraceAgeFdbEntry ==
    /\ IsEvent("age_fdb_entry")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
       IN
       /\ AgeFdbEntry(mac, v)
       /\ ValidateFdbState
       /\ ValidateCounterState
    /\ l' = l + 1

TraceAgeFdbEntryDropped ==
    /\ IsEvent("age_fdb_entry_dropped")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
       IN
       /\ AgeFdbEntryDropped(mac, v)
    /\ l' = l + 1

TraceMoveFdbEntry ==
    /\ IsEvent("move_fdb_entry")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
           p == MapPort(logline.new_port)
       IN
       /\ MoveFdbEntry(mac, v, p)
       /\ ValidateFdbState
       /\ ValidateCounterState
    /\ l' = l + 1

\* --- Control Plane FDB Actions ---

TraceAddFdbEntryProvisioned ==
    /\ IsEvent("add_fdb_entry_provisioned")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
           p == MapPort(logline.port)
       IN
       /\ AddFdbEntryProvisioned(mac, v, p)
       /\ ValidateFdbState
       /\ ValidateCounterState
    /\ l' = l + 1

TraceRemoveFdbEntry ==
    /\ IsEvent("remove_fdb_entry")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
           origin == MapOrigin(logline.origin)
       IN
       /\ RemoveFdbEntry(mac, v, origin)
       /\ ValidateFdbState
       /\ ValidateCounterState
    /\ l' = l + 1

\* --- VXLAN Tunnel FDB Actions ---

TraceLearnFdbOnTunnel ==
    /\ IsEvent("learn_fdb_on_tunnel")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
           vtep == MapVtep(logline.vtep)
       IN
       /\ LearnFdbOnTunnel(mac, v, vtep)
       /\ ValidateFdbState
       /\ ValidateTunnelState
    /\ l' = l + 1

TraceAgeFdbOnTunnel ==
    /\ IsEvent("age_fdb_on_tunnel")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
       IN
       /\ AgeFdbOnTunnel(mac, v)
       /\ ValidateFdbState
       /\ ValidateTunnelState
    /\ l' = l + 1

TraceFlushFdbOnTunnel ==
    /\ IsEvent("flush_fdb_on_tunnel")
    /\ LET mac == MapMac(logline.mac)
           v == MapVlan(logline.vlan)
       IN
       /\ FlushFdbOnTunnel(mac, v)
       /\ ValidateFdbState
    /\ l' = l + 1

\* --- VXLAN Tunnel Lifecycle Actions ---

TraceAddRemoteVNI ==
    /\ IsEvent("add_remote_vni")
    /\ LET vtep == MapVtep(logline.vtep) IN
       /\ AddRemoteVNI(vtep)
       /\ ValidateTunnelState
    /\ l' = l + 1

TraceDelRemoteVNI ==
    /\ IsEvent("del_remote_vni")
    /\ LET vtep == MapVtep(logline.vtep) IN
       /\ DelRemoteVNI(vtep)
       /\ ValidateTunnelState
    /\ l' = l + 1

------------------------------------------------------------------------
(* SILENT ACTIONS *)
(* Handle state transitions not directly observed in the trace.
 * Each is tightly constrained to prevent state space explosion.
 *)

\* Silent bridge port removal: happens after RemoveVlanMember when last VLAN
\* Must be constrained to only fire when next event requires it
SilentFlushFDBForRemove ==
    /\ l <= Len(TraceLog)
    /\ \E p \in Port :
        /\ bridgePortExists[p]
        /\ \A v \in VLAN : p \notin vlanMembers[v]
        /\ p \notin pendingFlushPort
        \* Only fire if the next event involves this port's bridge port removal
        /\ \/ (IsEvent("remove_bridge_port_hw") /\ MapPort(logline.port) = p)
           \/ (IsEvent("handle_flush_notification") /\ MapPort(logline.port) = p)
        /\ FlushFDBForRemove(p)
    /\ UNCHANGED l

SilentRemoveBridgePortHW ==
    /\ l <= Len(TraceLog)
    /\ \E p \in Port :
        /\ bridgePortExists[p]
        /\ \A v \in VLAN : p \notin vlanMembers[v]
        /\ p \in pendingFlushPort
        \* Only fire if needed before flush notification
        /\ IsEvent("handle_flush_notification")
        /\ MapPort(logline.port) = p
        /\ RemoveBridgePortHW(p)
    /\ UNCHANGED l

\* Silent TryDeletePendingTunnel — fires when tunnel conditions met
SilentTryDeletePendingTunnel ==
    /\ l <= Len(TraceLog)
    /\ \E vtep \in RemoteVTEP :
        /\ delTnlHwPending
        /\ tunnelExists[vtep]
        /\ tunnelRefCnt[vtep] = 0
        /\ tunnelFdbCount[vtep] = 0
        /\ TryDeletePendingTunnel(vtep)
    /\ UNCHANGED l

------------------------------------------------------------------------
(* TRACE INIT *)

TraceInit ==
    /\ Init
    /\ l = 1

------------------------------------------------------------------------
(* TRACE NEXT *)

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ \/ TraceAddVlanMember
          \/ TraceRemoveVlanMember
          \/ TraceFlushFDBForRemove
          \/ TraceRemoveBridgePortHW
          \/ TraceHandleFlushNotification
          \/ TraceHandleFlushNotificationVlan
          \/ TraceFlushFdbByVlan
          \/ TraceLearnFdbEntry
          \/ TraceLearnFdbEntryDropped
          \/ TraceAgeFdbEntry
          \/ TraceAgeFdbEntryDropped
          \/ TraceMoveFdbEntry
          \/ TraceAddFdbEntryProvisioned
          \/ TraceRemoveFdbEntry
          \/ TraceLearnFdbOnTunnel
          \/ TraceAgeFdbOnTunnel
          \/ TraceFlushFdbOnTunnel
          \/ TraceAddRemoteVNI
          \/ TraceDelRemoteVNI
    \* Silent actions (no l advance)
    \/ /\ l <= Len(TraceLog)
       /\ \/ SilentFlushFDBForRemove
          \/ SilentRemoveBridgePortHW
          \/ SilentTryDeletePendingTunnel
    \* Stuttering when trace consumed
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED traceVars

TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)

------------------------------------------------------------------------
(* TRACE COMPLETION *)

TraceMatched == <>(l > Len(TraceLog))

========================================================================
