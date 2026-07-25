------------------------------ MODULE MC ------------------------------
(*
 * Model checking wrapper for the SPDM MEL base spec.
 *
 * Counter-bounds fault-injection actions (MelUpdate, negotiation variants).
 * Deterministic/reactive actions (RespondGetMelFirstChunk, ProcessGetMelFirstChunkResp,
 * etc.) are NOT bounded — only actions that introduce non-determinism.
 *)

EXTENDS base, Naturals

CONSTANTS
    MelUpdateLimit,     \* max times MEL may change between chunks (Family 1)
    NegotiateLimit      \* max negotiation attempts (covers both cap variants)

VARIABLES
    faultCnt  \* record: [melUpdate: Nat, negotiate: Nat]

MCInit ==
    /\ Init
    /\ faultCnt = [melUpdate |-> 0, negotiate |-> 0]

\* =============================================================
\* Bounded fault-injection wrappers
\* =============================================================

\* MelUpdate is the key adversary action for Family 1.
\* Bounded so TLC doesn't explore unbounded generation increments.
MCMelUpdate ==
    /\ faultCnt.melUpdate < MelUpdateLimit
    /\ MelUpdate
    /\ faultCnt' = [faultCnt EXCEPT !.melUpdate = @ + 1]

\* NegotiateAlgorithmsWithSessionCap: deterministic when wire_val is fixed,
\* but we bound it to avoid repeated negotiation cycles.
MCNegotiateWithSessionCap(w) ==
    /\ faultCnt.negotiate < NegotiateLimit
    /\ NegotiateAlgorithmsWithSessionCap(w)
    /\ faultCnt' = [faultCnt EXCEPT !.negotiate = @ + 1]

MCNegotiateWithoutSessionCap(w) ==
    /\ faultCnt.negotiate < NegotiateLimit
    /\ NegotiateAlgorithmsWithoutSessionCap(w)
    /\ faultCnt' = [faultCnt EXCEPT !.negotiate = @ + 1]

\* =============================================================
\* Pass-through wrappers for reactive (non-fault) actions
\* These are deterministic responses to existing state — not bounded.
\* =============================================================

MCSendGetMelFirstChunk ==
    /\ SendGetMelFirstChunk
    /\ UNCHANGED faultCnt

MCRespondGetMelFirstChunk(p) ==
    /\ RespondGetMelFirstChunk(p)
    /\ UNCHANGED faultCnt

MCProcessGetMelFirstChunkResp ==
    /\ ProcessGetMelFirstChunkResp
    /\ UNCHANGED faultCnt

MCSendGetMelNextChunk ==
    /\ SendGetMelNextChunk
    /\ UNCHANGED faultCnt

MCRespondGetMelNextChunk(p) ==
    /\ RespondGetMelNextChunk(p)
    /\ UNCHANGED faultCnt

MCProcessGetMelNextChunkResp ==
    /\ ProcessGetMelNextChunkResp
    /\ UNCHANGED faultCnt

\* Error path: Responder rejects GET_MEL because mel_spec_conn = 0.
\* libspdm_rsp_measurement_extension_log.c:86-91: mel_spec != 0 check fires,
\* Responder returns an error response, Requester transfer is aborted.
\* Resolves the deadlock caused by the MelSpecPreSend bug (Family 3):
\* the Requester sends GET_MEL without checking mel_spec_conn != 0,
\* and the Responder rejects it. MelSpecPreSend captures this bug when enabled.
MCRespondGetMelError ==
    /\ req_pending
    /\ ~rsp_pending
    /\ mel_spec_conn = MEL_SPEC_UNSET
    /\ req_pending' = FALSE
    /\ transfer_state' = TS_IDLE
    /\ UNCHANGED <<connVars, respVars,
                   mel_offset, mel_snapshot_gen, first_portion_len,
                   req_offset, req_length,
                   rsp_pending, rsp_portion_len, rsp_remainder, rsp_generation,
                   faultCnt>>

\* =============================================================
\* MCNext
\* =============================================================

MCNext ==
    \/ \E w \in {MEL_SPEC_UNSET, MEL_SPEC_DMTF, MEL_SPEC_INVALID} :
           MCNegotiateWithSessionCap(w)
    \/ \E w \in {MEL_SPEC_UNSET, MEL_SPEC_DMTF, MEL_SPEC_INVALID} :
           MCNegotiateWithoutSessionCap(w)
    \/ MCMelUpdate
    \/ MCSendGetMelFirstChunk
    \/ \E p \in 1..MAX_CHUNK : MCRespondGetMelFirstChunk(p)
    \/ MCRespondGetMelError
    \/ MCProcessGetMelFirstChunkResp
    \/ MCSendGetMelNextChunk
    \/ \E p \in 1..MAX_CHUNK : MCRespondGetMelNextChunk(p)
    \/ MCProcessGetMelNextChunkResp

MCSpec == MCInit /\ [][MCNext]_<<vars, faultCnt>>

\* =============================================================
\* Symmetry / View
\* =============================================================

\* No symmetry reduction needed (no symmetric server set).
\* Exclude fault counters from the state fingerprint to reduce duplicate states.
MCView == vars

\* =============================================================
\* Message buffer pruning
\* (channel is single-slot; no extra pruning needed)
\* =============================================================

\* =============================================================
\* Structural invariants (always enabled in MC.cfg)
\* =============================================================

MCTypeOK      == TypeOK /\ faultCnt \in [melUpdate: Nat, negotiate: Nat]
MCChannelOK   == ChannelOK
MCOffsetGrowth == OffsetGrowth

\* =============================================================
\* Extension invariants — targeted in MC_hunt_*.cfg
\* Listed here for reference; commented out in MC.cfg
\* =============================================================

\* MCMelConsistency  == MelConsistency
\* MCMelHeaderComplete == MelHeaderComplete
\* MCMelSpecValid    == MelSpecValid
\* MCMelSpecPreSend  == MelSpecPreSend

======================================================================
