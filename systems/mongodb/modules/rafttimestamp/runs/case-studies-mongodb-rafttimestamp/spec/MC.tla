---- MODULE MC ----
\*****************************************************************************
\* Model Checking wrapper for the MongoDB RaftMongoReplTimestamp base spec.
\*
\* Counter-bounds fault-injection and non-deterministic actions.
\* Does NOT bound reactive/deterministic actions (message handlers, commit
\* point learning, recovery steps, hole closing).
\*****************************************************************************
EXTENDS base

\* --- Bounding constants ---
CONSTANT MaxTerm            \* Max global term (bounds elections)
CONSTANT MaxLogLen          \* Max log length per server
CONSTANT MaxRestartTimes    \* Max crashes per server
CONSTANT MaxFailoverTimes   \* Max stepdowns per server
CONSTANT MaxPrepareCount    \* Max prepared transactions (Bug Family 1)
CONSTANT MaxFlusherCount    \* Max journal flusher captures (Bug Family 2)
CONSTANT MaxWCWriteCount    \* Max write-concern writes (Bug Family 3)
CONSTANT MaxRecoveryCrashCount \* Max crashes during recovery (Bug Family 5)

\* --- Counter variables ---
VARIABLE faultCounters
\* faultCounters is a record:
\*   [prepareCount    |-> Nat,
\*    flusherCount    |-> Nat,
\*    wcWriteCount    |-> Nat,
\*    recCrashCount   |-> Nat]

mcVars == <<vars, faultCounters>>

----
\* State constraint — bounds the state space.
StateConstraint ==
    /\ GlobalCurrentTerm <= MaxTerm
    /\ \A i \in Server :
        /\ Len(log[i]) <= MaxLogLen
        /\ restartTimes[i] <= MaxRestartTimes
        /\ failoverTimes[i] <= MaxFailoverTimes
    /\ faultCounters.prepareCount <= MaxPrepareCount
    /\ faultCounters.flusherCount <= MaxFlusherCount
    /\ faultCounters.wcWriteCount <= MaxWCWriteCount
    /\ faultCounters.recCrashCount <= MaxRecoveryCrashCount

\* Symmetry reduction on server identities.
ServerSymmetry == Permutations(Server)

----
\* MC Init
MCInit ==
    /\ Init
    /\ faultCounters = [prepareCount    |-> 0,
                         flusherCount    |-> 0,
                         wcWriteCount    |-> 0,
                         recCrashCount   |-> 0]

----
\*****************************************************************************
\* Counter-bounded action wrappers
\*****************************************************************************

\* --- Bounded: PrepareTransaction (Bug Family 1) ---
MCPrepareTransaction ==
    /\ faultCounters.prepareCount < MaxPrepareCount
    /\ PrepareTransactionAction
    /\ faultCounters' = [faultCounters EXCEPT !.prepareCount = @ + 1]

\* --- Bounded: JournalFlusherCapture (Bug Family 2) ---
MCJournalFlusherCapture ==
    /\ faultCounters.flusherCount < MaxFlusherCount
    /\ JournalFlusherCaptureAction
    /\ faultCounters' = [faultCounters EXCEPT !.flusherCount = @ + 1]

\* --- Bounded: ClientWriteWithWC (Bug Family 3) ---
MCClientWriteWithWC ==
    /\ faultCounters.wcWriteCount < MaxWCWriteCount
    /\ ClientWriteWithWCAction
    /\ faultCounters' = [faultCounters EXCEPT !.wcWriteCount = @ + 1]

\* --- Bounded: RecoveryCrash (Bug Family 5) ---
MCRecoveryCrash ==
    /\ faultCounters.recCrashCount < MaxRecoveryCrashCount
    /\ RecoveryCrashAction
    /\ faultCounters' = [faultCounters EXCEPT !.recCrashCount = @ + 1]

\* --- Unbounded (reactive/deterministic) actions pass through ---
PassThrough(action) == action /\ UNCHANGED faultCounters

MCNext ==
    \* --- Replication protocol (unbounded) ---
    \/ PassThrough(AppendOplogAction)
    \/ PassThrough(RollbackOplogAction)
    \/ PassThrough(BecomePrimaryByMagicAction)
    \/ PassThrough(StepdownAction)
    \/ PassThrough(UpdateTermThroughHeartbeatAction)
    \* --- Oplog + durability (unbounded) ---
    \/ PassThrough(ClientWriteAction)
    \/ PassThrough(CloseOplogHoleAction)
    \/ PassThrough(PersistOplogAction)
    \/ PassThrough(ApplyOplogAction)
    \* --- Commit point (unbounded) ---
    \/ PassThrough(AdvanceCommitPoint)
    \/ PassThrough(LearnCommitPointWithTermCheckAction)
    \/ PassThrough(LearnCommitPointFromSyncSourceAction)
    \* --- Bug Family 1: Prepared transactions (bounded) ---
    \/ MCPrepareTransaction
    \/ PassThrough(CommitPreparedTxnAction)
    \* --- Bug Family 2: Async journal flusher (bounded capture, unbounded flush) ---
    \/ MCJournalFlusherCapture
    \/ PassThrough(JournalFlusherFlushAction)
    \* --- Bug Family 3: Write concern (bounded writes, unbounded satisfaction) ---
    \/ MCClientWriteWithWC
    \/ PassThrough(WriteConcernSatisfiedAction)
    \* --- Bug Family 5: Crash + recovery ---
    \/ PassThrough(CrashAction)
    \/ PassThrough(RecoverTruncateOplogAction)
    \/ PassThrough(RecoverReplayOplogAction)
    \/ PassThrough(RecoverSetTimestampsAction)
    \/ MCRecoveryCrash

MCSpec == MCInit /\ [][MCNext]_mcVars

----
\*****************************************************************************
\* Invariants (for MC.cfg)
\*****************************************************************************

\* The state view excludes fault counters (they don't affect correctness).
View == vars

====
