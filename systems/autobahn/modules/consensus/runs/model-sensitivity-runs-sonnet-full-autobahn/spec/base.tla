---------------------------- MODULE autobahn ----------------------------
(*
 * Autobahn BFT Consensus — Base Specification
 *
 * Category: A (Distributed / Message-Passing / BFT)
 * n >= 3f+1 nodes, authenticated partial-synchrony, static corruption.
 * Protocol: 3-phase Prepare–Confirm–Commit with view-change via TC.
 * Source: primary/src/{messages,core}.rs, hotstuff/src/core.rs
 *
 * Bug families modeled:
 *   F1 — Proposal-Binding Failure     messages.rs:237-279
 *   F2 — View-Change Safety Rules     messages.rs:1349-1358, 1454-1455, 1518-1546
 *   F3 — Confirm Equivocation Guard   core.rs:1167-1183
 *   F4 — Incomplete 2-Chain / Persist hotstuff/core.rs:327, 118
 *   F5 — Inverted GC Predicate        core.rs:1612-1617
 *)

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Nodes,      \* full replica set
    ByzNodes,   \* Byzantine subset (ByzNodes \subseteq Nodes)
    Slots,      \* finite set of pipeline slots {1..S}
    Views,      \* finite set of view numbers {1..V}
    HSRounds,   \* finite set of HotStuff rounds {0..R}
    K,          \* pipeline depth; slot s is in lane s % K
    Proposals,  \* abstract payload universe {P1, P2, ...}
    None        \* sentinel for "absent"

ASSUME ByzNodes \subseteq Nodes
ASSUME Cardinality(Nodes) >= 3 * Cardinality(ByzNodes) + 1
ASSUME K >= 1
ASSUME None \notin Nodes \cup Proposals

HonestNodes == Nodes \ ByzNodes
F == Cardinality(ByzNodes)
QuorumSize  == 2 * F + 1      \* 2f+1
TCQuorumSize == F + 1          \* f+1 for TC formation

IsQuorum(S)     == Cardinality(S) >= QuorumSize
IsWeakQuorum(S) == Cardinality(S) >= TCQuorumSize

Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : x >= y

MinView == Min(Views)
MaxView == Max(Views)
MinSlot == Min(Slots)
MinRound == Min(HSRounds)

-----------------------------------------------------------------------------
\* VARIABLES

VARIABLES
  \* --- Core 3-phase protocol ---
  msgs,           \* set of all broadcast messages (network abstraction)
  nodeView,       \* nodeView[n, s]: view node n is in for slot s
                  \*   primary/src/core.rs: self.views: HashMap<Slot, View>
  committed,      \* committed[s]: proposals committed at slot s, or None
  prepareVoted,   \* prepareVoted[n, s, v]: n cast PrepareVote for (s,v)
                  \*   core.rs:1448: last_voted_consensus: HashSet<(Slot,View)>
  confirmVoted,   \* confirmVoted[n, s, v]: n cast ConfirmVote for (s,v)
                  \*   F3: no such guard exists for Confirm (core.rs:1167-1183)
  prepareQC,      \* prepareQC[s, v]: voters set forming PrepareQC, or None
  confirmQC,      \* confirmQC[s, v]: voters set forming ConfirmQC, or None

  \* --- F1: Proposal-binding ---
  \* messages.rs:237-279 Hash for ConsensusMessage excludes proposals field.
  \* voteDigest[n,s,v] = <<s,v>> (not <<s,v,proposals>>): signatures reusable.
  proposalContent, \* proposalContent[s, v]: proposals the leader sent for (s,v)
  voteDigest,      \* voteDigest[n, s, v]: digest n signed — buggy: omits proposals

  \* --- F2: View-change ---
  \* messages.rs:1349-1358: Hash for Timeout hashes nothing (empty digest).
  \* messages.rs:1454-1455: TC::get_winning_proposals uses wrong variable.
  timeoutSenders,  \* timeoutSenders[s, v]: set of nodes that sent Timeout for (s,v)
  timeoutHighQC,   \* timeoutHighQC[n, s, v]: high_qc view n claimed in Timeout(s,v)
                   \*   empty digest -> Byzantine node can set arbitrary value
  tcFormed,        \* tcFormed[s, v]: winning proposals from TC, or None

  \* --- F4: HotStuff 2-chain + crash-recovery ---
  \* hotstuff/core.rs:327: only checks b0.round+1==b1.round, not b1.round+1==block.round
  \* hotstuff/core.rs:118: last_voted_round and high_qc not written to storage
  hsVotedRound,    \* hsVotedRound[n]: in-memory last voted round (NOT persisted)
  hsVoteCount,     \* hsVoteCount[n, r]: times n voted in round r (ghost; detects dup votes)
  hsCrashed,       \* hsCrashed[n]: n is in crashed/recovering state
  hsBlock,         \* hsBlock[r]: proposals at HotStuff round r, or None
  hsParentRound,   \* hsParentRound[r]: parent round of block r (may gap after view-change)
  hsCommittedRound, \* set of rounds whose blocks have been committed

  \* --- F5: Inverted GC predicate ---
  \* core.rs:1612-1617: retain predicate is De Morgan complement of intended
  activeConsensus,  \* set of (slot,view) pairs in consensus_instances

  \* --- Per-node committed tracking (for AgreementOnProposals) ---
  \* nodeCommitted[n, s]: proposals node n committed for slot s, or None.
  \* Separate from committed[s] so two nodes can commit different values (F1 violation).
  nodeCommitted     \* [Nodes \times Slots -> Proposals \cup {None}]

allVars == <<msgs, nodeView, committed, prepareVoted, confirmVoted,
             prepareQC, confirmQC, proposalContent, voteDigest,
             timeoutSenders, timeoutHighQC, tcFormed,
             hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
             hsParentRound, hsCommittedRound, activeConsensus,
             nodeCommitted>>

-----------------------------------------------------------------------------
\* INIT

Init ==
  /\ msgs             = {}
  /\ nodeView         = [n \in Nodes, s \in Slots |-> MinView]
  /\ committed        = [s \in Slots |-> None]
  /\ prepareVoted     = [n \in Nodes, s \in Slots, v \in Views |-> FALSE]
  /\ confirmVoted     = [n \in Nodes, s \in Slots, v \in Views |-> FALSE]
  /\ prepareQC        = [s \in Slots, v \in Views |-> None]
  /\ confirmQC        = [s \in Slots, v \in Views |-> None]
  /\ proposalContent  = [s \in Slots, v \in Views |-> None]
  /\ voteDigest       = [n \in Nodes, s \in Slots, v \in Views |-> None]
  /\ timeoutSenders   = [s \in Slots, v \in Views |-> {}]
  /\ timeoutHighQC    = [n \in Nodes, s \in Slots, v \in Views |-> None]
  /\ tcFormed         = [s \in Slots, v \in Views |-> None]
  /\ hsVotedRound     = [n \in Nodes |-> 0]
  /\ hsVoteCount      = [n \in Nodes, r \in HSRounds |-> 0]
  /\ hsCrashed        = [n \in Nodes |-> FALSE]
  /\ hsBlock          = [r \in HSRounds |-> None]
  /\ hsParentRound    = [r \in HSRounds |-> 0]
  /\ hsCommittedRound = {}
  /\ activeConsensus  = {}
  /\ nodeCommitted    = [n \in Nodes, s \in Slots |-> None]

-----------------------------------------------------------------------------
\* HELPERS

\* Was a PrepareQC formed for (s,v)? (voters set non-None)
HasPrepareQC(s, v) == prepareQC[s, v] /= None

\* Was a ConfirmQC formed for (s,v)?
HasConfirmQC(s, v) == confirmQC[s, v] /= None

\* All PrepareVote senders in msgs for (s,v)
PrepareVoters(s, v) ==
    { m.sender : m \in { m2 \in msgs : m2.type = "PrepareVote"
                                    /\ m2.slot = s /\ m2.view = v } }

\* All ConfirmVote senders in msgs for (s,v)
ConfirmVoters(s, v) ==
    { m.sender : m \in { m2 \in msgs : m2.type = "ConfirmVote"
                                    /\ m2.slot = s /\ m2.view = v } }

\* Timeout senders for (s,v) -- wrapper for readability
TimeoutCount(s, v) == Cardinality(timeoutSenders[s, v])

\* The proposals a TC resolves to after the buggy get_winning_proposals.
\* messages.rs:1454-1455: winning_view is set to timeout.view (the TC view, constant)
\* rather than the embedded ConfirmQC view. Effect: whichever timeout with a high_qc
\* appears first in iteration order wins, not the highest-view one.
GetWinningProposalsBuggy(s, v) ==
    LET with_qc == { n \in timeoutSenders[s, v] : timeoutHighQC[n, s, v] /= None }
    IN IF with_qc = {}
       THEN None   \* no high_qc present; new leader proposes fresh
       ELSE        \* BUG: CHOOSE picks arbitrary sender, not highest-view one
            LET n_winner == CHOOSE n \in with_qc : TRUE
            IN proposalContent[s, timeoutHighQC[n_winner, s, v]]

\* Correct version for comparison (not what the code does)
GetWinningProposalsCorrect(s, v) ==
    LET with_qc == { n \in timeoutSenders[s, v] : timeoutHighQC[n, s, v] /= None }
    IN IF with_qc = {}
       THEN None
       ELSE LET best_view == Max({ timeoutHighQC[n, s, v] : n \in with_qc })
                n_winner  == CHOOSE n \in with_qc : timeoutHighQC[n, s, v] = best_view
            IN proposalContent[s, timeoutHighQC[n_winner, s, v]]

-----------------------------------------------------------------------------
\* PHASE 1: SEND PREPARE
\* primary/src/core.rs: process_prepare_message / leader broadcast

\* Honest node sends Prepare for (slot, view) with proposals P.
\* Any honest node may propose (leader selection not enforced for safety checking).
\* Pre: no Prepare sent yet for this (slot, view) — proposalContent[s,v] = None.
SendPrepare(n, s, v, P) ==
    /\ n \in HonestNodes
    /\ proposalContent[s, v] = None    \* first proposal for this (slot, view)
    /\ v = nodeView[n, s]              \* n is in the correct view
    \* For v > MinView, require either TC or PrepareQC from prior view
    /\ IF v = MinView
       THEN TRUE
       ELSE \/ HasPrepareQC(s, v - 1)          \* has ticket: QC from prev view
            \/ tcFormed[s, v] /= None           \* has ticket: TC triggered new view
    /\ msgs' = msgs \cup { [type |-> "Prepare", sender |-> n,
                             slot |-> s, view |-> v, proposals |-> P] }
    /\ proposalContent' = [proposalContent EXCEPT ![s, v] = P]
    /\ activeConsensus'  = activeConsensus \cup {<<s, v>>}
    /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, nodeCommitted>>

\* F1: Byzantine equivocation at Prepare phase.
\* messages.rs:237-279: ConsensusMessage digest excludes proposals field.
\* Byzantine leader sends TWO Prepare messages for the same (slot, view)
\* with different proposals — same digest, different payloads.
\* Honest replicas sign both without detecting equivocation.
ByzEquivocatePrepare(n, s, v, P1, P2) ==
    /\ n \in ByzNodes
    /\ P1 /= P2
    /\ proposalContent[s, v] = None    \* first equivocation attempt
    /\ msgs' = msgs \cup { [type |-> "Prepare", sender |-> n,
                             slot |-> s, view |-> v, proposals |-> P1],
                            [type |-> "Prepare", sender |-> n,
                             slot |-> s, view |-> v, proposals |-> P2] }
    \* Record BOTH proposals; voteDigest will use only (s,v), enabling reuse
    \* We record P1 as the "official" content; P2 is the equivocating one.
    /\ proposalContent' = [proposalContent EXCEPT ![s, v] = P1]
    /\ activeConsensus'  = activeConsensus \cup {<<s, v>>}
    /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, nodeCommitted>>

-----------------------------------------------------------------------------
\* PHASE 1 VOTE: CAST PREPARE VOTE
\* primary/src/core.rs:1448 process_prepare_message

\* Honest node n votes Prepare for (slot s, view v).
\* Guard: n has not yet voted for (s, v) — last_voted_consensus check (core.rs:1448).
\* BUG F1: voteDigest is <<s, v>>, NOT <<s, v, proposals>>.
\*         Signatures are therefore reusable for any proposal at (s,v).
CastPrepareVote(n, s, v) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    \* A Prepare message exists for (s, v)
    /\ \E m \in msgs : m.type = "Prepare" /\ m.slot = s /\ m.view = v
    \* core.rs:1448: guard — has not voted for (s,v) yet
    /\ prepareVoted[n, s, v] = FALSE
    /\ v >= nodeView[n, s]             \* not a stale view
    \* Advance nodeView if needed (core.rs:1158-1165: is_valid side-effect for Prepare)
    /\ nodeView' = [nodeView EXCEPT ![n, s] = IF v > nodeView[n, s] THEN v ELSE @]
    /\ prepareVoted' = [prepareVoted EXCEPT ![n, s, v] = TRUE]
    \* F1: digest = <<s, v>> only; proposals excluded (messages.rs:237-279)
    /\ voteDigest' = [voteDigest EXCEPT ![n, s, v] = <<s, v>>]
    /\ msgs' = msgs \cup { [type |-> "PrepareVote", sender |-> n,
                             slot |-> s, view |-> v] }
    /\ UNCHANGED <<committed, confirmVoted, prepareQC, confirmQC,
                   proposalContent, timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

-----------------------------------------------------------------------------
\* FORM PREPARE QC
\* primary/src/messages.rs: QC formation

\* Once 2f+1 PrepareVote messages for (s,v) are observed, form PrepareQC.
\* F1: The QC is bound to (s,v) and a set of voters, but NOT to proposals.
\* Any subset of 2f+1 voters who voted for (s,v) can form a QC for ANY proposals P.
\* This is the core of the Family 1 attack: two QCs with different proposals, same voters.
FormPrepareQC(s, v, voters, P) ==
    /\ prepareQC[s, v] = None          \* QC not yet formed for this (slot,view)
    /\ IsQuorum(voters)
    /\ voters \subseteq Nodes
    \* All voters must have cast PrepareVote for (s,v)
    /\ \A n \in voters : prepareVoted[n, s, v] = TRUE \/ n \in ByzNodes
    \* F1: P can be ANY proposals — not bound to what voters actually signed
    \* The implementation verifies only (slot,view) in the digest, not proposals
    /\ proposalContent[s, v] /= None   \* some Prepare was sent for this (slot,view)
    /\ prepareQC' = [prepareQC EXCEPT ![s, v] = voters]
    \* Update proposalContent to reflect what this QC claims (may differ from original!)
    /\ proposalContent' = [proposalContent EXCEPT ![s, v] = P]
    /\ msgs' = msgs \cup { [type |-> "PrepareQC", slot |-> s, view |-> v,
                             voters |-> voters, proposals |-> P] }
    /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                   confirmQC, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

-----------------------------------------------------------------------------
\* PHASE 2: SEND CONFIRM
\* primary/src/core.rs: leader sends Confirm after receiving PrepareQC

SendConfirm(n, s, v) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    /\ HasPrepareQC(s, v)
    /\ \* No Confirm yet sent for (s,v)
       ~ \E m \in msgs : m.type = "Confirm" /\ m.slot = s /\ m.view = v
                      /\ m.sender \in HonestNodes
    /\ msgs' = msgs \cup { [type |-> "Confirm", sender |-> n,
                             slot |-> s, view |-> v,
                             proposals |-> proposalContent[s, v]] }
    /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

-----------------------------------------------------------------------------
\* PHASE 2 VOTE: CAST CONFIRM VOTE
\* primary/src/core.rs:1167-1183 is_valid Confirm branch

\* F3: The implementation's is_valid for Confirm at core.rs:1167-1183 does NOT
\* check last_voted_consensus before voting. An honest node may cast Confirm vote
\* multiple times for the same (slot,view) on receiving re-sent or replayed Confirms.
\*
\* The CORRECT implementation would guard with:
\*   !self.last_voted_consensus.contains(&(slot, view))
\* as the Prepare branch does (core.rs:1448).
\*
\* Here we model the BUGGY behavior: no equivocation check.
CastConfirmVote(n, s, v) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    /\ \E m \in msgs : m.type = "Confirm" /\ m.slot = s /\ m.view = v
    /\ v >= nodeView[n, s]
    \* F3 BUG: no guard on confirmVoted[n, s, v]
    \* A node can vote Confirm multiple times for the same (slot,view).
    \* (Correct implementation would require: confirmVoted[n,s,v] = FALSE)
    /\ confirmVoted' = [confirmVoted EXCEPT ![n, s, v] = TRUE]
    /\ msgs' = msgs \cup { [type |-> "ConfirmVote", sender |-> n,
                             slot |-> s, view |-> v] }
    /\ UNCHANGED <<nodeView, committed, prepareVoted, prepareQC,
                   confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

-----------------------------------------------------------------------------
\* FORM CONFIRM QC

FormConfirmQC(s, v, voters) ==
    /\ confirmQC[s, v] = None
    /\ IsQuorum(voters)
    /\ voters \subseteq Nodes
    /\ \A n \in voters : confirmVoted[n, s, v] = TRUE \/ n \in ByzNodes
    /\ HasPrepareQC(s, v)
    /\ confirmQC' = [confirmQC EXCEPT ![s, v] = voters]
    /\ msgs' = msgs \cup { [type |-> "ConfirmQC", slot |-> s, view |-> v,
                             voters |-> voters] }
    /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

-----------------------------------------------------------------------------
\* PHASE 3: SEND COMMIT

SendCommit(n, s, v) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    /\ HasConfirmQC(s, v)
    /\ ~ \E m \in msgs : m.type = "Commit" /\ m.slot = s /\ m.view = v
                      /\ m.sender \in HonestNodes
    /\ msgs' = msgs \cup { [type |-> "Commit", sender |-> n,
                             slot |-> s, view |-> v,
                             proposals |-> proposalContent[s, v]] }
    /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

\* Node commits slot s at view v.
ProcessCommit(n, s, v) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    /\ nodeCommitted[n, s] = None    \* node-local guard (not shared committed)
    /\ \E m \in msgs : m.type = "Commit" /\ m.slot = s /\ m.view = v
    /\ HasConfirmQC(s, v)
    \* Update both per-node and shared committed for backward compat
    /\ nodeCommitted' = [nodeCommitted EXCEPT ![n, s] = proposalContent[s, v]]
    /\ committed' = [committed EXCEPT ![s] = proposalContent[s, v]]
    /\ UNCHANGED <<msgs, nodeView, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus>>

-----------------------------------------------------------------------------
\* GC: F5 — INVERTED PREDICATE
\* primary/src/core.rs:1612-1617 clean_slot_periods

\* Called after committing slot s (core.rs: process_commit_message calls this).
\* Intended: drop old entries in the same pipeline lane (s2 % K == slot_period && s2 <= s).
\* Actual predicate: retain(|(s2,_),_| s2 % K != slot_period && s2 <= s)
\*   = drop where NOT (s2 % K != slot_period && s2 <= s)
\*   = drop where (s2 % K == slot_period || s2 > s)
\*   = drops ALL future slots s2 > s in ANY lane  ← BUG
\*   = also drops same-lane entries s2 % K == slot_period  (intended behavior)
\* The inverted De Morgan complement: active future-slot instances are silently purged.
CleanSlotPeriods(s) ==
    /\ committed[s] /= None            \* s was just committed (trigger condition)
    /\ LET slot_period == s % K
           \* BUG: the actual predicate (De Morgan complement of intended):
           buggy_retain == { <<s2, v>> \in activeConsensus :
                               s2 % K /= slot_period /\ s2 <= s }
           \* Correct predicate (keep future-slot entries + entries in other lanes):
           \* correct_retain == { <<s2,v>> \in activeConsensus :
           \*                       s2 % K /= slot_period \/ s2 > s }
       IN activeConsensus' = buggy_retain
    /\ UNCHANGED <<msgs, nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, nodeCommitted>>

-----------------------------------------------------------------------------
\* VIEW CHANGE: TIMEOUT
\* primary/src/core.rs: timeout handler

\* Honest node sends Timeout for (slot s, view v).
\* It includes its highest known ConfirmQC as high_qc.
\* high_qc is encoded as the VIEW of the highest ConfirmQC n has seen for slot s.
SendTimeout(n, s, v) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    /\ v = nodeView[n, s]
    /\ timeoutSenders[s, v] = timeoutSenders[s, v] \* idempotent guard
    /\ ~ (n \in timeoutSenders[s, v])               \* haven't sent timeout for this view
    \* Record n's high_qc: highest view w < v for which n has a ConfirmQC for s
    /\ LET high_qc_view == IF \E w \in Views : w < v /\ confirmQC[s, w] /= None
                           THEN Max({ w \in Views : w < v /\ confirmQC[s, w] /= None })
                           ELSE None
       IN /\ timeoutSenders' = [timeoutSenders EXCEPT ![s, v] =
                                    timeoutSenders[s, v] \cup {n}]
          /\ timeoutHighQC' = [timeoutHighQC EXCEPT ![n, s, v] = high_qc_view]
          /\ msgs' = msgs \cup { [type |-> "Timeout", sender |-> n,
                                   slot |-> s, view |-> v,
                                   highQCView |-> high_qc_view] }
    /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

\* F2: Byzantine node sends Timeout with ARBITRARY high_qc.
\* messages.rs:1349-1358: Hash for Timeout hashes nothing (all hasher.update calls
\* are commented out). Digest = SHA512(""). Signatures are interchangeable.
\* A Byzantine node can forge high_qc = any view, steering the TC winning selection.
ByzSendTimeout(n, s, v, fake_high_qc_view) ==
    /\ n \in ByzNodes
    /\ ~ (n \in timeoutSenders[s, v])
    \* fake_high_qc_view can be ANY view (including one with no real ConfirmQC)
    \* because the Timeout digest is empty, signatures don't bind to high_qc
    /\ fake_high_qc_view \in Views \cup {None}
    /\ timeoutSenders' = [timeoutSenders EXCEPT ![s, v] =
                              timeoutSenders[s, v] \cup {n}]
    /\ timeoutHighQC' = [timeoutHighQC EXCEPT ![n, s, v] = fake_high_qc_view]
    /\ msgs' = msgs \cup { [type |-> "Timeout", sender |-> n,
                              slot |-> s, view |-> v,
                              highQCView |-> fake_high_qc_view] }
    /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

-----------------------------------------------------------------------------
\* FORM TC (Timeout Certificate)
\* primary/src/messages.rs:1518-1546 TC::verify
\* primary/src/messages.rs:1454-1455 TC::get_winning_proposals (BUGGY)

\* Collect f+1 Timeout messages for (s, v) and form TC.
\* F2 BUG 1: TC::verify never verifies embedded high_qc fields (messages.rs:1518-1546).
\* F2 BUG 2: get_winning_proposals assigns winning_view = timeout.view instead of
\*           *other_view, making winner selection non-deterministic (first match wins).
FormTC(s, v) ==
    /\ tcFormed[s, v] = None
    /\ IsWeakQuorum(timeoutSenders[s, v])   \* f+1 timeouts collected
    \* F2 BUG: winning proposals chosen by buggy algorithm (first-found, not highest-view)
    /\ LET win_proposals == GetWinningProposalsBuggy(s, v)
       IN /\ tcFormed' = [tcFormed EXCEPT ![s, v] = win_proposals]
          /\ msgs' = msgs \cup { [type |-> "TC", slot |-> s, view |-> v,
                                   winProposals |-> win_proposals] }
    /\ UNCHANGED <<nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

\* Node processes TC and advances to next view.
\* hotstuff/src/core.rs:391-397: handle_tc does not call tc.verify() at all.
ProcessTC(n, s, v) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    /\ tcFormed[s, v] /= None
    /\ v >= nodeView[n, s]
    \* advance to next view; v+1 must be in Views for model
    /\ v + 1 \in Views \/ v = MaxView
    /\ LET next_view == IF v + 1 \in Views THEN v + 1 ELSE v
       IN nodeView' = [nodeView EXCEPT ![n, s] = next_view]
    /\ UNCHANGED <<msgs, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, hsCommittedRound, activeConsensus, nodeCommitted>>

-----------------------------------------------------------------------------
\* HOTSTUFF (separate crate: hotstuff/src/core.rs)

\* Publish a HotStuff block at round r with parent at parent_r.
HSPublishBlock(r, parent_r, P) ==
    /\ r \in HSRounds
    /\ parent_r \in HSRounds \cup {0}
    /\ parent_r < r
    /\ hsBlock[r] = None
    /\ hsBlock' = [hsBlock EXCEPT ![r] = P]
    /\ hsParentRound' = [hsParentRound EXCEPT ![r] = parent_r]
    /\ UNCHANGED <<msgs, nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed,
                   hsCommittedRound, activeConsensus, nodeCommitted>>

\* Honest node n votes for HotStuff round r.
\* hotstuff/core.rs: make_vote
\* F4 BUG (persistence): hotstuff/core.rs:118 — TODO: Write to storage
\*   preferred_round and last_voted_round. Neither is persisted.
\*   We model this: hsVotedRound is updated in memory but hsCrashRecover resets it.
HSMakeVote(n, r) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    /\ r \in HSRounds
    /\ hsBlock[r] /= None              \* block exists
    /\ r > hsVotedRound[n]             \* core safety check: only vote for higher rounds
    /\ hsVotedRound' = [hsVotedRound EXCEPT ![n] = r]
    /\ hsVoteCount'  = [hsVoteCount  EXCEPT ![n, r] = @ + 1]
    \* F4 BUG: no durable write here; crash will reset hsVotedRound[n] to 0
    /\ UNCHANGED <<msgs, nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsCrashed, hsBlock, hsParentRound,
                   hsCommittedRound, activeConsensus, nodeCommitted>>

\* Process HotStuff block at round r2, check 2-chain commit rule.
\* hotstuff/core.rs:327 — BUGGY check:
\*   if b0.round + 1 == b1.round { self.commit(b0) }
\* Missing second link: b1.round + 1 == block.round is NEVER checked.
\* Correct rule (Jolteon 2-chain): both b0->b1 AND b1->block must be consecutive.
HSProcessBlock(n, r2) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    /\ r2 \in HSRounds
    /\ hsBlock[r2] /= None
    /\ LET r1 == hsParentRound[r2]
           \* r1 may be 0 (genesis) if block r2 has no real parent in HSRounds
           r0 == IF r1 \in HSRounds THEN hsParentRound[r1] ELSE 0
       IN /\ r0 \in HSRounds \cup {0}
          /\ IF r0 \in HSRounds THEN hsBlock[r0] /= None ELSE r0 = 0
          \* F4 BUG: only checks r0+1=r1 (first consecutive link).
          \* Missing: r1+1=r2 (second consecutive link).
          \* When r1=0 (genesis parent), no commit can happen (chain too short).
          /\ IF r1 \in HSRounds /\ r0 + 1 = r1
             THEN hsCommittedRound' = hsCommittedRound \cup {r0}
             ELSE UNCHANGED hsCommittedRound
    /\ UNCHANGED <<msgs, nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsCrashed, hsBlock,
                   hsParentRound, activeConsensus, nodeCommitted>>

\* F4: Crash and recovery.
\* hotstuff/core.rs:118: last_voted_round not persisted.
\* After recovery, in-memory voted round resets to 0 (initial value).
\* Node may then re-vote in rounds it already voted in.
HSCrashRecover(n) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = TRUE             \* must be in crashed state
    /\ hsCrashed' = [hsCrashed EXCEPT ![n] = FALSE]
    \* F4 BUG: voted round resets to 0 because nothing was persisted
    /\ hsVotedRound' = [hsVotedRound EXCEPT ![n] = 0]
    /\ UNCHANGED <<msgs, nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVoteCount, hsBlock, hsParentRound,
                   hsCommittedRound, activeConsensus, nodeCommitted>>

\* Initiate crash (separate from recovery to create a crash window)
HSCrash(n) ==
    /\ n \in HonestNodes
    /\ hsCrashed[n] = FALSE
    /\ hsCrashed' = [hsCrashed EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<msgs, nodeView, committed, prepareVoted, confirmVoted,
                   prepareQC, confirmQC, proposalContent, voteDigest,
                   timeoutSenders, timeoutHighQC, tcFormed,
                   hsVotedRound, hsVoteCount, hsBlock, hsParentRound,
                   hsCommittedRound, activeConsensus, nodeCommitted>>

-----------------------------------------------------------------------------
\* NEXT

Next ==
    \* --- Autobahn 3-phase ---
    \/ \E n \in HonestNodes, s \in Slots, v \in Views, P \in Proposals :
           SendPrepare(n, s, v, P)
    \/ \E n \in ByzNodes, s \in Slots, v \in Views, P1, P2 \in Proposals :
           ByzEquivocatePrepare(n, s, v, P1, P2)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           CastPrepareVote(n, s, v)
    \/ \E s \in Slots, v \in Views, voters \in SUBSET Nodes, P \in Proposals :
           FormPrepareQC(s, v, voters, P)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           SendConfirm(n, s, v)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           CastConfirmVote(n, s, v)
    \/ \E s \in Slots, v \in Views, voters \in SUBSET Nodes :
           FormConfirmQC(s, v, voters)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           SendCommit(n, s, v)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           ProcessCommit(n, s, v)
    \/ \E s \in Slots : CleanSlotPeriods(s)
    \* --- View change ---
    \/ \E n \in HonestNodes, s \in Slots, v \in Views :
           SendTimeout(n, s, v)
    \/ \E n \in ByzNodes, s \in Slots, v \in Views, w \in Views \cup {None} :
           ByzSendTimeout(n, s, v, w)
    \/ \E s \in Slots, v \in Views : FormTC(s, v)
    \/ \E n \in HonestNodes, s \in Slots, v \in Views : ProcessTC(n, s, v)
    \* --- HotStuff ---
    \/ \E r \in HSRounds, pr \in HSRounds \cup {0}, P \in Proposals :
           HSPublishBlock(r, pr, P)
    \/ \E n \in HonestNodes, r \in HSRounds : HSMakeVote(n, r)
    \/ \E n \in HonestNodes, r \in HSRounds : HSProcessBlock(n, r)
    \/ \E n \in HonestNodes : HSCrash(n)
    \/ \E n \in HonestNodes : HSCrashRecover(n)

Spec == Init /\ [][Next]_allVars

-----------------------------------------------------------------------------
\* INVARIANTS

\* --- Structural ---

TypeOK ==
    \* Messages have different field sets depending on type; only check type membership.
    /\ \A m \in msgs : m.type \in {"Prepare","PrepareVote","PrepareQC",
                                    "Confirm","ConfirmVote","ConfirmQC",
                                    "Commit","Timeout","TC"}
    /\ committed \in [Slots -> Proposals \cup {None}]
    /\ prepareVoted \in [Nodes \times Slots \times Views -> BOOLEAN]
    /\ confirmVoted \in [Nodes \times Slots \times Views -> BOOLEAN]

\* At most one proposal committed per slot across all views.
CommitOnce ==
    \A s \in Slots, v1, v2 \in Views :
        /\ HasConfirmQC(s, v1) /\ committed[s] /= None
        /\ HasConfirmQC(s, v2) /\ committed[s] /= None
        => v1 = v2

\* --- F1: AgreementOnProposals ---
\* No two honest nodes commit different proposals for the same slot.
\* Uses nodeCommitted[n, s] so two nodes can observe different proposals (F1 attack).
\* Family 1: proposal-binding failure allows Byzantine leader to form two PrepareQCs
\* with the same voter set but different proposals, steering two nodes to different commits.
AgreementOnProposals ==
    \A s \in Slots, n1 \in HonestNodes, n2 \in HonestNodes :
        /\ nodeCommitted[n1, s] /= None
        /\ nodeCommitted[n2, s] /= None
        => nodeCommitted[n1, s] = nodeCommitted[n2, s]

\* Stronger form: at most one proposal value committed per slot
UniqueCommit ==
    \A s \in Slots, v1, v2 \in Views :
        /\ proposalContent[s, v1] /= None /\ HasConfirmQC(s, v1)
        /\ proposalContent[s, v2] /= None /\ HasConfirmQC(s, v2)
        => proposalContent[s, v1] = proposalContent[s, v2]

\* --- F2: ViewChangeSafety ---
\* The winning proposal after any TC at (s, v+1) is consistent with the highest
\* value locked (confirmed) before the view change.
\* Violation: TC picks proposals from a lower-view ConfirmQC when a higher one exists.
ViewChangeSafety ==
    \A s \in Slots, v \in Views :
        tcFormed[s, v] /= None
        => \* If there is a ConfirmQC for (s, v-1) from the previous view,
           \* the TC's winning proposals should match.
           \A prev_v \in Views :
               /\ prev_v < v
               /\ HasConfirmQC(s, prev_v)
               => tcFormed[s, v] = proposalContent[s, prev_v]
                  \/ \* A higher view also has a ConfirmQC — still OK
                     \E higher_v \in Views :
                         /\ higher_v > prev_v /\ higher_v < v
                         /\ HasConfirmQC(s, higher_v)

\* --- F2: TimeoutAuthenticityBound ---
\* A Byzantine node cannot cause honest nodes to adopt a winning_proposal
\* that no honest node had locked (i.e., no honest node has a ConfirmQC for).
\* Violation: Byzantine timeout with fake high_qc steers TC to an unlocked value.
TimeoutAuthenticityBound ==
    \A s \in Slots, v \in Views :
        tcFormed[s, v] /= None
        => \* The winning proposals must correspond to a real ConfirmQC from honest nodes
           \/ tcFormed[s, v] = None   \* no locking: fresh proposal OK
           \/ \E w \in Views :
                  /\ w < v
                  /\ HasConfirmQC(s, w)
                  /\ proposalContent[s, w] = tcFormed[s, v]

\* --- F3: NoConfirmEquivocation ---
\* An honest node casts at most one Confirm vote per (slot, view).
\* Family 3: is_valid for Confirm at core.rs:1167-1183 lacks the equivocation guard.
NoConfirmEquivocation ==
    \A n \in HonestNodes, s \in Slots, v \in Views :
        \* Count ConfirmVote messages from n for (s,v); must be <= 1
        Cardinality({ m \in msgs : m.type = "ConfirmVote"
                                /\ m.sender = n
                                /\ m.slot = s /\ m.view = v }) <= 1

\* --- F4: TwoChainCommitRule ---
\* A block is committed only when the full 2-chain (both consecutive links) holds.
\* Family 4: hotstuff/core.rs:327 only checks b0.round+1==b1.round.
TwoChainCommitRule ==
    \A r0 \in hsCommittedRound :
        \* There must exist r1, r2 such that both links are consecutive
        \E r1 \in HSRounds, r2 \in HSRounds :
            /\ hsParentRound[r1] = r0
            /\ hsParentRound[r2] = r1
            /\ r0 + 1 = r1          \* first link
            /\ r1 + 1 = r2          \* second link (this is what the code skips)

\* --- F4: VoteSafety ---
\* No honest node votes for the same HotStuff round twice.
\* Violation: crash + recovery resets hsVotedRound to 0; node re-votes in earlier round.
VoteSafety ==
    \A n \in HonestNodes, r \in HSRounds : hsVoteCount[n, r] <= 1

\* --- F5: GCPreservesActive ---
\* After committing slot s, all consensus instances for future slots in the same
\* pipeline lane (s2 % K = s % K, s2 > s) must remain in activeConsensus.
\* Family 5: the inverted predicate drops them (core.rs:1612-1617).
GCPreservesActive ==
    \A s \in Slots, s2 \in Slots, v \in Views :
        /\ committed[s] /= None
        /\ s2 % K = s % K
        /\ s2 > s
        /\ \E n \in HonestNodes : prepareVoted[n, s2, v]  \* evidence instance was active
        => <<s2, v>> \in activeConsensus

=============================================================================
