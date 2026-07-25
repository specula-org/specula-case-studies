---- MODULE MC ----
\* Model-checking wrapper for the libspdm chunking / reassembly spec.
\* Wraps fault-injection actions with per-action counters.
\* Deterministic / reactive actions pass through unchanged.
\*
\* Usage: tlc -config MC.cfg MC
\*
\* Normal convergence run: use MC.cfg (extension invariants commented out).
\* Bug-hunting runs: use MC_hunt_<family>.cfg (tight bounds, targeted invariant).

EXTENDS base

\* ------------------------------------------------------------------
\* Counter record — one field per non-deterministic action
\* ------------------------------------------------------------------
VARIABLE faultCounts

MCFaultCountsInit ==
    faultCounts = [
        sourceBound     |-> 0,    \* Family 4: unbounded chunk_size accepted
        midSendChunkGet |-> 0,    \* Family 5: CHUNK_GET during active SEND
        invalidSeqNo    |-> 0,    \* Family 2: seq-no mismatch path
        bufferOverflow  |-> 0     \* Family 3: transfer complete, buffer too small
    ]

\* ------------------------------------------------------------------
\* Tuning constants (overridden by .cfg files)
\* ------------------------------------------------------------------
CONSTANTS
    MaxSourceBoundFaults,    \* bound on Family-4 fault firings
    MaxMidSendChunkGet,      \* bound on Family-5 fault firings
    MaxInvalidSeqNo,         \* bound on Family-2 fault firings
    MaxBufferOverflow,       \* bound on Family-3 fault firings
    MaxMsgBuffer             \* message buffer bound (state-space control)

\* ------------------------------------------------------------------
\* MCInit
\* ------------------------------------------------------------------
MCInit ==
    /\ Init
    /\ MCFaultCountsInit

\* ------------------------------------------------------------------
\* Counter-bounded wrappers for fault-injection actions
\* ------------------------------------------------------------------

\* Family 4 — SourceLengthUnboundedInReassemblyCopy
MCRequesterProcessChunkResponseSourceUnbounded ==
    /\ faultCounts.sourceBound < MaxSourceBoundFaults
    /\ RequesterProcessChunkResponseSourceUnbounded
    /\ faultCounts' = [faultCounts EXCEPT !.sourceBound = @ + 1]

\* Family 5 — MutualExclusionAsymmetry: CHUNK_GET while SEND in progress
MCResponderServesChunkGetWhileSendInProgress ==
    /\ faultCounts.midSendChunkGet < MaxMidSendChunkGet
    /\ ResponderServesChunkGetWhileSendInProgress
    /\ faultCounts' = [faultCounts EXCEPT !.midSendChunkGet = @ + 1]

\* Family 2 — ControlFlowOrderingSeqNoMismatch
MCResponderChunkSendReceivedInvalidSeqNo ==
    /\ faultCounts.invalidSeqNo < MaxInvalidSeqNo
    /\ ResponderChunkSendReceivedInvalidSeqNo
    /\ faultCounts' = [faultCounts EXCEPT !.invalidSeqNo = @ + 1]

\* Family 3 — ReassemblyOutputValidityAfterCompletion (buffer overflow path)
MCRequesterTransferCompleteBufferOverflow ==
    /\ faultCounts.bufferOverflow < MaxBufferOverflow
    /\ RequesterTransferCompleteBufferOverflow
    /\ faultCounts' = [faultCounts EXCEPT !.bufferOverflow = @ + 1]

\* ------------------------------------------------------------------
\* Pass-through wrappers for deterministic / reactive actions
\* (these do not introduce non-determinism, so no counter needed)
\* ------------------------------------------------------------------
MCResponderChunkSendReceivedFirstChunk ==
    /\ ResponderChunkSendReceivedFirstChunk
    /\ UNCHANGED faultCounts

MCResponderChunkSendReceivedValidSeqNo ==
    /\ ResponderChunkSendReceivedValidSeqNo
    /\ UNCHANGED faultCounts

MCResponderServesChunkGet ==
    /\ ResponderServesChunkGet
    /\ UNCHANGED faultCounts

MCRequesterReceivesLargeResponseError ==
    /\ RequesterReceivesLargeResponseError
    /\ UNCHANGED faultCounts

MCRequesterProcessChunkResponseValid ==
    /\ RequesterProcessChunkResponseValid
    /\ UNCHANGED faultCounts

MCRequesterTransferCompleteSuccess ==
    /\ RequesterTransferCompleteSuccess
    /\ UNCHANGED faultCounts

MCResponderLargeResponseReady(h, ls) ==
    /\ ResponderLargeResponseReady(h, ls)
    /\ UNCHANGED faultCounts

MCRequesterSendsFirstChunk(h, cs, ls) ==
    /\ ~get_in_use  \* responder rejects CHUNK_SEND when GET is active (rsp_chunk_send_ack.c:90-95)
    /\ RequesterSendsFirstChunk(h, cs, ls)
    /\ UNCHANGED faultCounts

MCRequesterSendsContinuationChunk(h, sn, cs, il, ts, ls) ==
    /\ send_in_use  \* continuation only after responder acknowledged first chunk
    /\ ~get_in_use  \* responder rejects CHUNK_SEND when GET is active
    /\ RequesterSendsContinuationChunk(h, sn, cs, il, ts, ls)
    /\ UNCHANGED faultCounts

\* ------------------------------------------------------------------
\* Message buffer constraint (state-space pruning)
\* ------------------------------------------------------------------
MCMsgBufConstraint ==
    BagCardinality(messages) <= MaxMsgBuffer

\* ------------------------------------------------------------------
\* MCNext
\* ------------------------------------------------------------------
MCNext ==
    \/ MCResponderChunkSendReceivedFirstChunk
    \/ MCResponderChunkSendReceivedValidSeqNo
    \/ MCResponderChunkSendReceivedInvalidSeqNo
    \/ MCResponderServesChunkGetWhileSendInProgress
    \/ MCResponderServesChunkGet
    \/ MCRequesterReceivesLargeResponseError
    \/ MCRequesterProcessChunkResponseValid
    \/ MCRequesterProcessChunkResponseSourceUnbounded
    \/ MCRequesterTransferCompleteSuccess
    \/ MCRequesterTransferCompleteBufferOverflow
    \/ \E h \in 0..3 : \E cs \in 1..MaxLargeSize : \E ls \in (cs+1)..MaxLargeSize :
           MCRequesterSendsFirstChunk(h, cs, ls)
    \/ \E h \in 0..3, sn \in 1..MaxChunks, cs \in 1..MaxLargeSize,
           il \in BOOLEAN, ts \in 0..MaxLargeSize, ls \in 1..MaxLargeSize :
           MCRequesterSendsContinuationChunk(h, sn, cs, il, ts, ls)
    \/ \E h \in 0..3, ls \in 1..MaxLargeSize :
           MCResponderLargeResponseReady(h, ls)

\* ------------------------------------------------------------------
\* Spec
\* ------------------------------------------------------------------
MCSpec == MCInit /\ [][MCNext]_<<vars, faultCounts>>

\* ------------------------------------------------------------------
\* Symmetry
\* ------------------------------------------------------------------
\* No server symmetry applicable here (single Requester/Responder pair).
\* Symmetry over handles can be added if handle set is enlarged.

\* Exclude fault counters from state view for symmetry reduction.
MCView == <<messages, sendVars, getVars, reqVars, protocolVars>>

\* ------------------------------------------------------------------
\* Structural invariants (always-on in MC.cfg)
\* ------------------------------------------------------------------
MCTypeOK == TypeOK
MCSendBytesInRange == SendBytesInRange
MCGetBytesInRange == GetBytesInRange
MCRequesterBytesInRange == RequesterBytesInRange
MCLargeMessageSizeConsistent == LargeMessageSizeConsistent

\* ------------------------------------------------------------------
\* Extension invariants (BUG-HUNTING — commented out in MC.cfg,
\* enabled in MC_hunt_<family>.cfg)
\* ------------------------------------------------------------------
MCTransferCompleteImpliesLastChunk == TransferCompleteImpliesLastChunk   \* Family 1
MCNoStateAdvanceOnSeqNoMismatch    == NoStateAdvanceOnSeqNoMismatch       \* Family 2
MCSuccessImpliesOutputWritten      == SuccessImpliesOutputWritten         \* Family 3
MCSourceBoundedness                == SourceBoundedness                   \* Family 4
MCSingleDirectionAtATime           == SingleDirectionAtATime              \* Family 5

====
