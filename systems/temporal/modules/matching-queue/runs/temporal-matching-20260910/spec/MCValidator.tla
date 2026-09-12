---------------------------- MODULE MCValidator ----------------------------
EXTENDS MCContract, ValidatorBase
V == INSTANCE ValidatorBase
vvars == <<mcvars, validationHolds>>
VInit == MCInit /\ ValidationInit
VResult(p,result) ==
    /\ dispatch[p].pc = "matched" /\ validationHolds[dispatch[p].owner].poller = p
    /\ (result = "obsolete" /\ ~history[dispatch[p].work].obsolete => faults.obsolete < ObsoleteLimit)
    /\ Track(V!ValidationResult(p,result))
    /\ faults' = [faults EXCEPT !.obsolete =
          IF result = "obsolete" /\ ~history[dispatch[p].work].obsolete THEN @ + 1 ELSE @]
VNext ==
    \/ ContractNext /\ ValidationCompatible /\ UNCHANGED validationHolds
    \/ \E o \in Owners : \E r \in owner[o].queued : \E p \in Pollers :
          Track(V!ValidationMatch(o,r,p)) /\ UNCHANGED faults
    \/ \E p \in Pollers : \E result \in {"valid","expired","obsolete"} : VResult(p,result)
    \/ \E o \in Owners : Track(V!ValidationDone(o)) /\ UNCHANGED faults
VSpec == VInit /\ [][VNext]_vvars
VView == <<ContractView,validationHolds>>
=============================================================================
