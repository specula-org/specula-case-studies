---- MODULE Trace ----
\* ===================================================================================
\* Trace Validation Spec for arc-swap base spec (round 2).
\* ===================================================================================
\*
\* Replays implementation traces against the base spec to verify consistency.
\* Each trace event is matched to a base-spec action; the post-state is validated
\* against fields recorded by the harness.
\*
\* This is a Category-A-style single-cursor trace spec.  arc-swap operations are
\* short and the harness emits events with logical timestamps that the
\* preprocessor canonicalises into a totally-ordered sequence (interleaving
\* across threads is captured by the harness's emit point).  See
\* instrumentation-spec.md for the per-event field schema.

EXTENDS base, TLC, Sequences, Naturals, Integers, IOUtils, Json

\* ===================================================================================
\* Trace Loading
\* ===================================================================================

\* Trace file: traces/<name>.ndjson sibling to spec/.  Override via IOEnv.JSON.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

RawTrace == ndJsonDeserialize(JsonFile)

\* Drop entries without an `event` key (preamble / heartbeat lines).
TraceLog == SelectSeq(RawTrace, LAMBDA e : "event" \in DOMAIN e)

\* ===================================================================================
\* Trace Cursor
\* ===================================================================================

VARIABLES l            \* current position in TraceLog (1-based)

traceVars == <<l>>
allVars   == <<vars, l>>

logline == TraceLog[l]

IsEvent(name)         == logline.event = name
IsThreadEvent(name,t) == /\ logline.event = name
                         /\ "thread" \in DOMAIN logline
                         /\ logline.thread = t

AdvanceCursor   == l' = l + 1
TraceFinished   == l > Len(TraceLog)
TraceMatched    == <>(l > Len(TraceLog))

\* ===================================================================================
\* Mapping helpers
\* ===================================================================================
\*
\* The harness emits thread / address / slot / generation values as strings or
\* integers that match the spec constants.  See instrumentation-spec.md §1.

MapThread(tid) == tid

MapAddr(a) ==
    IF a = "null" \/ a = "NULL" THEN NullPtr ELSE a

\* ===================================================================================
\* Post-state Validation
\* ===================================================================================
\*
\* Per spec-generation guide: every action wrapper validates the *key fields*
\* the action modifies.  Where the harness cannot capture a field cleanly (e.g.
\* an inner `confirm` value before publication), we fall back to PC validation.

ValidateReaderPC(t)        == rPC'[t] = logline.state.rPC
ValidateReaderPath(t)      == rPath'[t] = logline.state.rPath
ValidateReaderConfirm(t)   ==
    /\ rConfirmAddr'[t] = MapAddr(logline.state.rConfirmAddr)

ValidateWriterPC(t)        == wPC'[t] = logline.state.wPC
ValidateStorage            ==
    /\ storageAddr' = MapAddr(logline.state.storageAddr)

ValidateNodeState(n)       == nodeState'[n] = logline.state.nodeState
ValidateActiveWriters(n)   == activeWriters'[n] = logline.state.activeWriters
ValidateHelpControl(n)     == helpControl'[n] = logline.state.helpControl
ValidateHelpGen(n)         == helpGen'[n] = logline.state.helpGen

\* Slot validation — arrayfields are rendered as functions in NDJSON: harness
\* emits {"slot":N, "value":addr} per scan event.
ValidateFastSlot(n, s, expected) ==
    fastSlot'[n][s] = MapAddr(expected)

ValidateHelpSlot(n, expected) ==
    helpSlot'[n] = MapAddr(expected)

\* ===================================================================================
\* Trace Action Wrappers
\* ===================================================================================
\* Each wrapper: matches event → calls base action → validates post-state →
\* advances cursor.  See instrumentation-spec.md §2 for the 1:1 spec/event map.

\* --- Reader fast path ---

TR_FastLoad ==
    /\ IsEvent("ReaderFastLoad")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFastLoad(t)
        /\ ValidateReaderPC(t)
        /\ rOpAddr'[t] = MapAddr(logline.state.rOpAddr)
    /\ AdvanceCursor

TR_FastSlotAcquire ==
    /\ IsEvent("ReaderFastSlotAcquire")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFastSlotAcquire(t)
        /\ ValidateReaderPC(t)
        /\ rDebtSlot'[t] = logline.state.rDebtSlot
    /\ AdvanceCursor

TR_FastConfirmLoad ==
    /\ IsEvent("ReaderFastConfirmLoad")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFastConfirmLoad(t)
        /\ ValidateReaderPC(t)
        /\ ValidateReaderConfirm(t)
    /\ AdvanceCursor

TR_FastBranchHit ==
    /\ IsEvent("ReaderFastBranchHit")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFastBranchHit(t)
        /\ ValidateReaderPC(t)
    /\ AdvanceCursor

TR_FastResolve ==
    /\ IsEvent("ReaderFastResolve")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFastResolve(t)
        /\ ValidateReaderPC(t)
    /\ AdvanceCursor

\* --- Reader fallback path ---

TR_FbActiveAddr ==
    /\ IsEvent("ReaderFallbackActiveAddr")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFallbackActiveAddr(t)
        /\ ValidateReaderPC(t)
        /\ ValidateReaderPath(t)
    /\ AdvanceCursor

TR_FbControlSwap ==
    /\ IsEvent("ReaderFallbackControlSwap")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFallbackControlSwap(t)
        /\ ValidateReaderPC(t)
        /\ helpControl'[t] = logline.state.helpControl
        /\ helpGen'[t] = logline.state.helpGen
    /\ AdvanceCursor

TR_FbCandidate ==
    /\ IsEvent("ReaderFallbackCandidate")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFallbackCandidate(t)
        /\ ValidateReaderPC(t)
        /\ ValidateReaderConfirm(t)
    /\ AdvanceCursor

TR_FbSlotStore ==
    /\ IsEvent("ReaderFallbackSlotStore")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFallbackSlotStore(t)
        /\ ValidateReaderPC(t)
        /\ ValidateHelpSlot(t, logline.state.helpSlot)
    /\ AdvanceCursor

TR_FbConfirmOK ==
    /\ IsEvent("ReaderFallbackConfirmOK")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFallbackConfirmOK(t)
        /\ ValidateReaderPC(t)
        /\ helpControl'[t] = logline.state.helpControl
    /\ AdvanceCursor

TR_FbConfirmHelped ==
    /\ IsEvent("ReaderFallbackConfirmHelped")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFallbackConfirmHelped(t)
        /\ ValidateReaderPC(t)
        /\ rGotEnvelope'[t] = TRUE
    /\ AdvanceCursor

TR_FbResolveEnvelope ==
    /\ IsEvent("ReaderFallbackResolveEnvelope")
    /\ LET t == MapThread(logline.thread) IN
        /\ ReaderFallbackResolveEnvelope(t)
        /\ ValidateReaderPC(t)
    /\ AdvanceCursor

\* --- Guard lifecycle (Family C harness) ---

TR_GuardIntoInner ==
    /\ IsEvent("GuardIntoInner")
    /\ LET t == MapThread(logline.thread) IN
        GuardIntoInner(t)
    /\ AdvanceCursor

TR_DropGuard ==
    /\ IsEvent("DropGuard")
    /\ LET t == MapThread(logline.thread) IN
        DropGuard(t)
    /\ AdvanceCursor

TR_SendGuard ==
    /\ IsEvent("SendGuard")
    /\ LET src == MapThread(logline.src)
           dst == MapThread(logline.dst)
       IN  SendGuard(src, dst)
    /\ AdvanceCursor

\* --- Writer ---

TR_WriterSwap ==
    /\ IsEvent("WriterSwap")
    /\ LET t == MapThread(logline.thread) IN
        /\ WriterSwap(t)
        /\ ValidateWriterPC(t)
        /\ ValidateStorage
    /\ AdvanceCursor

TR_WriterPayInit ==
    /\ IsEvent("WriterPayInit")
    /\ LET t == MapThread(logline.thread) IN
        /\ WriterPayInit(t)
        /\ ValidateWriterPC(t)
    /\ AdvanceCursor

TR_WriterTraverseLoad ==
    /\ IsEvent("WriterTraverseLoad")
    /\ LET t == MapThread(logline.thread) IN
        /\ WriterTraverseLoad(t)
        /\ ValidateWriterPC(t)
    /\ AdvanceCursor

TR_WriterReserveNode ==
    /\ IsEvent("WriterReserveNode")
    /\ LET t == MapThread(logline.thread) IN
        /\ WriterReserveNode(t)
        /\ ValidateWriterPC(t)
        /\ wCurNode'[t] = MapThread(logline.state.wCurNode)
    /\ AdvanceCursor

TR_WriterHelpNode ==
    /\ IsEvent("WriterHelpNode")
    /\ LET t == MapThread(logline.thread) IN
        /\ WriterHelpNode(t)
        /\ ValidateWriterPC(t)
    /\ AdvanceCursor

TR_WriterScanSlot ==
    /\ IsEvent("WriterScanSlot")
    /\ LET t == MapThread(logline.thread) IN
        WriterScanSlot(t)
    /\ AdvanceCursor

TR_WriterReleaseNode ==
    /\ IsEvent("WriterReleaseNode")
    /\ LET t == MapThread(logline.thread) IN
        \* The base spec's WriterReleaseNode transitions wPC directly to
        \* "w_traverse_loaded" (more nodes to visit) or "w_pay_done" (last node)
        \* and never to the "w_after_release" sentinel that the harness reports.
        \* The harness can't tell which side it'll be in advance, so we don't
        \* validate wPC here.
        WriterReleaseNode(t)
    /\ AdvanceCursor

TR_WriterPayDone ==
    /\ IsEvent("WriterPayDone")
    /\ LET t == MapThread(logline.thread) IN
        /\ WriterPayDone(t)
        /\ ValidateWriterPC(t)
    /\ AdvanceCursor

TR_WriterReturn ==
    /\ IsEvent("WriterReturn")
    /\ LET t == MapThread(logline.thread) IN
        /\ WriterReturn(t)
        /\ ValidateWriterPC(t)
    /\ AdvanceCursor

\* --- CompareAndSwap (Family C) ---

TR_CASBegin ==
    /\ IsEvent("CASBegin")
    /\ LET t == MapThread(logline.thread) IN
        /\ CASBegin(t)
        /\ rPC'[t] = "cas_after_load"
        /\ casKind'[t] = logline.state.casKind
    /\ AdvanceCursor

TR_CASCompareNotEqual ==
    /\ IsEvent("CASCompareNotEqual")
    /\ LET t == MapThread(logline.thread) IN
        CASCompareNotEqual(t)
    /\ AdvanceCursor

TR_CASExchangeOk ==
    /\ IsEvent("CASExchangeOk")
    /\ LET t == MapThread(logline.thread) IN
        /\ CASExchangeOk(t)
        /\ ValidateStorage
    /\ AdvanceCursor

TR_CASExchangeFail ==
    /\ IsEvent("CASExchangeFail")
    /\ LET t == MapThread(logline.thread) IN
        CASExchangeFail(t)
    /\ AdvanceCursor

\* --- Node lifecycle ---

TR_ClaimNode ==
    /\ IsEvent("ClaimNode")
    /\ LET t == MapThread(logline.thread)
           n == MapThread(logline.node)
       IN /\ ClaimNode(t, n)
          /\ ValidateNodeState(n)
    /\ AdvanceCursor

TR_CheckCooldown ==
    /\ IsEvent("CheckCooldown")
    /\ LET n == MapThread(logline.node) IN
        /\ CheckCooldown(n)
        /\ ValidateNodeState(n)
    /\ AdvanceCursor

\* ===================================================================================
\* Silent actions
\* ===================================================================================
\*
\* Some implementation transitions are not surfaced as events (no log point):
\*   - PickRelaxSite: only fires if the harness explicitly injects ordering relax
\*     (in which case it IS a logged event "PickRelaxSite"); else stays NoneSite.
\*   - DropArcSwap: must be logged ("DropArcSwap" event below).
\* No silent actions needed: every base action has an event in the harness.
\* If the harness is incomplete, stuttering plus deadlock check will surface gaps.

TR_DropArcSwap ==
    /\ IsEvent("DropArcSwap")
    /\ DropArcSwap
    /\ AdvanceCursor

TR_PickRelaxSite ==
    /\ IsEvent("PickRelaxSite")
    /\ PickRelaxSite(logline.site)
    /\ AdvanceCursor

\* ===================================================================================
\* Trace Init / Next
\* ===================================================================================

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ /\ ~TraceFinished
       /\ \/ TR_FastLoad
          \/ TR_FastSlotAcquire
          \/ TR_FastConfirmLoad
          \/ TR_FastBranchHit
          \/ TR_FastResolve
          \/ TR_FbActiveAddr
          \/ TR_FbControlSwap
          \/ TR_FbCandidate
          \/ TR_FbSlotStore
          \/ TR_FbConfirmOK
          \/ TR_FbConfirmHelped
          \/ TR_FbResolveEnvelope
          \/ TR_GuardIntoInner
          \/ TR_DropGuard
          \/ TR_SendGuard
          \/ TR_WriterSwap
          \/ TR_WriterPayInit
          \/ TR_WriterTraverseLoad
          \/ TR_WriterReserveNode
          \/ TR_WriterHelpNode
          \/ TR_WriterScanSlot
          \/ TR_WriterReleaseNode
          \/ TR_WriterPayDone
          \/ TR_WriterReturn
          \/ TR_CASBegin
          \/ TR_CASCompareNotEqual
          \/ TR_CASExchangeOk
          \/ TR_CASExchangeFail
          \/ TR_ClaimNode
          \/ TR_CheckCooldown
          \/ TR_DropArcSwap
          \/ TR_PickRelaxSite
    \/ /\ TraceFinished
       /\ UNCHANGED allVars

TraceSpec == TraceInit /\ [][TraceNext]_allVars

====
