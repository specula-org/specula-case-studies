---- MODULE MC ----
(*
 * Model Checking Wrapper for MongoDB Chunk Migration
 *
 * Bounds fault-injection actions and adds temporal properties for exhaustive
 * state space exploration. Supports bug-family hunting via per-family configs.
 *)

EXTENDS base, TLC

\* Counter-bounded fault injection actions
CONSTANT CrashLimit          \* Max crashes per shard
CONSTANT MessageLossLimit    \* Max message drops
CONSTANT TimeoutLimit        \* Max timeout/recovery cycles

VARIABLE faultCounters      \* Record of fault injection counts

faultVars == <<faultCounters>>

allVars == <<vars, faultVars>>

----

\* Fault injection counter management
InitCounters ==
    faultCounters = [
        donorCrash |-> 0,
        recipientCrash |-> 0,
        messageLoss |-> 0,
        timeout |-> 0
    ]

IncrementCounter(name) ==
    faultCounters' = [faultCounters EXCEPT ![name] = @ + 1]

CanCrash(limit) == faultCounters.donorCrash + faultCounters.recipientCrash < limit

CanLoseMessage(limit) == faultCounters.messageLoss < limit

CanTimeout(limit) == faultCounters.timeout < limit

----

\* Bounded versions of base spec actions

\* Deterministic/reactive actions pass through unchanged
MCRecipientStartClone == RecipientStartClone /\ UNCHANGED faultVars
MCRecipientCloneComplete == RecipientCloneComplete /\ UNCHANGED faultVars
MCDonorEnterCriticalSection == DonorEnterCriticalSection /\ UNCHANGED faultVars
MCDonorPersistCommitDecision == DonorPersistCommitDecision /\ UNCHANGED faultVars
MCDonorPersistAbortDecision == DonorPersistAbortDecision /\ UNCHANGED faultVars
MCDonorSendConfigServerCommit == DonorSendConfigServerCommit /\ UNCHANGED faultVars
MCConfigServerPersistCommit == ConfigServerPersistCommit /\ UNCHANGED faultVars
MCLaunchReleaseRecipientCriticalSection == LaunchReleaseRecipientCriticalSection /\ UNCHANGED faultVars
MCCriticalSectionReleaseSucceeds == CriticalSectionReleaseSucceeds /\ UNCHANGED faultVars
MCDonorDeleteRangeDeletionTaskLocally == DonorDeleteRangeDeletionTaskLocally /\ UNCHANGED faultVars
MCDonorRegisterRangeDeletionTask == DonorRegisterRangeDeletionTask /\ UNCHANGED faultVars
MCDonorDeleteRecipientRangeDeletionTask == DonorDeleteRecipientRangeDeletionTask /\ UNCHANGED faultVars
MCDonorMarkRangeDeletionReady == DonorMarkRangeDeletionReady /\ UNCHANGED faultVars
MCAbortDeleteDonorRangeDeletionTask == AbortDeleteDonorRangeDeletionTask /\ UNCHANGED faultVars
MCAbortBumpRecipientTxnNumber == AbortBumpRecipientTxnNumber /\ UNCHANGED faultVars
MCAbortMarkRecipientRangeDeletionReady == AbortMarkRecipientRangeDeletionReady /\ UNCHANGED faultVars
MCForgetMigration == ForgetMigration /\ UNCHANGED faultVars
MCAbortCleanup == AbortCleanup /\ UNCHANGED faultVars

\* Bounded fault-injection wrappers
MCConfigServerCommitFails ==
    /\ CanCrash(CrashLimit)
    /\ ConfigServerCommitFails
    /\ faultCounters' = faultCounters

MCCriticalSectionReleaseFails ==
    /\ CanTimeout(TimeoutLimit)
    /\ CriticalSectionReleaseFails
    /\ IncrementCounter("timeout")

MCAbortRecipientNotificationFails ==
    /\ CanTimeout(TimeoutLimit)
    /\ AbortRecipientNotificationFails
    /\ IncrementCounter("timeout")

MCDonorCrash ==
    /\ CanCrash(CrashLimit)
    /\ DonorCrash
    /\ faultCounters' = [faultCounters EXCEPT !.donorCrash = @ + 1]

MCDonorRecover ==
    /\ DonorRecover
    /\ UNCHANGED faultVars

MCRecipientCrash ==
    /\ CanCrash(CrashLimit)
    /\ RecipientCrash
    /\ faultCounters' = [faultCounters EXCEPT !.recipientCrash = @ + 1]

MCRecipientRecover ==
    /\ RecipientRecover
    /\ UNCHANGED faultVars

----

MCInit ==
    Init /\ InitCounters

MCNext ==
    \/ MCRecipientStartClone
    \/ MCRecipientCloneComplete
    \/ MCDonorEnterCriticalSection
    \/ MCDonorPersistCommitDecision
    \/ MCDonorPersistAbortDecision
    \/ MCDonorSendConfigServerCommit
    \/ MCConfigServerPersistCommit
    \/ MCConfigServerCommitFails
    \/ MCLaunchReleaseRecipientCriticalSection
    \/ MCCriticalSectionReleaseSucceeds
    \/ MCCriticalSectionReleaseFails
    \/ MCDonorDeleteRangeDeletionTaskLocally
    \/ MCDonorRegisterRangeDeletionTask
    \/ MCDonorDeleteRecipientRangeDeletionTask
    \/ MCDonorMarkRangeDeletionReady
    \/ MCAbortDeleteDonorRangeDeletionTask
    \/ MCAbortBumpRecipientTxnNumber
    \/ MCAbortMarkRecipientRangeDeletionReady
    \/ MCAbortRecipientNotificationFails
    \/ MCForgetMigration
    \/ MCAbortCleanup
    \/ MCDonorCrash
    \/ MCDonorRecover
    \/ MCRecipientCrash
    \/ MCRecipientRecover

----

\* State space pruning
StateConstraint ==
    /\ faultCounters.donorCrash <= CrashLimit
    /\ faultCounters.recipientCrash <= CrashLimit
    /\ faultCounters.timeout <= TimeoutLimit

----

\* Temporal properties
\* Liveness: if a commit decision is made, the migration should eventually complete
EventualCompletion ==
    (coordinatorDecision = "Commit" ~> donorState = "Done")

====
