------------------------------ MODULE MC ------------------------------
(*
 * Model Checking wrapper for SONiC FDB Bridge Port Lifecycle
 *
 * Counter-bounds fault-injection and non-deterministic actions.
 * Reactive/deterministic actions pass through unbounded.
 *)
EXTENDS base, TLC

CONSTANTS
    MaxVlanMemberOps,       \* Bound on AddVlanMember + RemoveVlanMember
    MaxFlushOps,            \* Bound on FlushFdbByVlan
    MaxLearnOps,            \* Bound on LearnFdbEntry (SAI learns)
    MaxProvisionOps,        \* Bound on AddFdbEntryProvisioned
    MaxRemoveOps,           \* Bound on RemoveFdbEntry (control plane DEL)
    MaxTunnelOps,           \* Bound on AddRemoteVNI + DelRemoteVNI
    MaxTunnelLearnOps,      \* Bound on LearnFdbOnTunnel
    MaxSetPendingOps        \* Bound on SetDelTnlHwPending

VARIABLES
    cntVlanMemberOps,
    cntFlushOps,
    cntLearnOps,
    cntProvisionOps,
    cntRemoveOps,
    cntTunnelOps,
    cntTunnelLearnOps,
    cntSetPendingOps

mcVars == <<cntVlanMemberOps, cntFlushOps, cntLearnOps,
            cntProvisionOps, cntRemoveOps, cntTunnelOps,
            cntTunnelLearnOps, cntSetPendingOps>>

allVars == <<vars, mcVars>>

------------------------------------------------------------------------
(* MC INIT *)

MCInit ==
    /\ Init
    /\ cntVlanMemberOps = 0
    /\ cntFlushOps = 0
    /\ cntLearnOps = 0
    /\ cntProvisionOps = 0
    /\ cntRemoveOps = 0
    /\ cntTunnelOps = 0
    /\ cntTunnelLearnOps = 0
    /\ cntSetPendingOps = 0

------------------------------------------------------------------------
(* COUNTER-BOUNDED WRAPPERS *)

\* --- Non-deterministic actions (bounded) ---

MCAddVlanMember(p, v) ==
    /\ cntVlanMemberOps < MaxVlanMemberOps
    /\ AddVlanMember(p, v)
    /\ cntVlanMemberOps' = cntVlanMemberOps + 1
    /\ UNCHANGED <<cntFlushOps, cntLearnOps, cntProvisionOps,
                   cntRemoveOps, cntTunnelOps, cntTunnelLearnOps,
                   cntSetPendingOps>>

MCRemoveVlanMember(p, v) ==
    /\ cntVlanMemberOps < MaxVlanMemberOps
    /\ RemoveVlanMember(p, v)
    /\ cntVlanMemberOps' = cntVlanMemberOps + 1
    /\ UNCHANGED <<cntFlushOps, cntLearnOps, cntProvisionOps,
                   cntRemoveOps, cntTunnelOps, cntTunnelLearnOps,
                   cntSetPendingOps>>

MCFlushFdbByVlan(v) ==
    /\ cntFlushOps < MaxFlushOps
    /\ FlushFdbByVlan(v)
    /\ cntFlushOps' = cntFlushOps + 1
    /\ UNCHANGED <<cntVlanMemberOps, cntLearnOps, cntProvisionOps,
                   cntRemoveOps, cntTunnelOps, cntTunnelLearnOps,
                   cntSetPendingOps>>

MCLearnFdbEntry(mac, v, p) ==
    /\ cntLearnOps < MaxLearnOps
    /\ LearnFdbEntry(mac, v, p)
    /\ cntLearnOps' = cntLearnOps + 1
    /\ UNCHANGED <<cntVlanMemberOps, cntFlushOps, cntProvisionOps,
                   cntRemoveOps, cntTunnelOps, cntTunnelLearnOps,
                   cntSetPendingOps>>

MCLearnFdbEntryDropped(mac, v, p) ==
    /\ cntLearnOps < MaxLearnOps
    /\ LearnFdbEntryDropped(mac, v, p)
    /\ cntLearnOps' = cntLearnOps + 1
    /\ UNCHANGED <<cntVlanMemberOps, cntFlushOps, cntProvisionOps,
                   cntRemoveOps, cntTunnelOps, cntTunnelLearnOps,
                   cntSetPendingOps>>

MCAddFdbEntryProvisioned(mac, v, p) ==
    /\ cntProvisionOps < MaxProvisionOps
    /\ AddFdbEntryProvisioned(mac, v, p)
    /\ cntProvisionOps' = cntProvisionOps + 1
    /\ UNCHANGED <<cntVlanMemberOps, cntFlushOps, cntLearnOps,
                   cntRemoveOps, cntTunnelOps, cntTunnelLearnOps,
                   cntSetPendingOps>>

MCRemoveFdbEntry(mac, v, o) ==
    /\ cntRemoveOps < MaxRemoveOps
    /\ RemoveFdbEntry(mac, v, o)
    /\ cntRemoveOps' = cntRemoveOps + 1
    /\ UNCHANGED <<cntVlanMemberOps, cntFlushOps, cntLearnOps,
                   cntProvisionOps, cntTunnelOps, cntTunnelLearnOps,
                   cntSetPendingOps>>

MCAddRemoteVNI(vtep) ==
    /\ cntTunnelOps < MaxTunnelOps
    /\ AddRemoteVNI(vtep)
    /\ cntTunnelOps' = cntTunnelOps + 1
    /\ UNCHANGED <<cntVlanMemberOps, cntFlushOps, cntLearnOps,
                   cntProvisionOps, cntRemoveOps, cntTunnelLearnOps,
                   cntSetPendingOps>>

MCDelRemoteVNI(vtep) ==
    /\ cntTunnelOps < MaxTunnelOps
    /\ DelRemoteVNI(vtep)
    /\ cntTunnelOps' = cntTunnelOps + 1
    /\ UNCHANGED <<cntVlanMemberOps, cntFlushOps, cntLearnOps,
                   cntProvisionOps, cntRemoveOps, cntTunnelLearnOps,
                   cntSetPendingOps>>

MCLearnFdbOnTunnel(mac, v, vtep) ==
    /\ cntTunnelLearnOps < MaxTunnelLearnOps
    /\ LearnFdbOnTunnel(mac, v, vtep)
    /\ cntTunnelLearnOps' = cntTunnelLearnOps + 1
    /\ UNCHANGED <<cntVlanMemberOps, cntFlushOps, cntLearnOps,
                   cntProvisionOps, cntRemoveOps, cntTunnelOps,
                   cntSetPendingOps>>

MCSetDelTnlHwPending ==
    /\ cntSetPendingOps < MaxSetPendingOps
    /\ SetDelTnlHwPending
    /\ cntSetPendingOps' = cntSetPendingOps + 1
    /\ UNCHANGED <<cntVlanMemberOps, cntFlushOps, cntLearnOps,
                   cntProvisionOps, cntRemoveOps, cntTunnelOps,
                   cntTunnelLearnOps>>

\* --- Reactive/deterministic actions (unbounded) ---

MCFlushFDBForRemove(p) ==
    /\ FlushFDBForRemove(p)
    /\ UNCHANGED mcVars

MCRemoveBridgePortHW(p) ==
    /\ RemoveBridgePortHW(p)
    /\ UNCHANGED mcVars

MCHandleFlushNotification(p) ==
    /\ HandleFlushNotification(p)
    /\ UNCHANGED mcVars

MCHandleFlushNotificationVlan(v) ==
    /\ HandleFlushNotificationVlan(v)
    /\ UNCHANGED mcVars

MCAgeFdbEntry(mac, v) ==
    /\ AgeFdbEntry(mac, v)
    /\ UNCHANGED mcVars

MCAgeFdbEntryDropped(mac, v) ==
    /\ AgeFdbEntryDropped(mac, v)
    /\ UNCHANGED mcVars

MCMoveFdbEntry(mac, v, p) ==
    /\ MoveFdbEntry(mac, v, p)
    /\ UNCHANGED mcVars

MCAgeFdbOnTunnel(mac, v) ==
    /\ AgeFdbOnTunnel(mac, v)
    /\ UNCHANGED mcVars

MCFlushFdbOnTunnel(mac, v) ==
    /\ FlushFdbOnTunnel(mac, v)
    /\ UNCHANGED mcVars

MCTryDeletePendingTunnel(vtep) ==
    /\ TryDeletePendingTunnel(vtep)
    /\ UNCHANGED mcVars

MCRemoveVlan(v) ==
    /\ RemoveVlan(v)
    /\ UNCHANGED mcVars

------------------------------------------------------------------------
(* MC NEXT *)

MCNext ==
    \* Bounded non-deterministic actions
    \/ \E p \in Port, v \in VLAN : MCAddVlanMember(p, v)
    \/ \E p \in Port, v \in VLAN : MCRemoveVlanMember(p, v)
    \/ \E v \in VLAN : MCFlushFdbByVlan(v)
    \/ \E mac \in MAC, v \in VLAN, p \in Port : MCLearnFdbEntry(mac, v, p)
    \/ \E mac \in MAC, v \in VLAN, p \in Port : MCLearnFdbEntryDropped(mac, v, p)
    \/ \E mac \in MAC, v \in VLAN, p \in Port : MCAddFdbEntryProvisioned(mac, v, p)
    \/ \E mac \in MAC, v \in VLAN, o \in Origins : MCRemoveFdbEntry(mac, v, o)
    \/ \E vtep \in RemoteVTEP : MCAddRemoteVNI(vtep)
    \/ \E vtep \in RemoteVTEP : MCDelRemoteVNI(vtep)
    \/ \E mac \in MAC, v \in VLAN, vtep \in RemoteVTEP : MCLearnFdbOnTunnel(mac, v, vtep)
    \/ MCSetDelTnlHwPending
    \* Unbounded reactive actions
    \/ \E p \in Port : MCFlushFDBForRemove(p)
    \/ \E p \in Port : MCRemoveBridgePortHW(p)
    \/ \E p \in Port : MCHandleFlushNotification(p)
    \/ \E v \in VLAN : MCHandleFlushNotificationVlan(v)
    \/ \E mac \in MAC, v \in VLAN : MCAgeFdbEntry(mac, v)
    \/ \E mac \in MAC, v \in VLAN : MCAgeFdbEntryDropped(mac, v)
    \/ \E mac \in MAC, v \in VLAN, p \in Port : MCMoveFdbEntry(mac, v, p)
    \/ \E mac \in MAC, v \in VLAN : MCAgeFdbOnTunnel(mac, v)
    \/ \E mac \in MAC, v \in VLAN : MCFlushFdbOnTunnel(mac, v)
    \/ \E vtep \in RemoteVTEP : MCTryDeletePendingTunnel(vtep)
    \/ \E v \in VLAN : MCRemoveVlan(v)

MCSpec == MCInit /\ [][MCNext]_allVars

------------------------------------------------------------------------
(* SYMMETRY *)

ModelSymmetry == Permutations(Port) \cup Permutations(MAC)

------------------------------------------------------------------------
(* STATE SPACE CONSTRAINT *)

\* Limit total FDB entries to prevent explosion
MaxFdbEntries == Cardinality(DOMAIN mEntries) <= Cardinality(MAC) * Cardinality(VLAN)

------------------------------------------------------------------------
(* VIEW — exclude counters from state space view for efficiency *)

MCView == <<vars>>

========================================================================
