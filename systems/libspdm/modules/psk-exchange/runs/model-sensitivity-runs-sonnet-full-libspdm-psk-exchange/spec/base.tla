-------------------------- MODULE base --------------------------
(*
  TLA+ base spec for libspdm PSK-based session establishment (SPDM DSP0274 §9).

  System category: A (Distributed / Message-Passing)
  Protocol:  PSK_EXCHANGE → PSK_EXCHANGE_RSP → [PSK_FINISH → PSK_FINISH_RSP]
  Parties:   Requester (REQ) and Responder (RSP)

  Bug families targeted:
    Family 1: Missing opaque data enforcement → session_version = 0
              libspdm_rsp_psk_exchange_rsp.c:272,274,371
    Family 2: Triple-call opaque callback race → version mismatch across transcript
              libspdm_rsp_psk_exchange_rsp.c:287,317,432
*)

EXTENDS Naturals, Sequences, FiniteSets, Bags

-----------------------------------------------------------------------------
\* CONSTANTS
-----------------------------------------------------------------------------

CONSTANTS
    REQ,        \* requester node identity
    RSP,        \* responder node identity
    V_NONE,     \* no version negotiated (maps to secured_message_version = 0)
    V_VALID,    \* a valid secured_message_version (e.g., DSP0277 v1.1)
    V_ALT,      \* alternate valid version (for triple-call divergence)
    SPDM_VER_12 \* SPDM spec version 1.2 or higher (opaque enforcement applies)

ASSUME REQ /= RSP
ASSUME V_NONE /= V_VALID /\ V_NONE /= V_ALT \* V_NONE = 0

\* PSK capability modes
\* PSK_CAP_REQUESTER_ONLY: no PSK_FINISH needed
\* PSK_CAP_RESPONDER_WITH_CONTEXT: PSK_FINISH required
CONSTANTS
    PSK_CAP_REQUESTER_ONLY,
    PSK_CAP_RESPONDER_WITH_CONTEXT

\* SPDM version in use (SPDM_VER_12 or lower)
CONSTANTS SpdmVersion

-----------------------------------------------------------------------------
\* MESSAGE TYPES
-----------------------------------------------------------------------------

CONSTANTS
    MSG_PSK_EXCHANGE,
    MSG_PSK_EXCHANGE_RSP,
    MSG_PSK_FINISH,
    MSG_PSK_FINISH_RSP,
    MSG_ERROR

-----------------------------------------------------------------------------
\* STATE CONSTANTS
-----------------------------------------------------------------------------

SESSION_NOT_STARTED == "NOT_STARTED"
SESSION_HANDSHAKING  == "HANDSHAKING"
SESSION_ESTABLISHED  == "ESTABLISHED"

\* Opaque callback invocation slots (Family 2)
OPAQUE_CALL_PROBE  == 1   \* call 1: probe size  (line 287)
OPAQUE_CALL_TEMP   == 2   \* call 2: temp fetch  (line 317)
OPAQUE_CALL_FINAL  == 3   \* call 3: final write (line 432)

-----------------------------------------------------------------------------
\* VARIABLES
-----------------------------------------------------------------------------

\* --- Network ---
VARIABLE msgs   \* message bag (multi-set)

\* --- Protocol state (per role) ---
VARIABLE req_state    \* requester's session-establishment state
VARIABLE rsp_state    \* responder's session-establishment state

(*  State record shape (for both req_state and rsp_state):
      [ session_state   : {SESSION_NOT_STARTED, SESSION_HANDSHAKING, SESSION_ESTABLISHED}
        session_id      : Nat \cup {0}
        session_version : {V_NONE, V_VALID, V_ALT}   \* secured_message_version
        hmac_verified   : BOOLEAN                    \* PSK_EXCHANGE_RSP HMAC checked by REQ
        finish_done     : BOOLEAN                    \* PSK_FINISH round-trip completed
        psk_cap         : {PSK_CAP_REQUESTER_ONLY, PSK_CAP_RESPONDER_WITH_CONTEXT}
      ]
*)

\* --- Extension variables (Family 1) ---
VARIABLE req_has_opaque  \* requester sent PSK_EXCHANGE with opaque data present
VARIABLE rsp_has_opaque  \* responder received PSK_EXCHANGE with opaque_length != 0

\* --- Extension variables (Family 2) ---
\* opaque_call_results[slot] = version returned by callback invocation `slot`
\* slot in {OPAQUE_CALL_PROBE, OPAQUE_CALL_TEMP, OPAQUE_CALL_FINAL}
VARIABLE opaque_call_results   \* [1..3 -> {V_NONE, V_VALID, V_ALT}]

\* responder's negotiated version (extracted from call 2)  -- Family 2
VARIABLE rsp_negotiated_version  \* = opaque_call_results[OPAQUE_CALL_TEMP] after build

\* requester's negotiated version (extracted from RSP message's final opaque) -- Family 2
VARIABLE req_negotiated_version  \* = opaque_call_results[OPAQUE_CALL_FINAL] as seen by REQ

-----------------------------------------------------------------------------
\* VARIABLE GROUPINGS (for UNCHANGED clauses)
-----------------------------------------------------------------------------

networkVars  == <<msgs>>
reqVars      == <<req_state, req_has_opaque, req_negotiated_version>>
rspVars      == <<rsp_state, rsp_has_opaque, rsp_negotiated_version, opaque_call_results>>
allVars      == <<msgs, req_state, rsp_state,
                  req_has_opaque, rsp_has_opaque,
                  opaque_call_results,
                  rsp_negotiated_version, req_negotiated_version>>

-----------------------------------------------------------------------------
\* HELPERS
-----------------------------------------------------------------------------

InitState(cap) ==
    [ session_state   |-> SESSION_NOT_STARTED
    , session_id      |-> 0
    , session_version |-> V_NONE
    , hmac_verified   |-> FALSE
    , finish_done     |-> FALSE
    , psk_cap         |-> cap
    ]

Send(m) == msgs' = msgs (+) SetToBag({m})
Recv(m) == /\ m \in DOMAIN msgs /\ msgs[m] >= 1
           /\ msgs' = msgs (-) SetToBag({m})

\* Opaque data present check (Family 1)
\* libspdm_rsp_psk_exchange_rsp.c:274 -- guard: if (spdm_request->opaque_length != 0)
HasOpaque(flag) == flag = TRUE

-----------------------------------------------------------------------------
\* INIT
-----------------------------------------------------------------------------

Init ==
    /\ msgs = EmptyBag
    /\ req_state = InitState(PSK_CAP_REQUESTER_ONLY)
    /\ rsp_state = InitState(PSK_CAP_RESPONDER_WITH_CONTEXT)
    /\ req_has_opaque  = FALSE
    /\ rsp_has_opaque  = FALSE
    /\ opaque_call_results = [i \in 1..3 |-> V_NONE]
    /\ rsp_negotiated_version = V_NONE
    /\ req_negotiated_version = V_NONE

-----------------------------------------------------------------------------
\* ACTION: SendPskExchange  (Requester)
\* libspdm_req_psk_exchange.c -- libspdm_try_send_receive_psk_exchange()
-----------------------------------------------------------------------------

(*
  Requester sends PSK_EXCHANGE.  `with_opaque` is nondeterministic input (Family 1).
  The message carries opaque_length = 0 or >0; whether version negotiation data is
  present determines whether the responder can extract a valid secured_message_version.

  libspdm_req_psk_exchange.c: full function
*)
SendPskExchange(with_opaque) ==
    /\ req_state.session_state = SESSION_NOT_STARTED
    /\ LET msg == [ mtype        |-> MSG_PSK_EXCHANGE
                  , from         |-> REQ
                  , to           |-> RSP
                  , has_opaque   |-> with_opaque   \* opaque_length field
                  , req_session_id |-> 1            \* simplified single-session ID
                  ]
       IN
       /\ Send(msg)
       /\ req_state' = [req_state EXCEPT
                          !.session_state = SESSION_HANDSHAKING,
                          !.session_id    = 1]
       /\ req_has_opaque' = with_opaque
    /\ UNCHANGED <<rsp_state, rsp_has_opaque, opaque_call_results,
                   rsp_negotiated_version, req_negotiated_version>>

-----------------------------------------------------------------------------
\* ACTION: GetResponsePskExchange  (Responder)
\* libspdm_rsp_psk_exchange_rsp.c -- libspdm_get_response_psk_exchange()
-----------------------------------------------------------------------------

(*
  Responder receives PSK_EXCHANGE and builds PSK_EXCHANGE_RSP.

  Key implementation flow reproduced here:
    line 272: secured_message_version = 0    (default, extension var Family 1)
    line 274: if (opaque_length != 0) { ... negotiate version ... }
    line 287: callback invocation 1 (probe size)                    (Family 2)
    line 317: callback invocation 2 (temp buffer → extract version) (Family 2)
    line 349: libspdm_zero_mem(response, *response_size)            (clears call-2 buffer)
    line 371: libspdm_assign_session_id(..., secured_message_version, ...)
    line 432: callback invocation 3 (final write to ptr)            (Family 2)
*)

\* Sub-action: ProbeOpaqueSize -- callback call 1  (line 287)
ProbeOpaqueSize ==
    \* Always fires when responder receives PSK_EXCHANGE (part of GetResponsePskExchange flow)
    \* Call 1 returns only a size, no version data. Modeled as picking arbitrary opaque result.
    /\ opaque_call_results' = [opaque_call_results EXCEPT ![OPAQUE_CALL_PROBE] = V_NONE]
    \* probe call does not yet set has_opaque or version

\* Sub-action: TempFetchOpaque -- callback call 2 (line 317)
\* This is where secured_message_version is extracted.
\* Non-deterministically returns V_VALID or V_ALT (Family 2).
TempFetchOpaque(has_op) ==
    IF has_op
    THEN \E v \in {V_VALID, V_ALT} :
            /\ opaque_call_results' = [opaque_call_results EXCEPT ![OPAQUE_CALL_TEMP] = v]
            /\ rsp_negotiated_version' = v   \* line 317: extracted secured_message_version
    ELSE \* opaque_length = 0: version stays V_NONE  (line 272 default, line 274 guard)
         /\ opaque_call_results' = [opaque_call_results EXCEPT ![OPAQUE_CALL_TEMP] = V_NONE]
         /\ rsp_negotiated_version' = V_NONE

\* Sub-action: FinalWriteOpaque -- callback call 3 (line 432)
\* Writes final opaque data into response; may differ from call 2 (Family 2).
FinalWriteOpaque(has_op) ==
    IF has_op
    THEN \E v \in {V_VALID, V_ALT} :
            opaque_call_results' = [opaque_call_results EXCEPT ![OPAQUE_CALL_FINAL] = v]
    ELSE opaque_call_results' = [opaque_call_results EXCEPT ![OPAQUE_CALL_FINAL] = V_NONE]

\* Full responder action that sequences the three sub-steps atomically at the spec level.
\* (The splitting above is modeled in the MC layer for Family 2 investigation.)
GetResponsePskExchange ==
    \E psk_req \in DOMAIN msgs :
    /\ msgs[psk_req] >= 1
    /\ psk_req.mtype = MSG_PSK_EXCHANGE
    /\ psk_req.to    = RSP
    /\ rsp_state.session_state = SESSION_NOT_STARTED
    \* --- line 287: probe size (call 1) ---
    \* --- line 317: temp fetch (call 2) → extract version ---
    \* --- line 349: zero temp buffer ---
    \* --- line 371: assign session with extracted version ---
    \* --- line 432: final write (call 3) to response ---
    /\ LET has_op  == psk_req.has_opaque
           \* line 272: default secured_message_version = 0
           \* line 274: only updated when has_opaque; callback may return V_VALID or V_ALT
           Versions == IF has_op THEN {V_VALID, V_ALT} ELSE {V_NONE}
       IN
       \* Nondeterministically choose call-2 and call-3 return values independently.
       \* The integrator callback is invoked twice (lines 317 and 432) and may
       \* return a different version each time — this is the Family 2 bug trigger.
       \E ver_call2 \in Versions :
       \E ver_call3 \in Versions :
       /\ msgs' = msgs (-) SetToBag({psk_req})
               (+) SetToBag({[ mtype             |-> MSG_PSK_EXCHANGE_RSP
                              , from              |-> RSP
                              , to                |-> REQ
                              , session_id        |-> psk_req.req_session_id
                              \* call-3 opaque goes into the actual response (Family 2)
                              , opaque_version    |-> ver_call3
                              \* HMAC covers call-3 data
                              , hmac_valid        |-> TRUE
                              ]})
       \* line 371: session assigned with call-2 version (may differ from call-3)
       /\ rsp_state' = [rsp_state EXCEPT
                           !.session_state   = SESSION_HANDSHAKING,
                           !.session_id      = psk_req.req_session_id,
                           !.session_version = ver_call2]
       /\ rsp_has_opaque'        = has_op
       /\ rsp_negotiated_version' = ver_call2   \* Family 2: version used for session
       /\ opaque_call_results'   = [ OPAQUE_CALL_PROBE |-> V_NONE
                                   , OPAQUE_CALL_TEMP  |-> ver_call2
                                   , OPAQUE_CALL_FINAL |-> ver_call3 ]
    /\ UNCHANGED <<req_state, req_has_opaque, req_negotiated_version>>

-----------------------------------------------------------------------------
\* ACTION: RecvPskExchangeRsp  (Requester)
\* libspdm_req_psk_exchange.c -- libspdm_try_send_receive_psk_exchange()
-----------------------------------------------------------------------------

(*
  Requester receives PSK_EXCHANGE_RSP.
  - Extracts secured_message_version from the response opaque data (call-3 version).
  - Verifies HMAC.
  - Transitions to HANDSHAKING (or ESTABLISHED if no PSK_FINISH required).

  libspdm_req_psk_exchange.c: receive/parse section
*)
RecvPskExchangeRsp ==
    \E rsp_msg \in DOMAIN msgs :
    /\ msgs[rsp_msg] >= 1
    /\ rsp_msg.mtype    = MSG_PSK_EXCHANGE_RSP
    /\ rsp_msg.to       = REQ
    /\ req_state.session_state = SESSION_HANDSHAKING
    /\ rsp_msg.hmac_valid = TRUE    \* HMAC verification by requester
    /\ LET ver == rsp_msg.opaque_version   \* requester sees call-3 version (Family 2)
       IN
       /\ msgs' = msgs (-) SetToBag({rsp_msg})
       /\ req_negotiated_version' = ver   \* Family 2: version requester assigns
       /\ req_state' = [req_state EXCEPT
                          !.session_version = ver,
                          !.hmac_verified   = TRUE,
                          \* If PSK_CAP_REQUESTER_ONLY → ESTABLISHED immediately
                          \* If PSK_CAP_RESPONDER_WITH_CONTEXT → stay HANDSHAKING
                          !.session_state   =
                              IF req_state.psk_cap = PSK_CAP_REQUESTER_ONLY
                              THEN SESSION_ESTABLISHED
                              ELSE SESSION_HANDSHAKING]
    /\ UNCHANGED <<rsp_state, req_has_opaque, rsp_has_opaque,
                   opaque_call_results, rsp_negotiated_version>>

-----------------------------------------------------------------------------
\* ACTION: SendPskFinish  (Requester)
\* libspdm_req_psk_finish.c -- libspdm_try_send_receive_psk_finish()
-----------------------------------------------------------------------------

(*
  Requester sends PSK_FINISH when PSK_CAP_RESPONDER_WITH_CONTEXT is set.
  libspdm_req_psk_finish.c: full function
*)
SendPskFinish ==
    /\ req_state.session_state = SESSION_HANDSHAKING
    /\ req_state.hmac_verified = TRUE
    /\ req_state.psk_cap = PSK_CAP_RESPONDER_WITH_CONTEXT
    /\ Send([ mtype      |-> MSG_PSK_FINISH
            , from       |-> REQ
            , to         |-> RSP
            , session_id |-> req_state.session_id
            ])
    /\ UNCHANGED <<req_state, rsp_state, req_has_opaque, rsp_has_opaque,
                   opaque_call_results, rsp_negotiated_version, req_negotiated_version>>

-----------------------------------------------------------------------------
\* ACTION: GetResponsePskFinish  (Responder)
\* libspdm_rsp_psk_finish_rsp.c -- libspdm_get_response_psk_finish()
-----------------------------------------------------------------------------

(*
  Responder receives PSK_FINISH and sends PSK_FINISH_RSP.
  On success, transitions responder session to ESTABLISHED.
  Dispatch layer then sets ESTABLISHED.
  libspdm_rsp_receive_send.c:764-827
*)
GetResponsePskFinish ==
    \E fin_msg \in DOMAIN msgs :
    /\ msgs[fin_msg] >= 1
    /\ fin_msg.mtype    = MSG_PSK_FINISH
    /\ fin_msg.to       = RSP
    /\ rsp_state.session_state = SESSION_HANDSHAKING
    /\ fin_msg.session_id = rsp_state.session_id
    /\ msgs' = msgs (-) SetToBag({fin_msg})
          (+) SetToBag({[ mtype      |-> MSG_PSK_FINISH_RSP
                        , from       |-> RSP
                        , to         |-> REQ
                        , session_id |-> rsp_state.session_id
                        ]})
    /\ rsp_state' = [rsp_state EXCEPT
                       !.session_state = SESSION_ESTABLISHED,
                       !.finish_done   = TRUE]
    /\ UNCHANGED <<req_state, req_has_opaque, rsp_has_opaque,
                   opaque_call_results, rsp_negotiated_version, req_negotiated_version>>

-----------------------------------------------------------------------------
\* ACTION: RecvPskFinishRsp  (Requester)
\* libspdm_req_psk_finish.c -- response processing
-----------------------------------------------------------------------------

RecvPskFinishRsp ==
    \E frsp \in DOMAIN msgs :
    /\ msgs[frsp] >= 1
    /\ frsp.mtype    = MSG_PSK_FINISH_RSP
    /\ frsp.to       = REQ
    /\ req_state.session_state = SESSION_HANDSHAKING
    /\ req_state.psk_cap = PSK_CAP_RESPONDER_WITH_CONTEXT
    /\ frsp.session_id = req_state.session_id
    /\ msgs' = msgs (-) SetToBag({frsp})
    /\ req_state' = [req_state EXCEPT
                       !.session_state = SESSION_ESTABLISHED,
                       !.finish_done   = TRUE]
    /\ UNCHANGED <<rsp_state, req_has_opaque, rsp_has_opaque,
                   opaque_call_results, rsp_negotiated_version, req_negotiated_version>>

-----------------------------------------------------------------------------
\* FAULT INJECTION ACTIONS
\* Only Family-1 and Family-2 mechanisms, as motivated by the modeling brief.
-----------------------------------------------------------------------------

(*
  DropMessage: Message loss during handshake.
  Bounds applied in MC spec.
*)
DropMessage ==
    \E m \in DOMAIN msgs :
    /\ msgs[m] >= 1
    /\ msgs' = msgs (-) SetToBag({m})
    /\ UNCHANGED <<req_state, rsp_state, req_has_opaque, rsp_has_opaque,
                   opaque_call_results, rsp_negotiated_version, req_negotiated_version>>

-----------------------------------------------------------------------------
\* NEXT
-----------------------------------------------------------------------------

Next ==
    \/ SendPskExchange(TRUE)    \* with opaque data
    \/ SendPskExchange(FALSE)   \* without opaque data (Family 1 trigger)
    \/ GetResponsePskExchange
    \/ RecvPskExchangeRsp
    \/ SendPskFinish
    \/ GetResponsePskFinish
    \/ RecvPskFinishRsp
    \/ DropMessage

Spec == Init /\ [][Next]_allVars

-----------------------------------------------------------------------------
\* INVARIANTS
-----------------------------------------------------------------------------

\* --- Structural invariants (always hold) ---

TypeOK ==
    /\ req_state.session_state \in {SESSION_NOT_STARTED, SESSION_HANDSHAKING, SESSION_ESTABLISHED}
    /\ rsp_state.session_state \in {SESSION_NOT_STARTED, SESSION_HANDSHAKING, SESSION_ESTABLISHED}
    /\ req_state.session_version  \in {V_NONE, V_VALID, V_ALT}
    /\ rsp_state.session_version  \in {V_NONE, V_VALID, V_ALT}
    /\ req_has_opaque  \in BOOLEAN
    /\ rsp_has_opaque  \in BOOLEAN
    /\ rsp_negotiated_version \in {V_NONE, V_VALID, V_ALT}
    /\ req_negotiated_version \in {V_NONE, V_VALID, V_ALT}

\* HMAC must be verified before ESTABLISHED (requester side)
NoEstablishWithoutHmacVerify ==
    req_state.session_state = SESSION_ESTABLISHED =>
        req_state.hmac_verified = TRUE

\* PSK_FINISH must complete before ESTABLISHED when context required (responder side)
PskFinishRequiredIfContext ==
    (rsp_state.session_state = SESSION_ESTABLISHED /\
     rsp_state.psk_cap = PSK_CAP_RESPONDER_WITH_CONTEXT) =>
        rsp_state.finish_done = TRUE

\* --- Extension invariants (Family 1) ---

(*
  ValidVersionOnEstablish:
  If a session is ESTABLISHED and SPDM version is >= 1.2, then secured_message_version
  must not be V_NONE (= 0).

  Violation trace: SendPskExchange(FALSE) → GetResponsePskExchange
  → RecvPskExchangeRsp (PSK_CAP_REQUESTER_ONLY) → req session = ESTABLISHED, version = V_NONE
  libspdm_rsp_psk_exchange_rsp.c:272,274,371
*)
ValidVersionOnEstablish ==
    SpdmVersion = SPDM_VER_12 =>
        (req_state.session_state = SESSION_ESTABLISHED =>
            req_state.session_version /= V_NONE)
        /\
        (rsp_state.session_state = SESSION_ESTABLISHED =>
            rsp_state.session_version /= V_NONE)

\* --- Extension invariants (Family 2) ---

(*
  VersionAgreement:
  Once the requester has verified the PSK_EXCHANGE_RSP HMAC (hmac_verified=TRUE),
  the secured_message_version it extracted from the response opaque (call-3 version)
  must equal the version the responder stored internally (call-2 version).

  Weakened from "both ESTABLISHED" to "req hmac_verified" so that the mismatch is
  caught under PSK_CAP_REQUESTER_ONLY (where only the requester establishes) as well
  as PSK_CAP_RESPONDER_WITH_CONTEXT (where both establish).

  Violation trace: nondeterministic callback returns V_VALID for call 2
  and V_ALT for call 3 → rsp assigns V_VALID, req extracts V_ALT from response.
  libspdm_rsp_psk_exchange_rsp.c:317 (call 2) vs :432 (call 3)
*)
VersionAgreement ==
    req_state.hmac_verified =>
        req_state.session_version = rsp_state.session_version

=================================================================
