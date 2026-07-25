-------------------------------- MODULE MC --------------------------------
(* Model checking wrapper for the MongoDB chunk migration base spec.
   Adds counter-bounded fault injection actions for exhaustive state-space exploration.

   Fault actions bounded:
   - CrashDonor: donor crash (fault injection, non-deterministic)
   - ConcurrentAbortSignalDuringRecovery: concurrent abort during recipient recovery

   All other actions are reactive/deterministic and are NOT bounded.
*)

EXTENDS base, Naturals

CONSTANTS
    MaxCrashLimit,       \* max times donor may crash (recommend 2)
    MaxConcAbortLimit    \* max concurrent abort signals (recommend 1)

VARIABLE faultVars
    \* faultVars == [crashes |-> Nat, concAborts |-> Nat]

MCInit ==
    /\ Init
    /\ faultVars = [crashes |-> 0, concAborts |-> 0]

-----------------------------------------------------------------------------
(* BOUNDED FAULT-INJECTION WRAPPERS *)

(* Family 1: Donor crash — bounded.
   Each crash consumes one crash token. *)
MCCrashDonor ==
    /\ faultVars.crashes < MaxCrashLimit
    /\ CrashDonor
    /\ faultVars' = [faultVars EXCEPT !.crashes = @ + 1]

(* Family 2: Concurrent abort signal during recipient recovery — bounded. *)
MCConcurrentAbortSignal ==
    /\ faultVars.concAborts < MaxConcAbortLimit
    /\ ConcurrentAbortSignalDuringRecovery
    /\ faultVars' = [faultVars EXCEPT !.concAborts = @ + 1]

-----------------------------------------------------------------------------
(* PASS-THROUGH WRAPPERS for normal (reactive) actions *)

MCStartClone                           == StartClone                           /\ UNCHANGED faultVars
MCRecipientBeginClone                  == RecipientBeginClone                  /\ UNCHANGED faultVars
MCDonorEnterCriticalSection            == DonorEnterCriticalSection            /\ UNCHANGED faultVars
MCRecipientEnterCriticalSection        == RecipientEnterCriticalSection        /\ UNCHANGED faultVars
MCCommitChunkMigrationOnConfigServer   == CommitChunkMigrationOnConfigServer   /\ UNCHANGED faultVars
MCLaunchReleaseRecipientCritSec        == LaunchReleaseRecipientCritSec        /\ UNCHANGED faultVars
MCRecipientReleaseCritSec              == RecipientReleaseCritSec              /\ UNCHANGED faultVars
MCPersistCommitDecision                == PersistCommitDecision                /\ UNCHANGED faultVars
MCDeleteRecipientRangeDeletionTask     == DeleteRecipientRangeDeletionTask     /\ UNCHANGED faultVars
MCMarkDonorRangeDeletionTaskReady      == MarkDonorRangeDeletionTaskReady      /\ UNCHANGED faultVars
MCForgetMigration                      == ForgetMigration                      /\ UNCHANGED faultVars
MCPersistAbortDecision                 == PersistAbortDecision                 /\ UNCHANGED faultVars
MCDeleteDonorRangeDeletionTaskOnAbort  == DeleteDonorRangeDeletionTaskOnAbort  /\ UNCHANGED faultVars
MCMarkRecipientRangeDeletionTaskReadyOnAbort == MarkRecipientRangeDeletionTaskReadyOnAbort /\ UNCHANGED faultVars
MCRecoverDonor                         == RecoverDonor                         /\ UNCHANGED faultVars
MCRecoverDonorNoDecision               == RecoverDonorNoDecision               /\ UNCHANGED faultVars
MCStartRecipientRecovery               == StartRecipientRecovery               /\ UNCHANGED faultVars
MCRecoverySetsCritSecState             == RecoverySetsCritSecState             /\ UNCHANGED faultVars

MCNext ==
    \* Normal reactive actions
    \/ MCStartClone
    \/ MCRecipientBeginClone
    \/ MCDonorEnterCriticalSection
    \/ MCRecipientEnterCriticalSection
    \/ MCCommitChunkMigrationOnConfigServer
    \/ MCLaunchReleaseRecipientCritSec
    \/ MCRecipientReleaseCritSec
    \/ MCPersistCommitDecision
    \/ MCDeleteRecipientRangeDeletionTask
    \/ MCMarkDonorRangeDeletionTaskReady
    \/ MCForgetMigration
    \/ MCPersistAbortDecision
    \/ MCDeleteDonorRangeDeletionTaskOnAbort
    \/ MCMarkRecipientRangeDeletionTaskReadyOnAbort
    \/ MCRecoverDonor
    \/ MCRecoverDonorNoDecision
    \/ MCStartRecipientRecovery
    \/ MCRecoverySetsCritSecState
    \* Bounded fault-injection
    \/ MCCrashDonor
    \/ MCConcurrentAbortSignal

MCSpec == MCInit /\ [][MCNext]_<<vars, faultVars>>

-----------------------------------------------------------------------------
(* VIEW: exclude fault counters from symmetry reduction state fingerprint *)
MCView == vars

=============================================================================
