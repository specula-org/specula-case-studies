--------------------------- MODULE base ---------------------------
(*
 * Aptos BFT (2-chain HotStuff / Jolteon) — Round 2 spec.
 *
 * Derived from: aptos-core/consensus/ (round_manager.rs, safety_rules.rs,
 *               safety_rules_2chain.rs, pending_order_votes.rs,
 *               order_vote_msg.rs, wrapped_ledger_info.rs, timeout_2chain.rs,
 *               buffer_manager.rs).
 *
 * System category: Category A (Distributed / Message-Passing) with a
 *   BYZANTINE threat model — n >= 3f + 1, static authenticated faulty set,
 *   partial synchrony.
 *
 * This round focuses on bug families surfaced by the modeling brief that
 * the prior round could not reproduce because the Byzantine adversary was
 * not modelled.  See modeling-brief.md §2.
 *
 * Bug Families:
 *   1 — Crash-window double vote with Byzantine equivocating proposer
 *   2 — Order-vote vs regular-vote guard asymmetry (no last_voted_round
 *       interlock on order votes; no per-author equivocation map)
 *   3 — Certificate / message value-binding gaps
 *       (WrappedLedgerInfo.verify omits verify_consensus_data_hash;
 *        OrderVoteMsg.verify defers QC verification;
 *        sign_commit_vote omits epoch / extension / round-monotonicity)
 *   4 — Cross-epoch replay (release-build debug_assert; weak RX epoch bind)
 *   5 — Pipeline race / decoupled-execution non-atomicity (narrow MC subset)
 *   7 — Optimistic-proposal bypass (light-weight model only)
 *
 * The Byzantine adversary categories from bft-analysis.md that we wire in:
 *   2.1 Equivocation (ByzEquivocateProposer / ByzEquivocateOrderVote)
 *   2.5 Replay      (ByzCrossEpochReplay)
 *   2.7 Certificate / Quorum-Proof Manipulation
 *       (ByzReuseRealCertificate against WrappedLedgerInfo,
 *        ByzForgeQCInOrderVoteMsg, ByzCommitVoteWithBadEpoch).
 *
 * Implementation faithfulness:
 *   Every action is annotated with file:line and follows the production
 *   code's control flow.  Where the production code is INCOMPLETE
 *   (TODOs at safety_rules.rs:412-413; lack of verify_consensus_data_hash
 *   in WrappedLedgerInfo::verify; lack of per-author dedup in
 *   pending_order_votes), the spec models the implementation's CURRENT
 *   behavior so TLC can expose what the implementation actually permits.
 *)

EXTENDS Integers, Sequences, FiniteSets, Bags, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server           \* Set of validator IDs (honest \cup Byzantine)
CONSTANT Faulty           \* Subset of Server — Byzantine validators
CONSTANT MaxRound         \* Maximum round to explore
CONSTANT MaxEpoch         \* Maximum epoch to explore
CONSTANT Nil              \* Sentinel value for "none"
CONSTANT Values           \* Set of abstract block values
CONSTANT Quorum           \* 2f+1 vote threshold

\* Message-type constants
CONSTANTS
    ProposalMsgType,      \* Block proposal (BLS-signed)
    OptProposalMsgType,   \* Optimistic proposal (no signature on block_data)
    VoteMsgType,          \* Regular vote (for QC formation)
    OrderVoteMsgType,     \* Order vote (Jolteon extension, Family 2)
    TimeoutMsgType,       \* 2-chain timeout
    CommitVoteMsgType     \* Commit vote (pipeline, Family 3)

\* Pipeline phase constants (buffer_item.rs:84-89, Family 5)
CONSTANTS
    Ordered,
    Executed,
    Signed,
    Aggregated

Honest == Server \ Faulty

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- SafetyData persistent fields (safety_data.rs:10-21, persistent_safety_storage.rs:150-170) ---
\* Family 1: split into in-flight and persistent views.  inflight_signed_vote
\*           captures the window between sign (safety_rules_2chain.rs:88) and
\*           set_safety_data (:92).  On Crash, the inflight is lost; the
\*           recovered node reads back persistedSafetyData.

VARIABLE persistedSafetyData
    \* [Server -> [epoch, lastVotedRound, preferredRound, oneChainRound,
    \*             highestTimeoutRound, lastVote]] — durable on disk
VARIABLE volatileSafetyData
    \* [Server -> same record] — in-memory copy mutated before persist
VARIABLE inflightSignedVote
    \* [Server -> record-or-Nil] — vote bytes returned to caller but not
    \* yet persisted.  This is the carrier of Family-1's double-vote
    \* mechanism: a Byzantine peer can observe the signed bytes and then
    \* the node crashes before set_safety_data completes.

\* --- Active per-server round state (round_manager.rs) ---
VARIABLE currentRound       \* [Server -> Nat]
VARIABLE alive              \* [Server -> BOOLEAN]
VARIABLE crashed            \* [Server -> BOOLEAN]
VARIABLE highestQCRound     \* [Server -> Nat]
VARIABLE highestTCRound     \* [Server -> Nat]
VARIABLE highestOrderedRound
    \* [Server -> Nat] — order-cert root; Family 2

\* --- Vote aggregation (per server view) ---
\* For Family 2 we model BOTH a digest -> author-set bag (matches the
\* implementation's NotEnoughVotes signature aggregator) AND an
\* authorContribCount that tracks how many DISTINCT digests each
\* author has contributed to.  The implementation lacks per-author
\* dedup, so authorContribCount can exceed 1 — that's the OrderVoteAggregatorDedup
\* invariant target.
VARIABLE votesForBlock        \* [Server -> [Round -> SUBSET Server]]
VARIABLE orderVotesForDigest
    \* [Server -> [Round -> [Value -> SUBSET Server]]] — keyed by
    \* (round, value); each value's set holds order-vote authors.
VARIABLE timeoutVotes         \* [Server -> [Round -> SUBSET Server]]
VARIABLE commitVotes          \* [Server -> [Round -> SUBSET Server]]

\* Family 3: track which (round, digest) pairs the receiver has already
\* "seen" — the first sighting triggers QC verification; subsequent
\* sightings skip it (round_manager.rs:1613-1633).
VARIABLE firstSeenDigest      \* [Server -> [Round -> SUBSET Value]]

\* --- Proposals + ghost leader election (round_manager.rs:500-503) ---
VARIABLE proposals            \* [Server -> [Round -> value or Nil]] per-server view
VARIABLE roundProposer        \* [Round -> Server \cup {Nil}]

\* --- Emitted artifacts (history variables) ---
\* These are the WHOLE history of safety-critical signed artifacts an
\* honest validator has ever emitted, regardless of whether the message
\* is still in the network bag.  They are the substrate of NoDoubleVote /
\* NoCrossPathSign / RecoverPreservesLastVote.
VARIABLE emittedVote
    \* [Server -> [Round -> SUBSET Value]] — set of values voted for at round
VARIABLE emittedOrderVote
    \* [Server -> [Round -> SUBSET Value]] — values order-voted for
VARIABLE emittedTimeout
    \* [Server -> [Round -> SUBSET Value]] — timeouts sent at round
    \* (value is Nil unless a Byzantine reason rewrite happened)
VARIABLE emittedCommitVote
    \* [Server -> [Round -> SUBSET [epoch: Nat, value: Value]]] — Family 3
    \* commit votes can vary by epoch field even at the same round when
    \* sign_commit_vote skips verify_epoch.

\* --- Network: bag of in-flight messages ---
VARIABLE msgs

\* --- Pipeline state (Family 5, buffer_item.rs:84-89) ---
VARIABLE pipelinePhase        \* [Server -> [Round -> phase or Nil]]
VARIABLE syncInProgress       \* [Server -> BOOLEAN]
VARIABLE epochChangeNotified  \* [Server -> BOOLEAN]

\* --- Commit state ---
VARIABLE committedRound       \* [Server -> Nat]
VARIABLE decidedValues        \* [Round -> value or Nil] — global witness

\* --- Forged-certificate library (Family 3, 2.7) ---
\* The Byzantine adversary can take a real signed cert that ever existed
\* and re-emit it with mutated *unsigned* fields (WrappedLedgerInfo's
\* vote_data; OrderVoteMsg's inner QC; the reason field of a RoundTimeout).
\* This is NOT a forge of signatures — it is exactly the value-binding
\* gap that brief Family 3 identifies.
VARIABLE realCerts
    \* SUBSET [kind: STRING, round: Nat, epoch: Nat, value: Value or Nil,
    \*         signers: SUBSET Server] — every QC / OC / TC ever formed.

\* ============================================================================
\* VARIABLE GROUPS (for UNCHANGED clauses)
\* ============================================================================

safetyVars    == <<persistedSafetyData, volatileSafetyData, inflightSignedVote>>
roundVars     == <<currentRound, alive, crashed>>
certVars      == <<highestQCRound, highestTCRound, highestOrderedRound>>
voteVars      == <<votesForBlock, orderVotesForDigest, timeoutVotes,
                   commitVotes, firstSeenDigest>>
emitVars      == <<emittedVote, emittedOrderVote, emittedTimeout,
                   emittedCommitVote>>
pipelineVars  == <<pipelinePhase, syncInProgress, epochChangeNotified>>
commitVars    == <<committedRound, decidedValues>>
blockVars     == <<proposals, roundProposer>>
byzVars       == <<realCerts>>

allVars == <<safetyVars, roundVars, certVars, voteVars, emitVars,
             pipelineVars, commitVars, blockVars, byzVars, msgs>>

\* ============================================================================
\* HELPERS
\* ============================================================================

\* The Server set already enumerates participating validators; there is no
\* per-server membership view in scope.
Validators == Server

HasQuorum(voteSet) == Cardinality(voteSet) >= Quorum

Max(a, b) == IF a >= b THEN a ELSE b

NextRound(r) == r + 1

\* Record-shaped sentinel used for `inflightSignedVote` slots that are
\* "empty".  Comparing heterogeneous shapes (record vs scalar Nil)
\* throws in TLC, so the slot is uniformly a record.  `round = 0`
\* and `value = Nil` distinguishes the sentinel from real votes.
NilInflight == [round |-> 0, value |-> Nil, epoch |-> 0]

\* Record-shaped sentinel for the `lastVote` field of SafetyData.
\* Same rationale as NilInflight.
NilLastVote == [round |-> 0, value |-> Nil]

\* Test for the lastVote sentinel using a record-vs-record comparison.
IsNoLastVote(lv) == lv = NilLastVote

\* Default SafetyData (safety_data.rs:24-30 SafetyData::new(e,0,0,0,None,0))
\* The two new fields (one_chain_round, highest_timeout_round) carry
\* serde(default) = 0 on legacy on-disk data.
NewSafetyData(e) ==
    [epoch              |-> e,
     lastVotedRound     |-> 0,
     preferredRound     |-> 0,
     oneChainRound      |-> 0,
     highestTimeoutRound |-> 0,
     lastVote           |-> NilLastVote]

\* Message constructor — `mvalue2` holds the cert-binding companion value
\* used in the WrappedLedgerInfo rebind action (a Byzantine MITM mutates
\* vote_data.proposed independent of the signed LI's commit_info).
Msg(type, src, round, epoch, value) ==
    [mtype   |-> type,
     msrc    |-> src,
     mround  |-> round,
     mepoch  |-> epoch,
     mvalue  |-> value,
     mvalue2 |-> value,
     mInnerQCEpoch |-> epoch,
     mReason       |-> "NoQC"]

Send(m) == msgs' = msgs (+) SetToBag({m})

Discard(m) == msgs' = msgs (-) SetToBag({m})

Broadcast(m) == msgs' = msgs (+) (m :> Cardinality(Server))

\* ============================================================================
\* INIT
\* ============================================================================

Init ==
    /\ persistedSafetyData = [s \in Server |-> NewSafetyData(1)]
    /\ volatileSafetyData  = [s \in Server |-> NewSafetyData(1)]
    /\ inflightSignedVote  = [s \in Server |-> NilInflight]
    /\ currentRound        = [s \in Server |-> 1]
    /\ alive               = [s \in Server |-> TRUE]
    /\ crashed             = [s \in Server |-> FALSE]
    /\ highestQCRound      = [s \in Server |-> 0]
    /\ highestTCRound      = [s \in Server |-> 0]
    /\ highestOrderedRound = [s \in Server |-> 0]
    /\ votesForBlock       = [s \in Server |->
         [r \in 1..MaxRound |-> {}]]
    /\ orderVotesForDigest = [s \in Server |->
         [r \in 1..MaxRound |-> [v \in Values |-> {}]]]
    /\ timeoutVotes        = [s \in Server |->
         [r \in 1..MaxRound |-> {}]]
    /\ commitVotes         = [s \in Server |->
         [r \in 1..MaxRound |-> {}]]
    /\ firstSeenDigest     = [s \in Server |->
         [r \in 1..MaxRound |-> {}]]
    /\ emittedVote         = [s \in Server |->
         [r \in 1..MaxRound |-> {}]]
    /\ emittedOrderVote    = [s \in Server |->
         [r \in 1..MaxRound |-> {}]]
    /\ emittedTimeout      = [s \in Server |->
         [r \in 1..MaxRound |-> {}]]
    /\ emittedCommitVote   = [s \in Server |->
         [r \in 1..MaxRound |-> {}]]
    /\ msgs                = EmptyBag
    /\ pipelinePhase       = [s \in Server |-> [r \in 1..MaxRound |-> Nil]]
    /\ syncInProgress      = [s \in Server |-> FALSE]
    /\ epochChangeNotified = [s \in Server |-> FALSE]
    /\ committedRound      = [s \in Server |-> 0]
    /\ decidedValues       = [r \in 1..MaxRound |-> Nil]
    /\ proposals           = [s \in Server |-> [r \in 1..MaxRound |-> Nil]]
    /\ roundProposer       = [r \in 1..MaxRound |-> Nil]
    /\ realCerts           = {}

\* ============================================================================
\* OBSERVE QC — update 1-chain and 2-chain rounds in volatile state
\* (safety_rules.rs:135-156, observe_qc)
\* ============================================================================

\* Pure helper: returns the updated volatileSafetyData[s] after observe_qc
\* applied with qcCertifiedRound / qcParentRound.
ObserveQCUpdate(sd, qcCertifiedRound, qcParentRound) ==
    [sd EXCEPT
        !.oneChainRound  = Max(@, qcCertifiedRound),
        !.preferredRound = Max(@, qcParentRound)]

\* ============================================================================
\* ACTION: Propose (regular path — ProposalMsg)
\* (round_manager.rs:532-600 generate_and_send_proposal,
\*  block_data.rs proposal authoring)
\* ============================================================================

Propose(s, v) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ currentRound[s] <= MaxRound
    /\ roundProposer[currentRound[s]] = Nil    \* single proposer per round
    \* round_manager.rs:500-503 — is_valid_proposer (we model abstractly)
    /\ \/ highestQCRound[s] = currentRound[s] - 1
       \/ highestTCRound[s] = currentRound[s] - 1
    /\ Broadcast(Msg(ProposalMsgType, s, currentRound[s],
                     volatileSafetyData[s].epoch, v))
    /\ proposals' = [proposals EXCEPT ![s][currentRound[s]] = v]
    /\ roundProposer' = [roundProposer EXCEPT ![currentRound[s]] = s]
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    pipelineVars, commitVars, byzVars>>

\* ============================================================================
\* ACTION: ProposeOpt — Optimistic proposal (Family 7)
\* (opt_proposal_msg.rs:96-131, round_manager.rs:820-913)
\*
\* OptProposalMsg is a parallel proposal path with weaker checks:
\*   - No BLS signature on block_data.  Authentication is only
\*     "sender field == proposer field" (opt_proposal_msg.rs:96-131).
\*   - failed_authors validation is gated `if !proposal.is_opt_block()`
\*     (round_manager.rs:1259-1274).
\* We model this as a proposal action where the proposer can be ANY
\* server (matching the "no signature" gap), then `process_proposal`
\* enforces the "sender == proposer" check at receive time.
\* ============================================================================

ProposeOpt(s, v) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ currentRound[s] <= MaxRound
    /\ roundProposer[currentRound[s]] = Nil
    \* Opt-proposal does not require the proposer's QC to be present.
    /\ Broadcast(Msg(OptProposalMsgType, s, currentRound[s],
                     volatileSafetyData[s].epoch, v))
    /\ proposals' = [proposals EXCEPT ![s][currentRound[s]] = v]
    /\ roundProposer' = [roundProposer EXCEPT ![currentRound[s]] = s]
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    pipelineVars, commitVars, byzVars>>

\* ============================================================================
\* ACTION: ByzEquivocateProposer (Family 1, BFT § 2.1)
\*
\* A Byzantine validator s \in Faulty acts as proposer for round r and
\* emits TWO conflicting proposals (v1, v2) with v1 /= v2.  Honest
\* validators do not multi-propose; the leader-election ghost variable
\* records ONE assignment, but a Byzantine s can short-circuit it.
\*
\* Composition partner for MC-1: the victim node h crashes between
\* SignVote(h, r, v1) and CompletePersistVote(h); after Recover,
\* persisted_last_voted_round is still r-1 and h re-enters
\* construct_and_sign_vote_two_chain with v2.
\* (safety_rules_2chain.rs:53-95)
\* ============================================================================

ByzEquivocateProposer(s, r, v1, v2) ==
    /\ s \in Faulty
    /\ r <= MaxRound
    /\ v1 \in Values /\ v2 \in Values /\ v1 /= v2
    \* Broadcast two distinct proposal messages at the same round.
    /\ msgs' = msgs (+) (Msg(ProposalMsgType, s, r,
                             volatileSafetyData[s].epoch, v1)
                         :> Cardinality(Server))
                     (+) (Msg(ProposalMsgType, s, r,
                              volatileSafetyData[s].epoch, v2)
                          :> Cardinality(Server))
    /\ roundProposer' =
         IF roundProposer[r] = Nil
         THEN [roundProposer EXCEPT ![r] = s]
         ELSE roundProposer
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    pipelineVars, commitVars, byzVars, proposals>>

\* ============================================================================
\* ACTION: ReceiveProposal
\* (round_manager.rs:1127-1307 process_proposal)
\* ============================================================================

ReceiveProposal(s, m) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype \in {ProposalMsgType, OptProposalMsgType}
    \* safety_rules.rs:204-210 — verify_epoch
    /\ m.mepoch = volatileSafetyData[s].epoch
    \* round_manager.rs:1739 — ensure_round_and_sync_up
    /\ m.mround >= currentRound[s]
    /\ m.mround <= MaxRound
    /\ proposals' = [proposals EXCEPT ![s][m.mround] = m.mvalue]
    /\ currentRound' = [currentRound EXCEPT ![s] =
         Max(currentRound[s], m.mround)]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, alive, crashed, certVars, voteVars,
                    emitVars, pipelineVars, commitVars, roundProposer,
                    byzVars>>

\* ============================================================================
\* ACTION SPLIT: SignVote then CompletePersistVote
\* (safety_rules_2chain.rs:53-95 guarded_construct_and_sign_vote_two_chain)
\*
\* Family 1 / MC-1: the crash window between sign (:88) and
\* set_safety_data (:92).  We split this into two actions:
\*
\*   SignVote(s)            — runs all guards, signs, broadcasts the
\*                            VoteMsg, and writes inflightSignedVote;
\*                            does NOT update persistedSafetyData.
\*   CompletePersistVote(s) — applies inflightSignedVote to
\*                            persistedSafetyData and clears the slot.
\*
\* Crash(s) between the two clears inflightSignedVote and leaves
\* persistedSafetyData stale, so on Recover the node may re-enter
\* SignVote with a different value at the same round (when a Byzantine
\* equivocating proposer supplies one).
\* ============================================================================

SignVote(s) ==
    LET r       == currentRound[s]
        qcRound == highestQCRound[s]
        tcRound == highestTCRound[s]
        sd      == volatileSafetyData[s]
    IN
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ inflightSignedVote[s] = NilInflight
        \* serializing token; SafetyRules holds a Mutex (round_manager.rs)
    /\ r <= MaxRound
    /\ proposals[s][r] /= Nil
    \* safety_rules_2chain.rs:61 — verify_proposal (incl. epoch + QC sig)
    /\ proposals[s][r] \in Values
    \* safety_rules_2chain.rs:70-74 — last_vote idempotent return.
    \* Guard the record access with IF-THEN-ELSE because TLC evaluates
    \* both disjuncts of `\/` and would otherwise dereference `.round`
    \* on the sentinel `Nil`.
    /\ IF IsNoLastVote(sd.lastVote)
       THEN TRUE
       ELSE sd.lastVote.round /= r
    \* safety_rules_2chain.rs:77-80 verify_and_update_last_vote_round (read-side)
    /\ r > sd.lastVotedRound
    \* safety_rules_2chain.rs:81 safe_to_vote (file:150-166)
    /\ \/ r = NextRound(qcRound)
       \/ (r = NextRound(tcRound) /\ qcRound >= tcRound)
    \* safety_rules_2chain.rs:84 — observe_qc (mutates volatile)
    /\ LET sd1 == ObserveQCUpdate(sd, qcRound, IF qcRound > 0 THEN qcRound - 1 ELSE 0)
           sd2 == [sd1 EXCEPT
                    !.lastVotedRound = r,
                    !.lastVote       = [round |-> r, value |-> proposals[s][r]]]
       IN /\ volatileSafetyData' = [volatileSafetyData EXCEPT ![s] = sd2]
          /\ inflightSignedVote' = [inflightSignedVote EXCEPT ![s] =
               [round |-> r, value |-> proposals[s][r], epoch |-> sd.epoch]]
    \* safety_rules_2chain.rs:88-89 — sign + emit VoteMsg
    /\ Broadcast(Msg(VoteMsgType, s, r, sd.epoch, proposals[s][r]))
    /\ emittedVote' = [emittedVote EXCEPT ![s][r] =
         @ \union {proposals[s][r]}]
    \* Self-record
    /\ votesForBlock' = [votesForBlock EXCEPT ![s][r] = @ \union {s}]
    /\ UNCHANGED <<persistedSafetyData, roundVars, certVars,
                    orderVotesForDigest, timeoutVotes, commitVotes,
                    firstSeenDigest, emittedOrderVote, emittedTimeout,
                    emittedCommitVote, pipelineVars, commitVars,
                    blockVars, byzVars>>

\* safety_rules_2chain.rs:91-92 — set_safety_data persists volatile copy
CompletePersistVote(s) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ inflightSignedVote[s] /= NilInflight
    /\ persistedSafetyData' = [persistedSafetyData EXCEPT ![s] = volatileSafetyData[s]]
    /\ inflightSignedVote'  = [inflightSignedVote EXCEPT ![s] = NilInflight]
    /\ UNCHANGED <<volatileSafetyData, roundVars, certVars, voteVars,
                    emitVars, pipelineVars, commitVars, blockVars,
                    byzVars, msgs>>

\* ============================================================================
\* ACTION: ReceiveVote
\* (round_manager.rs:1743-1793 process_vote)
\* ============================================================================

ReceiveVote(s, m) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = VoteMsgType
    /\ m.mepoch = volatileSafetyData[s].epoch
    /\ m.mround <= MaxRound
    \* round_manager.rs:1718-1737 — ensure_round_and_sync_up (regular votes)
    /\ m.mround >= currentRound[s]
    /\ ~HasQuorum(votesForBlock[s][m.mround])
    /\ votesForBlock' = [votesForBlock EXCEPT ![s][m.mround] =
         @ \union {m.msrc}]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, alive, crashed, currentRound, certVars,
                    orderVotesForDigest, timeoutVotes, commitVotes,
                    firstSeenDigest, emitVars, pipelineVars, commitVars,
                    blockVars, byzVars>>

\* ============================================================================
\* ACTION: FormQC
\* (round_manager.rs:1802-1837 — NewQuorumCertificate)
\* ============================================================================

FormQC(s, r) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    /\ HasQuorum(votesForBlock[s][r])
    /\ proposals[s][r] /= Nil
    /\ highestQCRound' = [highestQCRound EXCEPT ![s] = Max(@, r)]
    /\ currentRound' = [currentRound EXCEPT ![s] = Max(@, r + 1)]
    \* 2-chain commit rule (safety_rules_2chain.rs:195-214):
    \*    if round(B0) + 1 = round(B1), commit B0
    /\ IF r > 1
          /\ proposals[s][r - 1] /= Nil
          /\ HasQuorum(votesForBlock[s][r - 1])
       THEN
         /\ committedRound' = [committedRound EXCEPT ![s] = Max(@, r - 1)]
         /\ decidedValues' = [decidedValues EXCEPT ![r - 1] =
              IF decidedValues[r - 1] = Nil
              THEN proposals[s][r - 1]
              ELSE decidedValues[r - 1]]
       ELSE
         UNCHANGED commitVars
    /\ pipelinePhase' =
         IF pipelinePhase[s][r] = Nil
         THEN [pipelinePhase EXCEPT ![s][r] = Ordered]
         ELSE pipelinePhase
    \* Record certificate in the global library (Family 3 reuse)
    /\ realCerts' = realCerts \union
         {[kind |-> "QC", round |-> r,
           epoch |-> volatileSafetyData[s].epoch,
           value |-> proposals[s][r],
           signers |-> votesForBlock[s][r]]}
    /\ UNCHANGED <<safetyVars, alive, crashed, highestTCRound,
                    highestOrderedRound, voteVars, emitVars,
                    syncInProgress, epochChangeNotified,
                    blockVars, msgs>>

\* ============================================================================
\* ACTION: SignOrderVote (Family 2)
\* (safety_rules_2chain.rs:97-119 guarded_construct_and_sign_order_vote)
\*
\* Family 2's load-bearing asymmetry: this path does NOT call
\* verify_and_update_last_vote_round, does NOT update last_voted_round,
\* and the only guard is safe_for_order_vote (:168-178 — round >
\* highest_timeout_round).
\*
\* We INTENTIONALLY do not add a last_voted_round guard.  The goal of
\* the spec is to expose what the implementation actually permits.
\* ============================================================================

SignOrderVote(s, r) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    /\ proposals[s][r] /= Nil
    \* Precondition: a QC exists for round r (broadcast_order_vote, round_manager.rs:1674-1710)
    /\ HasQuorum(votesForBlock[s][r])
    \* safety_rules_2chain.rs:103 — verify_order_vote_proposal (epoch only)
    /\ volatileSafetyData[s].epoch = volatileSafetyData[s].epoch
    \* safety_rules_2chain.rs:108 — observe_qc (updates one_chain, preferred)
    /\ LET sd  == volatileSafetyData[s]
           sd1 == ObserveQCUpdate(sd, r, IF r > 0 THEN r - 1 ELSE 0)
       IN /\ sd1.oneChainRound = sd1.oneChainRound
          \* safety_rules_2chain.rs:110 — safe_for_order_vote (:168-178)
          /\ r > sd.highestTimeoutRound
          /\ volatileSafetyData' = [volatileSafetyData EXCEPT ![s] = sd1]
          \* safety_rules_2chain.rs:117 — set_safety_data (atomic with sign here;
          \*   we still split persist as a separate concern: the bug is the
          \*   missing last_voted_round, not crash window).
          /\ persistedSafetyData' = [persistedSafetyData EXCEPT ![s] = sd1]
    \* safety_rules_2chain.rs:115 — sign(ledger_info) + emit OrderVoteMsg
    /\ Broadcast(Msg(OrderVoteMsgType, s, r, volatileSafetyData[s].epoch,
                     proposals[s][r]))
    /\ orderVotesForDigest' = [orderVotesForDigest EXCEPT
         ![s][r][proposals[s][r]] = @ \union {s}]
    /\ emittedOrderVote' = [emittedOrderVote EXCEPT ![s][r] =
         @ \union {proposals[s][r]}]
    /\ UNCHANGED <<inflightSignedVote, roundVars, certVars,
                    votesForBlock, timeoutVotes, commitVotes,
                    firstSeenDigest, emittedVote, emittedTimeout,
                    emittedCommitVote, pipelineVars, commitVars,
                    blockVars, byzVars>>

\* ============================================================================
\* ACTION: ReceiveOrderVote (Family 2, 3)
\* (round_manager.rs:1582-1660 process_order_vote_msg)
\*
\* Family 2:
\*   - No ensure_round_and_sync_up (uses 100-round window instead).
\*   - No per-author equivocation dedup (pending_order_votes.rs:61-157).
\* Family 3:
\*   - QC verification only on FIRST sighting of a given li_digest
\*     (round_manager.rs:1613-1633).  Subsequent OrderVoteMsgs over the
\*     same digest don't re-verify the inner QC — so a Byzantine sender
\*     can ship a forged QC paired with a valid OrderVote bearing the
\*     same commit_info.
\* ============================================================================

ReceiveOrderVote(s, m) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = OrderVoteMsgType
    /\ m.mepoch = volatileSafetyData[s].epoch
    /\ m.mround <= MaxRound
    \* round_manager.rs:1607-1609 — 100-round window
    /\ m.mround > highestOrderedRound[s]
    /\ m.mround < highestOrderedRound[s] + 100
    \* round_manager.rs:1613 — if digest unseen, verify QC; else trust
    \* Family 3: this is where the QC verification can be skipped.
    /\ LET firstSeen == m.mvalue \in firstSeenDigest[s][m.mround]
       IN /\ orderVotesForDigest' = [orderVotesForDigest EXCEPT
              ![s][m.mround][m.mvalue] = @ \union {m.msrc}]
          /\ firstSeenDigest' = [firstSeenDigest EXCEPT
              ![s][m.mround] = @ \union {m.mvalue}]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, alive, crashed, currentRound, certVars,
                    votesForBlock, timeoutVotes, commitVotes, emitVars,
                    pipelineVars, commitVars, blockVars, byzVars>>

\* ============================================================================
\* ACTION: FormOrderingCert (Family 2, 3)
\* (round_manager.rs:1918-1944, pending_order_votes.rs:61-157)
\* ============================================================================

FormOrderingCert(s, r, v) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    /\ v \in Values
    /\ HasQuorum(orderVotesForDigest[s][r][v])
    /\ highestOrderedRound' = [highestOrderedRound EXCEPT ![s] = Max(@, r)]
    /\ pipelinePhase' =
         IF pipelinePhase[s][r] = Nil
         THEN [pipelinePhase EXCEPT ![s][r] = Ordered]
         ELSE pipelinePhase
    /\ realCerts' = realCerts \union
         {[kind |-> "OC", round |-> r,
           epoch |-> volatileSafetyData[s].epoch,
           value |-> v,
           signers |-> orderVotesForDigest[s][r][v]]}
    /\ UNCHANGED <<safetyVars, roundVars, highestQCRound, highestTCRound,
                    voteVars, emitVars, syncInProgress,
                    epochChangeNotified, commitVars, blockVars, msgs>>

\* ============================================================================
\* ACTION: ByzEquivocateOrderVote (Family 2, BFT § 2.1)
\*
\* A Byzantine validator s contributes its single signature to TWO
\* distinct (round, value) digests in pending_order_votes.  Because the
\* aggregator (pending_order_votes.rs:61-157) lacks an author->vote map,
\* both can independently reach 2f+1 power.
\* ============================================================================

ByzEquivocateOrderVote(s, r, v1, v2) ==
    /\ s \in Faulty
    /\ r <= MaxRound
    /\ v1 \in Values /\ v2 \in Values /\ v1 /= v2
    /\ Broadcast(Msg(OrderVoteMsgType, s, r,
                     volatileSafetyData[s].epoch, v1))
    /\ msgs' = msgs (+) (Msg(OrderVoteMsgType, s, r,
                             volatileSafetyData[s].epoch, v1)
                         :> Cardinality(Server))
                     (+) (Msg(OrderVoteMsgType, s, r,
                              volatileSafetyData[s].epoch, v2)
                          :> Cardinality(Server))
    /\ emittedOrderVote' = [emittedOrderVote EXCEPT ![s][r] =
         @ \union {v1, v2}]
    /\ UNCHANGED <<safetyVars, roundVars, certVars, votesForBlock,
                    orderVotesForDigest, timeoutVotes, commitVotes,
                    firstSeenDigest, emittedVote, emittedTimeout,
                    emittedCommitVote, pipelineVars, commitVars,
                    blockVars, byzVars>>

\* ============================================================================
\* ACTION: SignTimeout (2-chain)
\* (safety_rules_2chain.rs:19-51 guarded_sign_timeout_with_qc)
\*
\* Family 1 historical analog: this path persists BEFORE signing (:47
\* vs :49) and is the canonical fix that commit f58e184471 applied.
\* We model the persist-before-sign order honestly.
\* ============================================================================

SignTimeout(s) ==
    LET r       == currentRound[s]
        qcRound == highestQCRound[s]
        tcRound == highestTCRound[s]
        sd      == volatileSafetyData[s]
    IN
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    \* safety_rules_2chain.rs:26 verify_epoch
    /\ sd.epoch = sd.epoch
    \* safety_rules_2chain.rs:36 safe_to_timeout (:124-145)
    /\ \/ r = NextRound(qcRound)
       \/ r = NextRound(tcRound)
    /\ qcRound >= sd.oneChainRound
    \* safety_rules_2chain.rs:37-42 timeout.round >= last_voted_round
    /\ r >= sd.lastVotedRound
    /\ LET sd1 == [sd EXCEPT
                    !.lastVotedRound = Max(@, r),
                    !.highestTimeoutRound = Max(@, r)]
       IN /\ volatileSafetyData' = [volatileSafetyData EXCEPT ![s] = sd1]
          \* safety_rules_2chain.rs:47 — set_safety_data (BEFORE sign)
          /\ persistedSafetyData' = [persistedSafetyData EXCEPT ![s] = sd1]
    /\ Broadcast(Msg(TimeoutMsgType, s, r, sd.epoch, Nil))
    /\ timeoutVotes' = [timeoutVotes EXCEPT ![s][r] = @ \union {s}]
    /\ emittedTimeout' = [emittedTimeout EXCEPT ![s][r] = @ \union {Nil}]
    /\ UNCHANGED <<inflightSignedVote, roundVars, certVars,
                    votesForBlock, orderVotesForDigest, commitVotes,
                    firstSeenDigest, emittedVote, emittedOrderVote,
                    emittedCommitVote, pipelineVars, commitVars,
                    blockVars, byzVars>>

\* ============================================================================
\* ACTION: EchoTimeout — re-entry that can sign a 2nd timeout at the same
\* round across a crash window (modeling-brief.md Family 1 evidence point).
\*
\* safe_to_timeout allows round == last_voted_round (:37 uses `<` for
\* error, so equality passes).  After a Crash, last_voted_round reverts
\* to persistedSafetyData and the node can sign timeout(r) again.
\* (round_manager.rs:1855-1857 × safety_rules_2chain.rs:37-45)
\* ============================================================================

EchoTimeout(s) ==
    LET r  == currentRound[s]
        sd == volatileSafetyData[s]
    IN
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    /\ r >= sd.lastVotedRound
    /\ Broadcast(Msg(TimeoutMsgType, s, r, sd.epoch, Nil))
    /\ timeoutVotes' = [timeoutVotes EXCEPT ![s][r] = @ \union {s}]
    /\ emittedTimeout' = [emittedTimeout EXCEPT ![s][r] = @ \union {Nil}]
    /\ UNCHANGED <<safetyVars, roundVars, certVars, votesForBlock,
                    orderVotesForDigest, commitVotes, firstSeenDigest,
                    emittedVote, emittedOrderVote, emittedCommitVote,
                    pipelineVars, commitVars, blockVars, byzVars>>

\* ============================================================================
\* ACTION: ReceiveTimeout
\* (round_manager.rs:1876-1916 process_round_timeout_msg)
\* ============================================================================

ReceiveTimeout(s, m) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = TimeoutMsgType
    /\ m.mepoch = volatileSafetyData[s].epoch
    /\ m.mround <= MaxRound
    /\ m.mround >= currentRound[s]
    /\ timeoutVotes' = [timeoutVotes EXCEPT ![s][m.mround] = @ \union {m.msrc}]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, alive, crashed, currentRound, certVars,
                    votesForBlock, orderVotesForDigest, commitVotes,
                    firstSeenDigest, emitVars, pipelineVars, commitVars,
                    blockVars, byzVars>>

\* ============================================================================
\* ACTION: FormTC
\* ============================================================================

FormTC(s, r) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    /\ HasQuorum(timeoutVotes[s][r])
    /\ highestTCRound' = [highestTCRound EXCEPT ![s] = Max(@, r)]
    /\ currentRound' = [currentRound EXCEPT ![s] = Max(@, r + 1)]
    /\ realCerts' = realCerts \union
         {[kind |-> "TC", round |-> r,
           epoch |-> volatileSafetyData[s].epoch,
           value |-> Nil,
           signers |-> timeoutVotes[s][r]]}
    /\ UNCHANGED <<safetyVars, alive, crashed, highestQCRound,
                    highestOrderedRound, voteVars, emitVars,
                    pipelineVars, commitVars, blockVars, msgs>>

\* ============================================================================
\* ACTION: SignCommitVote (Family 3)
\* (safety_rules.rs:372-418 guarded_sign_commit_vote)
\*
\* Family 3 / MC-5: this path is INCOMPLETE per its own TODOs:
\*   - safety_rules.rs:412  TODO: add guarding rules in unhappy path
\*   - safety_rules.rs:413  TODO: add extension check
\* and crucially does NOT call verify_epoch on old_ledger_info.
\* We model exactly this: the only checks are match_ordered_only
\* (modeled as "order cert exists at round r") and signature
\* verification (modeled as "2f+1 votes").  No epoch check.  No
\* round-monotonicity check.
\* ============================================================================

SignCommitVote(s, r, e) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    /\ e >= 1 /\ e <= MaxEpoch
    \* Pipeline precondition (Family 5): block at least Executed
    /\ pipelinePhase[s][r] \in {Executed, Signed}
    \* safety_rules.rs:381-393 — is_ordered_only / match_ordered_only
    \* Modeled as "an order cert OR a QC has been seen for round r".
    /\ \/ \E v \in Values : HasQuorum(orderVotesForDigest[s][r][v])
       \/ HasQuorum(votesForBlock[s][r])
    \* safety_rules.rs:406-410 — verify aggregate signatures (>= Quorum)
    \* (modeled implicitly above)
    \* safety_rules.rs:412-413 — TODO: NO epoch check, NO extension check
    /\ Broadcast(Msg(CommitVoteMsgType, s, r, e, proposals[s][r]))
    /\ pipelinePhase' = [pipelinePhase EXCEPT ![s][r] = Signed]
    /\ commitVotes' = [commitVotes EXCEPT ![s][r] = @ \union {s}]
    /\ emittedCommitVote' = [emittedCommitVote EXCEPT ![s][r] =
         @ \union {[epoch |-> e, value |-> proposals[s][r]]}]
    /\ UNCHANGED <<safetyVars, roundVars, certVars,
                    votesForBlock, orderVotesForDigest, timeoutVotes,
                    firstSeenDigest, emittedVote, emittedOrderVote,
                    emittedTimeout, syncInProgress, epochChangeNotified,
                    commitVars, blockVars, byzVars>>

\* ============================================================================
\* ACTION: ReceiveCommitVote
\* (buffer_manager.rs:736-800 process_commit_message)
\* ============================================================================

ReceiveCommitVote(s, m) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = CommitVoteMsgType
    /\ m.mround <= MaxRound
    /\ commitVotes' = [commitVotes EXCEPT ![s][m.mround] = @ \union {m.msrc}]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, alive, crashed, currentRound, certVars,
                    votesForBlock, orderVotesForDigest, timeoutVotes,
                    firstSeenDigest, emitVars, pipelineVars, commitVars,
                    blockVars, byzVars>>

\* ============================================================================
\* PIPELINE ACTIONS (Family 5, buffer_item.rs / pipeline_builder.rs)
\* ============================================================================

ExecuteBlock(s, r) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    /\ pipelinePhase[s][r] = Ordered
    /\ ~syncInProgress[s]
    /\ ~epochChangeNotified[s]
    /\ pipelinePhase' = [pipelinePhase EXCEPT ![s][r] = Executed]
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    syncInProgress, epochChangeNotified, commitVars,
                    blockVars, byzVars, msgs>>

AggregateCommitVotes(s, r) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    /\ pipelinePhase[s][r] = Signed
    /\ HasQuorum(commitVotes[s][r])
    /\ pipelinePhase' = [pipelinePhase EXCEPT ![s][r] = Aggregated]
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    syncInProgress, epochChangeNotified, commitVars,
                    blockVars, byzVars, msgs>>

PersistBlock(s, r) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ r <= MaxRound
    /\ pipelinePhase[s][r] = Aggregated
    /\ ~syncInProgress[s]
    /\ committedRound' = [committedRound EXCEPT ![s] = Max(@, r)]
    /\ decidedValues' = [decidedValues EXCEPT ![r] =
         IF decidedValues[r] = Nil
         THEN proposals[s][r]
         ELSE decidedValues[r]]
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    pipelineVars, blockVars, byzVars, msgs>>

ResetPipeline(s) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ (syncInProgress[s] \/ epochChangeNotified[s])
    /\ pipelinePhase' = [pipelinePhase EXCEPT ![s] =
         [r \in 1..MaxRound |-> Nil]]
    /\ syncInProgress' = [syncInProgress EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    epochChangeNotified, commitVars, blockVars, byzVars,
                    msgs>>

TriggerSync(s) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ ~syncInProgress[s]
    /\ syncInProgress' = [syncInProgress EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    pipelinePhase, epochChangeNotified, commitVars,
                    blockVars, byzVars, msgs>>

\* ============================================================================
\* ACTION: EpochChange (Family 4)
\* (safety_rules.rs:265-344 guarded_initialize)
\* ============================================================================

EpochChange(s) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ volatileSafetyData[s].epoch < MaxEpoch
    /\ LET sd1 == NewSafetyData(volatileSafetyData[s].epoch + 1)
       IN /\ volatileSafetyData' = [volatileSafetyData EXCEPT ![s] = sd1]
          /\ persistedSafetyData' = [persistedSafetyData EXCEPT ![s] = sd1]
    /\ currentRound' = [currentRound EXCEPT ![s] = 1]
    /\ highestQCRound' = [highestQCRound EXCEPT ![s] = 0]
    /\ highestTCRound' = [highestTCRound EXCEPT ![s] = 0]
    /\ highestOrderedRound' = [highestOrderedRound EXCEPT ![s] = 0]
    /\ epochChangeNotified' = [epochChangeNotified EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<inflightSignedVote, alive, crashed, voteVars,
                    emitVars, pipelinePhase, syncInProgress, commitVars,
                    blockVars, byzVars, msgs>>

\* ============================================================================
\* ACTIONS: Crash / Recover  (Family 1)
\*
\* On Crash, the entire VOLATILE side is reset to PERSISTED.  Per
\* safety_rules_2chain.rs:53-95 the relevant lossy state is
\* inflightSignedVote — the bytes that were already returned to the
\* network but never durably persisted.
\* ============================================================================

Crash(s) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ alive' = [alive EXCEPT ![s] = FALSE]
    /\ crashed' = [crashed EXCEPT ![s] = TRUE]
    /\ inflightSignedVote' = [inflightSignedVote EXCEPT ![s] = NilInflight]
    /\ volatileSafetyData' = [volatileSafetyData EXCEPT ![s] =
         persistedSafetyData[s]]
    /\ UNCHANGED <<persistedSafetyData, currentRound, certVars,
                    voteVars, emitVars, pipelineVars, commitVars,
                    blockVars, byzVars, msgs>>

Recover(s) ==
    /\ alive[s] = FALSE
    /\ crashed[s] = TRUE
    /\ alive' = [alive EXCEPT ![s] = TRUE]
    /\ crashed' = [crashed EXCEPT ![s] = FALSE]
    \* persistent_safety_storage.rs:150-170 — load SafetyData on init
    /\ volatileSafetyData' = [volatileSafetyData EXCEPT ![s] =
         persistedSafetyData[s]]
    /\ inflightSignedVote' = [inflightSignedVote EXCEPT ![s] = NilInflight]
    /\ UNCHANGED <<persistedSafetyData, currentRound, certVars,
                    voteVars, emitVars, pipelineVars, commitVars,
                    blockVars, byzVars, msgs>>

\* ============================================================================
\* ACTION: ByzReuseRealCertificate (Family 3, 2.7)
\* (consensus-types/src/wrapped_ledger_info.rs:90-108 — verify omits
\*  verify_consensus_data_hash; vote_data is attacker-controlled)
\*
\* A Byzantine sender takes a real signed WrappedLedgerInfo over value
\* `v_signed` and re-emits it with `mvalue2` (the unsigned vote_data
\* field) mutated to a DIFFERENT value `v_rebound`.  The receiver-side
\* verify pred runs only signature verification on the LI — which is
\* still over `v_signed` — so verify passes, but downstream consumers
\* that read `vote_data.proposed` get `v_rebound`.
\* ============================================================================

ByzReuseRealCertificate(s, cert, vRebound) ==
    /\ s \in Faulty
    /\ cert \in realCerts
    /\ cert.kind = "QC"
    /\ vRebound \in Values
    /\ vRebound /= cert.value
    \* The rebound LI is shipped as an order-vote-msg (modeling the
    \* WrappedLedgerInfo "subsequent OrderVoteMsgs trust the inner QC"
    \* flow — Family 3 second row).
    /\ msgs' = msgs (+) SetToBag({
         [mtype |-> OrderVoteMsgType,
          msrc  |-> s,
          mround |-> cert.round,
          mepoch |-> cert.epoch,
          mvalue |-> cert.value,    \* signed
          mvalue2 |-> vRebound,     \* unsigned, mutated
          mInnerQCEpoch |-> cert.epoch,
          mReason |-> "NoQC"]})
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    pipelineVars, commitVars, blockVars, byzVars>>

\* ============================================================================
\* ACTION: ByzForgeQCInOrderVoteMsg (Family 3, MC-4 alternate path)
\* (order_vote_msg.rs:47-67 — verify_order_vote skips QC sig verify;
\*  round_manager.rs:1613-1633 — only first sighting verifies QC)
\*
\* After the receiver has already seen one order-vote at (round, value),
\* a Byzantine sender pairs the SAME OrderVote with a forged QC field.
\* The aggregator absorbs the order vote without rechecking the QC.
\* ============================================================================

ByzForgeQCInOrderVoteMsg(s, r, v, forgedValue) ==
    /\ s \in Faulty
    /\ r <= MaxRound
    /\ v \in Values /\ forgedValue \in Values
    /\ v \in firstSeenDigest[s][r]    \* receiver has already verified one
    /\ Broadcast(Msg(OrderVoteMsgType, s, r,
                     volatileSafetyData[s].epoch, v))
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    pipelineVars, commitVars, blockVars, byzVars>>

\* ============================================================================
\* ACTION: ByzCrossEpochReplay (Family 4, BFT § 2.5)
\* (consensus-types/src/timeout_2chain.rs:248-257 — debug_assert compiled
\*  out in release;  order_vote_msg.rs:47-67 — inner QC.certified_block.epoch
\*  not bound to order_vote.epoch)
\*
\* A Byzantine sender takes a real signed message from epoch N and
\* re-emits it claiming epoch = newEpoch.
\* ============================================================================

ByzCrossEpochReplay(s, cert, newEpoch) ==
    /\ s \in Faulty
    /\ cert \in realCerts
    /\ newEpoch >= 1 /\ newEpoch <= MaxEpoch
    /\ newEpoch /= cert.epoch
    /\ msgs' = msgs (+) SetToBag({
         [mtype  |-> IF cert.kind = "QC" THEN VoteMsgType
                     ELSE IF cert.kind = "OC" THEN OrderVoteMsgType
                          ELSE TimeoutMsgType,
          msrc   |-> s,
          mround |-> cert.round,
          mepoch |-> newEpoch,        \* claimed epoch
          mvalue |-> cert.value,
          mvalue2 |-> cert.value,
          mInnerQCEpoch |-> cert.epoch,   \* original inner-QC epoch unchanged
          mReason |-> "NoQC"]})
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    pipelineVars, commitVars, blockVars, byzVars>>

\* ============================================================================
\* ACTION: ByzCommitVoteBadEpoch (Family 3, MC-5)
\* (safety_rules.rs:372-418 — no verify_epoch on sign_commit_vote)
\*
\* A Byzantine actor causes an honest node to be asked to sign a
\* commit vote with a new_ledger_info whose epoch /= safety_data.epoch.
\* The implementation accepts it (no verify_epoch).  We expose this
\* by allowing SignCommitVote to be called with arbitrary e \in epochs.
\* ============================================================================

\* This is realized by SignCommitVote(s, r, e) above: any e can be passed.

\* ============================================================================
\* ACTION: ReceiveOrderVoteWeakEpoch (Family 4 — RX-side weak bind)
\* (order_vote_msg.rs:47-67 — verify_order_vote does NOT bind
\*  order_vote.epoch to inner_qc.certified_block().epoch)
\*
\* The receiver's epoch check (EpochManager) gates m.mepoch against
\* its current epoch.  But the inner QC's epoch (mInnerQCEpoch) is
\* NOT bound to m.mepoch.  So a Byzantine peer can ship a cross-epoch
\* message whose outer epoch matches but inner QC epoch differs.
\* ============================================================================

ReceiveOrderVoteWeakEpoch(s, m) ==
    /\ alive[s] = TRUE
    /\ ~crashed[s]
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ m.mtype = OrderVoteMsgType
    /\ m.mepoch = volatileSafetyData[s].epoch
    /\ m.mInnerQCEpoch /= m.mepoch       \* the unbound inner epoch
    /\ m.mround <= MaxRound
    /\ m.mround > highestOrderedRound[s]
    /\ m.mround < highestOrderedRound[s] + 100
    /\ orderVotesForDigest' = [orderVotesForDigest EXCEPT
         ![s][m.mround][m.mvalue] = @ \union {m.msrc}]
    /\ firstSeenDigest' = [firstSeenDigest EXCEPT
         ![s][m.mround] = @ \union {m.mvalue}]
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, alive, crashed, currentRound, certVars,
                    votesForBlock, timeoutVotes, commitVotes, emitVars,
                    pipelineVars, commitVars, blockVars, byzVars>>

\* ============================================================================
\* NETWORK FAULT
\* ============================================================================

DropMessage(m) ==
    /\ m \in DOMAIN msgs
    /\ msgs[m] > 0
    /\ Discard(m)
    /\ UNCHANGED <<safetyVars, roundVars, certVars, voteVars, emitVars,
                    pipelineVars, commitVars, blockVars, byzVars>>

\* ============================================================================
\* NEXT
\* ============================================================================

Next ==
    \/ \E s \in Server, v \in Values : Propose(s, v)
    \/ \E s \in Server, v \in Values : ProposeOpt(s, v)
    \/ \E s \in Faulty, r \in 1..MaxRound, v1, v2 \in Values :
        ByzEquivocateProposer(s, r, v1, v2)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveProposal(s, m)
    \/ \E s \in Server : SignVote(s)
    \/ \E s \in Server : CompletePersistVote(s)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveVote(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : FormQC(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : SignOrderVote(s, r)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveOrderVote(s, m)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveOrderVoteWeakEpoch(s, m)
    \/ \E s \in Server, r \in 1..MaxRound, v \in Values : FormOrderingCert(s, r, v)
    \/ \E s \in Faulty, r \in 1..MaxRound, v1, v2 \in Values :
        ByzEquivocateOrderVote(s, r, v1, v2)
    \/ \E s \in Server : SignTimeout(s)
    \/ \E s \in Server : EchoTimeout(s)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveTimeout(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : FormTC(s, r)
    \/ \E s \in Server, r \in 1..MaxRound, e \in 1..MaxEpoch : SignCommitVote(s, r, e)
    \/ \E s \in Server, m \in DOMAIN msgs : ReceiveCommitVote(s, m)
    \/ \E s \in Server, r \in 1..MaxRound : ExecuteBlock(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : AggregateCommitVotes(s, r)
    \/ \E s \in Server, r \in 1..MaxRound : PersistBlock(s, r)
    \/ \E s \in Server : ResetPipeline(s)
    \/ \E s \in Server : TriggerSync(s)
    \/ \E s \in Server : EpochChange(s)
    \/ \E s \in Server : Crash(s)
    \/ \E s \in Server : Recover(s)
    \/ \E s \in Faulty, cert \in realCerts, v \in Values :
        ByzReuseRealCertificate(s, cert, v)
    \/ \E s \in Faulty, r \in 1..MaxRound, v \in Values, fv \in Values :
        ByzForgeQCInOrderVoteMsg(s, r, v, fv)
    \/ \E s \in Faulty, cert \in realCerts, e \in 1..MaxEpoch :
        ByzCrossEpochReplay(s, cert, e)
    \/ \E m \in DOMAIN msgs : DropMessage(m)

Spec == Init /\ [][Next]_allVars

\* ============================================================================
\* INVARIANTS
\* ============================================================================

\* --- §5 Safety: Agreement ---
\* No two honest validators commit different blocks at the same round.
Agreement ==
    \A r \in 1..MaxRound :
        \A s1, s2 \in Honest :
            (committedRound[s1] >= r /\ committedRound[s2] >= r
                /\ decidedValues[r] /= Nil)
                => proposals[s1][r] = Nil \/ proposals[s2][r] = Nil
                   \/ proposals[s1][r] = proposals[s2][r]

\* --- §5 Safety: NoDoubleVote ---
\* An honest validator emits at most one Vote per (epoch, round).
\* Strengthened from prior round to test the post-crash recovery path.
\* (Family 1, MC-1)
NoDoubleVote ==
    \A s \in Honest, r \in 1..MaxRound :
        Cardinality(emittedVote[s][r]) <= 1

\* --- §5 Safety: NoCrossPathSign ---
\* An honest validator does not emit both a Vote and an OrderVote for
\* distinct values at the same (epoch, round).  (Family 2, MC-2)
NoCrossPathSign ==
    \A s \in Honest, r \in 1..MaxRound :
        \A v1, v2 \in Values :
            (v1 \in emittedVote[s][r] /\ v2 \in emittedOrderVote[s][r])
            => v1 = v2

\* --- §5 Safety: OrderVoteAggregatorDedup ---
\* If pending_order_votes reports EnoughVotes for a digest, no two of
\* the 2f+1 signers are the same author.  (Family 2, MC-3 — currently
\* the implementation has no per-author dedup, so this can be violated
\* by a single Byzantine signer contributing to two digests.)
\* Cross-server form: at each (round, value) digest with 2f+1 power,
\* require the signers be authors with single contributions.
OrderVoteAggregatorDedup ==
    \A s \in Server, r \in 1..MaxRound :
        \A v1, v2 \in Values :
            (v1 /= v2
                /\ HasQuorum(orderVotesForDigest[s][r][v1])
                /\ HasQuorum(orderVotesForDigest[s][r][v2]))
            => (orderVotesForDigest[s][r][v1]
                  \intersect orderVotesForDigest[s][r][v2]) \subseteq Faulty

\* --- §5 Safety: QCValueBound ---
\* If a node has accepted an order vote at (round, value), then EITHER
\* the proposal at that round is value OR the sender is faulty.  In
\* the rebind scenario (Family 3 / MC-4), an honest node should not
\* accumulate an order vote for v_rebound when the QC is over v_signed.
QCValueBound ==
    \A s \in Honest, r \in 1..MaxRound :
        \A v \in Values :
            (\E sig \in orderVotesForDigest[s][r][v] : sig \in Honest)
            =>  proposals[s][r] = v \/ proposals[s][r] = Nil

\* --- §5 Safety: TCQuorumPower ---
\* If a TwoChainTimeoutCertificate is recorded in realCerts, its signer
\* set has >= Quorum power.  (Family 3 — checks that the TC's verify
\* path enforces threshold; the actual verify lacks threshold check, so
\* this invariant is what we WANT to hold, may be violated.)
TCQuorumPower ==
    \A cert \in realCerts :
        cert.kind = "TC" => Cardinality(cert.signers) >= Quorum

\* --- §5 Safety: CommitEpochBound ---
\* A node signs a commit vote only for new_ledger_info whose epoch
\* matches volatileSafetyData[s].epoch.  Currently sign_commit_vote
\* has NO verify_epoch — so this can be violated (MC-5).
CommitEpochBound ==
    \A s \in Honest, r \in 1..MaxRound :
        \A cv \in emittedCommitVote[s][r] :
            cv.epoch = persistedSafetyData[s].epoch

\* --- §5 Safety: OrderVoteEpochBound ---
\* An accepted order vote's inner QC has the same epoch as the
\* order-vote's epoch.  Currently RX side does not bind these (Family 4,
\* MC-6) — a Byzantine peer can ship an order-vote with mismatched
\* inner_qc_epoch.  When violated, an order-vote was absorbed
\* whose inner QC was from a different epoch.
OrderVoteEpochBound ==
    \A s \in Honest, r \in 1..MaxRound, v \in Values :
        \A m \in DOMAIN msgs :
            (msgs[m] > 0 /\ m.mtype = OrderVoteMsgType
                /\ m.mround = r /\ m.mvalue = v
                /\ m.msrc \in orderVotesForDigest[s][r][v])
            => m.mInnerQCEpoch = m.mepoch

\* --- §5 Safety: RecoverPreservesLastVote ---
\* After Crash; Recover, persistedSafetyData[s].lastVotedRound is >=
\* the highest round at which `s` ever emitted a Vote whose response
\* could have been observed by an honest peer.  Currently this is
\* VIOLATED under sign-then-persist (Family 1, MC-1).
RecoverPreservesLastVote ==
    \A s \in Honest :
        \A r \in 1..MaxRound :
            (\E v \in emittedVote[s][r] : TRUE)
            => persistedSafetyData[s].lastVotedRound >= r

\* --- Standard: CommitSafety ---
CommitSafety ==
    \A r \in 1..MaxRound :
        decidedValues[r] /= Nil =>
            \A s \in Honest :
                (proposals[s][r] /= Nil /\ HasQuorum(votesForBlock[s][r]))
                => proposals[s][r] = decidedValues[r]

\* --- Structural ---

\* lastVotedRound (persistent) never exceeds current round + 1
LVRBound ==
    \A s \in Server :
        ~crashed[s] => persistedSafetyData[s].lastVotedRound <= MaxRound

RoundPositive ==
    \A s \in Server : currentRound[s] >= 1

\* highestTimeoutRound <= MaxRound
HTRBound ==
    \A s \in Server :
        persistedSafetyData[s].highestTimeoutRound <= MaxRound

\* lastVote in safety_data, when present, has the round it claims.
\* TLC evaluates both sides of `=>` so we have to gate the record
\* access behind IF-THEN-ELSE to avoid `.round` on the Nil sentinel.
LastVoteShape ==
    \A s \in Server :
        IF IsNoLastVote(persistedSafetyData[s].lastVote)
        THEN TRUE
        ELSE persistedSafetyData[s].lastVote.round
                <= persistedSafetyData[s].lastVotedRound

\* PipelinePhase monotonicity (informal)
PipelineMonotone ==
    \A s \in Server, r \in 1..MaxRound :
        \/ pipelinePhase[s][r] = Nil
        \/ pipelinePhase[s][r] = Ordered
        \/ pipelinePhase[s][r] = Executed
        \/ pipelinePhase[s][r] = Signed
        \/ pipelinePhase[s][r] = Aggregated

=============================================================================
