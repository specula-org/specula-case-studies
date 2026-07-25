----------------------- MODULE MC -------------------------
(* Model Checking wrapper for base spec with counter-bounded fault injection *)

EXTENDS base, Naturals

CONSTANTS
    (* Fault injection bounds *)
    MaxEndianSwaps,
    MaxKeyUpdateInitiations,
    MaxMessageLosses,
    MaxSequenceJumps

------------------------------------------------------------------------
(* FAULT INJECTION ACTIONS *)

(* Family 1: Force endianness determination with wrong choice *)
MCBugEndianWrongChoice(role, sid) ==
    /\ faultCounters.endian_swaps < MaxEndianSwaps
    /\ response_seq_num[role][sid] = 1
    /\ seq_num_endian[role][sid] \in {LITTLE_ENC_BOTH, BIG_ENC_BOTH}
    (* Inject fault: swap to opposite endian *)
    /\ LET opposite_endian ==
            IF seq_num_endian[role][sid] = LITTLE_ENC_BOTH
            THEN BIG_ENC_BIG ELSE LITTLE_ENC_LITTLE
       IN
           /\ seq_num_endian' = [seq_num_endian EXCEPT ![role][sid] = opposite_endian]
           /\ endian_determined_at' = [endian_determined_at EXCEPT ![role][sid] = 1]
           /\ response_seq_num' = [response_seq_num EXCEPT ![role][sid] = 2]
    /\ faultCounters' = [faultCounters EXCEPT !.endian_swaps = @ + 1]
    /\ UNCHANGED <<session_state, request_seq_num, key_update_phase, backup_valid,
                    application_secret, application_secret_backup, secrets_cleared,
                    messages, msg_history>>

(* Family 2: Desynchronize key update - one side pending, other IDLE *)
MCBugKeyUpdateDesync(role1, sid1, role2, sid2) ==
    /\ faultCounters.key_desync < MaxKeyUpdateInitiations
    /\ role1 /= role2  \* Different roles for multi-peer effect
    /\ key_update_phase[role1][sid1] = PENDING
    /\ backup_valid[role1][sid1] = TRUE
    /\ key_update_phase[role2][sid2] = IDLE
    (* Inject fault: force role2 to stay IDLE despite role1's pending *)
    /\ UNCHANGED <<session_state, request_seq_num, response_seq_num,
                    seq_num_endian, endian_determined_at, key_update_phase,
                    backup_valid, application_secret, application_secret_backup,
                    secrets_cleared, messages, msg_history>>
    /\ faultCounters' = [faultCounters EXCEPT !.key_desync = @ + 1]

(* Family 4: Try to overflow sequence number *)
MCBugSequenceOverflow(role, sid) ==
    /\ faultCounters.seq_jumps < MaxSequenceJumps
    /\ session_state[role][sid] = ESTABLISHED
    /\ request_seq_num[role][sid] < MaxSeqNum
    (* Inject: jump sequence number close to limit *)
    /\ request_seq_num' = [request_seq_num EXCEPT ![role][sid] = MaxSeqNum - 1]
    /\ faultCounters' = [faultCounters EXCEPT !.seq_jumps = @ + 1]
    /\ UNCHANGED <<session_state, response_seq_num, seq_num_endian,
                    endian_determined_at, key_update_phase, backup_valid,
                    application_secret, application_secret_backup, secrets_cleared,
                    messages, msg_history>>

(* Family 3: Attempt to encode while secrets not cleared *)
MCBugEncodeBeforeZeroization(role, sid) ==
    /\ session_state[role][sid] = ESTABLISHED
    /\ secrets_cleared[role][sid] = FALSE  \* Still uncleared
    /\ request_seq_num[role][sid] < MaxSeqNum
    (* Allow encoding anyway (spec bug) *)
    /\ LET seq == request_seq_num[role][sid]
           msg == [type |-> REQUEST_MSG, sender |-> role, session_id |-> sid,
                   seq |-> seq, secrets_cleared |-> FALSE]
       IN
           /\ messages' = Append(messages, msg)
           /\ request_seq_num' = [request_seq_num EXCEPT ![role][sid] = seq + 1]
    /\ faultCounters' = [faultCounters EXCEPT !.clearance_violation = @ + 1]
    /\ UNCHANGED <<session_state, response_seq_num, seq_num_endian,
                    endian_determined_at, key_update_phase, backup_valid,
                    application_secret, application_secret_backup, secrets_cleared,
                    msg_history>>

------------------------------------------------------------------------
(* MODEL CHECKING INIT *)

MCInit ==
    /\ Init
    /\ faultCounters = [endian_swaps |-> 0, key_desync |-> 0, seq_jumps |-> 0,
                        clearance_violation |-> 0]

------------------------------------------------------------------------
(* MODEL CHECKING NEXT (base actions + bounded faults) *)

MCNext ==
    \/ \E role \in Roles, sid \in SessionIDs :
        \/ InitializeSession(role, sid)
        \/ TransitionToEstablished(role, sid)
        \/ CompleteZeroization(role, sid)
        \/ EncodeSecuredMessage(role, sid)
        \/ AttemptDecodeFirstEndian(role, sid)
        \/ InitiateKeyUpdate(role, sid)
        \/ ConfirmKeyUpdate(role, sid)
        \/ RollbackToBackupKey(role, sid)
        \/ CloseSessionAtMaxSeqNum(role, sid)
        \/ MCBugEndianWrongChoice(role, sid)
        \/ MCBugSequenceOverflow(role, sid)
        \/ MCBugEncodeBeforeZeroization(role, sid)
    \/ \E role1 \in Roles, sid1 \in SessionIDs, role2 \in Roles, sid2 \in SessionIDs :
        MCBugKeyUpdateDesync(role1, sid1, role2, sid2)

------------------------------------------------------------------------
(* SPECIFICATION *)

MCSpec == MCInit /\ [][MCNext]_varAll

========================================================================
