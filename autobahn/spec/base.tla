--------------------------- MODULE base ---------------------------
(*
 * TLA+ specification for Autobahn BFT consensus (SOSP 2024).
 *
 * Derived from: neilgiri/autobahn-artifact primary/src/core.rs
 * Bug Families: 1 (Proposal Binding & Equivocation),
 *               2 (View Change Safety),
 *               3 (Message Acceptance Guards),
 *               4 (Fast/Slow Path Interaction),
 *               5 (Slot Bounding & GC)
 *
 * This spec models the implementation's actual control flow, not the
 * paper algorithm. Deviations from the reference are where bugs live.
 *
 * Abstraction: The DAG data dissemination layer is abstracted away.
 * Proposals are modeled as abstract values from set Values.
 * Vote collection is modeled globally (not as individual messages).
 *)

EXTENDS Integers, FiniteSets, TLC

\* ============================================================================
\* CONSTANTS
\* ============================================================================

CONSTANT Server          \* Set of server IDs (n = 3f+1)
CONSTANT MaxSlot         \* Maximum slot number to explore
CONSTANT MaxView         \* Maximum view per slot
CONSTANT K               \* Parallelism parameter (max concurrent slots)
CONSTANT Nil             \* Sentinel value for "none"

\* Proposal values (abstract DAG tip snapshots)
CONSTANT Values

\* Byzantine server set — at most f servers
CONSTANT Byzantine

\* Message type constants
CONSTANTS
    PrepareMsg,          \* Prepare message (phase 1)
    ConfirmMsg,          \* Confirm message (phase 2, carries PrepareQC)
    CommitMsg,           \* Commit message (phase 3, carries ConfirmQC or fast PrepareQC)
    TimeoutMsg           \* Timeout message (for view change)

\* ============================================================================
\* DERIVED CONSTANTS
\* ============================================================================

Honest == Server \ Byzantine

N == Cardinality(Server)
F == (N - 1) \div 3          \* f where n = 3f+1
QuorumSize == 2 * F + 1      \* 2f+1
FastSize == N                 \* 3f+1 = n (unanimity for fast path)
ValiditySize == F + 1         \* f+1

Slot == 1..MaxSlot
View == 1..MaxView

\* ============================================================================
\* HELPERS
\* ============================================================================

IsQuorum(S) == Cardinality(S) >= QuorumSize
IsFastQuorum(S) == Cardinality(S) >= FastSize
HasValidity(S) == Cardinality(S) >= ValiditySize

\* Leader election: SemiParallelRRLeaderElector (leader.rs:42)
\* index = (view + slot) % N, keys sorted (BTreeMap order)
\* Bug: keys.sort() commented out (leader.rs:41), but BTreeMap is sorted
ServerSeq == CHOOSE seq \in [1..N -> Server] :
                 \A i, j \in 1..N : i /= j => seq[i] /= seq[j]

Leader(sl, v) == ServerSeq[((v + sl) % N) + 1]

\* ============================================================================
\* VARIABLES
\* ============================================================================

\* --- Per-server, per-slot consensus state ---
\* Reference: core.rs self.views HashMap<Slot, View>
VARIABLE views              \* [Server -> [Slot -> 0..MaxView]]
                            \* 0 means slot not yet entered

\* Reference: core.rs:1448 self.last_voted_consensus HashSet<(Slot, View)>
\* Family 3: Code HAS this guard for Prepare
VARIABLE votedPrepare       \* [Server -> [Slot -> 0..MaxView]]
                            \* Last view voted for in Prepare (0 = not voted)

\* Family 3 Bug DA-6: Code DOES NOT have this guard for Confirm
\* We track it to DETECT double voting, not to PREVENT it
VARIABLE votedConfirm       \* [Server -> [Slot -> 0..MaxView]]
                            \* Last view voted for in Confirm (0 = not voted)
                            \* NOTE: This is NOT checked in the code!

\* --- QC/TC evidence (per server, per slot) ---
\* Reference: core.rs:1483 self.high_qcs HashMap<Slot, ConsensusMessage>
VARIABLE highQCView         \* [Server -> [Slot -> 0..MaxView]]
VARIABLE highQCValue        \* [Server -> [Slot -> Values \cup {Nil}]]

\* Reference: core.rs:1452 self.high_proposals (only if use_fast_path)
\* Family 4: Only tracked when fast path enabled
VARIABLE highPropView       \* [Server -> [Slot -> 0..MaxView]]
VARIABLE highPropValue      \* [Server -> [Slot -> Values \cup {Nil}]]

\* --- Decision state ---
VARIABLE committed          \* [Server -> [Slot -> Values \cup {Nil}]]

\* --- Vote collection (global per-slot, per-view) ---
\* Tracks WHICH servers voted, NOT what value they voted for.
\* Family 1: Votes don't bind to proposals (digest excludes proposals).
\* messages.rs:246 FIXME: proposal_digest not included.
VARIABLE prepareVotes       \* [Slot -> [View -> SUBSET Server]]
VARIABLE confirmVotes       \* [Slot -> [View -> SUBSET Server]]

\* --- Timeout tracking ---
VARIABLE timeoutSent        \* [Slot -> [View -> SUBSET Server]]

\* --- Proposal tracking ---
\* What values have been proposed for each (slot, view).
\* Family 1: Multiple values possible if Byzantine leader equivocates.
VARIABLE proposed           \* [Slot -> [View -> SUBSET Values]]

\* --- Timeout evidence (for TC formation) ---
\* Records each server's highQC and highProp at time of timeout.
\* Needed for get_winning_proposals() logic (messages.rs:1436-1499).
VARIABLE timeoutHighQCView  \* [Slot -> [View -> [Server -> 0..MaxView]]]
VARIABLE timeoutHighQCValue \* [Slot -> [View -> [Server -> Values \cup {Nil}]]]
VARIABLE timeoutHighPropView  \* [Slot -> [View -> [Server -> 0..MaxView]]]
VARIABLE timeoutHighPropValue \* [Slot -> [View -> [Server -> Values \cup {Nil}]]]

\* --- Messages (broadcast, not consumed on receive) ---
VARIABLE messages           \* Set of message records

\* ============================================================================
\* VARIABLE GROUPS
\* ============================================================================

serverVars == <<views, votedPrepare, votedConfirm>>
evidenceVars == <<highQCView, highQCValue, highPropView, highPropValue>>
decisionVars == <<committed>>
voteVars == <<prepareVotes, confirmVotes>>
timeoutVars == <<timeoutSent, timeoutHighQCView, timeoutHighQCValue,
                 timeoutHighPropView, timeoutHighPropValue>>
proposalVars == <<proposed>>

vars == <<serverVars, evidenceVars, decisionVars, voteVars,
          timeoutVars, proposalVars, messages>>

\* ============================================================================
\* TYPE INVARIANT
\* ============================================================================

TypeOK ==
    /\ views \in [Server -> [Slot -> 0..MaxView]]
    /\ votedPrepare \in [Server -> [Slot -> 0..MaxView]]
    /\ votedConfirm \in [Server -> [Slot -> 0..MaxView]]
    /\ highQCView \in [Server -> [Slot -> 0..MaxView]]
    /\ highQCValue \in [Server -> [Slot -> Values \cup {Nil}]]
    /\ highPropView \in [Server -> [Slot -> 0..MaxView]]
    /\ highPropValue \in [Server -> [Slot -> Values \cup {Nil}]]
    /\ committed \in [Server -> [Slot -> Values \cup {Nil}]]

\* ============================================================================
\* INITIALIZATION
\* ============================================================================

Init ==
    /\ views = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ votedPrepare = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ votedConfirm = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ highQCView = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ highQCValue = [s \in Server |-> [sl \in Slot |-> Nil]]
    /\ highPropView = [s \in Server |-> [sl \in Slot |-> 0]]
    /\ highPropValue = [s \in Server |-> [sl \in Slot |-> Nil]]
    /\ committed = [s \in Server |-> [sl \in Slot |-> Nil]]
    /\ prepareVotes = [sl \in Slot |-> [v \in View |-> {}]]
    /\ confirmVotes = [sl \in Slot |-> [v \in View |-> {}]]
    /\ timeoutSent = [sl \in Slot |-> [v \in View |-> {}]]
    /\ proposed = [sl \in Slot |-> [v \in View |-> {}]]
    /\ timeoutHighQCView = [sl \in Slot |-> [v \in View |->
                               [s \in Server |-> 0]]]
    /\ timeoutHighQCValue = [sl \in Slot |-> [v \in View |->
                                [s \in Server |-> Nil]]]
    /\ timeoutHighPropView = [sl \in Slot |-> [v \in View |->
                                 [s \in Server |-> 0]]]
    /\ timeoutHighPropValue = [sl \in Slot |-> [v \in View |->
                                  [s \in Server |-> Nil]]]
    /\ messages = {}

\* ============================================================================
\* ACTIONS
\* ============================================================================

\* --------------------------------------------------------------------------
\* SendPrepare: Leader sends Prepare for (slot, view) with a proposal value.
\*
\* Reference: core.rs:993-1090 (set_consensus_proposal)
\*
\* For honest leaders: sends same value to all (one message in set).
\* For Byzantine leaders: can send different values (multiple messages).
\*
\* Family 3 Bug DA-4: Receivers don't check sender == leader,
\* so any server can propose (modeled via ByzantinePrepare).
\* --------------------------------------------------------------------------
SendPrepare(s, sl, v, val) ==
    /\ s \in Honest
    /\ Leader(sl, v) = s
    /\ views[s][sl] <= v        \* Can propose for current or future view
    /\ val \in Values
    \* Honest leader proposes at most once per (slot, view)
    /\ ~\E m \in messages : m.mtype = PrepareMsg /\ m.mslot = sl
                            /\ m.mview = v /\ m.mauthor = s
    \* Slot bounding (core.rs:1036-1043): slot s needs commit from s-K
    \* Family 5: Only checked locally by leader
    /\ IF sl <= K THEN TRUE ELSE \E s2 \in Honest : committed[s2][sl - K] /= Nil
    \* Broadcast Prepare message
    /\ messages' = messages \cup
        {[mtype |-> PrepareMsg, mslot |-> sl, mview |-> v,
          mvalue |-> val, mauthor |-> s]}
    /\ proposed' = [proposed EXCEPT ![sl][v] = @ \cup {val}]
    /\ views' = [views EXCEPT ![s][sl] = v]
    /\ UNCHANGED <<votedPrepare, votedConfirm, evidenceVars, decisionVars,
                   voteVars, timeoutVars>>

\* --------------------------------------------------------------------------
\* ByzantinePrepare: Byzantine server sends arbitrary Prepare.
\*
\* Family 1: Can send different values to different nodes (equivocation).
\* Family 3 Bug DA-4: No leader check on receiver, so non-leader Prepares
\*                     are accepted and voted on.
\* --------------------------------------------------------------------------
ByzantinePrepare(s, sl, v, val) ==
    /\ s \in Byzantine
    /\ v \in View
    /\ sl \in Slot
    /\ val \in Values
    /\ messages' = messages \cup
        {[mtype |-> PrepareMsg, mslot |-> sl, mview |-> v,
          mvalue |-> val, mauthor |-> s]}
    /\ proposed' = [proposed EXCEPT ![sl][v] = @ \cup {val}]
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars>>

\* --------------------------------------------------------------------------
\* ReceivePrepare: Honest server receives Prepare and votes.
\*
\* Reference: core.rs:1406-1466 (process_prepare_message)
\*            core.rs:1108-1166 (is_valid for Prepare)
\*
\* Bug DA-4: NO check that m.mauthor == Leader(m.mslot, m.mview)
\*           Any server's Prepare is accepted.
\* Bug DA-8: NO check that committed[s][m.mslot] = Nil
\*           Votes on already-committed slots.
\* core.rs:1165: view check uses strict equality (==)
\* core.rs:1448: duplicate guard via last_voted_consensus
\* --------------------------------------------------------------------------
ReceivePrepare(s, sl, v) ==
    /\ s \in Honest
    /\ \E m \in messages :
        /\ m.mtype = PrepareMsg
        /\ m.mslot = sl
        /\ m.mview = v
        \* core.rs:1158-1161: advance view if behind
        \* core.rs:1165: strict equality check (views == view)
        /\ views[s][sl] <= v
        \* core.rs:1448: duplicate guard — haven't voted in this (slot, view)
        /\ votedPrepare[s][sl] /= v
        \* Bug DA-4: NO leader check — any author accepted
        \* Bug DA-8: NO committed check
        \* Vote for this Prepare
        /\ views' = [views EXCEPT ![s][sl] = v]
        /\ votedPrepare' = [votedPrepare EXCEPT ![s][sl] = v]
        /\ prepareVotes' = [prepareVotes EXCEPT ![sl][v] = @ \cup {s}]
        \* core.rs:1452: update highProp (Family 4: only if use_fast_path)
        /\ highPropView' = [highPropView EXCEPT ![s][sl] = v]
        /\ highPropValue' = [highPropValue EXCEPT ![s][sl] = m.mvalue]
        /\ UNCHANGED <<votedConfirm, highQCView, highQCValue,
                       decisionVars, confirmVotes, timeoutVars,
                       proposalVars, messages>>

\* --------------------------------------------------------------------------
\* SendConfirm: Leader sends Confirm after PrepareQC (2f+1 votes, slow path).
\*
\* Reference: core.rs process_vote -> QCMaker -> Confirm
\*            aggregators.rs:135-150 (fast path check)
\*
\* Family 1 Bug DA-1: QC doesn't bind to proposal value.
\* The QC is for (slot, view) regardless of value.
\* Leader can attach ANY value from proposed[sl][v].
\* --------------------------------------------------------------------------
SendConfirm(s, sl, v, val) ==
    /\ s \in Honest
    /\ IsQuorum(prepareVotes[sl][v])        \* 2f+1 Prepare votes
    /\ ~IsFastQuorum(prepareVotes[sl][v])   \* Not fast (otherwise skip to commit)
    \* Family 1: QC doesn't bind to value. Server uses value from the
    \* Prepare it accepted (highPropValue). Different honest servers may
    \* have different values due to Byzantine equivocation.
    /\ val = highPropValue[s][sl]
    /\ val /= Nil                           \* Must have accepted a Prepare
    /\ messages' = messages \cup
        {[mtype |-> ConfirmMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* --------------------------------------------------------------------------
\* ByzantineConfirm: Byzantine server sends Confirm with arbitrary value.
\* --------------------------------------------------------------------------
ByzantineConfirm(s, sl, v, val) ==
    /\ s \in Byzantine
    /\ IsQuorum(prepareVotes[sl][v])
    /\ val \in proposed[sl][v]    \* Byzantine can pick any proposed value
    /\ messages' = messages \cup
        {[mtype |-> ConfirmMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* --------------------------------------------------------------------------
\* ReceiveConfirm: Honest server receives Confirm and votes.
\*
\* Reference: core.rs:1468-1496 (process_confirm_message)
\*            core.rs:1167-1183 (is_valid for Confirm)
\*
\* Bug DA-6: NO duplicate voting guard (code lacks last_voted check).
\*           Unlike Prepare (which has last_voted_consensus guard at 1448),
\*           Confirm handler has NO such guard.
\* Bug DA-18: View check uses <= (not strict ==).
\*            core.rs:1171: curr_view <= view
\* --------------------------------------------------------------------------
ReceiveConfirm(s, sl, v) ==
    /\ s \in Honest
    /\ \E m \in messages :
        /\ m.mtype = ConfirmMsg
        /\ m.mslot = sl
        /\ m.mview = v
        \* core.rs:1171: view check uses <= (Bug DA-18)
        /\ views[s][sl] <= v
        \* Bug DA-6: NO duplicate guard for Confirm votes!
        \* The code does NOT check last_voted_consensus for Confirm.
        \* Vote for this Confirm
        /\ views' = [views EXCEPT ![s][sl] = v]
        /\ votedConfirm' = [votedConfirm EXCEPT ![s][sl] = v]
        /\ confirmVotes' = [confirmVotes EXCEPT ![sl][v] = @ \cup {s}]
        \* core.rs:1483: update highQC
        /\ highQCView' = [highQCView EXCEPT ![s][sl] = v]
        /\ highQCValue' = [highQCValue EXCEPT ![s][sl] = m.mvalue]
        /\ UNCHANGED <<votedPrepare, highPropView, highPropValue,
                       decisionVars, prepareVotes, timeoutVars,
                       proposalVars, messages>>

\* --------------------------------------------------------------------------
\* SendCommit: Leader sends Commit after ConfirmQC (2f+1 Confirm votes).
\*
\* Reference: core.rs process_vote -> QCMaker -> Commit
\*
\* Family 1: val can be ANY proposed value (QC doesn't bind).
\* --------------------------------------------------------------------------
SendCommit(s, sl, v, val) ==
    /\ s \in Honest
    /\ IsQuorum(confirmVotes[sl][v])       \* 2f+1 Confirm votes
    \* Family 1: QC doesn't bind. Server uses value from the Confirm it
    \* accepted (highQCValue). Different honest servers may differ.
    /\ val = highQCValue[s][sl]
    /\ val /= Nil                          \* Must have accepted a Confirm
    /\ messages' = messages \cup
        {[mtype |-> CommitMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* --------------------------------------------------------------------------
\* SendFastCommit: Leader sends Commit via fast path (3f+1 PrepareQC).
\*
\* Reference: aggregators.rs:135-150 (fast path: all N voters)
\*            Skips Confirm phase entirely.
\*
\* Family 4: Fast path interaction with slow path.
\* --------------------------------------------------------------------------
SendFastCommit(s, sl, v, val) ==
    /\ s \in Honest
    /\ IsFastQuorum(prepareVotes[sl][v])   \* 3f+1 = N Prepare votes
    \* Fast path: all N voted Prepare. Server uses its own highPropValue.
    /\ val = highPropValue[s][sl]
    /\ val /= Nil
    /\ messages' = messages \cup
        {[mtype |-> CommitMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* --------------------------------------------------------------------------
\* ByzantineCommit: Byzantine server sends Commit with arbitrary value.
\* Requires either ConfirmQC or fast PrepareQC to exist.
\* --------------------------------------------------------------------------
ByzantineCommit(s, sl, v, val) ==
    /\ s \in Byzantine
    /\ \/ IsQuorum(confirmVotes[sl][v])
       \/ IsFastQuorum(prepareVotes[sl][v])
    /\ val \in proposed[sl][v]
    /\ messages' = messages \cup
        {[mtype |-> CommitMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* --------------------------------------------------------------------------
\* ReceiveCommit: Honest server commits upon receiving valid Commit.
\*
\* Reference: core.rs:1517-1588 (process_commit_message)
\*            core.rs:1184-1190 (is_valid for Commit)
\*
\* Bug DA-14: NO check for already-committed slot.
\*            Can overwrite committed value.
\* Bug DA-5/core.rs:1185: Only calls verify_commit (QC signature check).
\*            No view check (commented out at core.rs:1189).
\* --------------------------------------------------------------------------
ReceiveCommit(s, sl, v) ==
    /\ s \in Honest
    /\ \E m \in messages :
        /\ m.mtype = CommitMsg
        /\ m.mslot = sl
        /\ m.mview = v
        \* core.rs:1185: only verify_commit (QC valid)
        \* No view check (core.rs:1189 commented out)
        \* Bug DA-14: NO check for already committed
        \* Commit the value
        /\ committed' = [committed EXCEPT ![s][sl] = m.mvalue]
        /\ UNCHANGED <<serverVars, evidenceVars, voteVars,
                       timeoutVars, proposalVars, messages>>

\* --------------------------------------------------------------------------
\* SendTimeout: Honest server times out for its current (slot, view).
\*
\* Reference: core.rs:1705-1776 (local_timeout_round)
\*            core.rs:1793: check slot not committed
\*            core.rs:1743-1751: create Timeout with highQC and highProp
\*
\* Timeout carries current highQC and highProp evidence for view change.
\* Bug DA-2: Timeout::digest() hashes NOTHING (messages.rs:1349-1358).
\*           Signature is meaningless. Modeled: timeouts accepted without
\*           content verification.
\* --------------------------------------------------------------------------
SendTimeout(s, sl) ==
    /\ s \in Honest
    /\ LET v == views[s][sl]
       IN
       /\ v > 0                              \* Must have entered the slot
       /\ v \in View                         \* Must be valid view
       /\ committed[s][sl] = Nil             \* core.rs:1793
       /\ s \notin timeoutSent[sl][v]        \* Don't re-send
       \* Record timeout with current evidence
       /\ timeoutSent' = [timeoutSent EXCEPT ![sl][v] = @ \cup {s}]
       /\ timeoutHighQCView' = [timeoutHighQCView EXCEPT
                                   ![sl][v][s] = highQCView[s][sl]]
       /\ timeoutHighQCValue' = [timeoutHighQCValue EXCEPT
                                    ![sl][v][s] = highQCValue[s][sl]]
       /\ timeoutHighPropView' = [timeoutHighPropView EXCEPT
                                     ![sl][v][s] = highPropView[s][sl]]
       /\ timeoutHighPropValue' = [timeoutHighPropValue EXCEPT
                                      ![sl][v][s] = highPropValue[s][sl]]
       /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                      voteVars, proposalVars, messages>>

\* --------------------------------------------------------------------------
\* AdvanceView: Server processes 2f+1 timeouts → TC forms → advance view.
\*
\* Reference: core.rs:1816-1825 (TC formation in handle_timeout)
\*            core.rs:1820: views.insert(timeout.slot, timeout.view + 1)
\*
\* Bug DA-3: TC::verify() always returns Ok (TC::PartialEq always true).
\*           messages.rs:1405-1411, 1518-1546.
\*           Modeled: any server can advance view when 2f+1 timeouts exist.
\* --------------------------------------------------------------------------
AdvanceView(s, sl, v) ==
    /\ s \in Honest
    /\ views[s][sl] = v
    /\ v < MaxView                           \* Don't exceed bound
    /\ IsQuorum(timeoutSent[sl][v])          \* 2f+1 timeouts for (slot, v)
    /\ committed[s][sl] = Nil                \* core.rs:1793
    \* Advance to view v+1
    /\ views' = [views EXCEPT ![s][sl] = v + 1]
    \* Reset votedPrepare for new view
    /\ votedPrepare' = [votedPrepare EXCEPT ![s][sl] = 0]
    /\ UNCHANGED <<votedConfirm, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars, messages>>

\* --------------------------------------------------------------------------
\* GeneratePrepareFromTC: New leader creates Prepare from TC evidence.
\*
\* Reference: core.rs:1856-1914 (generate_prepare_from_tc)
\*            messages.rs:1436-1499 (get_winning_proposals)
\*
\* Bug DA-5: winning_view = timeout.view instead of highQC's view.
\*           messages.rs:1455: winning_view = timeout.view (not other_view)
\*
\* The winning proposal selection logic:
\* 1. Find highest ConfirmQC among timeout senders → use its value
\*    BUG: winning_view is set to timeout's view, not QC's view
\* 2. Find f+1 matching Prepares → override
\*    BUG: matching by digest which doesn't include proposals,
\*         so ALL prepares for same (slot, view) "match"
\* --------------------------------------------------------------------------
GeneratePrepareFromTC(s, sl, v) ==
    /\ s \in Honest
    /\ Leader(sl, v) = s
    /\ views[s][sl] = v
    /\ v > 1                                 \* TC only for view > 1
    /\ LET prevV == v - 1
           senders == timeoutSent[sl][prevV]
       IN
       /\ IsQuorum(senders)                  \* TC exists (2f+1 timeouts)
       \* Determine winning value from TC evidence
       /\ \E val \in Values \cup {Nil} :
            \* The winning value comes from TC's get_winning_proposals logic.
            \* Due to Bug DA-5 (wrong view comparison) and Bug DA-1 (broken
            \* digest matching), the implementation may select incorrect values.
            \* We model this by allowing the leader to pick any value that
            \* COULD be selected under the buggy logic:
            \*
            \* Case 1: No evidence → propose freely
            /\ \/ (/\ \A s2 \in senders : timeoutHighQCView[sl][prevV][s2] = 0
                   /\ \A s2 \in senders : timeoutHighPropView[sl][prevV][s2] = 0
                   /\ val \in Values)
               \* Case 2: Some ConfirmQC evidence → use highest QC's value
               \* Bug DA-5: comparison may select wrong QC due to view bug
               \/ (/\ \E s2 \in senders : timeoutHighQCView[sl][prevV][s2] > 0
                   /\ LET bestSender == CHOOSE s2 \in senders :
                            /\ timeoutHighQCView[sl][prevV][s2] > 0
                            /\ \A s3 \in senders :
                                timeoutHighQCView[sl][prevV][s3] <=
                                timeoutHighQCView[sl][prevV][s2]
                      IN val = timeoutHighQCValue[sl][prevV][bestSender])
               \* Case 3: f+1 matching Prepares override
               \* Bug DA-1: digest matching is broken (all match same slot/view)
               \* So any prepare value from f+1 senders can be chosen
               \/ (/\ HasValidity({s2 \in senders :
                        timeoutHighPropView[sl][prevV][s2] > 0})
                   /\ \E s2 \in senders :
                        /\ timeoutHighPropView[sl][prevV][s2] > 0
                        /\ val = timeoutHighPropValue[sl][prevV][s2])
            \* Create new Prepare
            /\ messages' = messages \cup
                {[mtype |-> PrepareMsg, mslot |-> sl, mview |-> v,
                  mvalue |-> val, mauthor |-> s]}
            /\ proposed' = [proposed EXCEPT ![sl][v] = @ \cup {val}]
       /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                      voteVars, timeoutVars>>

\* --------------------------------------------------------------------------
\* EnterSlot: Server enters a new slot (view 1).
\*
\* Reference: core.rs process_prepare_message timer start (1433-1440)
\*            Models the initial entry into a slot's consensus.
\* --------------------------------------------------------------------------
EnterSlot(s, sl) ==
    /\ s \in Honest
    /\ views[s][sl] = 0                     \* Haven't entered this slot yet
    \* Slot bounding: need commit from sl-K (Family 5)
    /\ IF sl <= K THEN TRUE ELSE committed[s][sl - K] /= Nil
    /\ views' = [views EXCEPT ![s][sl] = 1]
    /\ UNCHANGED <<votedPrepare, votedConfirm, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars, messages>>

\* --------------------------------------------------------------------------
\* LoseMessage: Remove a message from the network (message loss).
\* Only used in MC spec (bounded).
\* --------------------------------------------------------------------------
LoseMessage(m) ==
    /\ m \in messages
    /\ messages' = messages \ {m}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* ============================================================================
\* NEXT STATE RELATION
\* ============================================================================

Next ==
    \/ \E s \in Server, sl \in Slot, v \in View, val \in Values :
        \/ SendPrepare(s, sl, v, val)
        \/ ByzantinePrepare(s, sl, v, val)
        \/ SendConfirm(s, sl, v, val)
        \/ ByzantineConfirm(s, sl, v, val)
        \/ SendCommit(s, sl, v, val)
        \/ SendFastCommit(s, sl, v, val)
        \/ ByzantineCommit(s, sl, v, val)
    \/ \E s \in Server, sl \in Slot, v \in View :
        \/ ReceivePrepare(s, sl, v)
        \/ ReceiveConfirm(s, sl, v)
        \/ ReceiveCommit(s, sl, v)
        \/ AdvanceView(s, sl, v)
        \/ GeneratePrepareFromTC(s, sl, v)
    \/ \E s \in Server, sl \in Slot :
        \/ SendTimeout(s, sl)
        \/ EnterSlot(s, sl)
    \/ \E m \in messages : LoseMessage(m)

Spec == Init /\ [][Next]_vars

\* ============================================================================
\* SAFETY INVARIANTS
\* ============================================================================

\* --------------------------------------------------------------------------
\* AgreementSafety: No two honest servers commit different values for the
\* same slot. This is the fundamental BFT safety property.
\*
\* Targets: Family 1 (equivocation), Family 2 (view change), Family 3 (guards)
\* --------------------------------------------------------------------------
AgreementSafety ==
    \A s1, s2 \in Honest : \A sl \in Slot :
        (committed[s1][sl] /= Nil /\ committed[s2][sl] /= Nil)
        => committed[s1][sl] = committed[s2][sl]

\* --------------------------------------------------------------------------
\* ViewChangeSafety: If a ConfirmQC formed for value val in view v,
\* then any committed value for the same slot must have been proposed
\* in that view. This ensures view change cannot override a locked value.
\*
\* A ConfirmQC for (sl, v) means IsQuorum(confirmVotes[sl][v]).
\*
\* Note: Uses proposed[] (persistent) instead of messages (lossy).
\*
\* Targets: Family 2
\* --------------------------------------------------------------------------
ViewChangeSafety ==
    \A sl \in Slot : \A v \in View :
        IsQuorum(confirmVotes[sl][v]) =>
            \A s \in Honest :
                committed[s][sl] /= Nil =>
                    committed[s][sl] \in proposed[sl][v]

\* --------------------------------------------------------------------------
\* NoDoubleVotePrepare: No honest server votes Prepare twice in the same
\* (slot, view). This SHOULD hold because the code has a guard (core.rs:1448).
\*
\* Targets: Family 3 (verification that guard works)
\* --------------------------------------------------------------------------
NoDoubleVotePrepare ==
    \A sl \in Slot : \A v \in View :
        \A s \in Honest :
            s \in prepareVotes[sl][v] =>
                votedPrepare[s][sl] = v

\* --------------------------------------------------------------------------
\* FastPathCorrectness: If a fast PrepareQC (3f+1) forms and a slow-path
\* ConfirmQC also forms for the same (slot, view), they must agree on value.
\*
\* Targets: Family 4
\* --------------------------------------------------------------------------
FastPathCorrectness ==
    \A sl \in Slot : \A v \in View :
        (IsFastQuorum(prepareVotes[sl][v]) /\ IsQuorum(confirmVotes[sl][v]))
        => \A m1, m2 \in messages :
            (/\ m1.mtype = CommitMsg /\ m1.mslot = sl /\ m1.mview = v
             /\ m2.mtype = CommitMsg /\ m2.mslot = sl /\ m2.mview = v)
            => m1.mvalue = m2.mvalue

\* --------------------------------------------------------------------------
\* CommitValidity: Any committed value was actually proposed.
\*
\* Targets: Family 3
\* --------------------------------------------------------------------------
CommitValidity ==
    \A s \in Honest : \A sl \in Slot :
        committed[s][sl] /= Nil =>
            \E v \in View : committed[s][sl] \in proposed[sl][v]

\* --------------------------------------------------------------------------
\* Structural invariants
\* --------------------------------------------------------------------------

\* View values are bounded
ViewBound ==
    \A s \in Server : \A sl \in Slot :
        views[s][sl] <= MaxView

\* Committed values are stable (no revocation)
\* Bug DA-14: This MAY be violated due to missing duplicate commit guard!
CommitStability ==
    \A s \in Honest : \A sl \in Slot :
        committed[s][sl] /= Nil =>
            committed'[s][sl] = committed[s][sl]

====
