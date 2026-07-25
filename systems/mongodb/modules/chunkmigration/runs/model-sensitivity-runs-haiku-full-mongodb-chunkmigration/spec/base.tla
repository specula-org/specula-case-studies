---- MODULE base ----
(*
 * MongoDB Chunk Migration: Commit and Recovery Protocol
 *
 * Models the 3-way coordination protocol for migrating a chunk between shards
 * via the config server. Targets bug families identified in modeling brief:
 * - Family 1: Non-atomic multi-node commit/abort decision
 * - Family 2: Filtering metadata inconsistency during commit failure
 * - Family 3: Range deletion task lifecycle mismatch
 * - Family 4: Asynchronous recipient critical section release
 * - Family 5: Error handling in abort decision propagation
 *)

EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANT Nodes          \* {Donor, Recipient, ConfigServer}
CONSTANT Decisions      \* {Commit, Abort, Undecided}

VARIABLE donorState     \* Donor shard state (migration_source_manager.cpp)
VARIABLE recipientState \* Recipient shard state (migration_destination_manager.cpp)
VARIABLE configState    \* Config server state
VARIABLE messages       \* Network messages between nodes

\* Metadata state (Family 2: filtering metadata inconsistency)
VARIABLE donorMetadata  \* Donor's view of chunk ownership {owned, not_owned}
VARIABLE recipientMetadata \* Recipient's view of chunk ownership {owned, not_owned}
VARIABLE criticalSectionActive \* Whether recipient critical section is active

\* Range deletion tasks (Family 3: task lifecycle mismatch)
VARIABLE donorRangeDeletionTask \* Donor task state: {pending, ready, deleted}
VARIABLE recipientRangeDeletionTask \* Recipient task state: {pending, ready, completed}

\* Decision persistence (Family 1: non-atomic commit/abort)
VARIABLE coordinatorDecision \* Decision persisted on coordinator: {Undecided, Commit, Abort}
VARIABLE donorDecision  \* Decision persisted on donor: {Undecided, Commit, Abort}
VARIABLE recipientClone \* Recipient clone completion: {not_cloned, cloned}

\* Critical section release state (Family 4: async release)
VARIABLE recipientCritSectionReleased \* {not_released, in_flight, released}

\* RPC failure tracking (Family 5: error handling)
VARIABLE lastRPCFailure \* {none, ShardNotFound, Transient}

vars == <<donorState, recipientState, configState, messages,
          donorMetadata, recipientMetadata, criticalSectionActive,
          donorRangeDeletionTask, recipientRangeDeletionTask,
          coordinatorDecision, donorDecision, recipientClone,
          recipientCritSectionReleased, lastRPCFailure>>

----

\* Donor state machine states (migration_source_manager.cpp:~100+)
DonorStates == {"Init", "Cloning", "CriticalSection", "CommittingOnConfig", "Done"}

\* Recipient state machine states (migration_destination_manager.cpp)
RecipientStates == {"Init", "Cloning", "CriticalSection", "Done"}

\* Config server states
ConfigStates == {"Init", "CommitReceived", "Committed", "Done"}

\* Range deletion task states
TaskStates == {"pending", "ready", "completed"}

MetadataOwned == {"owned", "not_owned"}

ReleasedStates == {"not_released", "in_flight", "released"}

----

\* Message types for RPC communication
IsValidMessage(msg) ==
    /\ msg \in [type: {"CommitDecision", "AbortDecision",
                       "ReleaseCriticalSection", "BumpTxnNumber",
                       "MarkRangeDeletionReady", "CritSectionReleased"}, from: Nodes, to: Nodes]

SendMessage(type, from, to) ==
    messages' = messages \cup {[type |-> type, from |-> from, to |-> to]}

DiscardMessage(msg) ==
    messages' = messages \ {msg}

----

Init ==
    /\ donorState = "Init"
    /\ recipientState = "Init"
    /\ configState = "Init"
    /\ messages = {}
    /\ donorMetadata = "owned"
    /\ recipientMetadata = "not_owned"
    /\ criticalSectionActive = FALSE
    /\ donorRangeDeletionTask = "pending"
    /\ recipientRangeDeletionTask = "pending"
    /\ coordinatorDecision = "Undecided"
    /\ donorDecision = "Undecided"
    /\ recipientClone = "not_cloned"
    /\ recipientCritSectionReleased = "not_released"
    /\ lastRPCFailure = "none"

----

\* Phase 1: Clone Phase
\* Recipient clones data from donor (migration_source_manager.cpp:404-529)
RecipientStartClone ==
    /\ recipientState = "Init"
    /\ recipientState' = "Cloning"
    /\ recipientClone' = "not_cloned"
    /\ UNCHANGED <<donorState, configState, messages, donorMetadata, recipientMetadata,
                   criticalSectionActive, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientCritSectionReleased, lastRPCFailure>>

RecipientCloneComplete ==
    /\ recipientState = "Cloning"
    /\ recipientClone' = "cloned"
    /\ recipientState' = "CriticalSection"
    /\ UNCHANGED <<donorState, configState, messages, donorMetadata, recipientMetadata,
                   criticalSectionActive, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientCritSectionReleased, lastRPCFailure>>

----

\* Phase 2: Critical Section Entry
\* Donor enters critical section (read-only mode) - migration_source_manager.cpp:550-593
DonorEnterCriticalSection ==
    /\ donorState = "Cloning"
    /\ recipientClone = "cloned"
    /\ donorState' = "CriticalSection"
    /\ criticalSectionActive' = TRUE
    /\ UNCHANGED <<recipientState, configState, messages, donorMetadata, recipientMetadata,
                   donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone, recipientCritSectionReleased, lastRPCFailure>>

----

\* Phase 3: Commit Decision Persistence (Family 1 extension)
\* Coordinator persists commit decision locally - migration_coordinator.cpp:233-240
DonorPersistCommitDecision ==
    /\ donorState = "CriticalSection"
    /\ recipientClone = "cloned"
    /\ coordinatorDecision' = "Commit"
    \* Crash window 1 (Family 1): decision persisted but recipient not yet notified
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, donorRangeDeletionTask,
                   recipientRangeDeletionTask, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

\* Abort decision persistence - migration_coordinator.cpp:327-334
DonorPersistAbortDecision ==
    /\ donorState = "CriticalSection"
    /\ coordinatorDecision' = "Abort"
    \* Crash window: decision persisted but cleanup not yet started
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, donorRangeDeletionTask,
                   recipientRangeDeletionTask, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

----

\* Phase 4: Config Server Commit (Family 2 extension)
\* Donor sends commit to config server - migration_source_manager.cpp:626-672
DonorSendConfigServerCommit ==
    /\ donorState = "CriticalSection"
    /\ coordinatorDecision = "Commit"
    /\ donorState' = "CommittingOnConfig"
    \* Enter commit phase on critical section - migration_source_manager.cpp:659
    /\ UNCHANGED <<recipientState, configState, messages, donorMetadata, recipientMetadata,
                   criticalSectionActive, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

\* Config server receives and persists commit
ConfigServerPersistCommit ==
    /\ configState = "Init"
    /\ coordinatorDecision = "Commit"
    /\ configState' = "Committed"
    /\ UNCHANGED <<donorState, recipientState, messages, donorMetadata, recipientMetadata,
                   criticalSectionActive, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

\* Config server commit failure (Family 2: trigger metadata inconsistency)
\* When config server commit fails, donor clears metadata - migration_source_manager.cpp:681-690
ConfigServerCommitFails ==
    /\ configState = "Init"
    /\ donorState = "CommittingOnConfig"
    /\ donorMetadata' = "not_owned"
    \* Critical section still active on recipient (Family 2 vulnerability)
    /\ configState' = "Done"
    /\ lastRPCFailure' = "Transient"
    /\ UNCHANGED <<donorState, recipientState, messages, recipientMetadata,
                   criticalSectionActive, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased>>

----

\* Critical Section Release (Family 4 extension)
\* Coordinator launches async critical section release - migration_coordinator.cpp:403-410
LaunchReleaseRecipientCriticalSection ==
    /\ coordinatorDecision \in {"Commit", "Abort"}
    /\ recipientCritSectionReleased = "not_released"
    /\ recipientCritSectionReleased' = "in_flight"
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, donorRangeDeletionTask,
                   recipientRangeDeletionTask, coordinatorDecision, donorDecision,
                   recipientClone, lastRPCFailure>>

\* Critical section release succeeds
CriticalSectionReleaseSucceeds ==
    /\ recipientCritSectionReleased = "in_flight"
    /\ criticalSectionActive' = FALSE
    /\ recipientCritSectionReleased' = "released"
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone, lastRPCFailure>>

\* Critical section release fails (Family 4 vulnerability)
CriticalSectionReleaseFails ==
    /\ recipientCritSectionReleased = "in_flight"
    /\ lastRPCFailure' = "ShardNotFound"
    /\ recipientCritSectionReleased' = "released"
    \* Critical section remains active (Family 4 bug: recipient stuck)
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, donorRangeDeletionTask,
                   recipientRangeDeletionTask, coordinatorDecision, donorDecision, recipientClone>>

----

\* Commit Path: Cleanup on Donor and Recipient
\* migration_coordinator.cpp:231-323 (Family 1 crash windows documented)

\* Delete donor range deletion task locally - migration_coordinator.cpp:347-350 (abort path)
DonorDeleteRangeDeletionTaskLocally ==
    /\ coordinatorDecision = "Commit"
    /\ donorRangeDeletionTask = "pending"
    /\ donorRangeDeletionTask' = "deleted"
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

\* Retrieve and register donor range deletion task - migration_coordinator.cpp:309-311
DonorRegisterRangeDeletionTask ==
    /\ coordinatorDecision = "Commit"
    /\ donorRangeDeletionTask = "pending"
    /\ configState = "Committed"
    /\ recipientCritSectionReleased = "released"
    /\ donorRangeDeletionTask' = "ready"
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

\* Delete recipient range deletion task - migration_coordinator.cpp:278-282
DonorDeleteRecipientRangeDeletionTask ==
    /\ coordinatorDecision = "Commit"
    /\ configState = "Committed"
    /\ recipientRangeDeletionTask = "pending"
    /\ recipientRangeDeletionTask' = "deleted"
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, donorRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

\* Mark donor range deletion as ready for processing - migration_coordinator.cpp:320-321
\* Crash window 3 (Family 1): task registered locally but not retrieved from recipient
DonorMarkRangeDeletionReady ==
    /\ coordinatorDecision = "Commit"
    /\ donorRangeDeletionTask = "ready"
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, donorRangeDeletionTask,
                   recipientRangeDeletionTask, coordinatorDecision, donorDecision,
                   recipientClone, recipientCritSectionReleased, lastRPCFailure>>

----

\* Abort Path: Non-atomic cleanup (Family 3, Family 5)
\* migration_coordinator.cpp:326-387

\* Abort: Delete donor range deletion task - migration_coordinator.cpp:347-350
AbortDeleteDonorRangeDeletionTask ==
    /\ coordinatorDecision = "Abort"
    /\ donorRangeDeletionTask = "pending"
    /\ donorRangeDeletionTask' = "deleted"
    \* Crash window 1 (Family 3): donor task deleted but recipient not yet notified
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

\* Abort: Bump txn number on recipient - migration_coordinator.cpp:361-364
AbortBumpRecipientTxnNumber ==
    /\ coordinatorDecision = "Abort"
    /\ donorRangeDeletionTask = "deleted"
    \* Crash window 2 (Family 3): txn bumped but task not marked ready
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, donorRangeDeletionTask,
                   recipientRangeDeletionTask, coordinatorDecision, donorDecision,
                   recipientClone, recipientCritSectionReleased, lastRPCFailure>>

\* Abort: Mark recipient range deletion ready - migration_coordinator.cpp:382-386
\* Can fail with ShardNotFound exception (Family 5: error handling)
AbortMarkRecipientRangeDeletionReady ==
    /\ coordinatorDecision = "Abort"
    /\ donorRangeDeletionTask = "deleted"
    /\ recipientRangeDeletionTask = "pending"
    /\ recipientRangeDeletionTask' = "ready"
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, donorRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

\* Abort: Notification to recipient fails (Family 5)
AbortRecipientNotificationFails ==
    /\ coordinatorDecision = "Abort"
    /\ donorRangeDeletionTask = "deleted"
    /\ recipientRangeDeletionTask = "pending"
    /\ lastRPCFailure' = "ShardNotFound"
    \* Recipient left in inconsistent state (Family 5 vulnerability)
    /\ UNCHANGED <<donorState, recipientState, configState, messages, donorMetadata,
                   recipientMetadata, criticalSectionActive, donorRangeDeletionTask,
                   recipientRangeDeletionTask, coordinatorDecision, donorDecision,
                   recipientClone, recipientCritSectionReleased>>

----

\* Coordinator Completion
\* migration_coordinator.cpp:183-229
\* Forgets migration after decision is delivered - lines 226-229
ForgetMigration ==
    /\ coordinatorDecision \in {"Commit", "Abort"}
    /\ donorState = "CommittingOnConfig"
    /\ donorState' = "Done"
    /\ UNCHANGED <<recipientState, configState, messages, donorMetadata, recipientMetadata,
                   criticalSectionActive, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

----

\* Cleanup after abort (abort path)
AbortCleanup ==
    /\ coordinatorDecision = "Abort"
    /\ recipientCritSectionReleased = "released"
    /\ recipientState' = "Done"
    /\ UNCHANGED <<donorState, configState, messages, donorMetadata, recipientMetadata,
                   criticalSectionActive, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

----

\* Crash and Recovery actions

\* Any node can crash and lose in-memory state but keep persistent state
DonorCrash ==
    /\ donorState \in {"CriticalSection", "CommittingOnConfig"}
    /\ donorState' = "Init"
    /\ UNCHANGED <<recipientState, configState, messages, donorMetadata, recipientMetadata,
                   criticalSectionActive, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

DonorRecover ==
    /\ donorState = "Init"
    /\ coordinatorDecision \in {"Commit", "Abort"}
    /\ donorState' = "CommittingOnConfig"
    /\ UNCHANGED <<recipientState, configState, messages, donorMetadata, recipientMetadata,
                   criticalSectionActive, donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

RecipientCrash ==
    /\ recipientState \in {"Cloning", "CriticalSection"}
    /\ recipientState' = "Init"
    /\ criticalSectionActive' = FALSE
    /\ UNCHANGED <<donorState, configState, messages, donorMetadata, recipientMetadata,
                   donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

RecipientRecover ==
    /\ recipientState = "Init"
    /\ recipientClone = "cloned"
    /\ recipientState' = "CriticalSection"
    /\ UNCHANGED <<donorState, configState, messages, donorMetadata, recipientMetadata,
                   donorRangeDeletionTask, recipientRangeDeletionTask,
                   coordinatorDecision, donorDecision, recipientClone,
                   recipientCritSectionReleased, lastRPCFailure>>

----

Next ==
    \/ RecipientStartClone
    \/ RecipientCloneComplete
    \/ DonorEnterCriticalSection
    \/ DonorPersistCommitDecision
    \/ DonorPersistAbortDecision
    \/ DonorSendConfigServerCommit
    \/ ConfigServerPersistCommit
    \/ ConfigServerCommitFails
    \/ LaunchReleaseRecipientCriticalSection
    \/ CriticalSectionReleaseSucceeds
    \/ CriticalSectionReleaseFails
    \/ DonorDeleteRangeDeletionTaskLocally
    \/ DonorRegisterRangeDeletionTask
    \/ DonorDeleteRecipientRangeDeletionTask
    \/ DonorMarkRangeDeletionReady
    \/ AbortDeleteDonorRangeDeletionTask
    \/ AbortBumpRecipientTxnNumber
    \/ AbortMarkRecipientRangeDeletionReady
    \/ AbortRecipientNotificationFails
    \/ ForgetMigration
    \/ AbortCleanup
    \/ DonorCrash
    \/ DonorRecover
    \/ RecipientCrash
    \/ RecipientRecover

----

\* INVARIANTS: Standard Safety Properties

\* Structural invariants
MCTypeOK ==
    /\ donorState \in DonorStates
    /\ recipientState \in RecipientStates
    /\ configState \in ConfigStates
    /\ donorMetadata \in MetadataOwned
    /\ recipientMetadata \in MetadataOwned
    /\ criticalSectionActive \in BOOLEAN
    /\ donorRangeDeletionTask \in TaskStates
    /\ recipientRangeDeletionTask \in TaskStates
    /\ coordinatorDecision \in Decisions
    /\ donorDecision \in Decisions
    /\ recipientClone \in {"not_cloned", "cloned"}
    /\ recipientCritSectionReleased \in ReleasedStates
    /\ lastRPCFailure \in {"none", "ShardNotFound", "Transient"}

\* Core Safety Properties

\* Family 2: ChunkOwnershipConsistency
\* At most one shard claims ownership of the chunk
ChunkOwnershipConsistency ==
    ~(donorMetadata = "owned" /\ recipientMetadata = "owned")

\* Family 1: DecisionDurabilityLeadsToCompletion
\* Once a decision is persisted, the migration must eventually complete consistently
DecisionDurabilityLeadsToCompletion ==
    coordinatorDecision = "Undecided" \/
    (coordinatorDecision = "Commit" =>
        (configState = "Committed" \/ configState = "Done")) \/
    (coordinatorDecision = "Abort" =>
        recipientState = "Done")

\* Family 3: RangeDeletionConsistency
\* Donor range deletion cannot be completed before recipient is ready
RangeDeletionConsistency ==
    (donorRangeDeletionTask = "ready" =>
        (recipientRangeDeletionTask \in {"ready", "completed", "deleted"} \/
         coordinatorDecision = "Undecided"))

\* Family 1: NoDoubleCommit
\* A migration cannot commit twice
NoDoubleCommit ==
    (coordinatorDecision = "Commit" =>
        configState \in {"Init", "Committed", "Done"})

\* Family 2: MetadataReflectsDecision
\* If commit is durable, metadata must reflect new ownership on at least one shard
MetadataReflectsDecision ==
    (configState = "Committed" =>
        recipientMetadata = "owned")

\* Family 4: CriticalSectionReleaseBeforeDone
\* Once migration is complete, critical section must be released
CriticalSectionReleaseBeforeDone ==
    (donorState = "Done" =>
        recipientCritSectionReleased = "released" \/ recipientState = "Init")

====
