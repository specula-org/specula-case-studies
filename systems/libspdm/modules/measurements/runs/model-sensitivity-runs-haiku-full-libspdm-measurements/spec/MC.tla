--------------------------- MODULE MC ---------------------------
(* Model Checking Wrapper for base.tla
 * Adds counter-bounded fault injection and state space constraints
 *)

EXTENDS base, Naturals, Sequences, FiniteSets, TLC

\* ============================================================================
\* Fault Injection Counters
\* ============================================================================

VARIABLE faultVars

CrashCount == faultVars.crashCount
MessageLossCount == faultVars.messageLossCount
VersionMismatchCount == faultVars.versionMismatchCount

\* ============================================================================
\* Constants for Fault Injection Bounds
\* ============================================================================

CONSTANT MaxCrashLimit, MaxMessageLossLimit, MaxVersionMismatchLimit

ASSUME MaxCrashLimit \in 0..5 /\ MaxMessageLossLimit \in 0..5 /\ MaxVersionMismatchLimit \in 0..5

\* ============================================================================
\* MC Init: Initialize faultVars
\* ============================================================================

MCInit ==
    /\ Init
    /\ faultVars = [crashCount |-> 0,
                    messageLossCount |-> 0,
                    versionMismatchCount |-> 0]

\* ============================================================================
\* Wrapped Fault Injection Actions
\* ============================================================================

\* Crash: limited by counter
MCCrash ==
    /\ CrashCount < MaxCrashLimit
    /\ Crash
    /\ faultVars' = [faultVars EXCEPT !.crashCount = CrashCount + 1]

\* Message Loss: limited by counter
MCMessageLoss ==
    /\ MessageLossCount < MaxMessageLossLimit
    /\ MessageLoss
    /\ faultVars' = [faultVars EXCEPT !.messageLossCount = MessageLossCount + 1]

\* Version Mismatch: limited by counter
MCVersionMismatch ==
    /\ VersionMismatchCount < MaxVersionMismatchLimit
    /\ VersionMismatch
    /\ faultVars' = [faultVars EXCEPT !.versionMismatchCount = VersionMismatchCount + 1]

\* ============================================================================
\* Normal (Non-Fault) Actions - Deterministic, Not Bounded
\* ============================================================================

MCNormalNext ==
    \/ \E v \in ValidSpdmVersions : NegotiateVersionRequester(v)
    \/ \E v \in ValidSpdmVersions : NegotiateVersionResponder(v)
    \/ \E sid \in 1..SESSION_ID_MAX : EstablishSession(sid)
    \/ ReceiveGetMeasurementsRequest
    \/ AppendRequestToTranscript
    \/ AppendResponseToTranscript
    \/ \E slot \in 0..(MAX_SLOT_COUNT-1) \cup {15} : ValidateSlotIDForSignature(slot)
    \/ ComputeSignature
    \/ ResetTranscriptAfterSignature
    \/ \E ctx \in {0, 1} : SendGetMeasurementsResponse(ctx)
    \/ \E sig \in {TRUE, FALSE} : \E ctx \in {0, 1} : BuildGetMeasurementsRequest(sig, ctx)
    \/ ValidateContextEcho
    \/ \E slot \in 0..(MAX_SLOT_COUNT-1) \cup {15} : VerifyMeasurementSignature(slot)

\* Bounded fault actions
MCFaultNext ==
    \/ MCCrash
    \/ MCMessageLoss
    \/ MCVersionMismatch

\* ============================================================================
\* MC Next State
\* ============================================================================

MCNext ==
    \/ (MCNormalNext /\ UNCHANGED faultVars)
    \/ MCFaultNext

\* ============================================================================
\* All MC Variables
\* ============================================================================

mcVars == <<vars, faultVars>>

\* ============================================================================
\* Symmetry Reduction
\* ============================================================================

\* Symmetric permutations of slot IDs
\* (15 is special and exempt from symmetry)
Symmetry == Permutations(0..(MAX_SLOT_COUNT-2))

\* ============================================================================
\* State Space Constraints
\* ============================================================================

\* Limit message queue depth to avoid explosion
MessageQueueBounded ==
    /\ (req_message.type = "GET_MEASUREMENTS") => (resp_message.type = "IDLE")

\* Prevent unbounded session IDs
SessionIDsBounded ==
    /\ session_id \in {NULL_SESSION_ID} \cup 1..10

\* ============================================================================
\* Invariants from Base Spec (Some Commented for Hunting)
\* ============================================================================

\* Standard Safety Invariants
TypeOK ==
    /\ role \in {"requester", "responder"}
    /\ spdm_version \in ValidSpdmVersions
    /\ session_state \in {"UNSECURED", "SESSION_ESTABLISHED", "SESSION_CLOSED"}
    /\ session_id \in {NULL_SESSION_ID} \cup 1..SESSION_ID_MAX
    /\ req_message.type \in {"IDLE", "GET_MEASUREMENTS"}
    /\ resp_message.type \in {"IDLE", "MEASUREMENTS"}
    /\ request_format_version \in ValidSpdmVersions
    /\ response_format_version \in ValidSpdmVersions

\* Extension Invariants (Bug-Family Specific - Commented Out, Enabled in Hunting Configs)

\* Family 1: Version-Dependent Message Handling
\* InvariantVersionFamily1 == TRUE

\* Family 2: Inconsistent State Validation
\* InvariantSessionFamily2 == TRUE

\* Family 3: Non-Atomic Signature Generation
\* InvariantTranscriptFamily3 == base!TranscriptResetAfterSignature
\* InvariantSignatureFamily3 == base!SignatureCoversFullTranscript

\* Family 4: Opaque Data Validation
\* InvariantOpaqueDataFamily4 == base!OpaqueDataValidation

\* Family 5: Requester Context Binding
\* InvariantContextFamily5 == base!ContextEchoedCorrectly

\* Family 6: Signature Slot ID Consistency
\* InvariantSlotIDFamily6 == base!SlotIDConsistency

\* Core invariants imported from base through EXTENDS

=============================================================================
