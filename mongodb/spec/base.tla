---- MODULE base ----
\* ===========================================================================
\* MongoDB Transaction Router & Resource Contention
\* ===========================================================================
\*
\* Models implementation-level concurrency bugs in MongoDB's distributed
\* transaction system. Targets 4 bug families identified from 52 historical
\* bug-fix commits:
\*
\*   Family 1: Router Commit Type Selection (25% of bugs)
\*     Source: transaction_router.cpp:1649-1771 (_commitTransaction)
\*     Bugs: SERVER-40201, SERVER-39973, SERVER-116284, SERVER-84796
\*
\*   Family 2: Ticket Starvation Deadlock (23% of bugs)
\*     Source: transaction_coordinator_util.cpp:496-500 (kExempt fix)
\*     Bugs: SERVER-60682, SERVER-65821, SERVER-82883, SERVER-115594
\*
\*   Family 3: Error Code Misclassification (15% of bugs)
\*     Source: transaction_coordinator_util.cpp:836-956, error_codes.yml
\*     Bugs: SERVER-106075, SERVER-105751, SERVER-50470
\*
\*   Family 4: Single-Write-Shard Retry Safety (6% of bugs)
\*     Source: transaction_router.cpp:1704-1746
\*     Bugs: SERVER-48307, SERVER-84796, SERVER-102481
\*
\* Abstraction: Decision logic & resource contention, NOT protocol messages.
\* The 2PC message exchange is abstracted (verified separately, 93M+ states).
\*
\* Source: mongodb/mongo commit 1425a42
\* ===========================================================================

EXTENDS Integers, FiniteSets, Sequences, TLC

\* ===========================================================================
\* Constants
\* ===========================================================================

CONSTANTS
    Shard,              \* Set of shard IDs
    Router,             \* Set of router IDs (typically 1 for MC)
    Txn,                \* Set of transaction IDs
    MaxTickets,         \* WiredTiger write ticket pool size [Family 2]
    CoordTicketExempt   \* BOOLEAN: TRUE = coordinator uses kExempt bypass
                        \* (SERVER-60682 fix: transaction_coordinator_util.cpp:499
                        \*  ScopedAdmissionPriority kExempt)

ASSUME MaxTickets >= 1
ASSUME CoordTicketExempt \in BOOLEAN

\* ===========================================================================
\* Value Constants
\* ===========================================================================

\* --- Commit types (transaction_router.h CommitType enum) ---
CTNone     == "CT_none"
CTNoShards == "CT_noShards"      \* transaction_router.cpp:1658
CTSingle   == "CT_single"        \* transaction_router.cpp:1696
CTSWS      == "CT_sws"           \* transaction_router.cpp:1714
CTReadOnly == "CT_readOnly"      \* transaction_router.cpp:1758
CT2PC      == "CT_2pc"           \* transaction_router.cpp:1767
CTRecover  == "CT_recover"       \* transaction_router.cpp:1642

\* --- Participant kinds (transaction_router.cpp:1668-1681) ---
PKNone     == "PK_none"          \* Not a participant
PKReadOnly == "PK_ro"            \* Participant::ReadOnly::kReadOnly (line 1675)
PKWrite    == "PK_wr"            \* Participant::ReadOnly::kNotReadOnly (line 1678)

\* --- Router phases ---
RPIdle      == "RP_idle"         \* No transaction
RPStarted   == "RP_started"      \* Txn started, participants assigned
RPCommitting == "RP_committing"  \* Commit type selected, executing
RPDone      == "RP_done"         \* Commit succeeded
RPAborted   == "RP_aborted"      \* Transaction aborted
RPFailed    == "RP_failed"       \* Commit failed (retryable)

\* --- Coordinator phases ---
CPNone      == "CP_none"         \* No coordinator
CPPreparing == "CP_preparing"    \* Preparing participants
CPDecided   == "CP_decided"      \* Decision made, not yet persisted
CPSending   == "CP_sending"      \* Sending decision to participants
CPDone      == "CP_done"         \* All acks received, cleanup done

\* --- Shard transaction states (transaction_participant.cpp:3020-3088) ---
SSNone       == "SS_none"
SSInProgress == "SS_inProg"      \* kInProgress
SSPrepared   == "SS_prepared"    \* kPrepared — holds locks and ticket
SSCommitted  == "SS_committed"   \* kCommitted
SSAborted    == "SS_aborted"     \* kAbortedWith(out)Prepare
SSReaped     == "SS_reaped"      \* Session destroyed by reaper [Family 3]

\* --- Decisions ---
DNone   == "D_none"
DCommit == "D_commit"
DAbort  == "D_abort"

\* --- Error responses (error_codes.yml) ---
ROk            == "R_ok"
RNoSuchTxn     == "R_noSuchTxn"      \* Code 251
RTxnTooOld     == "R_txnTooOld"      \* Code 225
RAPIMismatch   == "R_apiMismatch"    \* Code 347

\* Error categories (error_codes.yml:21-29)
\* isVoteAbortError: codes 148, 225, 251, 263, 347, 356
VoteAbortErrors   == {RNoSuchTxn, RTxnTooOld, RAPIMismatch}
\* isTwoPhaseDecisionAckError: codes 225, 251, 356
DecisionAckErrors == {RNoSuchTxn, RTxnTooOld}

\* --- SWS execution phases [Family 4] ---
SWNone       == "SW_none"
SWReadOnly   == "SW_readOnly"    \* Entered SWS path
SWWriteReady == "SW_writeReady"  \* Read-only done, write shard next
SWDone       == "SW_done"
SWFailed     == "SW_failed"

\* ===========================================================================
\* Variables
\* ===========================================================================

VARIABLES
    \* --- Router state [Family 1, 4] ---
    rPhase,          \* [Router -> [Txn -> RouterPhases]]
    rCommitType,     \* [Router -> [Txn -> CommitTypes]]
    rPK,             \* [Router -> [Txn -> [Shard -> ParticipantKinds]]]
    rAttempt,        \* [Router -> [Txn -> Nat]] — commit attempt number
    rDisallowSWS,    \* [Router -> [Txn -> BOOLEAN]] — sticky flag [Family 4]

    \* --- Coordinator state [Family 2, 3] ---
    cPhase,          \* [Txn -> CoordPhases]
    cDecision,       \* [Txn -> Decisions]
    cParticipants,   \* [Txn -> SUBSET Shard] — enrolled participants
    cAcks,           \* [Txn -> SUBSET Shard] — shards that acked decision

    \* --- Shard/Participant state ---
    sState,          \* [Shard -> [Txn -> ShardStates]]

    \* --- Ticket pool [Family 2] ---
    tickets,         \* Nat — available write tickets (0..MaxTickets)
    bgWaiting,       \* [Shard -> BOOLEAN] — background task holding ticket

    \* --- Error/Response tracking [Family 3] ---
    sResponse,       \* [Shard -> [Txn -> Responses]] — last response from shard

    \* --- SWS state [Family 4] ---
    swPhase          \* [Router -> [Txn -> SWSPhases]]

\* Variable groups for UNCHANGED clauses
routerVars == <<rPhase, rCommitType, rPK, rAttempt, rDisallowSWS>>
coordVars  == <<cPhase, cDecision, cParticipants, cAcks>>
shardVars  == <<sState>>
ticketVars == <<tickets, bgWaiting>>
respVars   == <<sResponse>>
swsVars    == <<swPhase>>

vars == <<routerVars, coordVars, shardVars, ticketVars, respVars, swsVars>>

\* ===========================================================================
\* Helpers
\* ===========================================================================

\* Participants by kind for router r, transaction t
ReadOnlyShards(r, t) == {s \in Shard : rPK[r][t][s] = PKReadOnly}
WriteShards(r, t)    == {s \in Shard : rPK[r][t][s] = PKWrite}
AllParticipants(r, t) == ReadOnlyShards(r, t) \cup WriteShards(r, t)

\* Is first commit attempt? (transaction_router.cpp:1718)
IsFirstAttempt(r, t) == rAttempt[r][t] = 0

\* The single write shard (for SWS path — exactly 1 write shard)
WriteShard(r, t) == CHOOSE s \in WriteShards(r, t) : TRUE

\* Commit type selection — transaction_router.cpp:1649-1771
\* Faithfully models the if-else chain order in _commitTransaction()
SelectCommitType(r, t) ==
    LET P  == AllParticipants(r, t)
        W  == WriteShards(r, t)
        nP == Cardinality(P)
        nW == Cardinality(W)
    IN
    IF nP = 0 THEN CTNoShards              \* line 1649: participants.empty()
    ELSE IF nP = 1 THEN CTSingle           \* line 1684: participants.size() == 1
    ELSE IF nW = 1 /\ ~rDisallowSWS[r][t]
         THEN CTSWS                         \* line 1704: writeShards.size()==1 && !disallow
    ELSE IF nW = 0 THEN CTReadOnly          \* line 1748: writeShards.size() == 0
    ELSE CT2PC                              \* line 1765: multiple write shards

\* ===========================================================================
\* Init
\* ===========================================================================

Init ==
    /\ rPhase       = [r \in Router |-> [t \in Txn |-> RPIdle]]
    /\ rCommitType  = [r \in Router |-> [t \in Txn |-> CTNone]]
    /\ rPK          = [r \in Router |-> [t \in Txn |-> [s \in Shard |-> PKNone]]]
    /\ rAttempt     = [r \in Router |-> [t \in Txn |-> 0]]
    /\ rDisallowSWS = [r \in Router |-> [t \in Txn |-> FALSE]]
    /\ cPhase       = [t \in Txn |-> CPNone]
    /\ cDecision    = [t \in Txn |-> DNone]
    /\ cParticipants = [t \in Txn |-> {}]
    /\ cAcks        = [t \in Txn |-> {}]
    /\ sState       = [s \in Shard |-> [t \in Txn |-> SSNone]]
    /\ tickets      = MaxTickets
    /\ bgWaiting    = [s \in Shard |-> FALSE]
    /\ sResponse    = [s \in Shard |-> [t \in Txn |-> ROk]]
    /\ swPhase      = [r \in Router |-> [t \in Txn |-> SWNone]]

\* ===========================================================================
\* Actions: Transaction Setup
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* RouterStartTxn — Router starts a transaction targeting participant shards.
\*
\* Source: transaction_router.cpp beginOrContinueTxn, processParticipantResponse
\*
\* Non-determinism: which shards participate and their read/write kind.
\* A write shard misclassified as read-only leads to wrong commit type [F1].
\* The disallowSWS flag may be stuck from a previous txn [F4, SERVER-102481].
\* ---------------------------------------------------------------------------
RouterStartTxn(r, t) ==
    /\ rPhase[r][t] = RPIdle
    /\ \E participants \in (SUBSET Shard) \ {{}} :
        \E kindMap \in [participants -> {PKReadOnly, PKWrite}] :
            /\ rPK' = [rPK EXCEPT ![r][t] =
                [s \in Shard |-> IF s \in participants
                                 THEN kindMap[s] ELSE PKNone]]
            /\ rPhase' = [rPhase EXCEPT ![r][t] = RPStarted]
            \* Shards move to inProgress when first contacted
            \* transaction_participant.cpp: beginOrContinueTransactionUnconditionally
            /\ sState' = [s \in Shard |->
                IF s \in participants
                THEN [sState[s] EXCEPT ![t] = SSInProgress]
                ELSE sState[s]]
    \* [Family 4] disallowSWS may be stuck (SERVER-102481)
    /\ \E flag \in BOOLEAN :
        rDisallowSWS' = [rDisallowSWS EXCEPT ![r][t] = flag]
    /\ UNCHANGED <<rCommitType, rAttempt, coordVars, ticketVars, respVars, swsVars>>

\* ===========================================================================
\* Actions: Family 1 — Router Commit Type Selection
\* Source: transaction_router.cpp:1649-1771 (_commitTransaction)
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* RouterCommitTxn — Select commit type and initiate execution.
\*
\* Models the 5-way if-else chain in _commitTransaction().
\* The commit type is a deterministic function of participant classification.
\* This is the core action for Family 1 — wrong selection = wrong path.
\*
\* Source lines for each branch:
\*   CTNoShards:  1649-1663 (participants.empty())
\*   CTSingle:    1684-1702 (participants.size() == 1)
\*   CTSWS:       1704-1746 (writeShards.size()==1 && !disallowSWS)
\*   CTReadOnly:  1748-1763 (writeShards.size() == 0)
\*   CT2PC:       1765-1771 (else — hand off to coordinator)
\* ---------------------------------------------------------------------------
RouterCommitTxn(r, t) ==
    /\ rPhase[r][t] = RPStarted
    /\ LET ct == SelectCommitType(r, t)
           P  == AllParticipants(r, t)
       IN
       /\ rCommitType' = [rCommitType EXCEPT ![r][t] = ct]
       /\ rPhase' = [rPhase EXCEPT ![r][t] =
            IF ct = CTNoShards THEN RPDone ELSE RPCommitting]
       \* For 2PC: start coordinator — transaction_router.cpp:1770
       /\ cPhase' = [cPhase EXCEPT ![t] =
            IF ct = CT2PC THEN CPPreparing ELSE @]
       /\ cParticipants' = [cParticipants EXCEPT ![t] =
            IF ct = CT2PC THEN P ELSE @]
       /\ UNCHANGED <<cDecision, cAcks>>
       \* For SWS: enter SWS phase — transaction_router.cpp:1714
       /\ swPhase' = [swPhase EXCEPT ![r][t] =
            IF ct = CTSWS THEN SWReadOnly ELSE @]
    /\ UNCHANGED <<rPK, rAttempt, rDisallowSWS, shardVars, ticketVars, respVars>>

\* ---------------------------------------------------------------------------
\* DirectCommit — Execute direct commit (singleShard or readOnly paths).
\*
\* Source: sendCommitDirectlyToShards (transaction_router.cpp:1701, 1762)
\* All participants receive commitTransaction and transition to committed.
\* ---------------------------------------------------------------------------
DirectCommit(r, t) ==
    /\ rPhase[r][t] = RPCommitting
    /\ rCommitType[r][t] \in {CTSingle, CTReadOnly}
    /\ LET P == AllParticipants(r, t) IN
       /\ \A s \in P : sState[s][t] = SSInProgress
       /\ sState' = [s \in Shard |->
            IF s \in P THEN [sState[s] EXCEPT ![t] = SSCommitted]
            ELSE sState[s]]
       /\ rPhase' = [rPhase EXCEPT ![r][t] = RPDone]
    /\ UNCHANGED <<rCommitType, rPK, rAttempt, rDisallowSWS,
                   coordVars, ticketVars, respVars, swsVars>>

\* ---------------------------------------------------------------------------
\* DirectCommitPartial — SERVER-116284: commit loop exits early on error.
\*
\* Models: AsyncRequestsSender destroyed before all commits dispatched.
\* Only a strict subset of participants receives commit.
\* [Family 1] Fault injection.
\* ---------------------------------------------------------------------------
DirectCommitPartial(r, t) ==
    /\ rPhase[r][t] = RPCommitting
    /\ rCommitType[r][t] \in {CTSingle, CTReadOnly}
    /\ LET P == AllParticipants(r, t) IN
       /\ Cardinality(P) > 1  \* Partial send needs >1 participant
       /\ \A s \in P : sState[s][t] = SSInProgress
       /\ \E committed \in (SUBSET P) \ {{}, P} :
            sState' = [s \in Shard |->
                IF s \in committed
                THEN [sState[s] EXCEPT ![t] = SSCommitted]
                ELSE sState[s]]
       /\ rPhase' = [rPhase EXCEPT ![r][t] = RPFailed]
    /\ UNCHANGED <<rCommitType, rPK, rAttempt, rDisallowSWS,
                   coordVars, ticketVars, respVars, swsVars>>

\* ===========================================================================
\* Actions: Family 4 — Single-Write-Shard Execution
\* Source: transaction_router.cpp:1704-1746
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* SWSCommitReadOnly — Phase 1: commit read-only shards (first attempt).
\*
\* Source: transaction_router.cpp:1734
\*   auto readOnlyShardsResponse = sendCommitDirectlyToShards(opCtx, readOnlyShards);
\* ---------------------------------------------------------------------------
SWSCommitReadOnly(r, t) ==
    /\ rPhase[r][t] = RPCommitting
    /\ rCommitType[r][t] = CTSWS
    /\ swPhase[r][t] = SWReadOnly
    /\ IsFirstAttempt(r, t)
    /\ LET RO == ReadOnlyShards(r, t) IN
       /\ \A s \in RO : sState[s][t] = SSInProgress
       /\ sState' = [s \in Shard |->
            IF s \in RO THEN [sState[s] EXCEPT ![t] = SSCommitted]
            ELSE sState[s]]
       /\ swPhase' = [swPhase EXCEPT ![r][t] = SWWriteReady]
    /\ UNCHANGED <<rPhase, rCommitType, rPK, rAttempt, rDisallowSWS,
                   coordVars, ticketVars, respVars>>

\* ---------------------------------------------------------------------------
\* SWSReadOnlyFail — Read-only phase fails (first attempt).
\*
\* Source: transaction_router.cpp:1738-1744
\*   if (!readOnlyCmdStatus.isOK()) return readOnlyShardsResponse;
\*   if (!readOnlyWCE.isOK()) uassertStatusOK(readOnlyWCE);
\*
\* [Family 4] Fault injection: read-only commit fails, write shard not touched.
\* ---------------------------------------------------------------------------
SWSReadOnlyFail(r, t) ==
    /\ rPhase[r][t] = RPCommitting
    /\ rCommitType[r][t] = CTSWS
    /\ swPhase[r][t] = SWReadOnly
    /\ IsFirstAttempt(r, t)
    /\ swPhase' = [swPhase EXCEPT ![r][t] = SWFailed]
    /\ rPhase' = [rPhase EXCEPT ![r][t] = RPFailed]
    /\ UNCHANGED <<rCommitType, rPK, rAttempt, rDisallowSWS,
                   coordVars, shardVars, ticketVars, respVars>>

\* ---------------------------------------------------------------------------
\* SWSCommitWrite — Phase 2: commit write shard (after read-only success).
\*
\* Source: transaction_router.cpp:1745
\*   return sendCommitDirectlyToShards(opCtx, writeShards);
\* ---------------------------------------------------------------------------
SWSCommitWrite(r, t) ==
    /\ rPhase[r][t] = RPCommitting
    /\ rCommitType[r][t] = CTSWS
    /\ swPhase[r][t] = SWWriteReady
    /\ LET ws == WriteShard(r, t) IN
       /\ sState[ws][t] = SSInProgress
       /\ sState' = [sState EXCEPT ![ws][t] = SSCommitted]
    /\ swPhase' = [swPhase EXCEPT ![r][t] = SWDone]
    /\ rPhase' = [rPhase EXCEPT ![r][t] = RPDone]
    /\ UNCHANGED <<rCommitType, rPK, rAttempt, rDisallowSWS,
                   coordVars, ticketVars, respVars>>

\* ---------------------------------------------------------------------------
\* SWSWriteFail — Write shard commit fails with unknown error.
\*
\* Source: transaction_router.cpp:1745 (sendCommitDirectlyToShards error)
\* The write shard may or may not have committed (network error).
\* Router transitions to failed, retry will use recovery token.
\*
\* [Family 4] The non-deterministic committed flag models the in-flight
\* uncertainty that leads to SERVER-48307.
\* ---------------------------------------------------------------------------
SWSWriteFail(r, t) ==
    /\ rPhase[r][t] = RPCommitting
    /\ rCommitType[r][t] = CTSWS
    /\ swPhase[r][t] = SWWriteReady
    /\ LET ws == WriteShard(r, t) IN
       /\ \E committed \in BOOLEAN :
            sState' = [sState EXCEPT ![ws][t] =
                IF committed THEN SSCommitted ELSE SSInProgress]
    /\ swPhase' = [swPhase EXCEPT ![r][t] = SWFailed]
    /\ rPhase' = [rPhase EXCEPT ![r][t] = RPFailed]
    /\ UNCHANGED <<rCommitType, rPK, rAttempt, rDisallowSWS,
                   coordVars, ticketVars, respVars>>

\* ---------------------------------------------------------------------------
\* SWSRetryRecovery — Retry with recovery token (non-first attempt).
\*
\* Source: transaction_router.cpp:1718-1731
\*   if (!isFirstCommitAttempt) {
\*       TxnRecoveryToken syntheticRecoveryToken;
\*       syntheticRecoveryToken.setRecoveryShardId(writeShards[0]);
\*       return _commitWithRecoveryToken(opCtx, syntheticRecoveryToken);
\*   }
\*
\* Recovery sends coordinateCommitTransaction with empty participants to the
\* write shard. The write shard checks local participant state:
\*   - SSCommitted → return commit (safe)
\*   - SSInProgress → abort it (SERVER-48307 pattern)
\*   - SSAborted → return abort
\*
\* [Family 4] Models the recovery token protocol and its failure modes.
\* ---------------------------------------------------------------------------
SWSRetryRecovery(r, t) ==
    /\ rPhase[r][t] = RPCommitting
    /\ rCommitType[r][t] = CTSWS
    /\ swPhase[r][t] = SWReadOnly     \* Re-entered SWS branch on retry
    /\ ~IsFirstAttempt(r, t)           \* Must be a retry (line 1718)
    /\ LET ws == WriteShard(r, t) IN
       /\ rCommitType' = [rCommitType EXCEPT ![r][t] = CTRecover]
       /\ swPhase' = [swPhase EXCEPT ![r][t] = SWDone]
       \* Recovery checks local participant state
       \* txn_two_phase_commit_cmds.cpp:400-438
       /\ IF sState[ws][t] = SSCommitted THEN
            \* Write shard already committed — return success
            /\ rPhase' = [rPhase EXCEPT ![r][t] = RPDone]
            /\ UNCHANGED sState
          ELSE IF sState[ws][t] = SSInProgress THEN
            \* SERVER-48307: local check finds inProgress, aborts it.
            \* If the commit was in-flight, this may contradict reality.
            /\ sState' = [sState EXCEPT ![ws][t] = SSAborted]
            /\ rPhase' = [rPhase EXCEPT ![r][t] = RPAborted]
          ELSE
            \* SSAborted, SSPrepared, SSReaped, SSNone → return abort/error
            /\ rPhase' = [rPhase EXCEPT ![r][t] = RPAborted]
            /\ UNCHANGED sState
    /\ UNCHANGED <<rPK, rAttempt, rDisallowSWS, coordVars, ticketVars, respVars>>

\* ---------------------------------------------------------------------------
\* RouterRetry — Retry a failed commit (increment attempt counter).
\*
\* Source: transaction_router.cpp _commitTransaction() retry path
\* On retry, SWS falls back to recovery token (line 1718).
\* ---------------------------------------------------------------------------
RouterRetry(r, t) ==
    /\ rPhase[r][t] = RPFailed
    /\ rAttempt' = [rAttempt EXCEPT ![r][t] = rAttempt[r][t] + 1]
    /\ rPhase' = [rPhase EXCEPT ![r][t] = RPStarted]
    /\ rCommitType' = [rCommitType EXCEPT ![r][t] = CTNone]
    /\ swPhase' = [swPhase EXCEPT ![r][t] = SWNone]
    /\ UNCHANGED <<rPK, rDisallowSWS, coordVars, shardVars, ticketVars, respVars>>

\* ===========================================================================
\* Actions: 2PC Coordinator (abstracted)
\* Families 2 and 3 — ticket management and error classification
\*
\* The 2PC protocol is abstracted: prepare/vote exchange is atomic.
\* Key mechanisms modeled:
\*   - Ticket consumption by prepared transactions [Family 2]
\*   - Coordinator ticket dependency for persistence [Family 2]
\*   - Error classification during decision delivery [Family 3]
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* CoordDecideCommit — All participants prepare and vote commit.
\*
\* Source: transaction_coordinator_util.cpp:310-374 (sendPrepare)
\* Abstraction: all shards prepare atomically, each acquiring a write ticket.
\*
\* [Family 2] Prepared shards consume write tickets. If all tickets are
\* consumed and coordinator needs one for persistence → deadlock (SERVER-60682).
\* ---------------------------------------------------------------------------
CoordDecideCommit(t) ==
    /\ cPhase[t] = CPPreparing
    /\ LET P  == cParticipants[t]
           nP == Cardinality(P)
       IN
       \* All participants must be inProgress
       /\ \A s \in P : sState[s][t] = SSInProgress
       \* Need enough tickets for all preparing shards
       \* transaction_participant.cpp:2089 (prepared txn holds WT locks/ticket)
       /\ tickets >= nP
       \* All participants prepare and acquire tickets
       /\ sState' = [s \in Shard |->
            IF s \in P THEN [sState[s] EXCEPT ![t] = SSPrepared]
            ELSE sState[s]]
       /\ tickets' = tickets - nP
    /\ cDecision' = [cDecision EXCEPT ![t] = DCommit]
    /\ cPhase' = [cPhase EXCEPT ![t] = CPDecided]
    /\ UNCHANGED <<routerVars, cParticipants, cAcks, bgWaiting, respVars, swsVars>>

\* ---------------------------------------------------------------------------
\* CoordDecideAbort — At least one participant votes abort.
\*
\* Source: transaction_coordinator_util.cpp:836-843 (isVoteAbortError check)
\* Some shards prepare (acquire tickets), others return VoteAbortError.
\* ---------------------------------------------------------------------------
CoordDecideAbort(t) ==
    /\ cPhase[t] = CPPreparing
    /\ LET P == cParticipants[t] IN
       /\ Cardinality(P) >= 1
       /\ \A s \in P : sState[s][t] = SSInProgress
       \* Non-deterministic: choose which shards prepare vs abort
       /\ \E prepared \in SUBSET P :
            /\ prepared /= P  \* At least one shard votes abort
            /\ LET nPrep == Cardinality(prepared) IN
               /\ tickets >= nPrep
               /\ sState' = [s \in Shard |->
                    IF s \in prepared
                    THEN [sState[s] EXCEPT ![t] = SSPrepared]
                    ELSE IF s \in P
                    THEN [sState[s] EXCEPT ![t] = SSAborted]
                    ELSE sState[s]]
               /\ tickets' = tickets - nPrep
    /\ cDecision' = [cDecision EXCEPT ![t] = DAbort]
    /\ cPhase' = [cPhase EXCEPT ![t] = CPDecided]
    /\ UNCHANGED <<routerVars, cParticipants, cAcks, bgWaiting, respVars, swsVars>>

\* ---------------------------------------------------------------------------
\* CoordPersistAndSend — Persist decision and transition to sending phase.
\*
\* Source: transaction_coordinator_util.cpp:479-511 (persistDecision)
\*
\* [Family 2] Persistence requires a write ticket UNLESS coordinator is exempt.
\* With kExempt (line 499): always succeeds, no ticket needed.
\* Without kExempt (pre-fix): blocks if tickets = 0 → deadlock (SERVER-60682).
\*
\* Persistence is transient — ticket acquired and released in same step.
\* ---------------------------------------------------------------------------
CoordPersistAndSend(t) ==
    /\ cPhase[t] = CPDecided
    \* Ticket check: exempt bypasses, otherwise needs available ticket
    /\ \/ CoordTicketExempt   \* line 499: ScopedAdmissionPriority kExempt
       \/ tickets > 0         \* non-exempt: must have available ticket
    /\ cPhase' = [cPhase EXCEPT ![t] = CPSending]
    /\ UNCHANGED <<routerVars, cDecision, cParticipants, cAcks,
                   shardVars, ticketVars, respVars, swsVars>>

\* ---------------------------------------------------------------------------
\* CoordSendDecisionToShard — Send decision to one shard and process response.
\*
\* Source: transaction_coordinator_util.cpp:877-957 (sendDecisionToShard)
\*
\* [Family 3] Error classification per transaction_coordinator_util.cpp:933:
\*   if (ErrorCodes::isTwoPhaseDecisionAckError(status.code())) {
\*       status = Status::OK();  // Interpret as successful ack
\*   }
\*
\* Bug (SERVER-105751): session reaper destroys prepared txn → shard responds
\* NoSuchTransaction → coordinator classifies as ack → data loss.
\* ---------------------------------------------------------------------------
CoordSendDecisionToShard(t, s) ==
    /\ cPhase[t] = CPSending
    /\ s \in cParticipants[t]
    /\ s \notin cAcks[t]  \* Not yet acknowledged
    /\ \/ \* Normal: shard is prepared, processes decision
          /\ sState[s][t] = SSPrepared
          /\ sState' = [sState EXCEPT ![s][t] =
               IF cDecision[t] = DCommit THEN SSCommitted ELSE SSAborted]
          /\ tickets' = tickets + 1  \* Release ticket from prepared
          /\ sResponse' = [sResponse EXCEPT ![s][t] = ROk]
       \/ \* Reaped: session destroyed, responds NoSuchTransaction
          \* transaction_coordinator_util.cpp:933 — isTwoPhaseDecisionAckError
          \* Coordinator classifies NoSuchTxn as DecisionAckError → treats as ack!
          \* But the shard never actually committed/aborted. [SERVER-105751]
          /\ sState[s][t] = SSReaped
          /\ sResponse' = [sResponse EXCEPT ![s][t] = RNoSuchTxn]
          /\ UNCHANGED <<sState, tickets>>
       \/ \* Already in terminal state (idempotent)
          /\ sState[s][t] \in {SSCommitted, SSAborted}
          /\ sResponse' = [sResponse EXCEPT ![s][t] = ROk]
          /\ UNCHANGED <<sState, tickets>>
    /\ cAcks' = [cAcks EXCEPT ![t] = cAcks[t] \cup {s}]
    /\ UNCHANGED <<routerVars, cPhase, cDecision, cParticipants, bgWaiting, swsVars>>

\* ---------------------------------------------------------------------------
\* CoordFinish — All decision responses received, coordinator completes.
\*
\* Source: transaction_coordinator.cpp:350-370 (_done continuation)
\* ---------------------------------------------------------------------------
CoordFinish(t) ==
    /\ cPhase[t] = CPSending
    /\ cAcks[t] = cParticipants[t]  \* All participants acked
    /\ cPhase' = [cPhase EXCEPT ![t] = CPDone]
    /\ UNCHANGED <<routerVars, cDecision, cParticipants, cAcks,
                   shardVars, ticketVars, respVars, swsVars>>

\* ---------------------------------------------------------------------------
\* RouterReceive2PCResult — Router receives coordinator's result.
\*
\* Source: transaction_router.cpp:1770 (_handOffCommitToCoordinator returns)
\* ---------------------------------------------------------------------------
RouterReceive2PCResult(r, t) ==
    /\ rPhase[r][t] = RPCommitting
    /\ rCommitType[r][t] = CT2PC
    /\ cPhase[t] = CPDone
    /\ rPhase' = [rPhase EXCEPT ![r][t] =
         IF cDecision[t] = DCommit THEN RPDone ELSE RPAborted]
    /\ UNCHANGED <<rCommitType, rPK, rAttempt, rDisallowSWS,
                   coordVars, shardVars, ticketVars, respVars, swsVars>>

\* ===========================================================================
\* Actions: Fault Injection
\* ===========================================================================

\* ---------------------------------------------------------------------------
\* SessionReaperFire — Session reaper destroys a prepared transaction.
\*
\* Source: SERVER-105751 — session reaper kills prepared txn.
\* The prepared transaction's effects are neither committed nor aborted.
\* When coordinator sends decision, shard responds NoSuchTransaction.
\*
\* [Family 3] Fault injection: SSPrepared → SSReaped, releases ticket.
\* ---------------------------------------------------------------------------
SessionReaperFire(s, t) ==
    /\ sState[s][t] = SSPrepared
    /\ sState' = [sState EXCEPT ![s][t] = SSReaped]
    /\ tickets' = tickets + 1  \* Reaped txn releases its ticket
    /\ UNCHANGED <<routerVars, coordVars, bgWaiting, respVars, swsVars>>

\* ---------------------------------------------------------------------------
\* BackgroundTaskAcquire — Background task acquires a write ticket.
\*
\* Source: SERVER-65821, SERVER-80978, SERVER-103744
\* Background tasks (TTLMonitor, setFCV) need write tickets and may conflict.
\*
\* [Family 2] Fault injection: consumes a ticket.
\* ---------------------------------------------------------------------------
BackgroundTaskAcquire(s) ==
    /\ ~bgWaiting[s]
    /\ tickets > 0
    /\ tickets' = tickets - 1
    /\ bgWaiting' = [bgWaiting EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<routerVars, coordVars, shardVars, respVars, swsVars>>

\* ---------------------------------------------------------------------------
\* BackgroundTaskRelease — Background task releases its write ticket.
\* ---------------------------------------------------------------------------
BackgroundTaskRelease(s) ==
    /\ bgWaiting[s]
    /\ tickets' = tickets + 1
    /\ bgWaiting' = [bgWaiting EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<routerVars, coordVars, shardVars, respVars, swsVars>>

\* ---------------------------------------------------------------------------
\* DelayedCommitArrival — Delayed commit reaches a write shard.
\*
\* Models: the original commit was in-flight when the router got an error.
\* The shard receives it after the router has already moved to retry.
\*
\* [Family 4] Tightly constrained: only for write shards of retrying txns.
\* ---------------------------------------------------------------------------
DelayedCommitArrival(s, t) ==
    /\ sState[s][t] = SSInProgress
    \* Only fire if some router is retrying this txn (commit was in-flight)
    /\ \E r \in Router :
        /\ rAttempt[r][t] > 0
        /\ s \in WriteShards(r, t)
    /\ sState' = [sState EXCEPT ![s][t] = SSCommitted]
    /\ UNCHANGED <<routerVars, coordVars, ticketVars, respVars, swsVars>>

\* ===========================================================================
\* Next State Relation
\* ===========================================================================

Next ==
    \* --- Transaction lifecycle ---
    \/ \E r \in Router, t \in Txn : RouterStartTxn(r, t)
    \/ \E r \in Router, t \in Txn : RouterCommitTxn(r, t)
    \/ \E r \in Router, t \in Txn : RouterRetry(r, t)
    \* --- Direct commit [Family 1] ---
    \/ \E r \in Router, t \in Txn : DirectCommit(r, t)
    \/ \E r \in Router, t \in Txn : DirectCommitPartial(r, t)
    \* --- SWS path [Family 4] ---
    \/ \E r \in Router, t \in Txn : SWSCommitReadOnly(r, t)
    \/ \E r \in Router, t \in Txn : SWSReadOnlyFail(r, t)
    \/ \E r \in Router, t \in Txn : SWSCommitWrite(r, t)
    \/ \E r \in Router, t \in Txn : SWSWriteFail(r, t)
    \/ \E r \in Router, t \in Txn : SWSRetryRecovery(r, t)
    \* --- 2PC coordinator [Family 2, 3] ---
    \/ \E t \in Txn : CoordDecideCommit(t)
    \/ \E t \in Txn : CoordDecideAbort(t)
    \/ \E t \in Txn : CoordPersistAndSend(t)
    \/ \E t \in Txn, s \in Shard : CoordSendDecisionToShard(t, s)
    \/ \E t \in Txn : CoordFinish(t)
    \/ \E r \in Router, t \in Txn : RouterReceive2PCResult(r, t)
    \* --- Fault injection ---
    \/ \E s \in Shard, t \in Txn : SessionReaperFire(s, t)
    \/ \E s \in Shard, t \in Txn : DelayedCommitArrival(s, t)
    \/ \E s \in Shard : BackgroundTaskAcquire(s)
    \/ \E s \in Shard : BackgroundTaskRelease(s)

Spec == Init /\ [][Next]_vars

\* ===========================================================================
\* Invariants
\* ===========================================================================

\* --- Family 1: Commit Type Selection ---

\* CommitTypeConsistency — Selected commit type matches participant state.
CommitTypeConsistency ==
    \A r \in Router, t \in Txn :
      rPhase[r][t] = RPCommitting =>
        LET ct == rCommitType[r][t]
            W  == WriteShards(r, t)
            P  == AllParticipants(r, t)
        IN
        /\ (ct = CTSingle => Cardinality(P) = 1)
        /\ (ct = CTReadOnly => Cardinality(W) = 0)
        /\ (ct = CTSWS => Cardinality(W) = 1)
        /\ (ct = CT2PC => Cardinality(W) > 1 \/ rDisallowSWS[r][t])

\* AllParticipantsReachTerminal — When router reports done, relevant
\* participants must be in a terminal state. Targets SERVER-116284.
\* For CTRecover (SWS retry), only write shards matter — read-only shards
\* may stay in-progress (their txns eventually timeout, no data impact).
AllParticipantsReachTerminal ==
    \A r \in Router, t \in Txn :
      rPhase[r][t] = RPDone =>
        IF rCommitType[r][t] = CTRecover
        THEN \A s \in WriteShards(r, t) :
               sState[s][t] \in {SSCommitted, SSAborted, SSReaped}
        ELSE \A s \in AllParticipants(r, t) :
               sState[s][t] \in {SSCommitted, SSAborted, SSReaped}

\* --- Family 2: Ticket Starvation Deadlock ---

\* NoTicketDeadlock — Coordinator can always persist its decision.
\* SERVER-60682: all tickets held by prepared txns, coordinator can't persist.
NoTicketDeadlock ==
    \A t \in Txn :
      (cPhase[t] = CPDecided /\ ~CoordTicketExempt) => tickets > 0

\* NoTicketDeadlockWithBg — Extended: includes background task interaction.
\* SERVER-65821: three-way deadlock.
NoTicketDeadlockWithBg ==
    \A t \in Txn :
      (cPhase[t] = CPDecided /\ ~CoordTicketExempt) =>
        tickets > 0 \/ \E s \in Shard : bgWaiting[s]

\* TicketPoolNonNegative — Structural: ticket count never goes negative.
TicketPoolNonNegative == tickets >= 0

\* --- Family 3: Error Code Misclassification ---

\* NoSilentDataLoss — After coordinator finishes, no participant is reaped.
\* SERVER-105751: session reaper + DecisionAckError misclassification.
NoSilentDataLoss ==
    \A t \in Txn :
      cPhase[t] = CPDone =>
        \A s \in cParticipants[t] :
          sState[s][t] /= SSReaped

\* ClassificationMatchesReality — Acked shards are truly done.
ClassificationMatchesReality ==
    \A s \in Shard, t \in Txn :
      (s \in cAcks[t] /\ cPhase[t] \in {CPSending, CPDone}) =>
        sState[s][t] \in {SSCommitted, SSAborted}

\* --- Family 4: SWS Retry Safety ---

\* RetryNeverContradictsOriginal — SERVER-48307
\* If retry returns "abort", the write shard must not be committed.
RetryNeverContradictsOriginal ==
    \A r \in Router, t \in Txn :
      (rCommitType[r][t] = CTRecover /\ rPhase[r][t] = RPAborted) =>
        \A s \in WriteShards(r, t) : sState[s][t] /= SSCommitted

\* SWSCorrectness — SWS path only used when exactly 1 write shard.
SWSCorrectness ==
    \A r \in Router, t \in Txn :
      rCommitType[r][t] = CTSWS =>
        Cardinality(WriteShards(r, t)) = 1

\* --- Structural invariants ---

\* TicketPoolBounded — Tickets never exceed maximum.
TicketPoolBounded == tickets <= MaxTickets + Cardinality(Shard)

\* DecisionIrreversible — Coordinator decision never reverts to none.
DecisionIrreversible ==
    \A t \in Txn :
      cDecision[t] /= DNone =>
        cDecision[t] \in {DCommit, DAbort}

\* ===========================================================================
\* Temporal Properties
\* ===========================================================================

\* CoordinatorProgress — If coordinator decides, it eventually finishes.
\* Requires weak fairness on CoordPersistAndSend, CoordSendDecisionToShard,
\* and CoordFinish. Violated when deadlocked (Family 2).
CoordinatorProgress ==
    \A t \in Txn :
      cPhase[t] = CPDecided ~> cPhase[t] = CPDone

====
