---------------------------- MODULE MC ----------------------------
(*
   Model Checking spec for Autobahn BFT consensus.

   Wraps base.tla with counter-bounded fault-injection actions,
   symmetry reduction, and structural invariants.

   Bug families with hunting configs:
   - MC1 (FAMILY 1): Persistent Voting State Loss
   - MC2 (FAMILY 3): TC Round Validation
   - MC3 (FAMILY 2): Interleaved QC/TC Processing
   - MC4 (FAMILY 5): Proposal Generation Idempotency
*)

EXTENDS base, Naturals, FiniteSets

(* ======================== Counter-Bounded Actions ======================== *)

VARIABLE crashCounter, timeoutCounter, lossCounter, proposeCounter

(* Counter tuple for view in symmetry reduction *)
faultVars == <<crashCounter, timeoutCounter, lossCounter, proposeCounter>>

(* MC1: Crash injection (targets Family 1) *)
MCCrash(n) ==
    /\ crashCounter < 3
    /\ Crash(n)
    /\ crashCounter' = crashCounter + 1
    /\ UNCHANGED <<timeoutCounter, lossCounter, proposeCounter>>

(* MC2: Timeout collection (targets Family 3) *)
MCAddTimeoutToTC(n, tcRound_val, sender) ==
    /\ timeoutCounter < 5
    /\ AddTimeoutToTC(n, tcRound_val, sender)
    /\ timeoutCounter' = timeoutCounter + 1
    /\ UNCHANGED <<crashCounter, lossCounter, proposeCounter>>

(* MC3: Message loss (targets Family 3 and MC2) *)
MCLoseMessage ==
    /\ lossCounter < 4
    /\ LoseMessage
    /\ lossCounter' = lossCounter + 1
    /\ UNCHANGED <<crashCounter, timeoutCounter, proposeCounter>>

(* MC4: Duplicate proposal attempts (targets Family 5) *)
MCGenerateProposalDuplicate(n) ==
    /\ proposeCounter < 3
    /\ GenerateProposal(n)
    /\ proposeCounter' = proposeCounter + 1
    /\ UNCHANGED <<crashCounter, timeoutCounter, lossCounter>>

(* Unconstrained reactions (no counter) *)
MCCheckVoteSafety(n, r, qcr) ==
    /\ CheckVoteSafety(n, r, qcr)
    /\ UNCHANGED faultVars

MCPersistVoteRound(n) ==
    /\ PersistVoteRound(n)
    /\ UNCHANGED faultVars

MCSendVote(n) ==
    /\ SendVote(n)
    /\ UNCHANGED faultVars

MCProcessQCFromProposal(n, br, qcr) ==
    /\ ProcessQCFromProposal(n, br, qcr)
    /\ UNCHANGED faultVars

MCAdvanceRoundFromQC(n, nr) ==
    /\ AdvanceRoundFromQC(n, nr)
    /\ UNCHANGED faultVars

MCCommitRoundAdvance(n) ==
    /\ CommitRoundAdvance(n)
    /\ UNCHANGED faultVars

MCAdvanceRoundViaTC(n) ==
    /\ AdvanceRoundViaTC(n)
    /\ UNCHANGED faultVars

MCRecover(n) ==
    /\ Recover(n)
    /\ UNCHANGED faultVars

(* ======================== Init and Next ======================== *)

MCInit ==
    /\ Init
    /\ crashCounter = 0
    /\ timeoutCounter = 0
    /\ lossCounter = 0
    /\ proposeCounter = 0

MCNext ==
    \/ \E n \in Node, r \in 1..MaxRound, qcr \in 0..MaxRound : MCCheckVoteSafety(n, r, qcr)
    \/ \E n \in Node : MCPersistVoteRound(n)
    \/ \E n \in Node : MCSendVote(n)
    \/ \E n \in Node, br \in 1..MaxRound, qcr \in 0..MaxRound : MCProcessQCFromProposal(n, br, qcr)
    \/ \E n \in Node, nr \in 1..MaxRound : MCAdvanceRoundFromQC(n, nr)
    \/ \E n \in Node : MCCommitRoundAdvance(n)
    \/ \E n \in Node, tcr \in 1..MaxRound, s \in Node : MCAddTimeoutToTC(n, tcr, s)
    \/ \E n \in Node : AdvanceRoundViaTC(n)  \* Not bounded
    \/ \E n \in Node : MCGenerateProposalDuplicate(n)
    \/ \E n \in Node : MCCrash(n)
    \/ \E n \in Node : MCRecover(n)
    \/ MCLoseMessage

(* ======================== Symmetry Reduction ======================== *)

(* Nodes are symmetric, permute them *)
Permutation == Permutations(Node)

(* Symmetry set *)
Symmetry == {p \in Permutation : TRUE}

(* View excludes fault counters for symmetry *)
MCView == <<round, highQC, highTC, msgs, lastVotedRound, persistentLastVotedRound,
            voteStatus, pendingRoundAdvance, qcProcessing, tcRound, tcSignatures,
            proposedRounds, crashed>>

(* Invariants are defined in base.tla *)
(* Bug-family hunting invariants are defined there as well *)
(* The config file (MC.cfg) declares which invariants to check *)

=============================================================================
