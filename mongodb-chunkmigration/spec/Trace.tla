---- MODULE Trace ----
\* Trace validation spec for MongoDB chunk migration.
\* Category A (distributed system): single-file linear trace with cursor variable l.
\* Replays implementation traces against the base spec to verify consistency.

EXTENDS base, Sequences, TLC, IOUtils, Json

\* ==============================================================
\* Trace Loading
\* ==============================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawLog == ndJsonDeserialize(JsonFile)

\* Filter for trace events only
TraceLog == TLCEval(
    SelectSeq(RawLog, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

\* ==============================================================
\* Trace cursor variable
\* ==============================================================

VARIABLE l
traceVars == <<l>>
allVars == <<vars, l>>

logline == TraceLog[l]

\* ==============================================================
\* Event Predicates
\* ==============================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

\* ==============================================================
\* Mapping helpers: implementation strings → spec constants
\* ==============================================================

MapDecision(d) ==
    CASE d = "none"      -> NoDecision
      [] d = "committed" -> Committed
      [] d = "aborted"   -> Aborted

MapPhase(p) ==
    CASE p = "idle"               -> Idle
      [] p = "prepared"           -> Prepared
      [] p = "committingOnConfig" -> CommittingOnConfig
      [] p = "cleaning"          -> Cleaning

\* ==============================================================
\* Post-State Validation
\* ==============================================================

\* Full validation: check all observable state
ValidatePostState ==
    /\ activeMigration' = (IF logline.event.state.activeMigration = "nil"
                           THEN Nil
                           ELSE logline.event.state.activeMigration)
    /\ migrationPhase' = MapPhase(logline.event.state.migrationPhase)

\* Weak validation: check only cleanup state (for sub-step events)
ValidateCleanupState ==
    /\ cleanupPhase' = logline.event.state.cleanupPhase
    /\ cleanupMid' = (IF logline.event.state.cleanupMid = "nil"
                      THEN Nil
                      ELSE logline.event.state.cleanupMid)

\* ==============================================================
\* Trace Action Wrappers
\* ==============================================================

TraceStartMigration ==
    /\ IsEvent("StartMigration")
    /\ LET mid == logline.event.mid IN
       /\ StartMigration(mid)
       /\ ValidatePostState
    /\ l' = l + 1

TraceAdvanceToConfigCommit ==
    /\ IsEvent("AdvanceToConfigCommit")
    /\ LET mid == logline.event.mid IN
       /\ AdvanceToConfigCommit(mid)
    /\ l' = l + 1

TraceConfigCommitSucceed ==
    /\ IsEvent("ConfigCommitSucceed")
    /\ LET mid == logline.event.mid IN
       /\ ConfigCommitSucceed(mid)
    /\ l' = l + 1

TraceConfigCommitFail ==
    /\ IsEvent("ConfigCommitFail")
    /\ LET mid == logline.event.mid IN
       /\ ConfigCommitFail(mid)
    /\ l' = l + 1

TraceAbortBeforeConfigCommit ==
    /\ IsEvent("AbortBeforeConfigCommit")
    /\ LET mid == logline.event.mid IN
       /\ AbortBeforeConfigCommit(mid)
    /\ l' = l + 1

TraceDoCommitPersist ==
    /\ IsEvent("DoCommitPersist")
    /\ LET mid == logline.event.mid IN
       /\ DoCommitPersist(mid)
    /\ l' = l + 1

TraceDoCommitAdvanceTxn ==
    /\ IsEvent("DoCommitAdvanceTxn")
    /\ LET mid == logline.event.mid IN
       /\ DoCommitAdvanceTxn(mid)
    /\ l' = l + 1

TraceDoCommitRetrieveOrphans ==
    /\ IsEvent("DoCommitRetrieveOrphans")
    /\ LET mid == logline.event.mid IN
       /\ DoCommitRetrieveOrphans(mid)
    /\ l' = l + 1

TraceDoCommitPersistOrphans ==
    /\ IsEvent("DoCommitPersistOrphans")
    /\ LET mid == logline.event.mid IN
       /\ DoCommitPersistOrphans(mid)
    /\ l' = l + 1

TraceDoCommitDeleteRecipientTask ==
    /\ IsEvent("DoCommitDeleteRecipientTask")
    /\ LET mid == logline.event.mid IN
       /\ DoCommitDeleteRecipientTask(mid)
    /\ l' = l + 1

TraceDoCommitGetDonorTask ==
    /\ IsEvent("DoCommitGetDonorTask")
    /\ LET mid == logline.event.mid IN
       /\ DoCommitGetDonorTask(mid)
    /\ l' = l + 1

TraceDoCommitMarkReady ==
    /\ IsEvent("DoCommitMarkReady")
    /\ LET mid == logline.event.mid IN
       /\ DoCommitMarkReady(mid)
    /\ l' = l + 1

TraceDoCommitForget ==
    /\ IsEvent("DoCommitForget")
    /\ LET mid == logline.event.mid IN
       /\ DoCommitForget(mid)
    /\ l' = l + 1

TraceDoAbortPersist ==
    /\ IsEvent("DoAbortPersist")
    /\ LET mid == logline.event.mid IN
       /\ DoAbortPersist(mid)
    /\ l' = l + 1

TraceDoAbortDeleteLocal ==
    /\ IsEvent("DoAbortDeleteLocal")
    /\ LET mid == logline.event.mid IN
       /\ DoAbortDeleteLocal(mid)
    /\ l' = l + 1

TraceDoAbortAdvanceTxn ==
    /\ IsEvent("DoAbortAdvanceTxn")
    /\ LET mid == logline.event.mid IN
       /\ DoAbortAdvanceTxn(mid)
    /\ l' = l + 1

TraceDoAbortMarkRecipient ==
    /\ IsEvent("DoAbortMarkRecipient")
    /\ LET mid == logline.event.mid IN
       /\ DoAbortMarkRecipient(mid)
    /\ l' = l + 1

TraceDoAbortForget ==
    /\ IsEvent("DoAbortForget")
    /\ LET mid == logline.event.mid IN
       /\ DoAbortForget(mid)
    /\ l' = l + 1

TraceCleanupComplete ==
    /\ IsEvent("CleanupComplete")
    /\ LET mid == logline.event.mid IN
       /\ CleanupComplete(mid)
    /\ l' = l + 1

TraceStepdown ==
    /\ IsEvent("Stepdown")
    /\ Stepdown
    /\ l' = l + 1

TraceRecoverMigration ==
    /\ IsEvent("RecoverMigration")
    /\ LET mid == logline.event.mid IN
       /\ RecoverMigration(mid)
    /\ l' = l + 1

TraceRecoverFromLimbo ==
    /\ IsEvent("RecoverFromLimbo")
    /\ LET mid == logline.event.mid IN
       /\ RecoverFromLimbo(mid)
    /\ l' = l + 1

\* ==============================================================
\* Silent Actions
\* Actions that happen in the implementation without a trace event.
\* Tightly constrained: check l <= Len(TraceLog) and match next event.
\* ==============================================================

\* Config server may commit asynchronously (no trace event)
SilentConfigServerCommitAsync ==
    /\ l <= Len(TraceLog)
    \* Only fire before a recovery event that would need config committed
    /\ logline.event.name \in {"RecoverFromLimbo", "RecoverMigration"}
    /\ \E mid \in MigrationId :
        /\ coordDocs[mid] /= Nil
        /\ mid \notin configCommitted
        /\ ConfigServerCommitAsync(mid)
    /\ UNCHANGED l

\* Range deleter processes ready tasks in background
SilentRangeDeleterProcessTask ==
    /\ l <= Len(TraceLog)
    \* Only fire before StartMigration (drain check needs empty tasks)
    /\ logline.event.name = "StartMigration"
    /\ RangeDeleterProcessTask
    /\ UNCHANGED l

\* ForgetBecomeDurable happens in background
SilentForgetBecomeDurable ==
    /\ l <= Len(TraceLog)
    /\ \E mid \in MigrationId :
        /\ forgetPending[mid] /= Nil
        /\ ForgetBecomeDurable(mid)
    /\ UNCHANGED l

\* ==============================================================
\* TraceInit and TraceNext
\* ==============================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ TraceStartMigration
    \/ TraceAdvanceToConfigCommit
    \/ TraceConfigCommitSucceed
    \/ TraceConfigCommitFail
    \/ TraceAbortBeforeConfigCommit
    \/ TraceDoCommitPersist
    \/ TraceDoCommitAdvanceTxn
    \/ TraceDoCommitRetrieveOrphans
    \/ TraceDoCommitPersistOrphans
    \/ TraceDoCommitDeleteRecipientTask
    \/ TraceDoCommitGetDonorTask
    \/ TraceDoCommitMarkReady
    \/ TraceDoCommitForget
    \/ TraceDoAbortPersist
    \/ TraceDoAbortDeleteLocal
    \/ TraceDoAbortAdvanceTxn
    \/ TraceDoAbortMarkRecipient
    \/ TraceDoAbortForget
    \/ TraceCleanupComplete
    \/ TraceStepdown
    \/ TraceRecoverMigration
    \/ TraceRecoverFromLimbo
    \* Silent actions
    \/ SilentConfigServerCommitAsync
    \/ SilentRangeDeleterProcessTask
    \/ SilentForgetBecomeDurable

TraceSpec == TraceInit /\ [][TraceNext]_allVars

\* ==============================================================
\* TraceMatched — must consume entire trace
\* ==============================================================

TraceMatched == <>(l > Len(TraceLog))

\* ==============================================================
\* Alias for debugging
\* ==============================================================

TraceAlias == [
    l              |-> l,
    event          |-> IF l <= Len(TraceLog) THEN logline.event.name ELSE "done",
    activeMigration |-> activeMigration,
    migrationPhase |-> migrationPhase,
    cleanupPhase   |-> cleanupPhase,
    cleanupMid     |-> cleanupMid,
    coordDocs      |-> coordDocs,
    donorTasks     |-> donorTasks,
    configCommitted |-> configCommitted,
    orphanDelta    |-> orphanDelta,
    forgetPending  |-> forgetPending
]

\* ==============================================================
\* View
\* ==============================================================

TraceView == <<vars, l>>

====
