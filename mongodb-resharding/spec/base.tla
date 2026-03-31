---- MODULE base ----
(* =========================================================================
 * MongoDB Resharding Coordinator State Machine
 * =========================================================================
 *
 * Models the 3-party resharding protocol: Coordinator + Donors + Recipients.
 * Focus: coordinator failover safety and participant synchronization.
 *
 * Bug Families targeted:
 *   Family 1: Abort decision lost on coordinator failover (SERVER-61483)
 *   Family 2: Observer promise deadlock during abort (SERVER-120917)
 *   Family 3: DAO invariant crash on state race (SERVER-74647)
 *   Family 4: Participant w:1 state lost on stepdown (SERVER-68628)
 *
 * Source: mongodb/mongo, src/mongo/db/s/resharding/
 * ========================================================================= *)
EXTENDS Integers, FiniteSets, TLC

(* =========================================================================
 * Constants
 * ========================================================================= *)
CONSTANTS
    Donor,        \* Set of donor shard IDs
    Recipient,    \* Set of recipient shard IDs
    CoordTicketExempt  \* BOOLEAN: post-commit uses LOGV2_FATAL vs safe retry

Participant == Donor \cup Recipient

(* =========================================================================
 * Coordinator States (CoordinatorStateEnum)
 * resharding_coordinator.h — reconstructed from usage
 * Ordered: kUnused < kInitializing < ... < kDone
 * ========================================================================= *)
CUnused          == 0   \* In-memory only, no persistence
CInitializing    == 1   \* Coord doc inserted
CPreparingToDonate == 2 \* Participant shards computed
CCloning         == 3   \* All donors reported minFetchTimestamp
CApplying        == 4   \* All recipients finished cloning
CBlockingWrites  == 5   \* Critical section — donors block writes
CCommitting      == 6   \* Point of no return — metadata swapped
CAborting        == 7   \* Abort in progress (participants aware)
CQuiesced        == 8   \* Complete, holding doc for retries
CDone            == 9   \* Terminal — doc deleted

CoordStates == {CUnused, CInitializing, CPreparingToDonate, CCloning,
                CApplying, CBlockingWrites, CCommitting, CAborting,
                CQuiesced, CDone}

\* Happy-path ordering for > comparisons (resharding_coordinator.inl:167)
HappyPathStates == {CUnused, CInitializing, CPreparingToDonate, CCloning,
                    CApplying, CBlockingWrites, CCommitting, CQuiesced, CDone}

(* =========================================================================
 * Donor States (DonorStateEnum)
 * resharding_donor_service.cpp
 * ========================================================================= *)
DNone     == "D_none"
DDonating == "D_donating"     \* kDonatingInitialData
DBlocking == "D_blocking"     \* kBlockingWrites
DDone     == "D_done"         \* kDone
DError    == "D_error"        \* kError

DonorStates == {DNone, DDonating, DBlocking, DDone, DError}

(* =========================================================================
 * Recipient States (RecipientStateEnum)
 * resharding_recipient_service.cpp
 * ========================================================================= *)
RNone       == "R_none"
RCloning    == "R_cloning"      \* kCloning
RApplying   == "R_applying"     \* kApplying
RStrict     == "R_strict"       \* kStrictConsistency
RDone       == "R_done"         \* kDone
RError      == "R_error"        \* kError

RecipientStates == {RNone, RCloning, RApplying, RStrict, RDone, RError}

(* =========================================================================
 * Variables
 * ========================================================================= *)
VARIABLES
    \* --- Coordinator state ---
    coordState,     \* CoordStates — in-memory state
    coordDoc,       \* CoordStates — on-disk persisted state [Family 1]
    coordDocDurable,\* BOOLEAN — TRUE iff coordDoc is majority-committed [Family 1]
    coordAlive,     \* BOOLEAN — coordinator primary is alive
    abortReason,    \* BOOLEAN — TRUE if abort was requested [Family 1]
    abortPersisted, \* BOOLEAN — abort state written to doc [Family 1]

    \* --- Donor state ---
    donorState,     \* [Donor -> DonorStates]
    donorDocDurable,\* [Donor -> BOOLEAN] — w:1 vs majority [Family 4]

    \* --- Recipient state ---
    recipState,     \* [Recipient -> RecipientStates]
    recipDocDurable,\* [Recipient -> BOOLEAN] — w:1 vs majority [Family 4]

    \* --- Observer promises [Family 2] ---
    \* Each promise: "pending" | "fulfilled" | "errored"
    \* resharding_coordinator_observer.cpp:40-80
    promDonorsReady,     \* All donors reached DDonating
    promRecipientsCloned,\* All recipients reached RApplying
    promRecipientsStrict,\* All recipients reached RStrict
    promRecipientsDone,  \* All recipients reached RDone
    promDonorsDone       \* All donors reached DDone

\* Variable groups
coordVars == <<coordState, coordDoc, coordDocDurable, coordAlive, abortReason, abortPersisted>>
donorVars == <<donorState, donorDocDurable>>
recipVars == <<recipState, recipDocDurable>>
promVars == <<promDonorsReady, promRecipientsCloned, promRecipientsStrict, promRecipientsDone, promDonorsDone>>

vars == <<coordVars, donorVars, recipVars, promVars>>

(* =========================================================================
 * Helpers
 * ========================================================================= *)

\* All donors in at least state s
AllDonorsAtLeast(s) ==
    \A d \in Donor :
        \/ donorState[d] = s
        \/ donorState[d] = DDone
        \/ (s = DDonating /\ donorState[d] = DBlocking)
        \/ (s = DDonating /\ donorState[d] = DDone)
        \/ (s = DBlocking /\ donorState[d] = DDone)

\* All recipients in at least state s
AllRecipientsAtLeast(s) ==
    \A r \in Recipient :
        \/ recipState[r] = s
        \/ recipState[r] = RDone
        \/ (s = RCloning /\ recipState[r] \in {RApplying, RStrict, RDone})
        \/ (s = RApplying /\ recipState[r] \in {RStrict, RDone})
        \/ (s = RStrict /\ recipState[r] = RDone)

\* Any participant has error
AnyParticipantError ==
    \/ \E d \in Donor : donorState[d] = DError
    \/ \E r \in Recipient : recipState[r] = RError

AllParticipantsDone ==
    /\ \A d \in Donor : donorState[d] = DDone
    /\ \A r \in Recipient : recipState[r] = RDone

(* =========================================================================
 * Init
 * ========================================================================= *)
Init ==
    /\ coordState = CUnused
    /\ coordDoc = CUnused
    /\ coordDocDurable = FALSE
    /\ coordAlive = TRUE
    /\ abortReason = FALSE
    /\ abortPersisted = FALSE
    /\ donorState = [d \in Donor |-> DNone]
    /\ donorDocDurable = [d \in Donor |-> FALSE]
    /\ recipState = [r \in Recipient |-> RNone]
    /\ recipDocDurable = [r \in Recipient |-> FALSE]
    /\ promDonorsReady = "pending"
    /\ promRecipientsCloned = "pending"
    /\ promRecipientsStrict = "pending"
    /\ promRecipientsDone = "pending"
    /\ promDonorsDone = "pending"

(* =========================================================================
 * Coordinator Actions — Happy Path
 * ========================================================================= *)

\* _insertCoordDocAndChangeOrigCollEntry (resharding_coordinator.inl:~330)
\* kUnused -> kInitializing
CoordInitialize ==
    /\ coordAlive
    /\ coordState = CUnused
    /\ coordState' = CInitializing
    /\ coordDoc' = CInitializing
    /\ coordDocDurable' = FALSE  \* local write first, majority later
    /\ UNCHANGED <<abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

\* waitForMajority after Initialize (resharding_coordinator.inl:~350)
CoordInitializeMajority ==
    /\ coordAlive
    /\ coordState = CInitializing
    /\ coordDoc = CInitializing
    /\ ~coordDocDurable
    /\ coordDocDurable' = TRUE
    /\ UNCHANGED <<coordState, coordDoc, abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

\* _calculateParticipantsAndChunksThenWriteToDisk (resharding_coordinator.inl:~344)
\* kInitializing -> kPreparingToDonate
CoordPrepare ==
    /\ coordAlive
    /\ coordState = CInitializing
    /\ coordDocDurable  \* must have majority for kInitializing first
    /\ coordState' = CPreparingToDonate
    /\ coordDoc' = CPreparingToDonate
    /\ coordDocDurable' = FALSE
    /\ UNCHANGED <<abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

\* waitForMajority + tell participants (resharding_coordinator.inl:~350)
CoordPrepareMajority ==
    /\ coordAlive
    /\ coordState = CPreparingToDonate
    /\ coordDoc = CPreparingToDonate
    /\ ~coordDocDurable
    /\ coordDocDurable' = TRUE
    \* Participants become aware — transition from None to initial states
    /\ donorState' = [d \in Donor |-> IF donorState[d] = DNone THEN DDonating ELSE donorState[d]]
    /\ recipState' = [r \in Recipient |-> IF recipState[r] = RNone THEN RCloning ELSE recipState[r]]
    /\ donorDocDurable' = [d \in Donor |-> FALSE]
    /\ recipDocDurable' = [r \in Recipient |-> FALSE]
    /\ UNCHANGED <<coordState, coordDoc, abortReason, abortPersisted, coordAlive, promVars>>

\* _awaitAllDonorsReadyToDonate → kCloning (resharding_coordinator.inl:~356)
CoordTransitionToCloning ==
    /\ coordAlive
    /\ coordState = CPreparingToDonate
    /\ coordDocDurable
    /\ promDonorsReady = "fulfilled"  \* observer promise fulfilled
    /\ coordState' = CCloning
    /\ coordDoc' = CCloning
    /\ coordDocDurable' = FALSE
    /\ UNCHANGED <<abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

\* _awaitAllRecipientsFinishedCloning → kApplying (resharding_coordinator.inl:~378)
CoordTransitionToApplying ==
    /\ coordAlive
    /\ coordState = CCloning
    /\ coordDocDurable
    /\ promRecipientsCloned = "fulfilled"
    /\ coordState' = CApplying
    /\ coordDoc' = CApplying
    /\ coordDocDurable' = FALSE
    /\ UNCHANGED <<abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

\* _awaitAllRecipientsFinishedApplying → kBlockingWrites (resharding_coordinator.inl:~394)
CoordTransitionToBlocking ==
    /\ coordAlive
    /\ coordState = CApplying
    /\ coordDocDurable
    /\ promRecipientsStrict = "fulfilled"  \* simplified: recipients strict = ready for blocking
    /\ coordState' = CBlockingWrites
    /\ coordDoc' = CBlockingWrites
    /\ coordDocDurable' = FALSE
    /\ UNCHANGED <<abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

\* _commit → kCommitting — POINT OF NO RETURN (resharding_coordinator.inl:~419)
\* Single txn: coord doc update + metadata swap
CoordCommit ==
    /\ coordAlive
    /\ coordState = CBlockingWrites
    /\ coordDocDurable
    /\ ~abortReason  \* abort token not cancelled (resharding_coordinator.inl: token switch)
    /\ promRecipientsStrict = "fulfilled"
    /\ coordState' = CCommitting
    /\ coordDoc' = CCommitting
    /\ coordDocDurable' = FALSE
    /\ UNCHANGED <<abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

\* waitForMajority after commit (resharding_coordinator.inl:~449)
\* Majority-commits the commit doc. Does NOT atomically transition participants.
\* Participants are notified asynchronously via _tellAllParticipantsToCommit.
CoordCommitMajority ==
    /\ coordAlive
    /\ coordState = CCommitting
    /\ ~coordDocDurable
    /\ coordDocDurable' = TRUE
    /\ UNCHANGED <<coordState, coordDoc, abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

\* Tell all participants to commit (async — each transitions to Done independently)
\* resharding_coordinator.inl:~1960 (_tellAllParticipantsToCommit)
CoordTellParticipantsCommit ==
    /\ coordAlive
    /\ coordState = CCommitting
    /\ coordDocDurable
    \* Each participant independently transitions to Done
    /\ donorState' = [d \in Donor |-> IF donorState[d] \in {DDonating, DBlocking} THEN DDone ELSE donorState[d]]
    /\ recipState' = [r \in Recipient |-> IF recipState[r] \in {RCloning, RApplying, RStrict} THEN RDone ELSE recipState[r]]
    /\ donorDocDurable' = [d \in Donor |-> FALSE]
    /\ recipDocDurable' = [r \in Recipient |-> FALSE]
    /\ UNCHANGED <<coordVars, promVars>>

\* Coordinator finishes → kDone
\* resharding_coordinator.inl:1793-1795: waits on done-promise futures
CoordFinish ==
    /\ coordAlive
    /\ coordState = CCommitting
    /\ coordDocDurable
    /\ promRecipientsDone \in {"fulfilled", "errored"}
    /\ promDonorsDone \in {"fulfilled", "errored"}
    /\ coordState' = CDone
    /\ coordDoc' = CDone
    /\ coordDocDurable' = TRUE
    /\ UNCHANGED <<abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

(* =========================================================================
 * Coordinator Actions — Abort Path [Family 1, 2]
 * ========================================================================= *)

\* External abort request (user command or critical section timeout)
\* resharding_coordinator.inl:123-140 (CoordinatorCancellationTokenHolder::abort)
CoordAbortRequest ==
    /\ coordAlive
    /\ ~abortReason
    /\ coordState \in {CInitializing, CPreparingToDonate, CCloning, CApplying, CBlockingWrites}
    /\ abortReason' = TRUE
    /\ UNCHANGED <<coordState, coordDoc, coordDocDurable, coordAlive, abortPersisted, donorVars, recipVars, promVars>>

\* Participant error triggers abort
\* resharding_coordinator_observer.cpp:274-286 (_onAbortOrStepdown)
CoordAbortOnParticipantError ==
    /\ coordAlive
    /\ ~abortReason
    /\ AnyParticipantError
    /\ coordState \in {CPreparingToDonate, CCloning, CApplying, CBlockingWrites}
    /\ abortReason' = TRUE
    \* _onAbortOrStepdown: errors first 3 promises only [Family 2]
    /\ promDonorsReady' = IF promDonorsReady = "pending" THEN "errored" ELSE promDonorsReady
    /\ promRecipientsCloned' = IF promRecipientsCloned = "pending" THEN "errored" ELSE promRecipientsCloned
    /\ promRecipientsStrict' = IF promRecipientsStrict = "pending" THEN "errored" ELSE promRecipientsStrict
    \* NOTE: promRecipientsDone and promDonorsDone are NOT errored here! [Family 2 bug]
    /\ UNCHANGED <<coordState, coordDoc, coordDocDurable, coordAlive, abortPersisted,
                   promRecipientsDone, promDonorsDone, donorVars, recipVars>>

\* _onAbortCoordinatorOnly — abort before participants are aware
\* resharding_coordinator.inl:~580
CoordAbortCoordinatorOnly ==
    /\ coordAlive
    /\ abortReason
    /\ coordState \in {CUnused, CInitializing}
    /\ coordState' = CDone
    /\ coordDoc' = CDone
    /\ coordDocDurable' = TRUE
    /\ abortPersisted' = TRUE
    /\ UNCHANGED <<abortReason, coordAlive, donorVars, recipVars, promVars>>

\* _onAbortCoordinatorAndParticipants — abort with participant notification
\* resharding_coordinator.inl:~590-640
\* Step 1: persist kAborting
CoordAbortPersist ==
    /\ coordAlive
    /\ abortReason
    /\ coordState \in {CPreparingToDonate, CCloning, CApplying, CBlockingWrites}
    /\ coordState' = CAborting
    /\ coordDoc' = CAborting
    /\ coordDocDurable' = FALSE
    /\ abortPersisted' = TRUE
    /\ UNCHANGED <<abortReason, coordAlive, donorVars, recipVars, promVars>>

\* Step 2: wait for majority on abort doc
\* Majority-commits the abort doc. Does NOT atomically transition participants.
CoordAbortMajority ==
    /\ coordAlive
    /\ coordState = CAborting
    /\ ~coordDocDurable
    /\ coordDocDurable' = TRUE
    /\ UNCHANGED <<coordState, coordDoc, abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

\* Step 2b: Tell all participants to abort (async)
\* resharding_coordinator.inl:890 (_tellAllParticipantsToAbort)
CoordTellParticipantsAbort ==
    /\ coordAlive
    /\ coordState = CAborting
    /\ coordDocDurable
    /\ donorState' = [d \in Donor |-> IF donorState[d] \notin {DDone, DError} THEN DDone ELSE donorState[d]]
    /\ recipState' = [r \in Recipient |-> IF recipState[r] \notin {RDone, RError} THEN RDone ELSE recipState[r]]
    /\ donorDocDurable' = [d \in Donor |-> FALSE]
    /\ recipDocDurable' = [r \in Recipient |-> FALSE]
    /\ UNCHANGED <<coordVars, promVars>>

\* Step 3: wait for all participants done then finish
\* resharding_coordinator.inl:895-896: _awaitAllParticipantShardsDone waits on
\* done-promise futures, NOT directly on participant state.
CoordAbortFinish ==
    /\ coordAlive
    /\ coordState = CAborting
    /\ coordDocDurable
    \* Must wait on done-promises (not AllParticipantsDone directly!)
    \* This is the key: coordinator uses observer futures.
    /\ promRecipientsDone \in {"fulfilled", "errored"}
    /\ promDonorsDone \in {"fulfilled", "errored"}
    /\ coordState' = CDone
    /\ coordDoc' = CDone
    /\ coordDocDurable' = TRUE
    /\ UNCHANGED <<abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

(* =========================================================================
 * Coordinator Crash and Recovery [Family 1, 3]
 * ========================================================================= *)

\* Coordinator primary steps down — loses in-memory state
\* PrimaryOnlyService interrupts the running instance
CoordCrash ==
    /\ coordAlive
    /\ coordState \notin {CUnused, CDone}
    /\ coordAlive' = FALSE
    \* In-memory state lost; on-disk state may or may not be durable
    /\ coordState' = CUnused  \* in-memory reverts
    \* If doc was NOT majority-committed, it might be rolled back on new primary
    /\ coordDoc' = IF coordDocDurable THEN coordDoc ELSE
                   \* Non-deterministic: doc might or might not survive rollback [Family 1]
                   \* In reality, w:majority writes survive; w:1 writes may not
                   IF coordDoc \in {CInitializing, CPreparingToDonate, CCloning, CApplying,
                                    CBlockingWrites, CCommitting, CAborting}
                   THEN coordDoc  \* survived (was actually replicated)
                   ELSE coordDoc  \* for simplicity, keep it — MC will explore both paths via non-determinism in recovery
    /\ coordDocDurable' = coordDocDurable  \* durability status preserved
    \* Abort persistence may be lost if abort doc wasn't majority
    /\ abortPersisted' = IF ~coordDocDurable /\ abortPersisted THEN FALSE ELSE abortPersisted
    /\ UNCHANGED <<abortReason, donorVars, recipVars, promVars>>

\* Coordinator step-up recovery
\* resharding_coordinator.inl:147-192 (constructor)
\* PrimaryOnlyService reconstructs from persisted doc
CoordRecover ==
    /\ ~coordAlive
    /\ coordDoc \notin {CUnused, CDone}
    /\ coordAlive' = TRUE
    \* Resume from persisted doc state (resharding_coordinator.inl:167)
    /\ coordState' = coordDoc
    /\ coordDocDurable' = TRUE  \* on step-up, we wait for majority before recovery
    \* Re-prime observer promises (resharding_coordinator.inl:167-169)
    \* Constructor calls onReshardingParticipantTransition if state > kInitializing
    /\ promDonorsReady' = IF coordDoc >= CCloning /\ AllDonorsAtLeast(DDonating)
                          THEN "fulfilled" ELSE promDonorsReady
    /\ promRecipientsCloned' = IF coordDoc >= CApplying /\ AllRecipientsAtLeast(RApplying)
                               THEN "fulfilled" ELSE promRecipientsCloned
    /\ promRecipientsStrict' = IF coordDoc >= CBlockingWrites /\ AllRecipientsAtLeast(RStrict)
                               THEN "fulfilled" ELSE promRecipientsStrict
    /\ promRecipientsDone' = IF AllRecipientsAtLeast(RDone)
                             THEN "fulfilled" ELSE promRecipientsDone
    /\ promDonorsDone' = IF AllDonorsAtLeast(DDone)
                         THEN "fulfilled" ELSE promDonorsDone
    \* Abort reason restored from doc (resharding_coordinator.inl:183-186)
    /\ abortReason' = IF coordDoc = CAborting THEN TRUE ELSE abortReason
    /\ abortPersisted' = IF coordDoc = CAborting THEN TRUE ELSE abortPersisted
    /\ UNCHANGED <<coordDoc, donorVars, recipVars>>

(* =========================================================================
 * Participant Actions
 * ========================================================================= *)

\* Donor advances state (abstracted — donor signals readiness to coordinator)
\* resharding_donor_service.cpp — state machine progression
DonorAdvance(d) ==
    /\ donorState[d] = DDonating
    /\ donorState' = [donorState EXCEPT ![d] = DBlocking]
    /\ donorDocDurable' = [donorDocDurable EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<coordVars, recipVars, promVars>>

\* Donor finishes blocking → done (after coordinator commits)
DonorDone(d) ==
    /\ donorState[d] = DBlocking
    /\ donorState' = [donorState EXCEPT ![d] = DDone]
    /\ donorDocDurable' = [donorDocDurable EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<coordVars, recipVars, promVars>>

\* Donor encounters error
DonorError(d) ==
    /\ donorState[d] \in {DDonating, DBlocking}
    /\ donorState' = [donorState EXCEPT ![d] = DError]
    /\ donorDocDurable' = [donorDocDurable EXCEPT ![d] = FALSE]
    /\ UNCHANGED <<coordVars, recipVars, promVars>>

\* Recipient advances: cloning → applying → strict → done
RecipientAdvance(r) ==
    /\ \/ /\ recipState[r] = RCloning
          /\ recipState' = [recipState EXCEPT ![r] = RApplying]
       \/ /\ recipState[r] = RApplying
          /\ recipState' = [recipState EXCEPT ![r] = RStrict]
    /\ recipDocDurable' = [recipDocDurable EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<coordVars, donorVars, promVars>>

RecipientDone(r) ==
    /\ recipState[r] = RStrict
    /\ recipState' = [recipState EXCEPT ![r] = RDone]
    /\ recipDocDurable' = [recipDocDurable EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<coordVars, donorVars, promVars>>

\* Recipient error
RecipientError(r) ==
    /\ recipState[r] \in {RCloning, RApplying, RStrict}
    /\ recipState' = [recipState EXCEPT ![r] = RError]
    /\ recipDocDurable' = [recipDocDurable EXCEPT ![r] = FALSE]
    /\ UNCHANGED <<coordVars, donorVars, promVars>>

(* =========================================================================
 * Observer Promise Check [Family 2]
 * resharding_coordinator_observer.cpp:80-210
 * Key: checks promises in STRICT SEQUENTIAL ORDER, returns early
 * ========================================================================= *)

ObserverCheck ==
    /\ coordAlive
    /\ coordState \notin {CUnused, CDone}
    \* resharding_coordinator_observer.cpp:171-206
    \* First: check for abort reason → _onAbortOrStepdown errors first 3 promises
    \* (observer.cpp:174-176)
    /\ LET abortActive == abortReason IN
       \* _onAbortOrStepdown: error first 3 promises if pending (observer.cpp:274-286)
       LET pDR == IF abortActive /\ promDonorsReady = "pending" THEN "errored" ELSE promDonorsReady
           pRC == IF abortActive /\ promRecipientsCloned = "pending" THEN "errored" ELSE promRecipientsCloned
           pRS == IF abortActive /\ promRecipientsStrict = "pending" THEN "errored" ELSE promRecipientsStrict
       IN
       \* Then: sequential promise check (observer.cpp:179-205)
       \* stateTransistionsComplete returns TRUE if promise isReady (fulfilled OR errored)
       LET dr == IF pDR = "pending" /\ AllDonorsAtLeast(DDonating)
                 THEN "fulfilled" ELSE pDR
       IN
       LET rc == IF dr # "pending" /\ pRC = "pending" /\ AllRecipientsAtLeast(RApplying)
                 THEN "fulfilled" ELSE pRC
       IN
       LET rs == IF rc # "pending" /\ pRS = "pending" /\ AllRecipientsAtLeast(RStrict)
                 THEN "fulfilled" ELSE pRS
       IN
       \* Done promises: only checked if earlier promises are non-pending
       \* observer.cpp:198-205. NOT errored by _onAbortOrStepdown.
       LET rd == IF rs # "pending" /\ promRecipientsDone = "pending" /\ AllRecipientsAtLeast(RDone)
                 THEN "fulfilled" ELSE promRecipientsDone
       IN
       LET dd == IF rd # "pending" /\ promDonorsDone = "pending" /\ AllDonorsAtLeast(DDone)
                 THEN "fulfilled" ELSE promDonorsDone
       IN
       /\ promDonorsReady' = dr
       /\ promRecipientsCloned' = rc
       /\ promRecipientsStrict' = rs
       /\ promRecipientsDone' = rd
       /\ promDonorsDone' = dd
    /\ UNCHANGED <<coordVars, donorVars, recipVars>>

(* =========================================================================
 * State transition majority commits (generic)
 * ========================================================================= *)

CoordGenericMajority ==
    /\ coordAlive
    /\ coordState \in {CCloning, CApplying, CBlockingWrites}
    /\ coordDoc = coordState
    /\ ~coordDocDurable
    /\ coordDocDurable' = TRUE
    /\ UNCHANGED <<coordState, coordDoc, abortReason, abortPersisted, coordAlive, donorVars, recipVars, promVars>>

(* =========================================================================
 * Next
 * ========================================================================= *)

Next ==
    \* Coordinator happy path
    \/ CoordInitialize
    \/ CoordInitializeMajority
    \/ CoordPrepare
    \/ CoordPrepareMajority
    \/ CoordTransitionToCloning
    \/ CoordTransitionToApplying
    \/ CoordTransitionToBlocking
    \/ CoordCommit
    \/ CoordCommitMajority
    \/ CoordTellParticipantsCommit
    \/ CoordFinish
    \/ CoordGenericMajority
    \* Coordinator abort path
    \/ CoordAbortRequest
    \/ CoordAbortOnParticipantError
    \/ CoordAbortCoordinatorOnly
    \/ CoordAbortPersist
    \/ CoordAbortMajority
    \/ CoordTellParticipantsAbort
    \/ CoordAbortFinish
    \* Coordinator crash/recovery
    \/ CoordCrash
    \/ CoordRecover
    \* Participant actions
    \/ \E d \in Donor : DonorAdvance(d)
    \/ \E d \in Donor : DonorDone(d)
    \/ \E d \in Donor : DonorError(d)
    \/ \E r \in Recipient : RecipientAdvance(r)
    \/ \E r \in Recipient : RecipientDone(r)
    \/ \E r \in Recipient : RecipientError(r)
    \* Observer
    \/ ObserverCheck

Spec == Init /\ [][Next]_vars

(* =========================================================================
 * Invariants
 * ========================================================================= *)

\* --- Structural ---

\* Coordinator state is a valid value
CoordStateValid == coordState \in CoordStates

\* --- Standard safety ---

\* Once committed, never abort [Family 1]
NoCommitAfterAbort ==
    abortPersisted => coordState # CCommitting

\* Once in kCommitting, abort is impossible [Family 1]
PostCommitNoAbort ==
    coordState = CCommitting => ~abortReason \/ coordDoc = CCommitting

\* --- Extension: Family 1 ---

\* If abort was persisted with majority, recovery must see abort
AbortDecisionSurvivesFailover ==
    (abortPersisted /\ coordDocDurable /\ coordDoc = CAborting) =>
        (coordAlive => coordState \in {CAborting, CDone})

\* --- Extension: Family 2 ---

\* If coordinator is waiting for done promises, they must eventually be fulfillable
\* (no permanent block)
NoPromiseDeadlock ==
    \* If coordinator is in abort-finish waiting for AllParticipantsDone,
    \* but done-promises are "pending" (not "errored"), and all participants
    \* are actually in done/error state → promises should be fulfilled
    (coordState = CAborting /\ coordDocDurable /\ AllParticipantsDone) =>
        (promRecipientsDone \in {"fulfilled", "errored"} /\ promDonorsDone \in {"fulfilled", "errored"})

\* --- Extension: Family 3 ---

\* DAO invariant: transition should only happen from expected state
\* Models the non-atomic read-check-write in coordinator_dao.cpp
DAOConsistency ==
    \* coordDoc should never jump backwards (except on crash rollback)
    coordAlive => coordDoc >= coordState \/ coordState = CUnused

====
