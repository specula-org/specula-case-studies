---- MODULE MC ----
EXTENDS base

\*---------------------------------------------------------------------
\* Concrete constants for model checking
\*---------------------------------------------------------------------
MCRange == {"R1", "R2", "R3"}
MCMigration == {"M1", "M2"}
MCTask == {1, 2, 3}
MCQuery == {"Q1", "Q2"}

\* R1 and R2 overlap; R3 is disjoint from both
MCOverlap == {<<"R1", "R2">>, <<"R2", "R1">>}

\*---------------------------------------------------------------------
\* Counter-bounded fault injection for model checking
\*---------------------------------------------------------------------
CONSTANTS
    StepDownLimit,      \* Max step-down events (Family 1)
    ClearMetadataLimit, \* Max metadata clears (Family 3)
    RetryDeleteLimit,   \* Max retry-delete events (Family 4)
    TickClockLimit      \* Max clock advances (Families 1, 2)

\* Fault injection counters
VARIABLE faultCounts

faultVars == <<faultCounts>>
mcVars == <<vars, faultVars>>

\*---------------------------------------------------------------------
\* Init
\*---------------------------------------------------------------------
MCInit ==
    /\ Init
    /\ faultCounts = [stepDown     |-> 0,
                      clearMeta    |-> 0,
                      retryDelete  |-> 0,
                      tickClock    |-> 0]

\*---------------------------------------------------------------------
\* Counter-bounded wrappers (fault-injection actions)
\*---------------------------------------------------------------------

MCStepDown ==
    /\ faultCounts.stepDown < StepDownLimit
    /\ StepDown
    /\ faultCounts' = [faultCounts EXCEPT !.stepDown = @ + 1]

MCClearMetadata ==
    /\ faultCounts.clearMeta < ClearMetadataLimit
    /\ ClearMetadata
    /\ faultCounts' = [faultCounts EXCEPT !.clearMeta = @ + 1]

MCRetryDeleteTaskLocally ==
    /\ faultCounts.retryDelete < RetryDeleteLimit
    /\ \E m \in Migration : RetryDeleteTaskLocally(m)
    /\ faultCounts' = [faultCounts EXCEPT !.retryDelete = @ + 1]

MCTickClock ==
    /\ faultCounts.tickClock < TickClockLimit
    /\ TickClock
    /\ faultCounts' = [faultCounts EXCEPT !.tickClock = @ + 1]

\*---------------------------------------------------------------------
\* Unconstrained wrappers (reactive/deterministic actions)
\*---------------------------------------------------------------------

MCStepUp              == StepUp            /\ UNCHANGED faultVars
MCRecoveryBegin       == RecoveryBegin     /\ UNCHANGED faultVars
MCRecoveryComplete    == RecoveryComplete  /\ UNCHANGED faultVars

MCStartMigration      == \E m \in Migration, r \in Range, t \in Task :
                              StartMigration(m, r, t) /\ UNCHANGED faultVars
MCCommitMigration     == \E m \in Migration : CommitMigration(m) /\ UNCHANGED faultVars
MCAbortMigration      == \E m \in Migration : AbortMigration(m) /\ UNCHANGED faultVars

MCClearPending        == \E t \in Task : ClearPending(t)       /\ UNCHANGED faultVars
MCCheckOverlap        == \E t \in Task : CheckOverlap(t)       /\ UNCHANGED faultVars
MCOverlapResolved     == \E t \in Task : OverlapResolved(t)    /\ UNCHANGED faultVars
MCQueriesDrained      == \E t \in Task : QueriesDrained(t)     /\ UNCHANGED faultVars

MCProcessorPickTask   == \E t \in Task : ProcessorPickTask(t)  /\ UNCHANGED faultVars
MCCompleteTask        == \E t \in Task : CompleteTask(t)       /\ UNCHANGED faultVars

MCStartQuery          == \E q \in Query, r \in Range : StartQuery(q, r) /\ UNCHANGED faultVars
MCEndQuery            == \E q \in Query : EndQuery(q)                   /\ UNCHANGED faultVars

MCRefreshMetadata     == RefreshMetadata /\ UNCHANGED faultVars

\*---------------------------------------------------------------------
\* MCNext
\*---------------------------------------------------------------------
MCNext ==
    \* Service lifecycle
    \/ MCStepUp
    \/ MCRecoveryBegin
    \/ MCRecoveryComplete
    \/ MCStepDown
    \* Migration lifecycle
    \/ MCStartMigration
    \/ MCCommitMigration
    \/ MCAbortMigration
    \* Task registration chain
    \/ MCClearPending
    \/ MCCheckOverlap
    \/ MCOverlapResolved
    \/ MCQueriesDrained
    \* Deletion execution
    \/ MCProcessorPickTask
    \/ MCCompleteTask
    \* Query lifecycle
    \/ MCStartQuery
    \/ MCEndQuery
    \* Metadata lifecycle (bounded + unbounded)
    \/ MCClearMetadata
    \/ MCRefreshMetadata
    \* Clock (bounded)
    \/ MCTickClock
    \* Fault injection (bounded)
    \/ MCRetryDeleteTaskLocally

MCSpec == MCInit /\ [][MCNext]_mcVars

\*---------------------------------------------------------------------
\* State space constraint
\*---------------------------------------------------------------------
ClockConstraint == clock <= TickClockLimit + 2

\*---------------------------------------------------------------------
\* View (exclude counters from state fingerprint if needed)
\*---------------------------------------------------------------------
MCView == vars

====
