--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for Aptos BFT (2-chain HotStuff / Jolteon).
 *
 * Derived from: aptos-core/consensus/ (round_manager.rs, safety_rules.rs,
 *               safety_rules_2chain.rs, pending_order_votes.rs, buffer_manager.rs)
 *
 * Bug Families:
 *   1 — Missing Safety Guards on Auxiliary Voting Paths
 *   2 — Order Vote Protocol Verification Gaps
 *   3 — Pipeline/Buffer Manager Race Conditions
 *   4 — Non-Atomic Safety-Critical Persistence
 *   5 — Epoch Transition Boundary Bugs
 *
 * This spec models the implementation's actual control flow.
 * Deviations from the Jolteon paper are where bugs live.
 *)

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server           \* Set of validator IDs
CONSTANT MaxRound         \* Maximum round to explore
CONSTANT Nil              \* Sentinel value for "none"
CONSTANT Values           \* Set of abstract block values

\* Quorum threshold: number of nodes needed for 2f+1
\* For n=3f+1 validators, quorum = 2f+1
CONSTANT Quorum

\* Message type constants
CONSTANTS
    ProposalMsgType,      \* Block proposal
    VoteMsgType,          \* Regular vote (for QC formation)
    OrderVoteMsgType,     \* Order vote (Jolteon extension, Family 2)
    TimeoutMsgType,       \* 2-chain timeout
    CommitVoteMsgType     \* Commit vote (pipeline, Family 1)

\* Pipeline phase constants (Family 3: buffer_item.rs:84-89)
CONSTANTS
    Ordered,              \* Block has been ordered
    Executed,             \* Block has been executed
    Signed,               \* Commit vote has been signed
    Aggregated            \* 2f+1 commit votes collected, ready to persist

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Per-server safety data (safety_data.rs:10-21) ---
\* These correspond directly to SafetyData fields.

VARIABLE currentEpoch         \* [Server -> Nat] safety_data.epoch (Family 5)
VARIABLE lastVotedRound       \* [Server -> Nat] safety_data.last_voted_round
VARIABLE preferredRound       \* [Server -> Nat] safety_data.preferred_round (2-chain)
VARIABLE oneChainRound        \* [Server -> Nat] safety_data.one_chain_round (1-chain)
VARIABLE highestTimeoutRound  \* [Server -> Nat] safety_data.highest_timeout_round (Family 1,2)

\* --- Persistence state (Family 4: safety_rules_2chain.rs:66-92) ---
VARIABLE persistedSafetyData  \* [Server -> record] last persisted safety data
VARIABLE volatileSafetyData   \* [Server -> record] in-memory (may differ from persisted)

\* --- Per-server consensus state ---
VARIABLE currentRound         \* [Server -> Nat] round_state current round
VARIABLE alive                \* [Server -> BOOLEAN] whether server is alive (Family 4)

\* --- Block and certificate state ---
VARIABLE proposals            \* [Server -> [Round -> value or Nil]] known proposals per round
VARIABLE highestQCRound       \* [Server -> Nat] round of highest QC seen
VARIABLE highestTCRound       \* [Server -> Nat] round of highest TC seen
VARIABLE highestOrderedRound  \* [Server -> Nat] round of highest ordered cert (Family 2)

\* --- Vote tracking (per server's view) ---
VARIABLE votesForBlock        \* [Server -> [Round -> set of voters]] regular votes received
VARIABLE orderVotesForBlock   \* [Server -> [Round -> set of voters]] order votes (Family 2)
VARIABLE timeoutVotes         \* [Server -> [Round -> set of voters]] timeout votes
VARIABLE commitVotes          \* [Server -> [Round -> set of voters]] commit votes (Family 1,3)

\* --- Network: message bag ---
VARIABLE msgs                 \* Bag of messages in transit

\* --- Pipeline state (Family 3: buffer_item.rs:84-89) ---
VARIABLE pipelinePhase        \* [Server -> [Round -> phase]] per-block pipeline state
VARIABLE syncInProgress       \* [Server -> BOOLEAN] whether sync is active (Family 3)
VARIABLE epochChangeNotified  \* [Server -> BOOLEAN] epoch change signal sent (Family 3)

\* --- Committed state ---
VARIABLE committedRound       \* [Server -> Nat] highest committed round
VARIABLE decidedValues        \* [Round -> value or Nil] global decided values (for safety check)

\* --- Leader election (ghost variable modeling ProposerElection) ---
\* In the implementation, ProposerElection deterministically assigns one
\* leader per round. We model this abstractly: nondeterministic choice,
\* but at most one proposer per round.
VARIABLE roundProposer        \* [Round -> Server \cup {Nil}] who proposed for each round

\* ============================================================================
\* VARIABLE GROUPS (for UNCHANGED clauses)
\* ============================================================================

safetyVars    == <<lastVotedRound, preferredRound, oneChainRound, highestTimeoutRound>>
persistVars   == <<persistedSafetyData, volatileSafetyData>>
roundVars     == <<currentRound, currentEpoch, alive>>
certVars      == <<highestQCRound, highestTCRound, highestOrderedRound>>
voteVars      == <<votesForBlock, orderVotesForBlock, timeoutVotes, commitVotes>>
pipelineVars  == <<pipelinePhase, syncInProgress, epochChangeNotified>>
commitVars    == <<committedRound, decidedValues>>
blockVars     == <<proposals, roundProposer>>

allVars == <<safetyVars, persistVars, roundVars, certVars, voteVars,
             pipelineVars, commitVars, blockVars, msgs>>

\* ============================================================================
\* HELPERS
\* ============================================================================

\* A quorum is a set with >= Quorum members
HasQuorum(voteSet) == Cardinality(voteSet) >= Quorum

\* The set of all servers in the current epoch
\* (simplified: all servers participate in all epochs)
Validators == Server

\* Maximum of two values
Max(a, b) == IF a >= b THEN a ELSE b

\* Message constructor
Msg(type, src, round, epoch, value) ==
    [mtype   |-> type,
     msrc    |-> src,
     mround  |-> round,
     mepoch  |-> epoch,
     mvalue  |-> value]

\* Send a message (add to bag)
Send(m) == msgs' = msgs (+) SetToBag({m})

\* Discard a message (remove from bag)
Discard(m) == msgs' = msgs (-) SetToBag({m})

\* Send one, discard another
Reply(send, discard) ==
    msgs' = (msgs (-) SetToBag({discard})) (+) SetToBag({send})

\* Broadcast: send one copy per validator (each receiver consumes its copy)
Broadcast(type, src, round, epoch, value) ==
    LET m == Msg(type, src, round, epoch, value)
    IN msgs' = msgs (+) (m :> Cardinality(Server))

\* Next round helper (safety_rules.rs:36-38)
NextRound(r) == r + 1

\* SafetyData record constructor
SafetyDataRec(epoch, lvr, pr, ocr, htr) ==
    [epoch              |-> epoch,
     lastVotedRound     |-> lvr,
     preferredRound     |-> pr,
     oneChainRound      |-> ocr,
     highestTimeoutRound |-> htr]

\* ============================================================================
\* PHASE 1: INITIALIZATION
\* ============================================================================

Init ==
    \* Safety data (safety_data.rs:24-30 — SafetyData::new)
    /\ lastVotedRound      = [s \in Server |-> 0]
    /\ preferredRound      = [s \in Server |-> 0]
    /\ oneChainRound       = [s \in Server |-> 0]
    /\ highestTimeoutRound = [s \in Server |-> 0]
    \* Persistence (Family 4)
    /\ persistedSafetyData = [s \in Server |->
         SafetyDataRec(1, 0, 0, 0, 0)]
    /\ volatileSafetyData  = [s \in Server |->
         SafetyDataRec(1, 0, 0, 0, 0)]
    \* Round state
    /\ currentRound        = [s \in Server |-> 1]
    /\ currentEpoch        = [s \in Server |-> 1]
    /\ alive               = [s \in Server |-> TRUE]
    \* Blocks
    /\ proposals           = [s \in Server |-> [r \in 1..MaxRound |-> Nil]]
    \* Certificates
    /\ highestQCRound      = [s \in Server |-> 0]
    /\ highestTCRound      = [s \in Server |-> 0]
    /\ highestOrderedRound = [s \in Server |-> 0]
    \* Votes
    /\ votesForBlock       = [s \in Server |-> [r \in 1..MaxRound |-> {}]]
    /\ orderVotesForBlock  = [s \in Server |-> [r \in 1..MaxRound |-> {}]]
    /\ timeoutVotes        = [s \in Server |-> [r \in 1..MaxRound |-> {}]]
    /\ commitVotes         = [s \in Server |-> [r \in 1..MaxRound |-> {}]]
    \* Network
    /\ msgs = EmptyBag
    \* Pipeline (Family 3)
    /\ pipelinePhase       = [s \in Server |-> [r \in 1..MaxRound |-> Nil]]
    /\ syncInProgress      = [s \in Server |-> FALSE]
    /\ epochChangeNotified = [s \in Server |-> FALSE]
    \* Commits
    /\ committedRound      = [s \in Server |-> 0]
    /\ decidedValues       = [r \in 1..MaxRound |-> Nil]
    \* Leader election (ghost)
    /\ roundProposer       = [r \in 1..MaxRound |-> Nil]

\* ============================================================================
\* OBSERVE QC — update 1-chain and 2-chain rounds
\* (safety_rules.rs:135-156)
\* ============================================================================

\* observe_qc: updates oneChainRound and preferredRound from QC
\* qcCertifiedRound = qc.certified_block().round() (1-chain)
\* qcParentRound    = qc.parent_block().round() (2-chain)
ObserveQC(s, qcCertifiedRound, qcParentRound) ==
    \* safety_rules.rs:139-146 — update one_chain_round
    /\ oneChainRound' = [oneChainRound EXCEPT ![s] =
         Max(oneChainRound[s], qcCertifiedRound)]
    \* safety_rules.rs:147-154 — update preferred_round
    /\ preferredRound' = [preferredRound EXCEPT ![s] =
         Max(preferredRound[s], qcParentRound)]

\* ============================================================================
\* ACTION: Propose
\* (round_manager.rs:532-600 — generate_and_send_proposal)
\*
\* A leader for the current round proposes a block with a QC or TC.
\* ============================================================================

Propose(s, v) ==
    /\ alive[s] = TRUE
    /\ currentRound[s] <= MaxRound
    \* Leader election: at most one proposer per round (ProposerElection)
    /\ roundProposer[currentRound[s]] = Nil
    \* The proposer must have a QC or TC enabling this round
    \* round_manager.rs:500-503 — is_valid_proposer check
    /\ \/ highestQCRound[s] = currentRound[s] - 1    \* QC for previous round
       \/ highestTCRound[s] = currentRound[s] - 1     \* TC for previous round
    \* Proposal round check (safety_rules.rs:356-362)
    /\ currentRound[s] > lastVotedRound[s]
    \* Preferred round check (safety_rules.rs:173-188)
    /\ highestQCRound[s] >= preferredRound[s]
    \* Broadcast proposal
    /\ Broadcast(ProposalMsgType, s, currentRound[s], currentEpoch[s], v)
    \* Record locally
    /\ proposals' = [proposals EXCEPT ![s][currentRound[s]] = v]
    \* Record leader for this round (ghost)
    /\ roundProposer' = [roundProposer EXCEPT ![currentRound[s]] = s]
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    voteVars, pipelineVars, commitVars>>

\* ============================================================================
\* ACTION: ReceiveProposal
\* (round_manager.rs:1127-1307 — process_proposal)
\*
\* A server receives a proposal and stores it.
\* ============================================================================

ReceiveProposal(s, m) ==
    /\ alive[s] = TRUE
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = ProposalMsgType
    \* Epoch check (safety_rules.rs:204-210)
    /\ m.mepoch = currentEpoch[s]
    \* Round check — only accept proposals for current or future rounds
    /\ m.mround >= currentRound[s]
    /\ m.mround <= MaxRound
    \* Store the proposal
    /\ proposals' = [proposals EXCEPT ![s][m.mround] = m.mvalue]
    \* Update round if needed (ensure_round_and_sync_up, round_manager.rs:932-951)
    /\ currentRound' = [currentRound EXCEPT ![s] =
         Max(currentRound[s], m.mround)]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, persistVars, currentEpoch, alive,
                    certVars, voteVars, pipelineVars, commitVars,
                    roundProposer>>

\* ============================================================================
\* ACTION: CastVote (regular vote for QC formation)
\* (round_manager.rs:1521-1565 — vote_block)
\* (safety_rules_2chain.rs:53-95 — guarded_construct_and_sign_vote_two_chain)
\*
\* A server votes for a proposal in the current round.
\* This is the PRIMARY voting path with full safety guards.
\* Family 1: This path has all guards; compare with CastOrderVote/SignCommitVote.
\* ============================================================================

CastVote(s) ==
    LET r == currentRound[s]
        qcRound == highestQCRound[s]
        tcRound == highestTCRound[s]
    IN
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    /\ proposals[s][r] /= Nil
    \* safety_rules_2chain.rs:59 — signer check (implicit: alive)
    \* safety_rules_2chain.rs:61 — verify_proposal (includes epoch check)
    /\ currentEpoch[s] = currentEpoch[s]  \* trivially true; epoch consistency
    \* safety_rules_2chain.rs:70-74 — already voted check
    \* (we model this as: haven't voted in this round yet)
    /\ s \notin votesForBlock[s][r]
    \* safety_rules_2chain.rs:77-80 — verify_and_update_last_vote_round
    \* FIRST VOTING RULE: round > last_voted_round
    /\ r > lastVotedRound[s]
    \* safety_rules_2chain.rs:81 — safe_to_vote
    \* (safety_rules_2chain.rs:150-166)
    \* Rule: round == qc.round + 1 OR (round == tc.round + 1 AND qc.round >= tc.hqc_round)
    /\ \/ r = NextRound(qcRound)
       \/ (r = NextRound(tcRound) /\ qcRound >= 0)  \* simplified hqc check
    \* safety_rules_2chain.rs:84 — observe_qc (update 1-chain/2-chain rounds)
    /\ ObserveQC(s, qcRound, IF qcRound > 0 THEN qcRound - 1 ELSE 0)
    \* safety_rules_2chain.rs:77-80 — update last_voted_round
    /\ lastVotedRound' = [lastVotedRound EXCEPT ![s] = r]
    \* safety_rules_2chain.rs:91-92 — persist safety data
    /\ LET newSD == SafetyDataRec(currentEpoch[s], r,
                      preferredRound'[s], oneChainRound'[s],
                      highestTimeoutRound[s])
       IN /\ persistedSafetyData' = [persistedSafetyData EXCEPT ![s] = newSD]
          /\ volatileSafetyData'  = [volatileSafetyData EXCEPT ![s] = newSD]
    \* Broadcast vote
    /\ Broadcast(VoteMsgType, s, r, currentEpoch[s], proposals[s][r])
    \* Record self-vote locally
    /\ votesForBlock' = [votesForBlock EXCEPT ![s][r] =
         votesForBlock[s][r] \union {s}]
    /\ UNCHANGED <<highestTimeoutRound, roundVars, certVars,
                    orderVotesForBlock, timeoutVotes, commitVotes,
                    pipelineVars, commitVars, blockVars>>

\* ============================================================================
\* ACTION: ReceiveVote
\* (round_manager.rs:1743-1793 — process_vote)
\*
\* A server receives a regular vote. If enough votes accumulate, a QC is formed.
\* ============================================================================

ReceiveVote(s, m) ==
    /\ alive[s] = TRUE
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = VoteMsgType
    /\ m.mepoch = currentEpoch[s]
    /\ m.mround <= MaxRound
    \* round_manager.rs:1718-1737 — ensure_round_and_sync_up
    \* Regular votes DO call ensure_round_and_sync_up (unlike order votes)
    /\ m.mround >= currentRound[s]
    \* round_manager.rs:1781-1787 — check if QC already exists
    /\ ~HasQuorum(votesForBlock[s][m.mround])
    \* Add vote
    /\ votesForBlock' = [votesForBlock EXCEPT ![s][m.mround] =
         votesForBlock[s][m.mround] \union {m.msrc}]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    orderVotesForBlock, timeoutVotes, commitVotes,
                    pipelineVars, commitVars, blockVars>>

\* ============================================================================
\* ACTION: FormQC
\* (round_manager.rs:1802-1837 — NewQuorumCertificate branch)
\*
\* When enough votes arrive, a QC is formed. After QC formation,
\* order votes are broadcast (Family 2).
\* ============================================================================

FormQC(s, r) ==
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    /\ HasQuorum(votesForBlock[s][r])
    \* Update highest QC round
    /\ highestQCRound' = [highestQCRound EXCEPT ![s] = Max(highestQCRound[s], r)]
    \* Advance current round (process_certificates, round_manager.rs:1109-1119)
    /\ currentRound' = [currentRound EXCEPT ![s] = Max(currentRound[s], r + 1)]
    \* 2-chain commit rule (safety_rules_2chain.rs:195-214):
    \* If round(B0) + 1 = round(B1), commit B0
    /\ IF r > 1
          /\ proposals[s][r] /= Nil
          /\ proposals[s][r - 1] /= Nil
          /\ HasQuorum(votesForBlock[s][r - 1])
       THEN
         /\ committedRound' = [committedRound EXCEPT ![s] = Max(committedRound[s], r - 1)]
         /\ decidedValues' = [decidedValues EXCEPT ![r - 1] =
              IF decidedValues[r - 1] = Nil
              THEN proposals[s][r - 1]
              ELSE decidedValues[r - 1]]
       ELSE
         UNCHANGED commitVars
    \* Mark block as Ordered in pipeline (Family 3)
    /\ IF r <= MaxRound /\ pipelinePhase[s][r] = Nil
       THEN pipelinePhase' = [pipelinePhase EXCEPT ![s][r] = Ordered]
       ELSE UNCHANGED pipelinePhase
    /\ UNCHANGED <<safetyVars, persistVars, currentEpoch, alive,
                    highestTCRound, highestOrderedRound,
                    voteVars, syncInProgress, epochChangeNotified,
                    blockVars, msgs>>

\* ============================================================================
\* ACTION: CastOrderVote (Jolteon order vote)
\* (safety_rules_2chain.rs:97-119 — guarded_construct_and_sign_order_vote)
\* (round_manager.rs:1674-1710 — broadcast_order_vote)
\*
\* After a QC is formed, a server broadcasts an order vote.
\* Family 1,2: Order votes have INDEPENDENT safety checks from regular votes.
\* Key difference: does NOT check/update last_voted_round.
\* Only checks: round > highest_timeout_round.
\* ============================================================================

CastOrderVote(s, r) ==
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    /\ proposals[s][r] /= Nil
    \* Precondition: QC must exist for this round
    /\ HasQuorum(votesForBlock[s][r])
    \* safety_rules_2chain.rs:102 — signer check
    \* safety_rules_2chain.rs:103 — verify_order_vote_proposal (includes epoch check)
    \* (safety_rules.rs:87-111 — verify_order_vote_proposal)
    /\ currentEpoch[s] = currentEpoch[s]  \* epoch check
    \* safety_rules_2chain.rs:108 — observe_qc
    \* (updates one_chain_round and preferred_round, but NOT last_voted_round)
    /\ ObserveQC(s, r, IF r > 0 THEN r - 1 ELSE 0)
    \* safety_rules_2chain.rs:110 — safe_for_order_vote
    \* (safety_rules_2chain.rs:168-178)
    \* ONLY CHECK: round > highest_timeout_round
    \* Family 1,2: Does NOT check last_voted_round!
    /\ r > highestTimeoutRound[s]
    \* safety_rules_2chain.rs:117 — persist safety data
    /\ LET newSD == SafetyDataRec(currentEpoch[s], lastVotedRound[s],
                      preferredRound'[s], oneChainRound'[s],
                      highestTimeoutRound[s])
       IN /\ persistedSafetyData' = [persistedSafetyData EXCEPT ![s] = newSD]
          /\ volatileSafetyData'  = [volatileSafetyData EXCEPT ![s] = newSD]
    \* Broadcast order vote
    /\ Broadcast(OrderVoteMsgType, s, r, currentEpoch[s], proposals[s][r])
    \* Self-record
    /\ orderVotesForBlock' = [orderVotesForBlock EXCEPT ![s][r] =
         orderVotesForBlock[s][r] \union {s}]
    /\ UNCHANGED <<lastVotedRound, highestTimeoutRound,
                    roundVars, certVars, votesForBlock, timeoutVotes,
                    commitVotes, pipelineVars, commitVars, blockVars>>

\* ============================================================================
\* ACTION: ReceiveOrderVote
\* (round_manager.rs:1567-1645 — process_order_vote_msg)
\*
\* Family 2: Order vote processing does NOT call ensure_round_and_sync_up.
\* It uses a 100-round window instead.
\* QC verification is skipped for 2nd+ order votes per block.
\* ============================================================================

ReceiveOrderVote(s, m) ==
    /\ alive[s] = TRUE
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = OrderVoteMsgType
    /\ m.mepoch = currentEpoch[s]
    /\ m.mround <= MaxRound
    \* round_manager.rs:1582-1587 — skip if already have enough
    /\ ~HasQuorum(orderVotesForBlock[s][m.mround])
    \* round_manager.rs:1592-1593 — 100-round window check
    \* Family 2: No ensure_round_and_sync_up! Only window check.
    /\ m.mround > highestOrderedRound[s]
    /\ m.mround < highestOrderedRound[s] + 100
    \* Add order vote
    /\ orderVotesForBlock' = [orderVotesForBlock EXCEPT ![s][m.mround] =
         orderVotesForBlock[s][m.mround] \union {m.msrc}]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    votesForBlock, timeoutVotes, commitVotes,
                    pipelineVars, commitVars, blockVars>>

\* ============================================================================
\* ACTION: FormOrderingCert
\* (round_manager.rs:1918-1944 — process_order_vote_reception_result)
\* (pending_order_votes.rs:61-157 — insert_order_vote)
\*
\* When 2f+1 order votes accumulate for a round, an ordering certificate
\* is formed.
\* Family 2: Independent from QC — can order a block without regular QC.
\* ============================================================================

FormOrderingCert(s, r) ==
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    /\ HasQuorum(orderVotesForBlock[s][r])
    \* Update highest ordered round
    /\ highestOrderedRound' = [highestOrderedRound EXCEPT ![s] =
         Max(highestOrderedRound[s], r)]
    \* Mark block as Ordered in pipeline if not already
    /\ IF pipelinePhase[s][r] = Nil
       THEN pipelinePhase' = [pipelinePhase EXCEPT ![s][r] = Ordered]
       ELSE UNCHANGED pipelinePhase
    /\ UNCHANGED <<safetyVars, persistVars, roundVars,
                    highestQCRound, highestTCRound,
                    voteVars, syncInProgress, epochChangeNotified,
                    commitVars, blockVars, msgs>>

\* ============================================================================
\* ACTION: SignTimeout (2-chain timeout)
\* (safety_rules_2chain.rs:19-51 — guarded_sign_timeout_with_qc)
\* (round_manager.rs:1009-1106 — process_local_timeout)
\*
\* A server times out and broadcasts a timeout message.
\* Family 1: Timeout signing has specific safety checks:
\*   - epoch check
\*   - safe_to_timeout (round == qc.round+1 or round == tc.round+1,
\*                      qc.round >= one_chain_round)
\*   - round >= last_voted_round (may update if >)
\*   - updates highest_timeout_round
\* ============================================================================

SignTimeout(s) ==
    LET r == currentRound[s]
        qcRound == highestQCRound[s]
        tcRound == highestTCRound[s]
    IN
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    \* safety_rules_2chain.rs:26 — epoch check
    /\ currentEpoch[s] = currentEpoch[s]
    \* safety_rules_2chain.rs:36 — safe_to_timeout
    \* (safety_rules_2chain.rs:124-145)
    \* Rule 1: round == qc.round + 1 OR round == tc.round + 1
    /\ \/ r = NextRound(qcRound)
       \/ r = NextRound(tcRound)
    \* Rule 2: qc.round >= one_chain_round
    /\ qcRound >= oneChainRound[s]
    \* safety_rules_2chain.rs:37-42 — round >= last_voted_round check
    /\ r >= lastVotedRound[s]
    \* safety_rules_2chain.rs:43-45 — update last_voted_round if round > lvr
    /\ lastVotedRound' = [lastVotedRound EXCEPT ![s] =
         Max(lastVotedRound[s], r)]
    \* safety_rules_2chain.rs:46 — update highest_timeout_round
    /\ highestTimeoutRound' = [highestTimeoutRound EXCEPT ![s] =
         Max(highestTimeoutRound[s], r)]
    \* safety_rules_2chain.rs:47 — persist safety data
    /\ LET newSD == SafetyDataRec(currentEpoch[s], Max(lastVotedRound[s], r),
                      preferredRound[s], oneChainRound[s],
                      Max(highestTimeoutRound[s], r))
       IN /\ persistedSafetyData' = [persistedSafetyData EXCEPT ![s] = newSD]
          /\ volatileSafetyData'  = [volatileSafetyData EXCEPT ![s] = newSD]
    \* Broadcast timeout
    /\ Broadcast(TimeoutMsgType, s, r, currentEpoch[s], Nil)
    \* Self-vote on timeout
    /\ timeoutVotes' = [timeoutVotes EXCEPT ![s][r] =
         timeoutVotes[s][r] \union {s}]
    /\ UNCHANGED <<preferredRound, oneChainRound, roundVars, certVars,
                    votesForBlock, orderVotesForBlock, commitVotes,
                    pipelineVars, commitVars, blockVars>>

\* ============================================================================
\* ACTION: ReceiveTimeout
\* (round_manager.rs:1876-1916 — process_round_timeout_msg)
\*
\* A server receives a timeout message and adds it to timeout votes.
\* ============================================================================

ReceiveTimeout(s, m) ==
    /\ alive[s] = TRUE
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = TimeoutMsgType
    /\ m.mepoch = currentEpoch[s]
    /\ m.mround <= MaxRound
    \* round_manager.rs:1886-1893 — ensure_round_and_sync_up
    /\ m.mround >= currentRound[s]
    \* Add timeout vote
    /\ timeoutVotes' = [timeoutVotes EXCEPT ![s][m.mround] =
         timeoutVotes[s][m.mround] \union {m.msrc}]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    votesForBlock, orderVotesForBlock, commitVotes,
                    pipelineVars, commitVars, blockVars>>

\* ============================================================================
\* ACTION: FormTC (2-chain Timeout Certificate)
\* (round_manager.rs:1839-1841, 2026-2036 — New2ChainTimeoutCertificate)
\*
\* When 2f+1 timeouts accumulate, a TC is formed, advancing the round.
\* ============================================================================

FormTC(s, r) ==
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    /\ HasQuorum(timeoutVotes[s][r])
    \* Update highest TC round
    /\ highestTCRound' = [highestTCRound EXCEPT ![s] = Max(highestTCRound[s], r)]
    \* Advance to next round (process_certificates)
    /\ currentRound' = [currentRound EXCEPT ![s] = Max(currentRound[s], r + 1)]
    /\ UNCHANGED <<safetyVars, persistVars, currentEpoch, alive,
                    highestQCRound, highestOrderedRound,
                    voteVars, pipelineVars, commitVars, blockVars, msgs>>

\* ============================================================================
\* ACTION: SignCommitVote
\* (safety_rules.rs:372-418 — guarded_sign_commit_vote)
\*
\* Family 1: The commit vote path has explicit TODO markers for missing safety
\* guards. It checks:
\*   - is_ordered_only (line 381)
\*   - match_ordered_only (line 395-398)
\*   - signature verification (line 406-410)
\*   - But NO round-monotonicity check (TODO at line 412-413)
\*   - And NO extension check (TODO at line 413)
\*
\* This models the CURRENT (incomplete) implementation to detect violations.
\* ============================================================================

SignCommitVote(s, r) ==
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    \* Precondition: block must be at least Executed in pipeline (Family 3)
    /\ pipelinePhase[s][r] \in {Executed, Signed}
    \* safety_rules.rs:377 — signer check
    \* safety_rules.rs:381-393 — is_ordered_only check (has ordering cert)
    /\ HasQuorum(orderVotesForBlock[s][r])
    \* safety_rules.rs:406-410 — verify signatures (2f+1)
    \* (implicit: ordering cert was verified)
    \* safety_rules.rs:412 — TODO: add guarding rules in unhappy path
    \* safety_rules.rs:413 — TODO: add extension check
    \* Family 1: NO lastVotedRound check! NO preferredRound check!
    \* This is the missing guard that could allow conflicting commit votes.
    \* Sign and broadcast commit vote
    /\ Broadcast(CommitVoteMsgType, s, r, currentEpoch[s], proposals[s][r])
    \* Advance pipeline to Signed
    /\ pipelinePhase' = [pipelinePhase EXCEPT ![s][r] = Signed]
    \* Record commit vote
    /\ commitVotes' = [commitVotes EXCEPT ![s][r] =
         commitVotes[s][r] \union {s}]
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    votesForBlock, orderVotesForBlock, timeoutVotes,
                    syncInProgress, epochChangeNotified,
                    commitVars, blockVars>>

\* ============================================================================
\* ACTION: ReceiveCommitVote
\* (buffer_manager.rs:736-800 — process_commit_message)
\*
\* A server receives a commit vote and adds it to the commit vote set.
\* Family 3: This happens in the pipeline (BufferManager).
\* ============================================================================

ReceiveCommitVote(s, m) ==
    /\ alive[s] = TRUE
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = CommitVoteMsgType
    /\ m.mepoch = currentEpoch[s]
    /\ m.mround <= MaxRound
    \* Add commit vote
    /\ commitVotes' = [commitVotes EXCEPT ![s][m.mround] =
         commitVotes[s][m.mround] \union {m.msrc}]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    votesForBlock, orderVotesForBlock, timeoutVotes,
                    pipelineVars, commitVars, blockVars>>

\* ============================================================================
\* PIPELINE ACTIONS (Family 3)
\* (buffer_item.rs — BufferItem state machine)
\* Pipeline: Ordered -> Executed -> Signed -> Aggregated
\* These are separate async tasks that can interleave.
\* ============================================================================

\* Execute a block (pipeline transition: Ordered -> Executed)
\* (buffer_manager.rs — execution_schedule/execution_wait phases)
ExecuteBlock(s, r) ==
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    /\ pipelinePhase[s][r] = Ordered
    /\ ~syncInProgress[s]
    /\ ~epochChangeNotified[s]
    /\ pipelinePhase' = [pipelinePhase EXCEPT ![s][r] = Executed]
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    voteVars, syncInProgress, epochChangeNotified,
                    commitVars, blockVars, msgs>>

\* Aggregate commit votes (pipeline transition: Signed -> Aggregated)
\* (buffer_item.rs:237-255 — try_advance_to_aggregated)
AggregateCommitVotes(s, r) ==
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    /\ pipelinePhase[s][r] = Signed
    /\ HasQuorum(commitVotes[s][r])
    /\ pipelinePhase' = [pipelinePhase EXCEPT ![s][r] = Aggregated]
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    voteVars, syncInProgress, epochChangeNotified,
                    commitVars, blockVars, msgs>>

\* Persist/Commit a block (pipeline final: Aggregated -> committed)
\* (buffer_manager.rs — persisting_phase)
PersistBlock(s, r) ==
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    /\ pipelinePhase[s][r] = Aggregated
    /\ ~syncInProgress[s]
    /\ committedRound' = [committedRound EXCEPT ![s] = Max(committedRound[s], r)]
    /\ decidedValues' = [decidedValues EXCEPT ![r] =
         IF decidedValues[r] = Nil
         THEN proposals[s][r]
         ELSE decidedValues[r]]
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    voteVars, pipelineVars, blockVars, msgs>>

\* ============================================================================
\* ACTION: ResetPipeline (Family 3)
\* (buffer_manager.rs:546-570 — reset)
\*
\* Pipeline reset clears all in-flight items. Can race with ongoing
\* pipeline operations.
\* ============================================================================

ResetPipeline(s) ==
    /\ alive[s] = TRUE
    /\ syncInProgress[s] \/ epochChangeNotified[s]
    \* Clear all pipeline phases
    /\ pipelinePhase' = [pipelinePhase EXCEPT ![s] =
         [r \in 1..MaxRound |-> Nil]]
    /\ syncInProgress' = [syncInProgress EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    voteVars, epochChangeNotified,
                    commitVars, blockVars, msgs>>

\* ============================================================================
\* ACTION: TriggerSync (Family 3)
\* (sync_manager.rs:62-93 — need_sync_for_ledger_info)
\*
\* A server detects it is behind and initiates sync.
\* Family 3: Has side effect of pausing pre-commit (sync_manager.rs:76-83).
\* ============================================================================

TriggerSync(s) ==
    /\ alive[s] = TRUE
    /\ ~syncInProgress[s]
    \* Some trigger condition (simplified: a much higher round exists)
    /\ syncInProgress' = [syncInProgress EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    voteVars, pipelinePhase, epochChangeNotified,
                    commitVars, blockVars, msgs>>

\* ============================================================================
\* ACTION: EpochChange (Family 5)
\* (safety_rules.rs:265-344 — guarded_initialize)
\* (epoch_manager.rs — epoch lifecycle)
\*
\* A server transitions to a new epoch.
\* Family 5: Resets safety data; all message-processing must check epoch.
\* debug_assert for epoch in TC (timeout_2chain.rs:248-257) compiled out in release.
\* ============================================================================

EpochChange(s) ==
    /\ alive[s] = TRUE
    /\ currentEpoch[s] < 2   \* limit epoch changes for model checking
    \* safety_rules.rs:296-303 — start new epoch, reset safety data
    /\ currentEpoch' = [currentEpoch EXCEPT ![s] = currentEpoch[s] + 1]
    /\ lastVotedRound' = [lastVotedRound EXCEPT ![s] = 0]
    /\ preferredRound' = [preferredRound EXCEPT ![s] = 0]
    /\ oneChainRound' = [oneChainRound EXCEPT ![s] = 0]
    /\ highestTimeoutRound' = [highestTimeoutRound EXCEPT ![s] = 0]
    \* Reset persistence
    /\ LET newSD == SafetyDataRec(currentEpoch[s] + 1, 0, 0, 0, 0)
       IN /\ persistedSafetyData' = [persistedSafetyData EXCEPT ![s] = newSD]
          /\ volatileSafetyData'  = [volatileSafetyData EXCEPT ![s] = newSD]
    \* Reset round
    /\ currentRound' = [currentRound EXCEPT ![s] = 1]
    \* Reset certificates
    /\ highestQCRound' = [highestQCRound EXCEPT ![s] = 0]
    /\ highestTCRound' = [highestTCRound EXCEPT ![s] = 0]
    /\ highestOrderedRound' = [highestOrderedRound EXCEPT ![s] = 0]
    \* Signal epoch change to pipeline (Family 3)
    /\ epochChangeNotified' = [epochChangeNotified EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<alive, voteVars, pipelinePhase, syncInProgress,
                    commitVars, blockVars, msgs>>

\* ============================================================================
\* ACTION: Crash and Recovery (Family 4)
\* (safety_rules_2chain.rs:66-92 — read/modify/write pattern)
\*
\* Family 4: On crash, volatile safety data reverts to persisted state.
\* If crash happens between sign and persist, the node recovers with
\* stale safety data and may double-vote.
\* ============================================================================

Crash(s) ==
    /\ alive[s] = TRUE
    /\ alive' = [alive EXCEPT ![s] = FALSE]
    \* Volatile state is lost — will be reset on recovery
    /\ UNCHANGED <<safetyVars, persistVars, currentRound, currentEpoch,
                    certVars, voteVars, pipelineVars, commitVars,
                    blockVars, msgs>>

Recover(s) ==
    /\ alive[s] = FALSE
    /\ alive' = [alive EXCEPT ![s] = TRUE]
    \* Family 4: Recovery restores safety data from persisted state
    \* (safety_rules_2chain.rs — persistent_storage.safety_data())
    /\ lastVotedRound' = [lastVotedRound EXCEPT ![s] =
         persistedSafetyData[s].lastVotedRound]
    /\ preferredRound' = [preferredRound EXCEPT ![s] =
         persistedSafetyData[s].preferredRound]
    /\ oneChainRound' = [oneChainRound EXCEPT ![s] =
         persistedSafetyData[s].oneChainRound]
    /\ highestTimeoutRound' = [highestTimeoutRound EXCEPT ![s] =
         persistedSafetyData[s].highestTimeoutRound]
    /\ volatileSafetyData' = [volatileSafetyData EXCEPT ![s] =
         persistedSafetyData[s]]
    /\ currentEpoch' = [currentEpoch EXCEPT ![s] =
         persistedSafetyData[s].epoch]
    /\ UNCHANGED <<persistedSafetyData, currentRound,
                    certVars, voteVars, pipelineVars, commitVars,
                    blockVars, msgs>>

\* ============================================================================
\* ACTION: CrashBetweenSignAndPersist (Family 4)
\*
\* Models the race condition where a vote is signed but the safety data
\* update has not yet been persisted to disk.
\* The signed vote is in the network but safety data is stale.
\* This can lead to double-voting on recovery.
\*
\* (safety_rules_2chain.rs:66-92)
\* Read safety_data (line 66)
\* ... multiple mutations ...
\* Write safety_data (line 92) — CRASH BEFORE THIS
\* ============================================================================

CrashBetweenSignAndPersist(s) ==
    LET r == currentRound[s] IN
    /\ alive[s] = TRUE
    /\ r <= MaxRound
    /\ proposals[s][r] /= Nil
    \* The vote has been created (all checks passed) but persist hasn't happened
    /\ r > lastVotedRound[s]
    \* The vote message is already sent (network has it)
    /\ Broadcast(VoteMsgType, s, r, currentEpoch[s], proposals[s][r])
    \* But we crash BEFORE persisting the updated safety data
    \* So persistedSafetyData still has the OLD lastVotedRound
    /\ alive' = [alive EXCEPT ![s] = FALSE]
    \* Volatile state is lost; persisted state is STALE
    /\ UNCHANGED <<safetyVars, persistVars, currentRound, currentEpoch,
                    certVars, voteVars, pipelineVars, commitVars, blockVars>>

\* ============================================================================
\* ACTION: DropMessage (network fault)
\* ============================================================================

DropMessage(m) ==
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                    voteVars, pipelineVars, commitVars, blockVars>>

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

Next ==
    \* Proposal
    \/ \E s \in Server, v \in Values : Propose(s, v)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveProposal(s, m)
    \* Regular voting (full safety guards)
    \/ \E s \in Server : CastVote(s)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveVote(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : FormQC(s, r)
    \* Order voting (Family 1,2: weaker guards)
    \/ \E s \in Server, r \in 1..MaxRound : CastOrderVote(s, r)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveOrderVote(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : FormOrderingCert(s, r)
    \* Timeout (Family 1: specific safety checks)
    \/ \E s \in Server : SignTimeout(s)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveTimeout(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : FormTC(s, r)
    \* Commit vote (Family 1: missing guards)
    \/ \E s \in Server, r \in 1..MaxRound : SignCommitVote(s, r)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveCommitVote(s, m)
    \* Pipeline (Family 3)
    \/ \E s \in Server, r \in 1..MaxRound : ExecuteBlock(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : AggregateCommitVotes(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : PersistBlock(s, r)
    \/ \E s \in Server : ResetPipeline(s)
    \/ \E s \in Server : TriggerSync(s)
    \* Epoch (Family 5)
    \/ \E s \in Server : EpochChange(s)
    \* Crash/Recovery (Family 4)
    \/ \E s \in Server : Crash(s)
    \/ \E s \in Server : Recover(s)
    \/ \E s \in Server : CrashBetweenSignAndPersist(s)
    \* Network
    \/ \E m \in DOMAIN msgs : DropMessage(m)

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- Standard: VoteSafety ---
\* No two QCs for different blocks in the same (epoch, round).
\* If two servers both see a quorum for round r, they must agree on the value.
VoteSafety ==
    \A r \in 1..MaxRound :
        \A s1, s2 \in Server :
            (HasQuorum(votesForBlock[s1][r]) /\ HasQuorum(votesForBlock[s2][r]))
            => (proposals[s1][r] = proposals[s2][r] \/ proposals[s1][r] = Nil \/ proposals[s2][r] = Nil)

\* --- Family 2: OrderVoteSafety ---
\* No two ordering certs for different blocks in the same round.
OrderVoteSafety ==
    \A r \in 1..MaxRound :
        \A s1, s2 \in Server :
            (HasQuorum(orderVotesForBlock[s1][r]) /\ HasQuorum(orderVotesForBlock[s2][r]))
            => (proposals[s1][r] = proposals[s2][r] \/ proposals[s1][r] = Nil \/ proposals[s2][r] = Nil)

\* --- Standard: CommitSafety ---
\* 2-chain commit rule: committed values never conflict.
CommitSafety ==
    \A r \in 1..MaxRound :
        decidedValues[r] /= Nil =>
            \A s \in Server :
                (proposals[s][r] /= Nil /\ HasQuorum(votesForBlock[s][r]))
                => proposals[s][r] = decidedValues[r]

\* --- Family 5: EpochIsolation ---
\* No vote/order-vote/timeout from epoch E affects decisions in epoch E' /= E.
\* Modeled as: all messages a server processes must match its current epoch.
EpochIsolation ==
    \A s \in Server :
        \A m \in DOMAIN msgs :
            msgs[m] > 0 /\ m.msrc = s =>
                m.mepoch = currentEpoch[s]

\* --- Family 4: NoDoubleVoteAfterCrash ---
\* After crash recovery, a node does not vote for a conflicting block
\* in a previously-voted round.
\* (Structural: lastVotedRound monotonically increases)
NoDoubleVoteAfterCrash ==
    \A s \in Server :
        alive[s] = TRUE =>
            lastVotedRound[s] >= persistedSafetyData[s].lastVotedRound

\* --- Family 1: CommitVoteConsistency ---
\* A commit vote for round r implies the block was ordered with 2f+1 order votes.
CommitVoteConsistency ==
    \A s \in Server, r \in 1..MaxRound :
        (pipelinePhase[s][r] \in {Signed, Aggregated})
        => HasQuorum(orderVotesForBlock[s][r])

\* --- Family 3: PipelineMonotonicity ---
\* Pipeline phases advance monotonically for each block.
\* Once a block reaches phase P, it never goes back to an earlier phase
\* (unless pipeline is reset).
PipelineMonotonicity ==
    \A s \in Server, r \in 1..MaxRound :
        /\ (pipelinePhase[s][r] = Executed => pipelinePhase[s][r] /= Ordered)
        /\ (pipelinePhase[s][r] = Signed => pipelinePhase[s][r] /= Ordered
              /\ pipelinePhase[s][r] /= Executed)
        \* Note: the above is trivially true by construction but
        \* guards against spec bugs in action design

\* --- Structural: RoundMonotonicity ---
\* lastVotedRound never decreases (except on epoch change)
RoundMonotonicity ==
    \A s \in Server :
        alive[s] = TRUE =>
            volatileSafetyData[s].lastVotedRound <= lastVotedRound[s]

\* --- Family 1,2: MC-1 ---
\* Order vote cast at round R does not prevent regular vote at round < R.
\* This is a DESIRED property to verify: the independent tracking may be unsafe.
\* The invariant checks that if a server cast an order vote for round R,
\* it has NOT also cast a regular vote for a round < R after the order vote.
\* (This invariant may be VIOLATED, revealing the bug.)
IndependentRoundTracking ==
    \A s \in Server :
        alive[s] = TRUE =>
            \* If highest order vote round > last_voted_round, the gap
            \* represents a window where conflicting votes could occur
            highestTimeoutRound[s] <= lastVotedRound[s]
                \/ oneChainRound[s] <= lastVotedRound[s]

\* --- Family 1,2: OrderVoteGap ---
\* Direct check: does order-voting create a gap where oneChainRound > lastVotedRound?
\* CastOrderVote updates oneChainRound via ObserveQC but does NOT update lastVotedRound.
\* If violated, it proves the structural gap exists (though it may not cause safety violations).
OrderVoteGap ==
    \A s \in Server :
        alive[s] = TRUE =>
            oneChainRound[s] <= lastVotedRound[s]

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

Spec == Init /\ [][Next]_allVars

=============================================================================
