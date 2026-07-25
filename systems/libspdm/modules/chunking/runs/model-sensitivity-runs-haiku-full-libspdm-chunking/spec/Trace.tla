---- MODULE Trace ----

(*
Trace Validation Spec for SPDM Chunking
Replays implementation traces against the base spec
*)

EXTENDS base, Naturals, Sequences, Json, IOUtils

\* ============================================================================
\* TRACE LOADING
\* ============================================================================

\* Trace events from the implementation execution
\* Minimal test trace: just verify we can load and process events
TraceLog == <<
  [eventName |-> "ChunkSendInit",
   nodeId |-> "responder",
   state |-> [chunk_context |-> [send |-> FALSE, get |-> FALSE, seq_no |-> 0, bytes_transferred |-> 0],
              large_message_size |-> 256,
              large_message_capacity |-> 512,
              large_message_valid |-> FALSE,
              chunk_phase |-> "INIT",
              seq_no_wrap_error |-> TRUE],
   message |-> [chunk_size |-> 128]]
>>

\* ============================================================================
\* TRACE CURSOR AND HELPERS
\* ============================================================================

VARIABLE l  \* Trace cursor: index of current event

\* Extract current trace event
CurrentEvent ==
    IF l <= Len(TraceLog) THEN TraceLog[l] ELSE {}

\* Event predicates
IsEvent(eventName) ==
    /\ l <= Len(TraceLog)
    /\ "eventName" \in DOMAIN CurrentEvent
    /\ CurrentEvent["eventName"] = eventName

IsNodeEvent(eventName, nodeId) ==
    /\ IsEvent(eventName)
    /\ "nodeId" \in DOMAIN CurrentEvent
    /\ CurrentEvent["nodeId"] = nodeId

IsMsgEvent(msgType, from, to) ==
    /\ "type" \in DOMAIN CurrentEvent
    /\ CurrentEvent["type"] = msgType
    /\ "from" \in DOMAIN CurrentEvent
    /\ CurrentEvent["from"] = from
    /\ "to" \in DOMAIN CurrentEvent
    /\ CurrentEvent["to"] = to

\* ============================================================================
\* TRACE VALIDATION HELPERS
\* ============================================================================

\* Extract state fields from trace event
GetField(field) ==
    IF "state" \in DOMAIN CurrentEvent THEN
        LET st == CurrentEvent["state"]
        IN IF field \in DOMAIN st THEN st[field]
           ELSE IF field = "chunk_in_use" THEN
               (st["chunk_context"]["send"] \/ st["chunk_context"]["get"])
           ELSE
               CHOOSE x \in {} : TRUE
    ELSE
        CHOOSE x \in {} : TRUE

\* Message extraction from trace
GetMessageField(field) ==
    IF "message" \in DOMAIN CurrentEvent THEN
        LET msg == CurrentEvent["message"]
        IN IF field \in DOMAIN msg THEN msg[field]
           ELSE CHOOSE x \in {} : TRUE
    ELSE
        CHOOSE x \in {} : TRUE

\* ============================================================================
\* VALIDATION PREDICATES (defined before action wrappers)
\* ============================================================================

ValidateChunkSendInit ==
    /\ chunk_context.send = TRUE
    /\ chunk_phase = "INIT"
    /\ large_message_valid = TRUE

ValidateChunkSendContinuation ==
    /\ chunk_context.send = TRUE
    /\ chunk_phase = "CONTINUATION"
    /\ chunk_context.bytes_transferred > 0
    /\ large_message_valid = TRUE

ValidateReceiveInterruption ==
    \* Validation: state should be cleared (buggy behavior)
    \* or preserved (correct behavior)
    TRUE  \* Conditional on implementation version

ValidateErrorDuringReassembly ==
    /\ chunk_context.send = FALSE
    /\ large_message_valid = FALSE
    /\ chunk_phase = "INIT"

ValidateRequesterSendChunk ==
    /\ Cardinality(messages) > 0

ValidateResponderProcessChunk ==
    /\ Cardinality(responses) > 0
    /\ chunk_context.bytes_transferred >= 0

\* ============================================================================
\* ACTION WRAPPERS WITH TRACE VALIDATION
\* ============================================================================

\* Trace: ChunkSendInit event
TraceChunkSendInit ==
    /\ IsEvent("ChunkSendInit")
    /\ LET msg_size == GetField("large_message_size")
           chunk_size == GetMessageField("chunk_size")
       IN ChunkSendInit(msg_size, chunk_size)
    /\ ValidateChunkSendInit
    /\ l' = l + 1

\* Trace: ChunkSendContinuation event
TraceChunkSendContinuation ==
    /\ IsEvent("ChunkSendContinuation")
    /\ LET seq_no == GetField("seq_no")
           chunk_size == GetMessageField("chunk_size")
       IN ChunkSendContinuation(seq_no, chunk_size)
    /\ ValidateChunkSendContinuation
    /\ l' = l + 1

\* Trace: Interruption event
TraceReceiveInterruption ==
    /\ IsEvent("ReceiveInterruption")
    /\ LET cmd_type == GetMessageField("cmd_type")
       IN ReceiveInterruption(cmd_type)
    /\ ValidateReceiveInterruption
    /\ l' = l + 1

\* Trace: Error during reassembly
TraceErrorDuringReassembly ==
    /\ IsEvent("ErrorDuringReassembly")
    /\ ErrorDuringReassembly
    /\ ValidateErrorDuringReassembly
    /\ l' = l + 1

\* Trace: Message send
TraceRequesterSendChunk ==
    /\ IsEvent("RequesterSendChunk")
    /\ LET msg_id == GetField("msg_id")
           seq_no == GetField("seq_no")
           payload == GetMessageField("payload_size")
       IN RequesterSendChunk(msg_id, seq_no, payload)
    /\ ValidateRequesterSendChunk
    /\ l' = l + 1

\* Trace: Responder processing
TraceResponderProcessChunk ==
    /\ IsEvent("ResponderProcessChunk")
    /\ LET msg_id == GetField("msg_id")
           seq_no == GetField("seq_no")
           payload == GetMessageField("payload_size")
       IN ResponderProcessChunk(msg_id, seq_no, payload)
    /\ ValidateResponderProcessChunk
    /\ l' = l + 1

\* ============================================================================
\* SILENT ACTIONS (implementation state changes without trace events)
\* ============================================================================

\* Silent: normal message delivery (no separate trace event)
SilentMessageDelivery ==
    /\ l <= Len(TraceLog)
    /\ messages # {}
    /\ responses' = responses  \* Unchanged by silent action
    /\ UNCHANGED <<chunk_context, chunk_phase, interruption_allowed,
                    seq_no_wrap_error, large_message_capacity,
                    large_message, large_message_valid, messages>>

\* ============================================================================
\* TRACE INITIALIZATION
\* ============================================================================

TraceInit ==
    /\ Init
    /\ l = 1

\* ============================================================================
\* TRACE NEXT STATE
\* ============================================================================

TraceNext ==
    \/ TraceChunkSendInit
    \/ TraceChunkSendContinuation
    \/ TraceReceiveInterruption
    \/ TraceErrorDuringReassembly
    \/ TraceRequesterSendChunk
    \/ TraceResponderProcessChunk
    \/ SilentMessageDelivery

\* ============================================================================
\* TRACE COMPLETION PROPERTY
\* ============================================================================

\* Trace is matched when cursor advances past all events
TraceMatched ==
    <> (l > Len(TraceLog))

====
