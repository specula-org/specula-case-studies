---- MODULE Trace ----
(**
 * Trace validation spec for libspdm VCA handshake.
 *
 * Category A (Distributed/Message-Passing): single global trace cursor `l`.
 *
 * Usage:
 *   tlc Trace -config Trace.cfg -workers auto
 *
 * Trace file location: ../traces/trace.ndjson (override with IOEnv.JSON)
 *)
EXTENDS base, Sequences, Naturals, TLC, IOUtils, Json

----
\* ------------------------------------------------------------------
\*  TRACE LOADING
\* ------------------------------------------------------------------

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

TraceLog == ndJsonDeserialize(JsonFile)

\* Cursor variable: l ∈ 1..Len(TraceLog)+1
VARIABLES l

traceVars == <<vars, l>>

----
\* ------------------------------------------------------------------
\*  HELPERS
\* ------------------------------------------------------------------

IsEvent(name) ==
    /\ l \leq Len(TraceLog)
    /\ TraceLog[l].event = name

IsEventWithField(name, field, value) ==
    /\ IsEvent(name)
    /\ TraceLog[l][field] = value

\* Map trace version strings to spec constants
TraceVersion(v_str) ==
    CASE v_str = "1.0" -> Ver10
      [] v_str = "1.1" -> Ver11
      [] v_str = "1.2" -> Ver12
      [] v_str = "1.3" -> Ver13
      [] v_str = "1.4" -> Ver14
      [] OTHER         -> Ver10  \* safe default

\* Map trace algo value (0 or non-zero) to spec constant
TraceAlgo(v) == IF v = 0 THEN ALGO_NONE ELSE ALGO_SOME

\* Map trace capability flags (JSON array → TLA+ set)
TraceCapFlags(flag_names) == {flag_names[i] : i \in DOMAIN flag_names}

\* Map trace alg_types array to spec set
TraceAlgTypes(arr) == { x \in AllAlgTypes : arr[x] = TRUE }

----
\* ------------------------------------------------------------------
\*  POST-STATE VALIDATION
\* ------------------------------------------------------------------

\* After ReqHandleVersion: check conn_state and negotiated_version
ValidatePostVersion ==
    LET logline == TraceLog[l] IN
    /\ conn_state' = AFTER_VERSION
    /\ negotiated_version' = TraceVersion(logline.negotiated_version)

\* After RspHandleGetCapabilities / ReqHandleCapabilities: check conn_state and flags
ValidatePostCapabilities ==
    LET logline == TraceLog[l] IN
    /\ conn_state' = AFTER_CAPS
    /\ rsp_cap_flags' = TraceCapFlags(logline.rsp_cap_flags)

\* After ReqHandleAlgorithms / RspHandleNegotiateAlgorithms: check negotiated state
ValidatePostAlgorithms ==
    LET logline == TraceLog[l] IN
    /\ conn_state' = NEGOTIATED
    /\ base_hash_algo'     = TraceAlgo(logline.base_hash_algo)
    /\ base_asym_algo'     = TraceAlgo(logline.base_asym_algo)
    /\ measurement_spec'   = TraceAlgo(logline.measurement_spec)
    /\ measurement_hash_algo' = TraceAlgo(logline.measurement_hash_algo)
    /\ rsp_alg_types'      = TraceAlgTypes(logline.rsp_alg_types)

----
\* ------------------------------------------------------------------
\*  ACTION WRAPPERS
\* Each wrapper: matches trace event → calls base action → validates post-state → advances l
\* ------------------------------------------------------------------

TraceReqSendGetVersion ==
    /\ IsEvent("req_send_get_version")
    /\ ReqSendGetVersion
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceRspHandleGetVersion ==
    /\ IsEvent("rsp_handle_get_version")
    /\ LET logline == TraceLog[l]
           v == TraceVersion(logline.offered_version)
       IN RspHandleGetVersion(v)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceReqHandleVersion ==
    /\ IsEvent("req_handle_version")
    /\ ReqHandleVersion
    /\ ValidatePostVersion
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceReqSendGetCapabilities ==
    /\ IsEvent("req_send_get_capabilities")
    /\ LET logline == TraceLog[l]
           flags == TraceCapFlags(logline.req_cap_flags)
       IN ReqSendGetCapabilities(flags)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceRspHandleGetCapabilities ==
    /\ IsEvent("rsp_handle_get_capabilities")
    /\ LET logline == TraceLog[l]
           req_f == TraceCapFlags(logline.req_cap_flags)
           rsp_f == TraceCapFlags(logline.rsp_cap_flags)
       IN RspHandleGetCapabilities(req_f, rsp_f)
    /\ ValidatePostCapabilities
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceReqHandleCapabilities ==
    /\ IsEvent("req_handle_capabilities")
    /\ ReqHandleCapabilities
    /\ ValidatePostCapabilities
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceReqSendNegotiateAlgorithms ==
    /\ IsEvent("req_send_negotiate_algorithms")
    /\ LET logline == TraceLog[l]
           alg_types == TraceAlgTypes(logline.req_alg_types)
       IN ReqSendNegotiateAlgorithms(alg_types)
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceRspHandleNegotiateAlgorithms ==
    /\ IsEvent("rsp_handle_negotiate_algorithms")
    /\ LET logline == TraceLog[l]
           sh == TraceAlgo(logline.base_hash_algo)
           sa == TraceAlgo(logline.base_asym_algo)
           ms == TraceAlgo(logline.measurement_spec)
           mh == TraceAlgo(logline.measurement_hash_algo)
           st == TraceAlgTypes(logline.rsp_alg_types)
           dh == TraceAlgo(logline.dhe_algo)
           ae == TraceAlgo(logline.aead_algo)
           ra == TraceAlgo(logline.req_asym_algo)
           ks == TraceAlgo(logline.key_schedule_algo)
       IN RspHandleNegotiateAlgorithms(sh, sa, ms, mh, st, dh, ae, ra, ks)
    /\ ValidatePostAlgorithms
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceReqHandleAlgorithms ==
    /\ IsEvent("req_handle_algorithms")
    /\ ReqHandleAlgorithms
    /\ ValidatePostAlgorithms
    /\ l' = l + 1
    /\ UNCHANGED faultVars

\* Error path events (F4 transcript scenario)
TraceRspErrorInCapabilities ==
    /\ IsEvent("rsp_error_capabilities")
    /\ RspErrorInCapabilities
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceRspErrorInAlgorithms ==
    /\ IsEvent("rsp_error_algorithms")
    /\ RspErrorInAlgorithms
    /\ l' = l + 1
    /\ UNCHANGED faultVars

TraceContextReset ==
    /\ IsEvent("context_reset")
    /\ ContextReset
    /\ l' = l + 1

----
\* ------------------------------------------------------------------
\*  SILENT ACTIONS
\* Handle state transitions that the implementation makes internally
\* without emitting a trace event. Tightly constrained.
\* ------------------------------------------------------------------

\* No silent actions needed for VCA: every state transition in the
\* SPDM VCA protocol corresponds to an observable send/receive event.
\* (All state changes are driven by the instrumented message handlers.)

----
\* ------------------------------------------------------------------
\*  TraceInit / TraceNext
\* ------------------------------------------------------------------

TraceInit ==
    /\ Init
    /\ l = 1

TraceNext ==
    \/ TraceReqSendGetVersion
    \/ TraceRspHandleGetVersion
    \/ TraceReqHandleVersion
    \/ TraceReqSendGetCapabilities
    \/ TraceRspHandleGetCapabilities
    \/ TraceReqHandleCapabilities
    \/ TraceReqSendNegotiateAlgorithms
    \/ TraceRspHandleNegotiateAlgorithms
    \/ TraceReqHandleAlgorithms
    \/ TraceRspErrorInCapabilities
    \/ TraceRspErrorInAlgorithms
    \/ TraceContextReset
    \* Stuttering when trace is exhausted
    \/ (l > Len(TraceLog) /\ UNCHANGED traceVars)

TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceNext)

----
\* ------------------------------------------------------------------
\*  TEMPORAL PROPERTY
\* Verifies entire trace was consumed.
\* ------------------------------------------------------------------

TraceMatched == <>(l > Len(TraceLog))

====
