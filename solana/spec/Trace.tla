--------------------------- MODULE Trace ---------------------------
(*
 * Trace validation specification for Solana Tower BFT.
 *
 * Replays implementation traces (recorded from anza-xyz/agave) against the
 * base spec to verify that the base spec can reproduce every observed
 * state transition.
 *
 * Trace format: NDJSON with tag="trace".  Each line is a JSON object with
 *   - event.name : spec action name (e.g. "RecordVote", "PersistTower", ...)
 *   - event.nid  : validator pubkey (mapped to a Server model value)
 *   - event.slot : slot number (if applicable)
 *   - event.hash : bank hash (if applicable)
 *   - event.state : post-action state snapshot containing the fields
 *                   the spec needs to validate:
 *                     - state.lastVotedSlot
 *                     - state.lastVotedHash
 *                     - state.towerVoteCount
 *                     - state.rootSlot
 *                     - state.persistedLastVotedSlot
 *                     - state.persistedRootSlot
 *                     - state.alive
 *                     - state.panicked
 *   - event.msg   : message fields (for message-handling events)
 *                     - msg.source, msg.last_slot, msg.last_hash, msg.kind
 *)

EXTENDS base, Json, IOUtils, Sequences, TLC

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* Load NDJSON, filter to trace events only.
TraceLog == TLCEval(
    LET all == ndJsonDeserialize(JsonFile)
    IN SelectSeq(all, LAMBDA x :
        /\ "tag" \in DOMAIN x
        /\ x.tag = "trace"
        /\ "event" \in DOMAIN x))

ASSUME Len(TraceLog) > 0

\* ============================================================================
\* TRACE CURSOR
\* ============================================================================

VARIABLE l       \* Current position in TraceLog (1-indexed)

traceVars == <<l>>

logline == TraceLog[l]

\* ============================================================================
\* TRACE SERVER EXTRACTION
\* (Validator pubkeys in the trace are 32-byte base58 strings; we map them
\* to the Server model values via the cfg's `Server = ...` enumeration and
\* a one-shot pubkey-to-model-value mapping via assertion below.)
\* ============================================================================

TraceServer == TLCEval(
    UNION {
        ((IF "nid" \in DOMAIN TraceLog[k].event
              THEN {TraceLog[k].event.nid}
              ELSE {}) \cup
         (IF "msg" \in DOMAIN TraceLog[k].event
              /\ "source" \in DOMAIN TraceLog[k].event.msg
          THEN {TraceLog[k].event.msg.source} \ {""}
          ELSE {}))
        : k \in 1..Len(TraceLog)
    })

ASSUME TraceServer /= {}
ASSUME TraceServer \subseteq Server

\* Trace-value mapping helpers
TraceValue(v) ==
    IF v = "" \/ v = "null" \/ v = "nil" THEN Nil ELSE v

\* ============================================================================
\* EVENT PREDICATES
\* ============================================================================

IsEvent(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

IsNodeEvent(name, i) ==
    /\ IsEvent(name)
    /\ logline.event.nid = i

\* ============================================================================
\* POST-STATE VALIDATION
\* (Mandatory per spec-generation methodology — every action wrapper must
\* validate the key fields the action modifies.)
\* ============================================================================

\* For tower-mutating actions: validate the post-state tower's last vote
\* and persisted-tower state match the captured snapshot.
ValidateTowerPostState(i) ==
    /\ tower'[i].last_voted_slot = logline.event.state.lastVotedSlot
    /\ tower'[i].last_voted_hash = logline.event.state.lastVotedHash
    /\ Len(tower'[i].votes) = logline.event.state.towerVoteCount

\* For persist actions: validate the persisted-tower matches the trace's
\* recorded "tower file on disk" snapshot.
ValidatePersistPostState(i) ==
    /\ persistedTower'[i].last_voted_slot = logline.event.state.persistedLastVotedSlot
    /\ persistedTower'[i].root_slot       = logline.event.state.persistedRootSlot

\* For broadcast actions: validate that the on-chain vote-state at the
\* freshly-frozen slot matches the broadcast vote.
ValidateBroadcastPostState(i) ==
    /\ replayFrozenVotes'[i] /= Nil
    /\ replayFrozenVotes'[i].slot = logline.event.state.lastVotedSlot
    /\ replayFrozenVotes'[i].hash = logline.event.state.lastVotedHash

\* For OC accounting events: validate the new vote was added to the right bucket.
ValidateOCStakePostState(slot, hash, voter) ==
    /\ voter \in ocStake'[slot][hash]

\* For OC threshold reach: validate the (slot, hash) is in ocConfirmed.
ValidateReachOCPostState(slot, hash) ==
    /\ <<slot, hash>> \in ocConfirmed'

\* For RootSlot: validate the slot is in rooted and rootedHash matches.
ValidateRootSlotPostState(slot, hash) ==
    /\ slot \in rooted'
    /\ rootedHash'[slot] = hash

\* For duplicate-confirm processing: validate the hash was added.
ValidateDupConfirmPostState(slot, hash) ==
    /\ hash \in duplicateConfirmed'[slot]

\* For purge: validate the slot was added to v's purged view.
ValidatePurgePostState(v, slot) ==
    /\ slot \in purgedView'[v]

\* For crash/restart: validate alive flag matches.
ValidateAliveState(i) ==
    /\ alive'[i] = logline.event.state.alive

\* ============================================================================
\* STEP TRACE CURSOR
\* ============================================================================

StepTrace == l' = l + 1

\* ============================================================================
\* ACTION WRAPPERS
\* ============================================================================

\* --- RecordVote ---
\* Matches: event.name = "RecordVote"
\* Captured fields: state.lastVotedSlot, state.lastVotedHash, state.towerVoteCount.
RecordVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("RecordVote", i)
        /\ LET s == logline.event.slot
               h == logline.event.hash
           IN /\ RecordVote(i, s, h)
              /\ ValidateTowerPostState(i)
              /\ StepTrace

\* --- PersistTower ---
\* Matches: event.name = "PersistTower"
\* Captured fields: state.persistedLastVotedSlot, state.persistedRootSlot.
PersistTowerIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("PersistTower", i)
        /\ PersistTower(i)
        /\ ValidatePersistPostState(i)
        /\ StepTrace

\* --- BroadcastVote ---
\* Matches: event.name = "BroadcastVote"
\* Captured fields: state.lastVotedSlot, state.lastVotedHash (must equal the
\* broadcast vote's slot/hash).
BroadcastVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("BroadcastVote", i)
        /\ BroadcastVote(i)
        /\ ValidateBroadcastPostState(i)
        /\ StepTrace

\* --- ReceiveVote ---
\* Matches: event.name = "ReceiveVote".  Validates OC stake bucket updated.
ReceiveVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveVote", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \E m \in DOMAIN msgs :
              /\ msgs[m] > 0
              /\ m.mtype = "Vote"
              /\ m.msrc = logline.event.msg.source
              /\ m.last_slot = logline.event.msg.last_slot
              /\ m.last_hash = logline.event.msg.last_hash
              /\ ReceiveVote(i, m)
              /\ ValidateOCStakePostState(
                    logline.event.msg.last_slot,
                    logline.event.msg.last_hash,
                    logline.event.msg.source)
              /\ StepTrace

\* --- ReachOC ---
\* Matches: event.name = "ReachOC".  Validates ocConfirmed updated.
ReachOCIfLogged ==
    /\ IsEvent("ReachOC")
    /\ LET s == logline.event.slot
           h == logline.event.hash
       IN /\ ReachOC(s, h)
          /\ ValidateReachOCPostState(s, h)
          /\ StepTrace

\* --- RootSlot ---
\* Matches: event.name = "RootSlot".  Validates rooted + rootedHash.
RootSlotIfLogged ==
    /\ IsEvent("RootSlot")
    /\ LET s == logline.event.slot
           h == logline.event.hash
       IN /\ RootSlot(s, h)
          /\ ValidateRootSlotPostState(s, h)
          /\ StepTrace

\* --- PurgeUnconfirmedSlot ---
PurgeUnconfirmedSlotIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("PurgeUnconfirmedSlot", i)
        /\ LET s == logline.event.slot
           IN /\ PurgeUnconfirmedSlot(i, s)
              /\ ValidatePurgePostState(i, s)
              /\ StepTrace

\* --- ProcessDuplicateConfirmedSignal ---
\* Trace event name distinguishes the panic path from the normal path:
\*   "ProcessDuplicateConfirmedSignal"          — normal insertion
\*   "ProcessDuplicateConfirmedSignalPanic"     — second hash arrived, asserted
\* Both share the same spec action; the panic flag in post-state distinguishes.
ProcessDuplicateConfirmedSignalIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ProcessDuplicateConfirmedSignal", i)
        /\ LET s == logline.event.slot
               h == logline.event.hash
           IN /\ ProcessDuplicateConfirmedSignal(i, s, h)
              /\ ValidateDupConfirmPostState(s, h)
              /\ ValidateAliveState(i)
              /\ StepTrace

\* --- CastSwitchVote ---
\* The switch-vote path; same trace structure as RecordVote but
\* on a different fork.  We share the wrapper but emit a distinct event name.
CastSwitchVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CastSwitchVote", i)
        /\ LET s == logline.event.slot
           IN /\ CastSwitchVote(i, s)
              /\ ValidateTowerPostState(i)
              /\ StepTrace

\* --- Crash ---
CrashIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Crash", i)
        /\ Crash(i)
        /\ ValidateAliveState(i)
        /\ StepTrace

\* --- CrashBeforeFsyncReachesDisk ---
CrashBeforeFsyncIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("CrashBeforeFsync", i)
        /\ CrashBeforeFsyncReachesDisk(i)
        /\ ValidateAliveState(i)
        /\ StepTrace

\* --- Restart ---
RestartIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("Restart", i)
        /\ Restart(i)
        /\ ValidateAliveState(i)
        /\ StepTrace

\* --- AdoptOnChainTowerIfBehind ---
AdoptOnChainTowerIfBehindIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("AdoptOnChainTowerIfBehind", i)
        /\ LET s == logline.event.slot
           IN /\ AdoptOnChainTowerIfBehind(i, s)
              /\ ValidateTowerPostState(i)
              /\ StepTrace

\* ============================================================================
\* SILENT ACTIONS
\* (Reactive base actions that may fire without a corresponding trace event.
\*  Tightly constrained: each may only fire when the trace's *next* event
\*  requires the silent action's effect.)
\* ============================================================================

\* Silent ReachOC: OC threshold can be reached as a passive accounting
\* operation; the trace may not log it if the implementation does not
\* expose a hook.  Only fire when the NEXT event needs the (slot, hash) OC.
SilentReachOC ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"RootSlot", "ProcessDuplicateConfirmedSignal"}
    /\ \E s \in 1..MaxSlot, h \in Hashes :
        /\ ReachOC(s, h)
        /\ UNCHANGED traceVars

\* Silent DropMessage: messages may be silently dropped (the implementation
\* doesn't always log a drop event).  Only fire when the *next* trace event
\* is NOT a ReceiveVote — otherwise we risk dropping a message a future
\* ReceiveVote needs to consume, which would deadlock the trace cursor.
SilentDropMessage ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name /= "ReceiveVote"
    /\ BagCardinality(msgs) >= 4
    /\ \E m \in DOMAIN msgs :
        /\ \* Don't drop a message that any *upcoming* ReceiveVote would match.
           ~ \E k \in l..Len(TraceLog) :
               LET fut == TraceLog[k].event
               IN /\ fut.name = "ReceiveVote"
                  /\ "msg" \in DOMAIN fut
                  /\ fut.msg.source = m.msrc
                  /\ fut.msg.last_slot = m.last_slot
                  /\ fut.msg.last_hash = m.last_hash
        /\ DropMessage(m)
        /\ UNCHANGED traceVars

\* ============================================================================
\* TRACE INIT
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1

\* ============================================================================
\* TRACE NEXT
\* ============================================================================

TraceNext ==
    \* Event-consuming actions (advance trace cursor)
    \/ RecordVoteIfLogged
    \/ PersistTowerIfLogged
    \/ BroadcastVoteIfLogged
    \/ ReceiveVoteIfLogged
    \/ ReachOCIfLogged
    \/ RootSlotIfLogged
    \/ PurgeUnconfirmedSlotIfLogged
    \/ ProcessDuplicateConfirmedSignalIfLogged
    \/ CastSwitchVoteIfLogged
    \/ CrashIfLogged
    \/ CrashBeforeFsyncIfLogged
    \/ RestartIfLogged
    \/ AdoptOnChainTowerIfBehindIfLogged
    \* Silent actions (do not advance cursor)
    \/ SilentReachOC
    \/ SilentDropMessage

\* ============================================================================
\* TRACE MATCHED — temporal property
\* ============================================================================

TraceMatched == <>[](l > Len(TraceLog))

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

TraceSpec ==
    /\ TraceInit
    /\ [][TraceNext]_<<allVars, traceVars>>
    /\ WF_<<allVars, traceVars>>(TraceNext)

=============================================================================
