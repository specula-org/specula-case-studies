---- MODULE MC ----

(*
Model Checking wrapper for SPDM chunking.
Adds counter-bounded fault injection and bounded message handling.
*)

EXTENDS base, Naturals

\* ============================================================================
\* FAULT INJECTION COUNTER VARIABLES
\* ============================================================================

VARIABLE faultCounters

faultVars == <<faultCounters>>

\* ============================================================================
\* COUNTER-BOUNDED FAULT INJECTIONS
\* ============================================================================

\* Timeout: trigger a new chunk transfer or interruption
MCTimeout(limit) ==
    /\ faultCounters.timeoutCount < limit
    /\ \E cmd_type \in {"GET_VERSION", "DecryptError", "OTHER"}:
           RequesterSendInterruption(cmd_type)
    /\ faultCounters' = [faultCounters EXCEPT !.timeoutCount = @ + 1]
    /\ UNCHANGED <<chunk_context, chunk_phase, interruption_allowed,
                    seq_no_wrap_error, large_message_capacity,
                    large_message, large_message_valid, messages, responses>>

\* Loss: drop a message from the network
MCLoss(limit) ==
    /\ faultCounters.lossCount < limit
    /\ messages # {}
    /\ \E msg \in messages:
           messages' = messages \ {msg}
    /\ faultCounters' = [faultCounters EXCEPT !.lossCount = @ + 1]
    /\ UNCHANGED <<chunk_context, chunk_phase, interruption_allowed,
                    seq_no_wrap_error, large_message_capacity,
                    large_message, large_message_valid, responses>>

\* Crash: lose in-flight state (timeout recovery)
MCCrash(limit) ==
    /\ faultCounters.crashCount < limit
    /\ chunk_context.send = TRUE \/ chunk_context.get = TRUE
    /\ chunk_context' = [chunk_context EXCEPT
                          !.send = FALSE,
                          !.get = FALSE,
                          !.seq_no = 0,
                          !.bytes_transferred = 0]
    /\ large_message' = <<>>
    /\ large_message_valid' = FALSE
    /\ faultCounters' = [faultCounters EXCEPT !.crashCount = @ + 1]
    /\ UNCHANGED <<chunk_phase, interruption_allowed, seq_no_wrap_error,
                    large_message_capacity, messages, responses>>

\* ============================================================================
\* CONSTRAINED WRAPPERS (deterministic actions + counter bounds)
\* ============================================================================

MCChunkSendInit(limit, msg_size, chunk_size) ==
    /\ faultCounters.initCount < limit
    /\ ChunkSendInit(msg_size, chunk_size)
    /\ faultCounters' = [faultCounters EXCEPT !.initCount = @ + 1]

MCChunkSendContinuation(limit, chunk_seq, chunk_size) ==
    /\ faultCounters.contCount < limit
    /\ ChunkSendContinuation(chunk_seq, chunk_size)
    /\ faultCounters' = [faultCounters EXCEPT !.contCount = @ + 1]

\* ============================================================================
\* MC INITIALIZATION
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultCounters = [
         timeoutCount |-> 0,
         lossCount |-> 0,
         crashCount |-> 0,
         initCount |-> 0,
         contCount |-> 0
       ]

\* ============================================================================
\* MC NEXT STATE WITH BOUNDED ACTIONS
\* ============================================================================

MCNext ==
    \/ MCTimeout(3)
    \/ MCLoss(3)
    \/ MCCrash(2)
    \/ \E msg_size, chunk_size \in 1..MaxChunkSize: MCChunkSendInit(4, msg_size, chunk_size)
    \/ \E seq_no, chunk_size \in 0..MaxChunkSize: MCChunkSendContinuation(4, seq_no, chunk_size)
    \/ \E cmd_type \in {"GET_VERSION", "DecryptError", "OTHER"}: ReceiveInterruption(cmd_type)
    \/ ErrorDuringReassembly
    \/ \E msg_id, seq_no, payload \in 1..MaxChunkSize: RequesterSendChunk(msg_id, seq_no, payload)
    \/ \E msg_id, seq_no, payload \in 1..MaxChunkSize: ResponderProcessChunk(msg_id, seq_no, payload)
    \/ \E cmd_type \in {"GET_VERSION", "DecryptError", "OTHER"}: ResponderReceiveInterruption(cmd_type)

\* ============================================================================
\* STATE SPACE CONSTRAINTS
\* ============================================================================

\* Bound message buffer size for tractability
MessageBufferConstraint ==
    Cardinality(messages) <= 4

====
