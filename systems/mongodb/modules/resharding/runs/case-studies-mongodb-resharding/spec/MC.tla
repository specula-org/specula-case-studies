---- MODULE MC ----
EXTENDS base, TLC

CONSTANTS MaxCrash, MaxAbort, MaxParticipantError

VARIABLES crashCount, abortCount, participantErrorCount

faultVars == <<crashCount, abortCount, participantErrorCount>>
allVars == <<vars, faultVars>>

MCInit ==
    /\ Init
    /\ crashCount = 0
    /\ abortCount = 0
    /\ participantErrorCount = 0

\* --- Counter-bounded fault injection ---

MCCoordCrash ==
    /\ crashCount < MaxCrash
    /\ CoordCrash
    /\ crashCount' = crashCount + 1
    /\ UNCHANGED <<abortCount, participantErrorCount>>

MCCoordAbortRequest ==
    /\ abortCount < MaxAbort
    /\ CoordAbortRequest
    /\ abortCount' = abortCount + 1
    /\ UNCHANGED <<crashCount, participantErrorCount>>

MCDonorError(d) ==
    /\ participantErrorCount < MaxParticipantError
    /\ DonorError(d)
    /\ participantErrorCount' = participantErrorCount + 1
    /\ UNCHANGED <<crashCount, abortCount>>

MCRecipientError(r) ==
    /\ participantErrorCount < MaxParticipantError
    /\ RecipientError(r)
    /\ participantErrorCount' = participantErrorCount + 1
    /\ UNCHANGED <<crashCount, abortCount>>

\* --- Pass-through (unbounded) ---
PFV == UNCHANGED faultVars

MCNext ==
    \* Coordinator happy path (unbounded)
    \/ CoordInitialize /\ PFV
    \/ CoordInitializeMajority /\ PFV
    \/ CoordPrepare /\ PFV
    \/ CoordPrepareMajority /\ PFV
    \/ CoordTransitionToCloning /\ PFV
    \/ CoordTransitionToApplying /\ PFV
    \/ CoordTransitionToBlocking /\ PFV
    \/ CoordCommit /\ PFV
    \/ CoordCommitMajority /\ PFV
    \/ CoordTellParticipantsCommit /\ PFV
    \/ CoordFinish /\ PFV
    \/ CoordGenericMajority /\ PFV
    \* Coordinator abort (bounded: request, unbounded: persist/majority/finish)
    \/ MCCoordAbortRequest
    \/ CoordAbortOnParticipantError /\ PFV
    \/ CoordAbortCoordinatorOnly /\ PFV
    \/ CoordAbortPersist /\ PFV
    \/ CoordAbortMajority /\ PFV
    \/ CoordTellParticipantsAbort /\ PFV
    \/ CoordAbortFinish /\ PFV
    \* Coordinator crash/recovery (bounded)
    \/ MCCoordCrash
    \/ CoordRecover /\ PFV
    \* Participant (error bounded, advance/done unbounded)
    \/ \E d \in Donor : DonorAdvance(d) /\ PFV
    \/ \E d \in Donor : DonorDone(d) /\ PFV
    \/ \E d \in Donor : MCDonorError(d)
    \/ \E r \in Recipient : RecipientAdvance(r) /\ PFV
    \/ \E r \in Recipient : RecipientDone(r) /\ PFV
    \/ \E r \in Recipient : MCRecipientError(r)
    \* Observer (unbounded)
    \/ ObserverCheck /\ PFV

MCSpec == MCInit /\ [][MCNext]_allVars

\* --- Symmetry ---
MCSymmetry == Permutations(Donor) \cup Permutations(Recipient)

====
