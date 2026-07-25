---- MODULE base ----
(***************************************************************************)
(* MongoDB RangeDeletionsSecondaryNodes — Range Preserver on Secondaries   *)
(*                                                                         *)
(* Models the range deletion mechanism on secondary nodes with query        *)
(* protection via RangePreserver invalidation. Extends the existing         *)
(* MongoDB spec (187 lines, single query/single deletion) to cover:        *)
(*   - Family 1: Version comparison mismatch in invalidation (HIGH)        *)
(*   - Family 2: Recovery without re-invalidation after step-up (HIGH)     *)
(*   - Family 3: Feature flag gating disables safety (MEDIUM)              *)
(*   - Family 4: Multiple concurrent queries + range deletions (MEDIUM)    *)
(*   - Family 5: Oplog batch atomicity and ordering (LOW)                  *)
(*                                                                         *)
(* Key deviation from existing spec: models multiple metadata trackers     *)
(* with divergent collPlacementVersion vs shardPlacementVersion orderings, *)
(* the early-break optimization in invalidateRangePreservers, node role    *)
(* transitions with recovery, and feature flag gating of the kill check.   *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, Sequences, TLC

(*====================================================================*)
(* Constants                                                           *)
(*====================================================================*)

CONSTANTS
    Query,              \* Set of query identifiers
    RangeDeletion,      \* Set of range deletion identifiers
    NumTrackers,        \* Number of metadata trackers (ordered by collPlacementVersion)
    Doc,                \* Set of document identifiers
    MaxVersion,         \* Maximum shard placement version number
    FeatureEnabled,     \* BOOLEAN — gTerminateSecondaryReadsUponRangeDeletion
                        \* shard_role.cpp:1943-1951
    RDDocs              \* [RangeDeletion -> SUBSET Doc] docs each RD removes

\* Tracker indices: 1 = oldest collPlacementVersion, NumTrackers = newest
\* The _metadata list is sorted by collPlacementVersion (metadata_manager.cpp:203-217)
Tracker == 1..NumTrackers

(*====================================================================*)
(* Variables                                                           *)
(*====================================================================*)

VARIABLES
    \* --- Node state (Family 2: Recovery Without Re-Invalidation) ---
    nodeRole,           \* "SECONDARY" or "PRIMARY"
                        \* range_deleter_service.cpp:127-133 (onStepUpBegin)

    \* --- Metadata tracker state (Family 1: Version Comparison Mismatch) ---
    trackerShardV,      \* [Tracker -> 0..MaxVersion] shardPlacementVersion per tracker
                        \*   0 = unset placement version ({0,0}), shard lost all chunks
                        \*   Frozen in Init — represents metadata snapshots at different times
                        \*   metadata_manager.cpp:287
    trackerValid,       \* [Tracker -> BOOLEAN] validity of each tracker's RangePreserver
                        \*   metadata_manager.cpp:289

    \* --- Range deletion state ---
    signalState,        \* [RangeDeletion -> {"INIT", "UPDATED", "COMMITTED"}]
                        \*   Models processing=true update in oplog
                        \*   range_deleter_service_op_observer.cpp:164-168
    deleteState,        \* [RangeDeletion -> {"INIT", "UPDATED", "COMMITTED"}]
                        \*   Models actual range delete op in oplog
    batchState,         \* [RangeDeletion -> {"ONGOING", "COMMITTED"}]
                        \*   Oplog batch state for each RD's signal+delete pair
    rdRecovered,        \* [RangeDeletion -> BOOLEAN] whether processed via recovery
                        \*   TRUE when registered via recovery path (line 229)
    rdPreMigShardV,     \* [RangeDeletion -> 1..MaxVersion] preMigrationShardVersion
                        \*   Frozen in Init — the version threshold for invalidation
                        \*   range_deleter_service_op_observer.cpp:106

    \* --- Query state (Family 3: Feature Flag, Family 4: Concurrency) ---
    queryState,         \* [Query -> {"RESTORE_START", "SNAPSHOT_ADVANCED", "DONE_OK", "KILLED"}]
                        \*   shard_role.cpp:1973
    queryTracker,       \* [Query -> Tracker] which metadata tracker this query holds
                        \*   Frozen in Init — assigned when query obtains RangePreserver
                        \*   metadata_manager.cpp:124-158 (getActiveMetadata)
    querySnapshot,      \* [Query -> SUBSET Doc] docs seen by this query's snapshot

    \* --- Collection state ---
    lastAppliedSnapshot \* SUBSET Doc — docs visible at current applied oplog timestamp

vars == <<nodeRole, trackerShardV, trackerValid, signalState, deleteState,
          batchState, rdRecovered, rdPreMigShardV, queryState, queryTracker,
          querySnapshot, lastAppliedSnapshot>>

(*====================================================================*)
(* Helpers: Version Comparison                                         *)
(* Models ChunkVersion::operator<=> (chunk_version.h:222-245)          *)
(*====================================================================*)

\* Returns "less", "equal", "greater", or "unordered"
\* 0 represents unset placement version ({0,0})
\* chunk_version.h:237-239: same-collection unset → unordered
\* chunk_version.h:242-245: compare by timestamp, then major, then minor
CompareVersion(v1, v2) ==
    IF v1 = 0 \/ v2 = 0 THEN "unordered"   \* chunk_version.h:237-239
    ELSE IF v1 < v2 THEN "less"              \* chunk_version.h:242
    ELSE IF v1 = v2 THEN "equal"             \* chunk_version.h:245
    ELSE "greater"                            \* chunk_version.h:243

\* Default: each range deletion removes all documents (conservative)
DefaultRDDocs == [rd \in RangeDeletion |-> Doc]

(*====================================================================*)
(* Helpers: Invalidation Loop                                          *)
(* Models MetadataManager::invalidateRangePreserversOlderThanShardVersion *)
(* metadata_manager.cpp:273-295                                        *)
(*====================================================================*)

\* The loop iterates _metadata in collPlacementVersion order (ascending tracker index).
\* For each tracker, it compares shardPlacementVersion to preMigShardVersion:
\*   - not greater (less/equal/unordered) → invalidate (line 289)
\*   - greater → break (line 291)
\*
\* BUG FAMILY 1: _metadata is sorted by collPlacementVersion (line 203-217)
\* but comparison uses shardPlacementVersion (line 287). These orderings can
\* diverge when a shard gains/loses chunks. The early-break on line 291 can
\* skip trackers that should have been invalidated.

\* Find first tracker in collVersion order where shardV is "greater"
\* This is where the loop breaks (metadata_manager.cpp:291: else { break; })
BreakIndex(preMigV) ==
    LET greaterSet == {t \in Tracker :
            CompareVersion(trackerShardV[t], preMigV) = "greater"}
    IN IF greaterSet = {}
       THEN NumTrackers + 1   \* No break — all trackers checked
       ELSE CHOOSE t \in greaterSet :
                \A t2 \in greaterSet : t <= t2  \* Minimum index

\* Trackers invalidated by the loop: all indices before break point
\* metadata_manager.cpp:285-289: loop body sets valid=false
\* metadata_manager.cpp:291: break exits loop, remaining trackers unchecked
InvalidatedTrackers(preMigV) ==
    {t \in Tracker : t < BreakIndex(preMigV)}

\* Compute new trackerValid after running the invalidation loop
DoInvalidate(preMigV) ==
    LET inv == InvalidatedTrackers(preMigV)
    IN [t \in Tracker |->
           IF t \in inv THEN FALSE
           ELSE trackerValid[t]]

(*====================================================================*)
(* Init                                                                *)
(*====================================================================*)

Init ==
    \* Node starts as SECONDARY (typical for range deletion secondary spec)
    /\ nodeRole = "SECONDARY"
    \* Non-deterministic tracker shardPlacementVersions — key for Family 1
    \* Index order represents collPlacementVersion order (1=oldest, N=newest)
    \* shardPlacementVersions may NOT follow the same order — this is the bug
    /\ trackerShardV \in [Tracker -> 0..MaxVersion]
    /\ trackerValid = [t \in Tracker |-> TRUE]
    \* Range deletions start in INIT state (not yet processed via oplog)
    /\ signalState = [rd \in RangeDeletion |-> "INIT"]
    /\ deleteState = [rd \in RangeDeletion |-> "INIT"]
    /\ batchState = [rd \in RangeDeletion |-> "ONGOING"]
    /\ rdRecovered = [rd \in RangeDeletion |-> FALSE]
    \* Non-deterministic preMigShardVersion per RD — key for Family 1, 4
    /\ rdPreMigShardV \in [RangeDeletion -> 1..MaxVersion]
    \* Queries start at RESTORE_START with pre-assigned trackers
    \* Non-deterministic tracker assignment models different query start times
    /\ queryState = [q \in Query |-> "RESTORE_START"]
    /\ queryTracker \in [Query -> Tracker]
    /\ querySnapshot = [q \in Query |-> {}]
    \* All docs initially visible
    /\ lastAppliedSnapshot = Doc

(*====================================================================*)
(* Actions: Oplog Application (Secondary Flow)                         *)
(*====================================================================*)

\* --- OpApplierSignalUpdate(rd) ---
\* Oplog applier processes the processing=true update to config.rangeDeletions.
\* Triggers invalidateRangePreservers with the RD's preMigrationShardVersion.
\* range_deleter_service_op_observer.cpp:164-168 (trigger)
\* → collection_sharding_runtime.cpp:221-242 (UUID check + routing)
\* → metadata_manager.cpp:273-295 (invalidation loop with early-break)
OpApplierSignalUpdate(rd) ==
    /\ signalState[rd] = "INIT"
    /\ signalState' = [signalState EXCEPT ![rd] = "UPDATED"]
    \* Invalidate trackers using the early-break loop (Family 1 mechanism)
    /\ trackerValid' = DoInvalidate(rdPreMigShardV[rd])
    /\ UNCHANGED <<nodeRole, trackerShardV, deleteState, batchState, rdRecovered,
                    rdPreMigShardV, queryState, queryTracker, querySnapshot,
                    lastAppliedSnapshot>>

\* --- OpApplierSignalCommit(rd) ---
\* Signal op applier reaches COMMITTED state.
OpApplierSignalCommit(rd) ==
    /\ signalState[rd] = "UPDATED"
    /\ signalState' = [signalState EXCEPT ![rd] = "COMMITTED"]
    /\ UNCHANGED <<nodeRole, trackerShardV, trackerValid, deleteState, batchState,
                    rdRecovered, rdPreMigShardV, queryState, queryTracker,
                    querySnapshot, lastAppliedSnapshot>>

\* --- OpApplierDeleteUpdate(rd) ---
\* Oplog applier processes the actual range delete operation.
\* No special action beyond state transition.
OpApplierDeleteUpdate(rd) ==
    /\ deleteState[rd] = "INIT"
    /\ deleteState' = [deleteState EXCEPT ![rd] = "UPDATED"]
    /\ UNCHANGED <<nodeRole, trackerShardV, trackerValid, signalState, batchState,
                    rdRecovered, rdPreMigShardV, queryState, queryTracker,
                    querySnapshot, lastAppliedSnapshot>>

\* --- OpApplierDeleteCommit(rd) ---
\* Delete op applier reaches COMMITTED state.
OpApplierDeleteCommit(rd) ==
    /\ deleteState[rd] = "UPDATED"
    /\ deleteState' = [deleteState EXCEPT ![rd] = "COMMITTED"]
    /\ UNCHANGED <<nodeRole, trackerShardV, trackerValid, signalState, batchState,
                    rdRecovered, rdPreMigShardV, queryState, queryTracker,
                    querySnapshot, lastAppliedSnapshot>>

\* --- BatchCommitted(rd) ---
\* Once both ops (signal + delete) for an RD are committed, the batch commits.
\* The range deletion becomes visible: docs removed from lastAppliedSnapshot.
\* On secondary: oplog batch commit advances applied timestamp.
\* On primary (after recovery): range deleter service completes deletion.
\* Family 5: models the worst case where signal + delete are in the same batch.
BatchCommitted(rd) ==
    /\ batchState[rd] = "ONGOING"
    /\ signalState[rd] = "COMMITTED"
    /\ deleteState[rd] = "COMMITTED"
    /\ batchState' = [batchState EXCEPT ![rd] = "COMMITTED"]
    /\ lastAppliedSnapshot' = lastAppliedSnapshot \ RDDocs[rd]
    /\ UNCHANGED <<nodeRole, trackerShardV, trackerValid, signalState, deleteState,
                    rdRecovered, rdPreMigShardV, queryState, queryTracker,
                    querySnapshot>>

(*====================================================================*)
(* Actions: Query Execution                                            *)
(*====================================================================*)

\* --- QueryAdvanceSnapshot(q) ---
\* Query advances its storage snapshot at the yield point (restore).
\* Takes a snapshot of the current lastAppliedSnapshot.
\* shard_role.cpp:1973-1979
QueryAdvanceSnapshot(q) ==
    /\ queryState[q] = "RESTORE_START"
    /\ queryState' = [queryState EXCEPT ![q] = "SNAPSHOT_ADVANCED"]
    /\ querySnapshot' = [querySnapshot EXCEPT ![q] = lastAppliedSnapshot]
    /\ UNCHANGED <<nodeRole, trackerShardV, trackerValid, signalState, deleteState,
                    batchState, rdRecovered, rdPreMigShardV, queryTracker,
                    lastAppliedSnapshot>>

\* --- QueryKilled(q) ---
\* Query killed because its RangePreserver (tracker) has been invalidated.
\* Requires feature flag enabled (Family 3 gate).
\* shard_role.cpp:1943-1965 (checkOrphanRangePreserverIsStillValid lambda)
\*   - feature_flags::gTerminateSecondaryReadsUponRangeDeletion (line 1945)
\*   - terminateSecondaryReadsOnOrphanCleanup.load() (line 1947)
\*   - !ownershipFilter->isRangePreserverStillValid() (line 1959)
QueryKilled(q) ==
    /\ queryState[q] = "SNAPSHOT_ADVANCED"
    /\ trackerValid[queryTracker[q]] = FALSE    \* shard_role.cpp:1959
    /\ FeatureEnabled = TRUE                    \* shard_role.cpp:1943-1951
    /\ queryState' = [queryState EXCEPT ![q] = "KILLED"]
    /\ UNCHANGED <<nodeRole, trackerShardV, trackerValid, signalState, deleteState,
                    batchState, rdRecovered, rdPreMigShardV, queryTracker,
                    querySnapshot, lastAppliedSnapshot>>

\* --- QueryProceed(q) ---
\* Query proceeds if RangePreserver is still valid, or if feature flag is disabled.
\* Family 3: when FeatureEnabled=FALSE, query bypasses the kill check entirely.
\* shard_role.cpp:1973 (control passes checkOrphanRangePreserverIsStillValid)
QueryProceed(q) ==
    /\ queryState[q] = "SNAPSHOT_ADVANCED"
    /\ \/ trackerValid[queryTracker[q]] = TRUE  \* Tracker still valid — safe
       \/ FeatureEnabled = FALSE                \* Feature disabled — kill bypassed (Family 3)
    /\ queryState' = [queryState EXCEPT ![q] = "DONE_OK"]
    /\ UNCHANGED <<nodeRole, trackerShardV, trackerValid, signalState, deleteState,
                    batchState, rdRecovered, rdPreMigShardV, queryTracker,
                    querySnapshot, lastAppliedSnapshot>>

(*====================================================================*)
(* Actions: Step-Up and Recovery (Family 2)                            *)
(*====================================================================*)

\* --- StepUp ---
\* Secondary transitions to primary.
\* range_deleter_service.cpp:127-133 (onStepUpBegin)
\* range_deleter_service.cpp:135-180 (onStepUpComplete)
StepUp ==
    /\ nodeRole = "SECONDARY"
    /\ nodeRole' = "PRIMARY"
    /\ UNCHANGED <<trackerShardV, trackerValid, signalState, deleteState, batchState,
                    rdRecovered, rdPreMigShardV, queryState, queryTracker,
                    querySnapshot, lastAppliedSnapshot>>

\* --- RecoverTask(rd) ---
\* Recovery re-registers a range deletion task after step-up.
\* range_deleter_service.cpp:220-231 (_launchRangeDeletionRecoveryTask)
\*
\* FAMILY 2 BUG: Recovery calls registerTask with SemiFuture::makeReady() (line 229),
\* bypassing the query drain wait. More critically, recovery does NOT call
\* invalidateRangePreservers — that only happens from the op observer
\* (range_deleter_service_op_observer.cpp:164-168) when processing=true is SET,
\* not when the task is already marked processing=true in the database.
\*
\* Historical: SERVER-67385 (P2 Critical) — same class of bug on primary side.
RecoverTask(rd) ==
    /\ nodeRole = "PRIMARY"                     \* Must be primary (after step-up)
    /\ signalState[rd] = "INIT"                 \* Signal was never applied on this node
    \* Recovery marks signal and delete as effectively done
    \* (task already has processing=true in DB, no oplog application needed)
    /\ signalState' = [signalState EXCEPT ![rd] = "COMMITTED"]
    /\ deleteState' = [deleteState EXCEPT ![rd] = "COMMITTED"]
    /\ rdRecovered' = [rdRecovered EXCEPT ![rd] = TRUE]
    \* CRITICAL: NO invalidation of trackers — the op observer doesn't fire
    \* because there's no UPDATE to processing field (it's already true)
    /\ UNCHANGED <<nodeRole, trackerShardV, trackerValid, batchState,
                    rdPreMigShardV, queryState, queryTracker, querySnapshot,
                    lastAppliedSnapshot>>

(*====================================================================*)
(* Terminal state                                                      *)
(*====================================================================*)

\* Allow stuttering when all work is complete (prevents false deadlock reports)
Terminating ==
    /\ \A q \in Query : queryState[q] \in {"DONE_OK", "KILLED"}
    /\ \A rd \in RangeDeletion : batchState[rd] = "COMMITTED"
    /\ UNCHANGED vars

(*====================================================================*)
(* Specification                                                       *)
(*====================================================================*)

Next ==
    \/ \E rd \in RangeDeletion :
        \/ OpApplierSignalUpdate(rd)
        \/ OpApplierSignalCommit(rd)
        \/ OpApplierDeleteUpdate(rd)
        \/ OpApplierDeleteCommit(rd)
        \/ BatchCommitted(rd)
        \/ RecoverTask(rd)
    \/ \E q \in Query :
        \/ QueryAdvanceSnapshot(q)
        \/ QueryKilled(q)
        \/ QueryProceed(q)
    \/ StepUp
    \/ Terminating

Spec == Init /\ [][Next]_vars

(*====================================================================*)
(* Invariants                                                          *)
(*====================================================================*)

TypeOK ==
    /\ nodeRole \in {"SECONDARY", "PRIMARY"}
    /\ trackerShardV \in [Tracker -> 0..MaxVersion]
    /\ trackerValid \in [Tracker -> BOOLEAN]
    /\ signalState \in [RangeDeletion -> {"INIT", "UPDATED", "COMMITTED"}]
    /\ deleteState \in [RangeDeletion -> {"INIT", "UPDATED", "COMMITTED"}]
    /\ batchState \in [RangeDeletion -> {"ONGOING", "COMMITTED"}]
    /\ rdRecovered \in [RangeDeletion -> BOOLEAN]
    /\ rdPreMigShardV \in [RangeDeletion -> 1..MaxVersion]
    /\ queryState \in [Query -> {"RESTORE_START", "SNAPSHOT_ADVANCED",
                                  "DONE_OK", "KILLED"}]
    /\ queryTracker \in [Query -> Tracker]
    /\ \A q \in Query : querySnapshot[q] \subseteq Doc
    /\ lastAppliedSnapshot \subseteq Doc

\* --- QueryShouldReadAllDocs (Families 1, 2, 3, 4) ---
\* If a query reaches DONE_OK and is missing docs from a committed range deletion,
\* its tracker must have shardVersion "greater" than the RD's preMigShardVersion.
\* A tracker with shardV > preMigShardV has post-migration metadata and would use
\* the shard filter to exclude orphans — so missing docs are expected.
\* A tracker with shardV <= preMigShardV has pre-migration metadata — the query
\* should have been killed (tracker should have been invalidated).
\*
\* Violations indicate:
\*   - Family 1: early-break skipped a tracker that should have been invalidated
\*   - Family 2: recovery didn't invalidate any trackers
\*   - Family 3: feature flag disabled, kill check bypassed
\*   - Family 4: cross-invalidation between concurrent queries/deletions
QueryShouldReadAllDocs ==
    \A q \in Query :
        queryState[q] = "DONE_OK" =>
            \A rd \in RangeDeletion :
                (batchState[rd] = "COMMITTED" /\
                 ~(RDDocs[rd] \subseteq querySnapshot[q])) =>
                    CompareVersion(trackerShardV[queryTracker[q]],
                                   rdPreMigShardV[rd]) = "greater"

\* --- InvalidationBeforeVisibility (Families 1, 2) ---
\* After a batch commits, all trackers with shardVersion not-greater-than
\* preMigShardVersion should have been invalidated. Violations indicate the
\* invalidation loop is broken (Family 1: early-break bug) or was never
\* called (Family 2: recovery path).
InvalidationBeforeVisibility ==
    \A rd \in RangeDeletion :
        batchState[rd] = "COMMITTED" =>
            \A t \in Tracker :
                CompareVersion(trackerShardV[t], rdPreMigShardV[rd]) /= "greater" =>
                    trackerValid[t] = FALSE

(*====================================================================*)
(* Liveness                                                            *)
(*====================================================================*)

Fairness ==
    /\ \A q \in Query : WF_vars(QueryAdvanceSnapshot(q))
    /\ \A q \in Query : WF_vars(QueryKilled(q))
    /\ \A q \in Query : WF_vars(QueryProceed(q))
    /\ \A rd \in RangeDeletion : WF_vars(OpApplierSignalUpdate(rd))
    /\ \A rd \in RangeDeletion : WF_vars(OpApplierSignalCommit(rd))
    /\ \A rd \in RangeDeletion : WF_vars(OpApplierDeleteUpdate(rd))
    /\ \A rd \in RangeDeletion : WF_vars(OpApplierDeleteCommit(rd))
    /\ \A rd \in RangeDeletion : WF_vars(BatchCommitted(rd))

LiveSpec == Init /\ [][Next]_vars /\ Fairness

Termination ==
    /\ <>(\A q \in Query : queryState[q] \in {"DONE_OK", "KILLED"})
    /\ <>(\A rd \in RangeDeletion : batchState[rd] = "COMMITTED")

====
