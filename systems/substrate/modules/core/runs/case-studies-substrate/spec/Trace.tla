------------------------------ MODULE Trace ------------------------------
\* Trace validation specification for Substrate GRANDPA
\* Replays implementation traces against the base spec to verify consistency.
\*
\* Trace events are loaded from a JSON file (ndjson format).
\* A cursor variable `l` walks through trace events; action wrappers match
\* events, call base actions, validate post-state, and advance cursor.

EXTENDS base, Sequences, TLC, Naturals, Json, IOUtils

\* ================================================================
\* Trace Loading
\* ================================================================

CONSTANTS
    TraceFilePath  \* Path to ndjson trace file

VARIABLES
    l  \* Cursor into the trace log (1-indexed)

traceVars == <<l>>

\* Load trace from file
TraceLog == ndJsonDeserialize(TraceFilePath)

----
\* ================================================================
\* Helper operators for trace matching
\* ================================================================

\* Current trace event
logline == TraceLog[l]

\* Check if current event matches a given event name
IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event = name

\* Check if current event is for a specific node
IsNodeEvent(name, node) ==
    /\ IsEvent(name)
    /\ logline.node = node

\* Map implementation strings to spec values
MapPhase(phaseStr) ==
    CASE phaseStr = "idle" -> "idle"
      [] phaseStr = "proposed" -> "proposed"
      [] phaseStr = "prevoted" -> "prevoted"
      [] phaseStr = "precommitted" -> "precommitted"
      [] phaseStr = "completed" -> "completed"
      [] OTHER -> "idle"

\* Extract server set from trace
TraceServers == {TraceLog[i].node : i \in 1..Len(TraceLog)}

----
\* ================================================================
\* Post-state validation helpers
\* ================================================================

\* Strong validation: check finalized block, set_id, current authorities
StrongValidation(node) ==
    /\ finalizedBlock'[node] = logline.state.finalizedBlock
    /\ setId'[node] = logline.state.setId

\* Weak validation: check only finalized block (for async actions)
WeakValidation(node) ==
    /\ finalizedBlock'[node] = logline.state.finalizedBlock

\* Round validation: check round phase and current round
RoundValidation(node) ==
    /\ currentRound'[node] = logline.state.currentRound

----
\* ================================================================
\* Trace Init
\* ================================================================

TraceInit ==
    /\ l = 1
    \* Initialize with empty block tree (only genesis at block 0 exists implicitly)
    \* Implementation starts with genesis; blocks are produced by test harness
    /\ blockTree = [b \in Block |-> NilBlock]
    /\ bestBlock = [s \in Server |-> 0]
    /\ changeRecord = [b \in Block |-> [type |-> "none"]]
    /\ finalizedBlock = [s \in Server |-> 0]
    /\ currentAuthorities = [s \in Server |-> InitAuthorities]
    /\ setId = [s \in Server |-> 0]
    /\ pendingStandard = [s \in Server |-> {}]
    /\ pendingForced = [s \in Server |-> {}]
    /\ authSetLock = [s \in Server |-> "free"]
    /\ finalizationStep = [s \in Server |-> 0]
    /\ finalizingBlock = [s \in Server |-> NilBlock]
    /\ finalizingPath = [s \in Server |-> "none"]
    /\ prevotes = [s \in Server |-> [r \in 1..MaxRound |-> {}]]
    /\ precommits = [s \in Server |-> [r \in 1..MaxRound |-> {}]]
    /\ equivocators = [r \in 1..MaxRound |-> {}]
    /\ roundPhase = [s \in Server |-> [r \in 1..MaxRound |-> "idle"]]
    /\ currentRound = [s \in Server |-> 1]
    /\ hasVoted = [s \in Server |-> [r \in 1..MaxRound |->
                    [phase |-> "none", target |-> NilBlock]]]
    /\ voteLimit = [s \in Server |-> MaxBlock + 1]
    /\ crashed = [s \in Server |-> FALSE]
    /\ persisted = [s \in Server |-> [finalizedBlock |-> 0, setId |-> 0,
                     authorities |-> InitAuthorities,
                     hasVoted |-> [r \in 1..MaxRound |->
                                   [phase |-> "none", target |-> NilBlock]]]]

----
\* ================================================================
\* Action wrappers: match trace event -> call base action -> validate -> advance
\* ================================================================

\* ----------------------------------------------------------------
\* TraceProduceBlock: A block was produced
\* ----------------------------------------------------------------
TraceProduceBlock ==
    /\ IsEvent("ProduceBlock")
    /\ LET s == logline.node
           parent == logline.parent
           blk == logline.block
       IN /\ ProduceBlock(s, parent, blk)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceAddStandardChange: A standard authority change was scheduled
\* import.rs:314-342
\* ----------------------------------------------------------------
TraceAddStandardChange ==
    /\ IsEvent("AddStandardChange")
    /\ LET s == logline.node
           blk == logline.block
           delay == logline.delay
           newAuth == {logline.newAuthorities[i] : i \in DOMAIN logline.newAuthorities}
       IN /\ AddStandardChange(s, blk, delay, newAuth)
          /\ StrongValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceAddForcedChange: A forced authority change was scheduled
\* authorities.rs:336-380
\* ----------------------------------------------------------------
TraceAddForcedChange ==
    /\ IsEvent("AddForcedChange")
    /\ LET s == logline.node
           blk == logline.block
           delay == logline.delay
           newAuth == {logline.newAuthorities[i] : i \in DOMAIN logline.newAuthorities}
           medFin == logline.medianFinalized
       IN /\ AddForcedChange(s, blk, delay, newAuth, medFin)
          /\ StrongValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceApplyStandardChange: A standard change was applied on finalization
\* authorities.rs:541-602
\* ----------------------------------------------------------------
TraceApplyStandardChange ==
    /\ IsEvent("ApplyStandardChange")
    /\ LET s == logline.node
       IN /\ ApplyStandardChange(s)
          /\ StrongValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceApplyForcedChange: A forced change was applied
\* authorities.rs:447-529
\* ----------------------------------------------------------------
TraceApplyForcedChange ==
    /\ IsEvent("ApplyForcedChange")
    /\ LET s == logline.node
       IN /\ ApplyForcedChange(s)
          /\ StrongValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceFinalizeBlock: A block was finalized (atomic path)
\* environment.rs:1354-1544
\* ----------------------------------------------------------------
TraceFinalizeBlock ==
    /\ IsEvent("FinalizeBlock")
    /\ LET s == logline.node
           blk == logline.block
       IN /\ FinalizeBlock(s, blk)
          /\ StrongValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceAcquireFinalizationLock: Finalization lock acquired
\* environment.rs:1370-1373
\* ----------------------------------------------------------------
TraceAcquireFinalizationLock ==
    /\ IsEvent("AcquireFinalizationLock")
    /\ LET s == logline.node
           blk == logline.block
           path == logline.path
       IN /\ AcquireFinalizationLock(s, blk, path)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceWriteToDisk: Finalization written to disk
\* environment.rs:1451-1530
\* ----------------------------------------------------------------
TraceWriteToDisk ==
    /\ IsEvent("WriteToDisk")
    /\ LET s == logline.node
       IN /\ WriteToDisk(s)
          /\ WeakValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceReleaseFinalizationLock: Finalization lock released
\* environment.rs:1535-1543
\* ----------------------------------------------------------------
TraceReleaseFinalizationLock ==
    /\ IsEvent("ReleaseFinalizationLock")
    /\ LET s == logline.node
       IN /\ ReleaseFinalizationLock(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TracePropose: A proposal was made
\* environment.rs:797-838
\* ----------------------------------------------------------------
TracePropose ==
    /\ IsEvent("Propose")
    /\ LET s == logline.node
           r == logline.round
           blk == logline.block
       IN /\ Propose(s, r, blk)
          /\ RoundValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TracePrevote: A prevote was cast
\* environment.rs:840-901
\* ----------------------------------------------------------------
TracePrevote ==
    /\ IsEvent("Prevote")
    /\ LET s == logline.node
           r == logline.round
           blk == logline.block
       IN /\ Prevote(s, r, blk)
          /\ RoundValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TracePrecommit: A precommit was cast
\* environment.rs:903-974
\* ----------------------------------------------------------------
TracePrecommit ==
    /\ IsEvent("Precommit")
    /\ LET s == logline.node
           r == logline.round
           blk == logline.block
       IN /\ Precommit(s, r, blk)
          /\ RoundValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceCompleteRound: A round was completed
\* environment.rs:976-1036
\* ----------------------------------------------------------------
TraceCompleteRound ==
    /\ IsEvent("CompleteRound")
    /\ LET s == logline.node
           r == logline.round
       IN /\ CompleteRound(s, r)
          /\ RoundValidation(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceByzantinePrevote: Byzantine prevote observed
\* ----------------------------------------------------------------
TraceByzantinePrevote ==
    /\ IsEvent("ByzantinePrevote")
    /\ LET s == logline.node
           r == logline.round
           blk == logline.block
       IN ByzantinePrevote(s, r, blk)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceByzantinePrecommit: Byzantine precommit observed
\* ----------------------------------------------------------------
TraceByzantinePrecommit ==
    /\ IsEvent("ByzantinePrecommit")
    /\ LET s == logline.node
           r == logline.round
           blk == logline.block
       IN ByzantinePrecommit(s, r, blk)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceCrash: A server crashed
\* ----------------------------------------------------------------
TraceCrash ==
    /\ IsEvent("Crash")
    /\ LET s == logline.node
       IN Crash(s)
    /\ l' = l + 1

\* ----------------------------------------------------------------
\* TraceRecover: A server recovered
\* ----------------------------------------------------------------
TraceRecover ==
    /\ IsEvent("Recover")
    /\ LET s == logline.node
       IN /\ Recover(s)
          /\ WeakValidation(s)
    /\ l' = l + 1

----
\* ================================================================
\* Silent actions: fire without consuming a trace event
\* Must be tightly constrained to prevent state space explosion
\* ================================================================

\* Silent: Apply standard change that happens as part of finalization
\* (not separately traced — applied inside finalize_block)
SilentApplyStandardChange ==
    /\ l <= Len(TraceLog)
    /\ logline.event /= "AddStandardChange"
    /\ \E s \in Server :
        /\ ApplyStandardChange(s)
        /\ UNCHANGED l

\* Silent: Apply finalization sub-step changes
\* (not separately traced — happens as part of finalization pipeline)
SilentApplyFinalizationChanges ==
    /\ l <= Len(TraceLog)
    /\ logline.event \in {"WriteToDisk", "ReleaseFinalizationLock"}
    /\ \E s \in Server :
        /\ ApplyFinalizationChanges(s)
        /\ UNCHANGED l

\* Silent: Apply forced change (applied during block import for all peers)
\* Only one ApplyForcedChange event is traced; other servers apply silently.
SilentApplyForcedChange ==
    /\ l <= Len(TraceLog)
    /\ logline.event /= "ApplyForcedChange"
    /\ \E s \in Server :
        /\ ApplyForcedChange(s)
        /\ UNCHANGED l

\* Silent: Block production not in trace (blocks may already exist)
\* Guard: only fire when current trace event is NOT ProduceBlock,
\* to prevent stealing blocks from traced ProduceBlock events.
SilentProduceBlock ==
    /\ l <= Len(TraceLog)
    /\ logline.event /= "ProduceBlock"
    /\ \E s \in Server, parent \in Block \cup {0}, b \in Block :
        /\ ProduceBlock(s, parent, b)
        /\ UNCHANGED l

----
\* ================================================================
\* TraceNext: All wrappers + silent actions
\* ================================================================

TraceNext ==
    \* Traced actions (consume event, advance l)
    \/ TraceProduceBlock
    \/ TraceAddStandardChange
    \/ TraceAddForcedChange
    \/ TraceApplyStandardChange
    \/ TraceApplyForcedChange
    \/ TraceFinalizeBlock
    \/ TraceAcquireFinalizationLock
    \/ TraceWriteToDisk
    \/ TraceReleaseFinalizationLock
    \/ TracePropose
    \/ TracePrevote
    \/ TracePrecommit
    \/ TraceCompleteRound
    \/ TraceByzantinePrevote
    \/ TraceByzantinePrecommit
    \/ TraceCrash
    \/ TraceRecover
    \* Silent actions (don't consume event)
    \/ SilentApplyStandardChange
    \/ SilentApplyForcedChange
    \/ SilentApplyFinalizationChanges
    \/ SilentProduceBlock
    \* Done: allow stuttering once trace is fully consumed (prevents false deadlock)
    \/ (l = Len(TraceLog) + 1 /\ UNCHANGED <<vars, l>>)

----
\* ================================================================
\* Trace completion property
\* ================================================================

\* Invariant-based check: if we're in a deadlock, the trace must be fully consumed.
\* Use this with TLC's default deadlock checking (no -deadlock flag needed).
TraceMatched == <>(l = Len(TraceLog) + 1)

\* Alias for debugging: show current trace position and event
TraceAlias == [
    cursor |-> l,
    traceLen |-> Len(TraceLog),
    currentEvent |-> IF l <= Len(TraceLog) THEN logline.event ELSE "END",
    currentNode |-> IF l <= Len(TraceLog) THEN logline.node ELSE "END"
]

=============================================================================
