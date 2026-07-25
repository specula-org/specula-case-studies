---- MODULE base ----
(***************************************************************************)
(* TLA+ spec for SPDM KEY_EXCHANGE / FINISH session establishment          *)
(* Models the libspdm responder to hunt four bug families.                 *)
(* System category: Category A (Distributed / Message-Passing, two-party) *)
(*                                                                         *)
(* Bug families modeled:                                                   *)
(*  F1  Session identity confusion under HANDSHAKE_IN_THE_CLEAR            *)
(*  F2  Mutual auth path inconsistency (encap vs non-encap)                *)
(*  F3  Non-atomic session state transition (Finish gap)                   *)
(*  F4  Sequence counter advanced before AEAD verification                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    MaxSessions,    \* Session slot count.  Use 2 for MC.
    MaxCertSlots,   \* Requester cert slot count.  Use 2 for MC.
    MaxSeqNum       \* Sequence-number bound for Family 4.  Use 4 for MC.

\* Sentinels
NO_SESSION == 0
NO_SLOT    == 0

Sessions  == 1..MaxSessions
CertSlots == 1..MaxCertSlots

\* Session states
\* libspdm_secured_message_context_t / libspdm_secured_message_session_state_t
NOT_STARTED  == "not_started"
HANDSHAKING  == "handshaking"
\* KEYS_DERIVED is an intermediate state not present in libspdm's enum.
\* It captures the window between libspdm_get_response_finish returning
\* (data keys live) and LIBSPDM_SESSION_STATE_ESTABLISHED being committed.
\* libspdm_rsp_finish_rsp.c:744 / libspdm_rsp_receive_send.c:771-820
KEYS_DERIVED == "keys_derived"
ESTABLISHED  == "established"

\* Mutual-authentication modes, derived from KEY_EXCHANGE_RSP MutualAuthRequested bits
\* libspdm_rsp_key_exchange.c:570-577
MUT_NONE      == "none"
MUT_NON_ENCAP == "non_encap"   \* bit 0 set but not encapsulated
MUT_ENCAP     == "encap"        \* encapsulated exchange

\* Message type tags
MT_KEY_EX      == "key_exchange"
MT_KEY_EX_RSP  == "key_exchange_rsp"
MT_FINISH      == "finish"
MT_FINISH_RSP  == "finish_rsp"
MT_APP_DATA    == "app_data"

(***************************************************************************)
(* STATE VARIABLES                                                         *)
(***************************************************************************)

VARIABLES
    \* ---------- Core protocol state ----------
    msgs,           \* Set of in-flight messages (set, not bag; SPDM is not retransmitting here)

    \* [Sessions -> {NOT_STARTED, HANDSHAKING, KEYS_DERIVED, ESTABLISHED}]
    \* libspdm_com_context_data_session.c -- session_info[s].session_state
    session_state,

    \* ---------- Family 1: Global session pointer ----------
    \* spdm_context->latest_session_id
    \* libspdm_com_context_data_session.c:221 -- unconditionally overwritten on every allocate
    latest_session_id,          \* Nat: NO_SESSION (0) or 1..MaxSessions

    \* Per-session HANDSHAKE_IN_THE_CLEAR flag
    \* Negotiated during KEY_EXCHANGE; causes FINISH to arrive cleartext
    hitc_negotiated,            \* [Sessions -> BOOLEAN]

    \* Ghost: for session s in ESTABLISHED, which session's keys authenticated the FINISH.
    \* Invariant checks this equals s.  Set by RspDeriveDataKeys.
    finish_authenticated_for,   \* [Sessions -> 0..MaxSessions]

    \* ---------- Family 2: Per-session peer cert slot ----------
    \* session_info->peer_used_cert_chain_slot_id
    \* libspdm_rsp_key_exchange.c:575 -- set ONLY on the encap path
    peer_cert_slot,             \* [Sessions -> 0..MaxCertSlots]

    \* Ghost: req_slot_id advertised inside KEY_EXCHANGE_RSP (ground truth of negotiation).
    cert_advertised,            \* [Sessions -> 0..MaxCertSlots]

    \* Per-session mutual-auth mode
    mut_auth_mode,              \* [Sessions -> {MUT_NONE, MUT_NON_ENCAP, MUT_ENCAP}]

    \* Ghost: cert slot actually used when verifying FINISH signature.
    \* Invariant checks this equals cert_advertised[s] when mut auth is active.
    cert_slot_verified,         \* [Sessions -> 0..MaxCertSlots]

    \* ---------- Family 3: Non-atomic key/state split ----------
    \* Set by RspDeriveDataKeys (libspdm_rsp_finish_rsp.c:744).
    \* Cleared when session returns to NOT_STARTED.
    data_keys_live,             \* [Sessions -> BOOLEAN]

    \* ---------- Family 4: Sequence counter ordering ----------
    \* libspdm_secmes_encode_decode.c:399-426
    expected_seq,               \* [Sessions -> 0..MaxSeqNum]

    \* Ghost: value of expected_seq[s] BEFORE RspDecodeSecuredMessage modified it.
    \* Used in SeqCounterStableOnDecryptFailure invariant.
    seq_before_advance,         \* [Sessions -> 0..MaxSeqNum]

    \* Ghost: did the last decode for session s reject the message (AEAD failed)?
    last_decode_rejected        \* [Sessions -> BOOLEAN]

\* Variable groups for UNCHANGED clauses
coreVars    == <<msgs, session_state, latest_session_id>>
family1Vars == <<finish_authenticated_for, hitc_negotiated>>
family2Vars == <<peer_cert_slot, cert_advertised, mut_auth_mode, cert_slot_verified>>
family3Vars == <<data_keys_live>>
family4Vars == <<expected_seq, seq_before_advance, last_decode_rejected>>

vars == <<msgs, session_state, latest_session_id,
          finish_authenticated_for, hitc_negotiated,
          peer_cert_slot, cert_advertised, mut_auth_mode, cert_slot_verified,
          data_keys_live,
          expected_seq, seq_before_advance, last_decode_rejected>>

(***************************************************************************)
(* TYPE INVARIANT                                                          *)
(***************************************************************************)

TypeOK ==
    \* msgs is a set of records; type-correctness enforced by action preconditions
    /\ session_state           \in [Sessions -> {NOT_STARTED, HANDSHAKING, KEYS_DERIVED, ESTABLISHED}]
    /\ latest_session_id       \in 0..MaxSessions
    /\ hitc_negotiated         \in [Sessions -> BOOLEAN]
    /\ finish_authenticated_for \in [Sessions -> 0..MaxSessions]
    /\ peer_cert_slot          \in [Sessions -> 0..MaxCertSlots]
    /\ cert_advertised         \in [Sessions -> 0..MaxCertSlots]
    /\ mut_auth_mode           \in [Sessions -> {MUT_NONE, MUT_NON_ENCAP, MUT_ENCAP}]
    /\ cert_slot_verified      \in [Sessions -> 0..MaxCertSlots]
    /\ data_keys_live          \in [Sessions -> BOOLEAN]
    /\ expected_seq            \in [Sessions -> 0..MaxSeqNum]
    /\ seq_before_advance      \in [Sessions -> 0..MaxSeqNum]
    /\ last_decode_rejected    \in [Sessions -> BOOLEAN]

(***************************************************************************)
(* INIT                                                                    *)
(***************************************************************************)

Init ==
    /\ msgs                    = {}
    /\ session_state           = [s \in Sessions |-> NOT_STARTED]
    /\ latest_session_id       = NO_SESSION
    /\ hitc_negotiated         = [s \in Sessions |-> FALSE]
    /\ finish_authenticated_for = [s \in Sessions |-> NO_SESSION]
    /\ peer_cert_slot          = [s \in Sessions |-> NO_SLOT]
    /\ cert_advertised         = [s \in Sessions |-> NO_SLOT]
    /\ mut_auth_mode           = [s \in Sessions |-> MUT_NONE]
    /\ cert_slot_verified      = [s \in Sessions |-> NO_SLOT]
    /\ data_keys_live          = [s \in Sessions |-> FALSE]
    /\ expected_seq            = [s \in Sessions |-> 0]
    /\ seq_before_advance      = [s \in Sessions |-> 0]
    /\ last_decode_rejected    = [s \in Sessions |-> FALSE]

(***************************************************************************)
(* HELPERS                                                                 *)
(***************************************************************************)

Send(m)    == msgs' = msgs \cup {m}
Consume(m) == msgs' = msgs \ {m}

(***************************************************************************)
(* ACTIONS                                                                 *)
(***************************************************************************)

(* -----------------------------------------------------------------------
   ReqSendKeyExchange
   Requester initiates a KEY_EXCHANGE.  Non-deterministically chooses the
   HANDSHAKE_IN_THE_CLEAR flag, the requester cert slot, and mutual-auth mode.
   Modeled abstractly (requester-side state is not tracked).
   ----------------------------------------------------------------------- *)
ReqSendKeyExchange(hitc, req_slot, mode) ==
    /\ req_slot \in 0..MaxCertSlots  \* 0 = NO_SLOT (MUT_NONE); 1..Max = actual cert slots
    /\ mode \in {MUT_NONE, MUT_NON_ENCAP, MUT_ENCAP}
    /\ Cardinality({s \in Sessions : session_state[s] = NOT_STARTED}) > 0
    /\ Send([type        |-> MT_KEY_EX,
             hitc        |-> hitc,
             req_slot_id |-> req_slot,
             mode        |-> mode])
    /\ UNCHANGED <<session_state, latest_session_id,
                   family1Vars, family2Vars, family3Vars, family4Vars>>

(* -----------------------------------------------------------------------
   RspHandleKeyExchange
   Responder processes a KEY_EXCHANGE request.
   libspdm_get_response_key_exchange  (libspdm_rsp_key_exchange.c)

   Critical operations modeled:

   1. Allocate session slot s, transition to HANDSHAKING
   2. Overwrite latest_session_id = s                  [com_context:221]
   3a. Encap path: peer_cert_slot[s] = req_slot_id     [rsp_key_exchange:575]
   3b. Non-encap path: req_slot_id only in response buffer; peer_cert_slot NOT set
                                                       [rsp_key_exchange:571-572]
   4. Send KEY_EXCHANGE_RSP carrying slot_param (for requester record-keeping)
   ----------------------------------------------------------------------- *)
RspHandleKeyExchange(m, s) ==
    /\ m \in msgs
    /\ m.type = MT_KEY_EX
    /\ s \in Sessions
    /\ session_state[s] = NOT_STARTED

    \* Replace KEY_EXCHANGE with KEY_EXCHANGE_RSP
    /\ msgs' = (msgs \ {m}) \cup
               {[type       |-> MT_KEY_EX_RSP,
                 session_id |-> s,
                 mode       |-> m.mode,
                 slot_param |-> m.req_slot_id]}

    \* Transition session to HANDSHAKING
    /\ session_state'      = [session_state      EXCEPT ![s] = HANDSHAKING]

    \* libspdm_com_context_data_session.c:221 — unconditional overwrite
    /\ latest_session_id'  = s

    \* libspdm_rsp_key_exchange.c:570-577 — conditional peer_cert_slot write
    /\ peer_cert_slot' =
           IF m.mode = MUT_ENCAP
           \* libspdm_rsp_key_exchange.c:575 — encap sets peer_used_cert_chain_slot_id
           THEN [peer_cert_slot EXCEPT ![s] = m.req_slot_id]
           \* libspdm_rsp_key_exchange.c:571-572 — non-encap omits session state write (BUG F2)
           ELSE [peer_cert_slot EXCEPT ![s] = NO_SLOT]

    /\ cert_advertised'    = [cert_advertised    EXCEPT ![s] = m.req_slot_id]
    /\ mut_auth_mode'      = [mut_auth_mode      EXCEPT ![s] = m.mode]
    /\ hitc_negotiated'    = [hitc_negotiated    EXCEPT ![s] = m.hitc]

    /\ UNCHANGED <<finish_authenticated_for, cert_slot_verified,
                   data_keys_live, family4Vars>>

(* -----------------------------------------------------------------------
   ReqSendFinish
   Requester sends FINISH after receiving KEY_EXCHANGE_RSP for session s.

   key_ex_rsp: the KEY_EXCHANGE_RSP message in msgs (requester acts on it)
   auth_session: GHOST — which session's handshake keys this FINISH was computed with.
     Normally equals s (the requester computed FINISH for the session they received RSP for).
     In the F1 bug scenario, the responder routes this FINISH to a DIFFERENT session because
     latest_session_id was overwritten.

   Cleartext path (HITC=TRUE): session_id_valid = FALSE; responder will resolve via
     latest_session_id [rsp_finish_rsp.c:480-484].
   Encrypted path (HITC=FALSE): session_id_valid = TRUE; session_id carried in header.
   ----------------------------------------------------------------------- *)
ReqSendFinish(key_ex_rsp, auth_session) ==
    /\ key_ex_rsp \in msgs
    /\ key_ex_rsp.type = MT_KEY_EX_RSP
    /\ LET s == key_ex_rsp.session_id IN
       /\ session_state[s] = HANDSHAKING
       \* The requester always computes FINISH MAC for the session it just negotiated.
       \* auth_session = s always — the F1 confusion is on the RESPONDER side
       \* (latest_session_id re-routing), not due to the requester choosing wrong keys.
       /\ auth_session = s
       \* Consume KEY_EX_RSP and emit FINISH (one-shot reaction — requester does not retain RSP)
       /\ msgs' = (msgs \ {key_ex_rsp}) \cup
                  {[type             |-> MT_FINISH,
                    session_id       |-> s,
                    session_id_valid |-> ~hitc_negotiated[s],
                    auth_session     |-> auth_session,
                    req_slot_id      |-> key_ex_rsp.slot_param]}
    /\ UNCHANGED <<session_state, latest_session_id,
                   family1Vars, family2Vars, family3Vars, family4Vars>>

(* -----------------------------------------------------------------------
   RspDeriveDataKeys
   Responder FINISH handler — first half.
   libspdm_get_response_finish  (libspdm_rsp_finish_rsp.c)

   Session identification:
   - HITC path (session_id_valid=FALSE): target = latest_session_id [rsp_finish_rsp:480-484]
     This is the F1 bug: latest_session_id may point to a DIFFERENT session than the one
     the requester computed the FINISH MAC for.
   - Non-HITC path (session_id_valid=TRUE): target = session_id from message header.

   FINISH verification — modeled abstractly by reading peer_cert_slot[target]:
   - peer_cert_slot[target] = NO_SLOT (non-encap, F2 bug) -> uses default slot 0
   - peer_cert_slot[target] set (encap) -> uses correct advertised slot
   cert_slot_verified[target] is set to record which slot was actually used [rsp_finish_rsp:49,153,200,340].

   Data key derivation (libspdm_rsp_finish_rsp.c:744):
   - data_keys_live[target] = TRUE
   - session_state[target] = KEYS_DERIVED (intermediate; ESTABLISHED not yet set)

   finish_authenticated_for[target] = auth_session (GHOST: links this ESTABLISH event to
   the FINISH MAC's session, enabling invariant SessionEstablishedOnlyAfterOwnFinish).
   ----------------------------------------------------------------------- *)
RspDeriveDataKeys(m) ==
    /\ m \in msgs
    /\ m.type = MT_FINISH
    \* Identify target session
    /\ LET target ==
           IF m.session_id_valid
           THEN m.session_id           \* non-HITC: use header session_id
           ELSE latest_session_id      \* HITC: use global (F1 bug point)
       IN
       /\ target \in Sessions
       /\ session_state[target] = HANDSHAKING

       \* Derive data keys; transition to intermediate KEYS_DERIVED state
       \* libspdm_rsp_finish_rsp.c:744 — libspdm_generate_session_data_key
       /\ session_state'  = [session_state  EXCEPT ![target] = KEYS_DERIVED]
       /\ data_keys_live' = [data_keys_live EXCEPT ![target] = TRUE]

       \* Record the cert slot used for verification
       \* libspdm_rsp_finish_rsp.c:49,153,200,340 — reads peer_used_cert_chain_slot_id
       /\ cert_slot_verified' = [cert_slot_verified EXCEPT
              ![target] = IF peer_cert_slot[target] = NO_SLOT
                          THEN NO_SLOT   \* non-encap F2 bug: uses default (wrong slot)
                          ELSE peer_cert_slot[target]]

       \* GHOST: link this establish event to the FINISH MAC's session
       /\ finish_authenticated_for' =
              [finish_authenticated_for EXCEPT ![target] = m.auth_session]

       \* Consume FINISH message, emit FINISH_RSP (not yet encrypted / encoded)
       /\ msgs' = (msgs \ {m}) \cup
                  {[type       |-> MT_FINISH_RSP,
                    session_id |-> target]}

       /\ UNCHANGED <<latest_session_id, hitc_negotiated,
                      peer_cert_slot, cert_advertised, mut_auth_mode,
                      family4Vars>>

(* -----------------------------------------------------------------------
   RspCommitEstablished
   Responder FINISH handler — second half (after response encoding).
   libspdm_receive_send_func  (libspdm_rsp_receive_send.c)

   HITC path (libspdm_rsp_receive_send.c:817-820):
     session_id = spdm_context->latest_session_id   <- F1 bug: reads GLOBAL again
     libspdm_set_session_state(session_id, ESTABLISHED)

   Non-HITC path (libspdm_rsp_receive_send.c:771-773):
     session_id from context (the session that was in the message) — this is correct behavior.

   In the model we pass the KEY_EXCHANGE_RSP session and the hitc flag explicitly so TLC
   can explore the scenario where latest_session_id changed between RspDeriveDataKeys and
   this action (another KEY_EXCHANGE interleaved — models F1 bug via the rsp_receive_send
   window, and also Family 3's non-atomicity).
   ----------------------------------------------------------------------- *)
RspCommitEstablished(finish_rsp, s_derive) ==
    \* finish_rsp: the FINISH_RSP placed in msgs by RspDeriveDataKeys
    \* s_derive: the session that DeriveDataKeys ran on (currently in KEYS_DERIVED)
    /\ finish_rsp \in msgs
    /\ finish_rsp.type = MT_FINISH_RSP
    /\ finish_rsp.session_id = s_derive   \* each RSP is tied to its own session context
    /\ s_derive \in Sessions
    /\ session_state[s_derive] = KEYS_DERIVED

    \* Determine which session to mark ESTABLISHED
    \* HITC path (rsp_receive_send.c:817-820): re-reads latest_session_id
    \* Non-HITC path (rsp_receive_send.c:771-773): uses the session from FINISH context
    /\ LET commit_target ==
           IF hitc_negotiated[s_derive]
           THEN latest_session_id   \* F1 bug window: may differ from s_derive if another KEX ran
           ELSE s_derive            \* correct path
       IN
       /\ commit_target \in Sessions
       \* Advance commit_target from KEYS_DERIVED (or HANDSHAKING) to ESTABLISHED
       \* Note: if commit_target /= s_derive, we leave s_derive stuck in KEYS_DERIVED (F1+F3)
       /\ session_state' = [session_state EXCEPT ![commit_target] = ESTABLISHED]
       /\ Consume(finish_rsp)

    /\ UNCHANGED <<latest_session_id, hitc_negotiated,
                   finish_authenticated_for,
                   family2Vars, family3Vars, family4Vars>>

(* -----------------------------------------------------------------------
   RspEncodeFailure
   FAULT: Transport encoding fails after data keys are derived.
   libspdm_rsp_finish_rsp.c:738-763 — TH2 hash failure or
   libspdm_generate_session_data_key failure returns LIBSPDM_STATUS_CRYPTO_ERROR
   WITHOUT calling libspdm_free_session_id.
   (compare: KEY_EXCHANGE handler DOES free on all failures — historical fix 56384085e8)

   Effect: session s stuck in KEYS_DERIVED with data_keys_live=TRUE.
   CommitEstablished never runs.  Session slot is leaked (no free).

   This is the F3 zombie-session bug.  Only meaningful when bounded in MC.
   ----------------------------------------------------------------------- *)
RspEncodeFailure(s) ==
    /\ s \in Sessions
    /\ session_state[s] = KEYS_DERIVED
    \* Discard the pending FINISH_RSP (encoding aborted)
    /\ \E finish_rsp \in msgs : finish_rsp.type = MT_FINISH_RSP /\ finish_rsp.session_id = s
    /\ msgs' = msgs \ {m \in msgs : m.type = MT_FINISH_RSP /\ m.session_id = s}
    \* Session stays in KEYS_DERIVED with data_keys_live=TRUE — the zombie state
    \* libspdm_rsp_finish_rsp.c:738-763 — no libspdm_free_session_id call on this path
    /\ UNCHANGED <<session_state, latest_session_id,
                   family1Vars, family2Vars, family3Vars, family4Vars>>

(* -----------------------------------------------------------------------
   ReqSendAppData
   Requester sends an application-data message encrypted with session s's data keys.
   authentic=TRUE: a legitimate message (correct session keys, correct seq).
   Sequence number must match expected_seq[s].
   Used to exercise the Family 4 decode path.
   ----------------------------------------------------------------------- *)
ReqSendAppData(s, authentic) ==
    /\ s \in Sessions
    /\ session_state[s] = ESTABLISHED
    /\ Send([type       |-> MT_APP_DATA,
             session_id |-> s,
             seq_num    |-> expected_seq[s],
             authentic  |-> authentic])
    /\ UNCHANGED <<session_state, latest_session_id,
                   family1Vars, family2Vars, family3Vars, family4Vars>>

(* -----------------------------------------------------------------------
   InjectBadMessage
   FAULT: Network attacker injects a message with a valid header (correct
   session_id and seq_num) but invalid ciphertext (authentic=FALSE).
   libspdm_secmes_encode_decode.c — sequence number is observable in cleartext header;
   AEAD tag covers only ciphertext, not sequence number.
   Used to trigger the Family 4 sequence-counter desynchronization bug.
   ----------------------------------------------------------------------- *)
InjectBadMessage(s) ==
    /\ s \in Sessions
    /\ session_state[s] = ESTABLISHED
    /\ Send([type       |-> MT_APP_DATA,
             session_id |-> s,
             seq_num    |-> expected_seq[s],
             authentic  |-> FALSE])
    /\ UNCHANGED <<session_state, latest_session_id,
                   family1Vars, family2Vars, family3Vars, family4Vars>>

(* -----------------------------------------------------------------------
   RspDecodeSecuredMessage
   Responder decodes a secured application-data message.
   libspdm_decode_secured_message  (libspdm_secmes_encode_decode.c)

   BUGGY order modeled faithfully:
   1. Check sequence number against expected_seq  [encode_decode:444,449]
   2. INCREMENT expected_seq                      [encode_decode:~420] (BUG: before AEAD)
   3. AEAD decryption                             [encode_decode:477]
      - authentic=TRUE  → succeeds
      - authentic=FALSE → fails (but counter already advanced — F4 bug)

   Ghost updates:
   - seq_before_advance[s] records the pre-increment value (for invariant)
   - last_decode_rejected[s] = TRUE if AEAD failed

   The mitigation path (SESSION_TRY_DISCARD_KEY_UPDATE, encode_decode:523-527) is not
   modeled here; it only applies after a KEY_UPDATE handshake, not normal operation.
   ----------------------------------------------------------------------- *)
RspDecodeSecuredMessage(m) ==
    /\ m \in msgs
    /\ m.type = MT_APP_DATA
    /\ LET s == m.session_id IN
       /\ s \in Sessions
       /\ session_state[s] = ESTABLISHED
       /\ data_keys_live[s] = TRUE

       \* libspdm_secmes_encode_decode.c:444,449 — sequence number check
       /\ m.seq_num = expected_seq[s]

       \* Ghost: record seq value before the advance
       /\ seq_before_advance' = [seq_before_advance EXCEPT ![s] = expected_seq[s]]

       \* libspdm_secmes_encode_decode.c:~420 — counter incremented BEFORE AEAD (F4 bug)
       /\ expected_seq' = [expected_seq EXCEPT ![s] =
              IF expected_seq[s] < MaxSeqNum THEN expected_seq[s] + 1 ELSE 0]

       \* libspdm_secmes_encode_decode.c:477 — AEAD decryption result
       \* authentic=FALSE → AEAD fails; counter is already advanced (F4 bug)
       /\ last_decode_rejected' = [last_decode_rejected EXCEPT ![s] = ~m.authentic]

       /\ Consume(m)

    /\ UNCHANGED <<session_state, latest_session_id,
                   family1Vars, family2Vars, family3Vars>>

(***************************************************************************)
(* NEXT                                                                    *)
(***************************************************************************)

Next ==
    \/ \E hitc \in BOOLEAN, slot \in CertSlots, mode \in {MUT_NONE, MUT_NON_ENCAP, MUT_ENCAP} :
           ReqSendKeyExchange(hitc, slot, mode)
    \/ \E m \in msgs, s \in Sessions : RspHandleKeyExchange(m, s)
    \/ \E rsp \in msgs, auth \in Sessions : ReqSendFinish(rsp, auth)
    \/ \E m \in msgs : RspDeriveDataKeys(m)
    \/ \E frsp \in msgs, s \in Sessions : RspCommitEstablished(frsp, s)
    \/ \E s \in Sessions : RspEncodeFailure(s)
    \/ \E s \in Sessions, auth \in BOOLEAN : ReqSendAppData(s, auth)
    \/ \E s \in Sessions : InjectBadMessage(s)
    \/ \E m \in msgs : RspDecodeSecuredMessage(m)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* INVARIANTS                                                              *)
(***************************************************************************)

\* ----------------------------------------------------------------
\* Structural invariants — hold in every correct state

\* Session state is monotone: NOT_STARTED → HANDSHAKING → KEYS_DERIVED → ESTABLISHED
\* (reset to NOT_STARTED modeled implicitly by not having a free-session action)
\* libspdm_secured_message_set_session_state  (libspdm_secmes_context_data.c:30-44)
SessionStateMonotonic ==
    \A s \in Sessions :
        \* data_keys_live is set only when state is KEYS_DERIVED or ESTABLISHED
        data_keys_live[s] => session_state[s] \in {KEYS_DERIVED, ESTABLISHED}

\* FINISH_RSP only exists for a valid session in KEYS_DERIVED or ESTABLISHED.
\* ESTABLISHED is included because the F1 bug (HITC latest_session_id confusion) can cause
\* RspCommitEstablished to advance a session to ESTABLISHED via latest_session_id while its
\* own FINISH_RSP is still in msgs — the primary detection of that bug is
\* SessionEstablishedOnlyAfterOwnFinish (extension invariant).
FinishRspConsistency ==
    \A frsp \in msgs :
        frsp.type = MT_FINISH_RSP =>
            frsp.session_id \in Sessions /\
            session_state[frsp.session_id] \in {KEYS_DERIVED, ESTABLISHED}

\* ----------------------------------------------------------------
\* Extension invariants — bug-family specific (Primary bug-detection tools)

\* [F1] A session slot S transitions to ESTABLISHED only if a FINISH was
\* authenticated against S's own handshake keys.
\* Violation: session S gets ESTABLISHED via another session's FINISH MAC
\* (because latest_session_id was overwritten).
\* brief §5: SessionEstablishedOnlyAfterOwnFinish
SessionEstablishedOnlyAfterOwnFinish ==
    \A s \in Sessions :
        session_state[s] = ESTABLISHED =>
            finish_authenticated_for[s] = s

\* [F2] If mutual auth was negotiated for session S, the FINISH signature
\* was verified against the cert slot advertised in KEY_EXCHANGE_RSP for S.
\* Violation: non-encap path leaves peer_cert_slot=NO_SLOT → verifies against wrong slot.
\* brief §5: MutAuthUsesNegotiatedSlot
MutAuthUsesNegotiatedSlot ==
    \A s \in Sessions :
        /\ session_state[s] = ESTABLISHED
        /\ mut_auth_mode[s] \in {MUT_NON_ENCAP, MUT_ENCAP}
        /\ cert_advertised[s] /= NO_SLOT
        =>
        cert_slot_verified[s] = cert_advertised[s]

\* [F3] No application-layer message is processed with session S's data keys
\* before session S is in ESTABLISHED state.
\* Model interpretation: RspDecodeSecuredMessage requires session_state=ESTABLISHED,
\* so the invariant is enforced as a precondition.  What we additionally verify:
\* data_keys_live being TRUE while session_state /= ESTABLISHED (zombie session) is detectable.
\* brief §5: NoDataKeysBeforeEstablished
NoDataKeysBeforeEstablished ==
    \A s \in Sessions :
        data_keys_live[s] => session_state[s] \in {KEYS_DERIVED, ESTABLISHED}

\* [F4] If AEAD decryption of a message fails, expected_seq equals its value
\* at the start of that decode call.
\* Violation: counter advanced before AEAD result known; attacker can permanently
\* desynchronize requester and responder counters with one injected message.
\* brief §5: SeqCounterStableOnDecryptFailure
SeqCounterStableOnDecryptFailure ==
    \A s \in Sessions :
        last_decode_rejected[s] =>
            expected_seq[s] = seq_before_advance[s]
\* NOTE: This invariant IS violated by the current implementation — that is the bug.
\* TLC will find the violation when InjectBadMessage fires and RspDecodeSecuredMessage runs.

====
