------------------------------ MODULE Trace ------------------------------
(*
 * Trace validation spec for the SPDM MEL paged-transfer protocol.
 * Category A (single linear trace from a run of libspdm).
 *
 * Drives TLC through a recorded execution trace (NDJSON), verifying that
 * the base spec can reproduce every observed state transition.
 *)

EXTENDS base, Naturals, Sequences, TLC, IOUtils, Json

\* =============================================================
\* Trace loading
\* =============================================================

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* Cursor variable: walks through trace events 1..Len(TraceLog)
VARIABLE l

\* =============================================================
\* Event predicate
\* =============================================================

IsActionEvent(name) == l <= Len(TraceLog) /\ TraceLog[l].event = name

\* =============================================================
\* Value mapping from implementation wire values to spec constants
\* =============================================================

WireToMelSpec(w) ==
    IF w = 1 THEN MEL_SPEC_DMTF
    ELSE IF w = 3 THEN MEL_SPEC_INVALID
    ELSE MEL_SPEC_UNSET   \* 0 and any unrecognised value

\* =============================================================
\* TraceInit
\* Bootstrap state matches libspdm initial state before any exchange.
\* =============================================================

TraceInit ==
    /\ Init
    /\ l = 1

\* =============================================================
\* Action wrappers
\* Pattern: match event → call base action → l' = l + 1
\* The base action's primed assignments constrain next state;
\* additional field checks below validate trace consistency.
\* =============================================================

\* ---- NegotiateAlgorithmsWithSessionCap ----
TraceNegotiateWithSessionCap ==
    /\ IsActionEvent("negotiate_algorithms")
    /\ TraceLog[l].has_session_cap = TRUE
    /\ LET w == WireToMelSpec(TraceLog[l].mel_spec_wire)
       IN NegotiateAlgorithmsWithSessionCap(w)
    \* Post-state: stored mel_spec and conn_state must match trace
    /\ mel_spec_conn' = WireToMelSpec(TraceLog[l].mel_spec_wire)
    /\ l' = l + 1

\* ---- NegotiateAlgorithmsWithoutSessionCap ----
TraceNegotiateWithoutSessionCap ==
    /\ IsActionEvent("negotiate_algorithms")
    /\ TraceLog[l].has_session_cap = FALSE
    /\ LET w == WireToMelSpec(TraceLog[l].mel_spec_wire)
       IN NegotiateAlgorithmsWithoutSessionCap(w)
    \* Post-state: raw unvalidated value must match trace (bypass path)
    /\ mel_spec_conn' = WireToMelSpec(TraceLog[l].mel_spec_wire)
    /\ l' = l + 1

\* ---- MelUpdate ----
TraceMelUpdate ==
    /\ IsActionEvent("mel_update")
    /\ MelUpdate
    \* Post-state: generation must have incremented by exactly 1; new mel_size matches
    /\ mel_generation' = TraceLog[l].mel_generation
    /\ mel_size' = TraceLog[l].mel_size
    /\ l' = l + 1

\* ---- SendGetMelFirstChunk ----
TraceSendGetMelFirstChunk ==
    /\ IsActionEvent("send_get_mel_first_chunk")
    /\ SendGetMelFirstChunk
    /\ req_offset' = 0
    /\ req_length' = TraceLog[l].req_length
    /\ l' = l + 1

\* ---- RespondGetMelFirstChunk ----
TraceRespondGetMelFirstChunk ==
    /\ IsActionEvent("respond_get_mel_first_chunk")
    /\ LET p == TraceLog[l].portion_length
       IN RespondGetMelFirstChunk(p)
    /\ rsp_portion_len' = TraceLog[l].portion_length
    /\ rsp_remainder'   = TraceLog[l].remainder_length
    /\ rsp_generation'  = TraceLog[l].mel_generation
    /\ l' = l + 1

\* ---- ProcessGetMelFirstChunkResp ----
TraceProcessGetMelFirstChunkResp ==
    /\ IsActionEvent("process_mel_first_chunk_resp")
    /\ ProcessGetMelFirstChunkResp
    /\ mel_offset'        = TraceLog[l].mel_offset
    /\ first_portion_len' = TraceLog[l].first_portion_len
    /\ l' = l + 1

\* ---- SendGetMelNextChunk ----
TraceSendGetMelNextChunk ==
    /\ IsActionEvent("send_get_mel_next_chunk")
    /\ SendGetMelNextChunk
    /\ req_offset' = TraceLog[l].req_offset
    /\ l' = l + 1

\* ---- RespondGetMelNextChunk ----
TraceRespondGetMelNextChunk ==
    /\ IsActionEvent("respond_get_mel_next_chunk")
    /\ LET p == TraceLog[l].portion_length
       IN RespondGetMelNextChunk(p)
    /\ rsp_portion_len' = TraceLog[l].portion_length
    /\ rsp_remainder'   = TraceLog[l].remainder_length
    /\ rsp_generation'  = TraceLog[l].mel_generation
    /\ l' = l + 1

\* ---- ProcessGetMelNextChunkResp ----
TraceProcessGetMelNextChunkResp ==
    /\ IsActionEvent("process_mel_next_chunk_resp")
    /\ ProcessGetMelNextChunkResp
    /\ mel_offset' = TraceLog[l].mel_offset
    /\ l' = l + 1

\* =============================================================
\* Silent actions
\*
\* This protocol is single-threaded synchronous: every significant
\* state change is directly instrumented. No silent actions needed.
\* =============================================================

\* =============================================================
\* TraceNext
\* =============================================================

TraceNext ==
    \/ TraceNegotiateWithSessionCap
    \/ TraceNegotiateWithoutSessionCap
    \/ TraceMelUpdate
    \/ TraceSendGetMelFirstChunk
    \/ TraceRespondGetMelFirstChunk
    \/ TraceProcessGetMelFirstChunkResp
    \/ TraceSendGetMelNextChunk
    \/ TraceRespondGetMelNextChunk
    \/ TraceProcessGetMelNextChunkResp
    \* Stuttering once trace is fully consumed
    \/ (l > Len(TraceLog) /\ UNCHANGED <<vars, l>>)

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, l>>

\* =============================================================
\* Liveness: entire trace must be consumed
\* =============================================================

TraceMatched == <>(l > Len(TraceLog))

\* =============================================================
\* Invariants (checked during trace validation)
\*
\* Include: invariants that must hold on every real execution.
\* Exclude: fault-injection invariants (MelConsistency, MelHeaderComplete, etc.)
\*   — those require fault injection active; real traces run without forced faults.
\* =============================================================

TraceTypeOK    == TypeOK
TraceChannelOK == ChannelOK

======================================================================
