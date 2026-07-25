---------------------------------- MODULE MC -----------------------------------
\* Model checking wrapper for the MongoDB TxnsMoveRange base spec.
\* Bounds fault-injection actions with counters, adds symmetry reduction,
\* structural invariants, and hunting-config support.
\*
\* Normal (reactive/deterministic) actions are NOT bounded.
\* Bounded actions: StartMigration, ConfigCommitFail, DonorStepDown,
\*   DonorStepUp, CreateDatabase, ShardRespondAfterExec,
\*   RouterRetryOnStale, DonorRecoveryWrongInference.

EXTENDS base

\* ============================================================================
\* Counter bounds (set via cfg overrides)
\* ============================================================================
CONSTANTS
    MaxMigrations,            \* StartMigration bound
    MaxConfigFails,           \* ConfigCommitFail bound
    MaxStepDowns,             \* DonorStepDown bound
    MaxStepUps,               \* DonorStepUp bound
    MaxRetries,               \* RouterRetryOnStale bound
    MaxCreateDbs,             \* CreateDatabase bound
    MaxExecErrors,            \* ShardRespondAfterExec bound
    MaxWrongInferences        \* DonorRecoveryWrongInference bound

\* ============================================================================
\* Counter variables
\* ============================================================================
VARIABLE faultCounters
\* faultCounters is a record:
\*   [migrations, configFails, stepDowns, stepUps, retries,
\*    createDbs, execErrors, wrongInferences]

mcVars == <<vars, faultCounters>>

\* ============================================================================
\* Init
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [
        migrations       |-> 0,
        configFails      |-> 0,
        stepDowns        |-> 0,
        stepUps          |-> 0,
        retries          |-> 0,
        createDbs        |-> 0,
        execErrors       |-> 0,
        wrongInferences  |-> 0
       ]

\* ============================================================================
\* Counter-bounded wrappers
\* ============================================================================

MCStartMigration(ns, k, from, to) ==
    /\ faultCounters.migrations < MaxMigrations
    /\ StartMigration(ns, k, from, to)
    /\ faultCounters' = [faultCounters EXCEPT !.migrations = @ + 1]

MCConfigCommitFail(ns) ==
    /\ faultCounters.configFails < MaxConfigFails
    /\ ConfigCommitFail(ns)
    /\ faultCounters' = [faultCounters EXCEPT !.configFails = @ + 1]

MCDonorStepDown(s) ==
    /\ faultCounters.stepDowns < MaxStepDowns
    /\ DonorStepDown(s)
    /\ faultCounters' = [faultCounters EXCEPT !.stepDowns = @ + 1]

MCDonorStepUp(s) ==
    /\ faultCounters.stepUps < MaxStepUps
    /\ DonorStepUp(s)
    /\ faultCounters' = [faultCounters EXCEPT !.stepUps = @ + 1]

MCRouterRetryOnStale(t) ==
    /\ faultCounters.retries < MaxRetries
    /\ RouterRetryOnStale(t)
    /\ faultCounters' = [faultCounters EXCEPT !.retries = @ + 1]

MCCreateDatabase(t) ==
    /\ faultCounters.createDbs < MaxCreateDbs
    /\ CreateDatabase(t)
    /\ faultCounters' = [faultCounters EXCEPT !.createDbs = @ + 1]

MCShardRespondAfterExec(t, self) ==
    /\ faultCounters.execErrors < MaxExecErrors
    /\ ShardRespondAfterExec(t, self)
    /\ faultCounters' = [faultCounters EXCEPT !.execErrors = @ + 1]

MCDonorRecoveryWrongInference(s, ns) ==
    /\ faultCounters.wrongInferences < MaxWrongInferences
    /\ DonorRecoveryWrongInference(s, ns)
    /\ faultCounters' = [faultCounters EXCEPT !.wrongInferences = @ + 1]

\* ============================================================================
\* Unconstrained wrappers (reactive/deterministic — no bound needed)
\* ============================================================================

MCRouterSendTxnStmt(t, ns, k) ==
    /\ RouterSendTxnStmt(t, ns, k) /\ UNCHANGED faultCounters

MCRouterHandleOk(t, stm) ==
    /\ RouterHandleOk(t, stm) /\ UNCHANGED faultCounters

MCRouterHandleAbort(t, stm) ==
    /\ RouterHandleAbort(t, stm) /\ UNCHANGED faultCounters

MCShardRespond(t, self) ==
    /\ ShardRespond(t, self) /\ UNCHANGED faultCounters

MCConfigCommit(ns) ==
    /\ ConfigCommit(ns) /\ UNCHANGED faultCounters

MCReleaseCriticalSection(ns) ==
    /\ ReleaseCriticalSection(ns) /\ UNCHANGED faultCounters

MCDonorRecovery(s, ns) ==
    /\ DonorRecovery(s, ns) /\ UNCHANGED faultCounters

\* ============================================================================
\* MCNext
\* ============================================================================

MCNext ==
    \* --- Router actions (unconstrained) ---
    \/ \E t \in Txns, ns \in NameSpaces, k \in Keys : MCRouterSendTxnStmt(t, ns, k)
    \/ \E t \in Txns, stm \in Stmts : MCRouterHandleOk(t, stm)
    \/ \E t \in Txns, stm \in Stmts : MCRouterHandleAbort(t, stm)
    \* --- Router actions (bounded) ---
    \/ \E t \in Txns : MCRouterRetryOnStale(t)
    \/ \E t \in Txns : MCCreateDatabase(t)
    \* --- Shard actions ---
    \/ \E s \in Shards, t \in Txns : MCShardRespond(t, s)
    \/ \E s \in Shards, t \in Txns : MCShardRespondAfterExec(t, s)
    \* --- Migration actions ---
    \/ \E ns \in NameSpaces, k \in Keys, from, to \in Shards :
        MCStartMigration(ns, k, from, to)
    \/ \E ns \in NameSpaces : MCConfigCommit(ns)
    \/ \E ns \in NameSpaces : MCConfigCommitFail(ns)
    \/ \E ns \in NameSpaces : MCReleaseCriticalSection(ns)
    \* --- Failover actions ---
    \/ \E s \in Shards : MCDonorStepDown(s)
    \/ \E s \in Shards : MCDonorStepUp(s)
    \/ \E s \in Shards, ns \in NameSpaces : MCDonorRecovery(s, ns)
    \/ \E s \in Shards, ns \in NameSpaces : MCDonorRecoveryWrongInference(s, ns)
    \* --- Stuttering ---
    \/ UNCHANGED mcVars

MCSpec == MCInit /\ [][MCNext]_mcVars

\* ============================================================================
\* Symmetry reduction
\* ============================================================================

MCSymmetry == Permutations(Shards)

\* ============================================================================
\* State space pruning — message buffer limit
\* ============================================================================

MaxMsgBuffer == 6

MsgBufferConstraint ==
    \A t \in Txns : Len(request[t]) <= MaxMsgBuffer

\* ============================================================================
\* View (exclude counters from state fingerprint for some analyses)
\* ============================================================================

MCView == vars

================================================================================
