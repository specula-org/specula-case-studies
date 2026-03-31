---- MODULE Trace ----
\* Trace validation spec for MongoDB MoveRange commit protocol.
\* Replays NDJSON traces against the base spec to verify consistency.

EXTENDS base, Json, IOUtils, Sequences, TLC

\*---------------------------------------------------------------------------
\* Trace loading
\*---------------------------------------------------------------------------
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTraceLog == ndJsonDeserialize(JsonFile)

\* Filter to only migration-related events
TraceLog == SelectSeq(RawTraceLog,
    LAMBDA x : "event" \in DOMAIN x)

\*---------------------------------------------------------------------------
\* Cursor variable
\*---------------------------------------------------------------------------
VARIABLE l  \* Trace cursor: index into TraceLog

traceVars == <<migState, migDonor, migRecipient, coordDoc, rangeDel,
               configOwner, shardData, isPrimary, donorCritSec, recipientCritSec, l>>

\*---------------------------------------------------------------------------
\* Event helpers
\*---------------------------------------------------------------------------
logline == TraceLog[l]

IsEvent(name) == logline.event = name

\* Map shard/key names from trace — identity since cfg uses strings
MapShard(name) == name
MapKey(name) == name

\*---------------------------------------------------------------------------
\* Post-state validation
\*---------------------------------------------------------------------------

\* Strong validation: check full migration state
ValidatePostState(key) ==
    /\ IF "migState" \in DOMAIN logline
       THEN migState'[key] = logline.migState
       ELSE TRUE
    /\ IF "configOwner" \in DOMAIN logline
       THEN configOwner'[key] = MapShard(logline.configOwner)
       ELSE TRUE

\* Weak validation: check only what trace records
ValidatePostStateWeak == TRUE

\*---------------------------------------------------------------------------
\* Trace action wrappers
\*---------------------------------------------------------------------------

TraceStartMigration ==
    /\ IsEvent("StartMigration")
    /\ LET donor == MapShard(logline.donor)
           recipient == MapShard(logline.recipient)
           key == MapKey(logline.key) IN
        /\ StartMigration(donor, recipient, key)
        /\ ValidatePostState(key)
    /\ l' = l + 1

TraceRecipientEnterCriticalSection ==
    /\ IsEvent("RecipientEnterCriticalSection")
    /\ LET shard == MapShard(logline.shard)
           key == MapKey(logline.key) IN
        /\ RecipientEnterCriticalSection(shard, key)
    /\ l' = l + 1

TraceDonorEnterCriticalSection ==
    /\ IsEvent("DonorEnterCriticalSection")
    /\ LET shard == MapShard(logline.shard)
           key == MapKey(logline.key) IN
        /\ DonorEnterCriticalSection(shard, key)
    /\ l' = l + 1

TraceCommitOnConfigServer ==
    /\ IsEvent("CommitOnConfigServer")
    /\ LET key == MapKey(logline.key) IN
        /\ CommitOnConfigServer(key)
    /\ l' = l + 1

TracePersistCommitDecision ==
    /\ IsEvent("PersistCommitDecision")
    /\ LET donor == MapShard(logline.shard) IN
        /\ PersistCommitDecision(donor)
    /\ l' = l + 1

TraceCommitReleaseCritSec ==
    /\ IsEvent("CommitReleaseCritSec")
    /\ LET donor == MapShard(logline.shard) IN
        /\ CommitReleaseCritSec(donor)
    /\ l' = l + 1

TraceCommitBumpRecipientTxn ==
    /\ IsEvent("CommitBumpRecipientTxn")
    /\ LET donor == MapShard(logline.shard) IN
        /\ CommitBumpRecipientTxn(donor)
    /\ l' = l + 1

TraceCommitDeleteRecipientRangeDel ==
    /\ IsEvent("CommitDeleteRecipientRangeDel")
    /\ LET donor == MapShard(logline.shard) IN
        /\ CommitDeleteRecipientRangeDel(donor)
    /\ l' = l + 1

TraceCommitMarkDonorRangeDelReady ==
    /\ IsEvent("CommitMarkDonorRangeDelReady")
    /\ LET donor == MapShard(logline.shard) IN
        /\ CommitMarkDonorRangeDelReady(donor)
    /\ l' = l + 1

TraceCommitForgetMigration ==
    /\ IsEvent("CommitForgetMigration")
    /\ LET donor == MapShard(logline.shard) IN
        /\ CommitForgetMigration(donor)
    /\ l' = l + 1

TraceDecideAbort ==
    /\ IsEvent("DecideAbort")
    /\ LET key == MapKey(logline.key) IN
        /\ DecideAbort(key)
    /\ l' = l + 1

TraceAbortPersistDecision ==
    /\ IsEvent("AbortPersistDecision")
    /\ LET donor == MapShard(logline.shard) IN
        /\ AbortPersistDecision(donor)
    /\ l' = l + 1

TraceAbortReleaseCritSec ==
    /\ IsEvent("AbortReleaseCritSec")
    /\ LET donor == MapShard(logline.shard) IN
        /\ AbortReleaseCritSec(donor)
    /\ l' = l + 1

TraceAbortDeleteDonorRangeDel ==
    /\ IsEvent("AbortDeleteDonorRangeDel")
    /\ LET donor == MapShard(logline.shard) IN
        /\ AbortDeleteDonorRangeDel(donor)
    /\ l' = l + 1

TraceAbortBumpRecipientTxn ==
    /\ IsEvent("AbortBumpRecipientTxn")
    /\ LET donor == MapShard(logline.shard) IN
        /\ AbortBumpRecipientTxn(donor)
    /\ l' = l + 1

TraceAbortMarkRecipientRangeDelReady ==
    /\ IsEvent("AbortMarkRecipientRangeDelReady")
    /\ LET donor == MapShard(logline.shard) IN
        /\ AbortMarkRecipientRangeDelReady(donor)
    /\ l' = l + 1

TraceAbortForgetMigration ==
    /\ IsEvent("AbortForgetMigration")
    /\ LET donor == MapShard(logline.shard) IN
        /\ AbortForgetMigration(donor)
    /\ l' = l + 1

TraceStepdown ==
    /\ IsEvent("Stepdown")
    /\ LET shard == MapShard(logline.shard) IN
        /\ Stepdown(shard)
    /\ l' = l + 1

TraceStepUp ==
    /\ IsEvent("StepUp")
    /\ LET shard == MapShard(logline.shard) IN
        /\ StepUp(shard)
    /\ l' = l + 1

TraceRecoverMigration ==
    /\ IsEvent("RecoverMigration")
    /\ LET shard == MapShard(logline.shard) IN
        /\ RecoverMigration(shard)
    /\ l' = l + 1

TraceDeleteRange ==
    /\ IsEvent("DeleteRange")
    /\ LET shard == MapShard(logline.shard)
           key == MapKey(logline.key) IN
        /\ DeleteRange(shard, key)
    /\ l' = l + 1

TraceMajorityReplicateForget ==
    /\ IsEvent("MajorityReplicateForget")
    /\ LET shard == MapShard(logline.shard) IN
        /\ MajorityReplicateForget(shard)
    /\ l' = l + 1

\*---------------------------------------------------------------------------
\* Silent actions: base spec state changes without trace events
\* Tightly constrained to prevent state explosion
\*---------------------------------------------------------------------------

\* Silent range deletion: range deleter runs between observed events
\* Do not preempt a trace-driven DeleteRange event
SilentDeleteRange ==
    /\ l <= Len(TraceLog)
    /\ logline.event # "DeleteRange"
    /\ \E s \in Shard, k \in Key :
        /\ rangeDel[s][k] = "ready"
        /\ DeleteRange(s, k)
    /\ UNCHANGED l

\* Silent majority replicate: w:1 becomes majority between events
\* Do not preempt a trace-driven MajorityReplicateForget event
SilentMajorityReplicateForget ==
    /\ l <= Len(TraceLog)
    /\ logline.event # "MajorityReplicateForget"
    /\ \E s \in Shard :
        /\ coordDoc[s].forgetPending
        /\ MajorityReplicateForget(s)
    /\ UNCHANGED l

\* Silent commit release critical section: donor-side log absent, recipient
\* releases independently. Constrained to the commit release state.
SilentCommitReleaseCritSec ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Shard :
        /\ \E k \in Key : migState[k] = "commitReleaseCritSec" /\ migDonor[k] = s
        /\ CommitReleaseCritSec(s)
    /\ UNCHANGED l

\* Silent abort release critical section
SilentAbortReleaseCritSec ==
    /\ l <= Len(TraceLog)
    /\ \E s \in Shard :
        /\ \E k \in Key : migState[k] = "abortReleaseCritSec" /\ migDonor[k] = s
        /\ AbortReleaseCritSec(s)
    /\ UNCHANGED l

\*---------------------------------------------------------------------------
\* TraceInit
\*---------------------------------------------------------------------------
TraceInit ==
    /\ Init
    /\ l = 1
    \* Constrain non-deterministic initial configOwner from first trace event
    /\ IF Len(TraceLog) > 0 /\ "donor" \in DOMAIN TraceLog[1]
       THEN configOwner = [k \in Key |-> MapShard(TraceLog[1].donor)]
       ELSE TRUE

\*---------------------------------------------------------------------------
\* TraceNext
\*---------------------------------------------------------------------------
TraceNext ==
    \/ (l <= Len(TraceLog) /\
        (\/ TraceStartMigration
         \/ TraceRecipientEnterCriticalSection
         \/ TraceDonorEnterCriticalSection
         \/ TraceCommitOnConfigServer
         \/ TracePersistCommitDecision
         \/ TraceCommitBumpRecipientTxn
         \/ TraceCommitDeleteRecipientRangeDel
         \/ TraceCommitMarkDonorRangeDelReady
         \/ TraceCommitForgetMigration
         \/ TraceDecideAbort
         \/ TraceAbortPersistDecision
         \/ TraceAbortDeleteDonorRangeDel
         \/ TraceAbortBumpRecipientTxn
         \/ TraceAbortMarkRecipientRangeDelReady
         \/ TraceAbortForgetMigration
         \/ TraceStepdown
         \/ TraceStepUp
         \/ TraceRecoverMigration
         \/ TraceDeleteRange
         \/ TraceMajorityReplicateForget))
    \/ SilentDeleteRange
    \/ SilentMajorityReplicateForget
    \/ SilentCommitReleaseCritSec
    \/ SilentAbortReleaseCritSec

\*---------------------------------------------------------------------------
\* Temporal property: entire trace was consumed
\*---------------------------------------------------------------------------
TraceMatched == <>(l = Len(TraceLog) + 1)

====
