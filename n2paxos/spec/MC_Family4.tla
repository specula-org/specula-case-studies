---- MODULE MC_Family4 ----
EXTENDS base

VARIABLE recovEvtCount

f4vars == <<recovEvtCount>>

F4Init ==
    /\ Init
    /\ recovEvtCount = 0

\* Recovery message families are registered in defs.go but not consumed in run loop.
\* Model them as explicit no-op events over protocol state.
RecvM1A ==
    /\ recovEvtCount < 6
    /\ UNCHANGED vars
    /\ recovEvtCount' = recovEvtCount + 1

RecvM1B ==
    /\ recovEvtCount < 6
    /\ UNCHANGED vars
    /\ recovEvtCount' = recovEvtCount + 1

RecvSync ==
    /\ recovEvtCount < 6
    /\ UNCHANGED vars
    /\ recovEvtCount' = recovEvtCount + 1

F4Normal ==
    /\ NoOp
    /\ UNCHANGED f4vars

F4Next ==
    \/ RecvM1A
    \/ RecvM1B
    \/ RecvSync
    \/ F4Normal

RecoveryMessagesNoEffect ==
    /\ status = [r \in Servers |-> NORMAL]
    /\ ballot = [r \in Servers |-> 0]
    /\ cballot = [r \in Servers |-> 0]
    /\ phases = {}
    /\ delivered = {}

F4Spec == F4Init /\ [][F4Next]_<<vars, f4vars>>

=============================================================================
