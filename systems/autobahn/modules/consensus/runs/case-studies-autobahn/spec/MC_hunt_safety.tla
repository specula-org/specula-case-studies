--------------------------- MODULE MC_hunt_safety ---------------------------
(*
 * Hunting specification for safety bugs with DA-1 FIXED.
 *
 * Adds three capabilities missing from the base MC spec:
 *
 *   1. ByzantineTimeout (DA-2+DA-3): Byzantine can inject forged timeout
 *      entries for any (slot, view) with arbitrary QC/Prop evidence.
 *      Models DA-2 (Timeout::digest hashes nothing → forgeable) combined
 *      with DA-3 (TC::verify always passes → forged TC accepted).
 *
 *   2. ByzantineVotePrepare/Confirm: Byzantine nodes' votes are counted
 *      toward QC quorum. The base spec only counts honest votes in
 *      prepareVotes/confirmVotes. In the real system, vote aggregation
 *      counts all valid signatures including Byzantine ones.
 *
 *   3. BuggyGeneratePrepareFromTC (DA-5): The winning proposal selection
 *      can pick a sender with a LOWER QC view. Models the bug where
 *      winning_view = timeout.view instead of the QC's actual view.
 *
 * Two specifications are provided:
 *   - MCHuntDA23Spec: DA-1 fixed + DA-2/DA-3 (correct GeneratePrepareFromTC)
 *   - MCHuntDA5Spec:  DA-1 fixed + DA-2/DA-3 + DA-5 (buggy selection)
 *)

EXTENDS MC_noDA1

\* ============================================================================
\* NEW ACTIONS: Byzantine TC forgery (DA-2 + DA-3)
\* ============================================================================

\* Byzantine forges timeout entry for any (slot, view).
\* DA-2: Timeout::digest() hashes nothing → all timeouts have same digest.
\* DA-3: TC::verify() always passes → any TC is accepted.
\* Combined: Byzantine can inject fake timeout entries with arbitrary evidence
\* into any (slot, view)'s timeout set, enabling TC formation without
\* real honest timeouts reaching quorum.
ByzantineTimeout(s, sl, v) ==
    /\ s \in Byzantine
    /\ v \in View
    /\ sl \in Slot
    /\ timeoutSent' = [timeoutSent EXCEPT ![sl][v] = @ \cup {s}]
    /\ \E qcV \in 0..MaxView :
       \E qcVal \in Values \cup {Nil} :
        /\ timeoutHighQCView' = [timeoutHighQCView EXCEPT ![sl][v][s] = qcV]
        /\ timeoutHighQCValue' = [timeoutHighQCValue EXCEPT ![sl][v][s] = qcVal]
    /\ \E propV \in 0..MaxView :
       \E propVal \in Values \cup {Nil} :
        /\ timeoutHighPropView' = [timeoutHighPropView EXCEPT ![sl][v][s] = propV]
        /\ timeoutHighPropValue' = [timeoutHighPropValue EXCEPT ![sl][v][s] = propVal]
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, proposalVars, messages>>

\* ============================================================================
\* NEW ACTIONS: Byzantine vote contribution
\* ============================================================================

\* Byzantine Prepare vote counted toward QC quorum.
\* In the real system, QCMaker.append() counts all valid vote signatures,
\* including Byzantine. The base spec only adds honest IDs to prepareVotes.
ByzantineVotePrepare(s, sl, v, val) ==
    /\ s \in Byzantine
    /\ sl \in Slot
    /\ v \in View
    /\ val \in Values
    /\ prepareVotes' = [prepareVotes EXCEPT ![sl][v] = @ \cup {s}]
    /\ prepareVotesFor' = [prepareVotesFor EXCEPT ![sl][v][val] = @ \cup {s}]
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   confirmVotes, confirmVotesFor, timeoutVars,
                   proposalVars, messages>>

\* Byzantine Confirm vote counted toward QC quorum.
ByzantineVoteConfirm(s, sl, v, val) ==
    /\ s \in Byzantine
    /\ sl \in Slot
    /\ v \in View
    /\ val \in Values
    /\ confirmVotes' = [confirmVotes EXCEPT ![sl][v] = @ \cup {s}]
    /\ confirmVotesFor' = [confirmVotesFor EXCEPT ![sl][v][val] = @ \cup {s}]
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   prepareVotes, prepareVotesFor, timeoutVars,
                   proposalVars, messages>>

\* ============================================================================
\* DA-5 BUGGY GeneratePrepareFromTC
\* ============================================================================

\* Bug DA-5: In get_winning_proposals(), winning_view is set to timeout.view
\* instead of the highQC's actual view (messages.rs:1455).
\*
\* Effect: When iterating timeouts, the first timeout with any QC evidence
\* sets winning_view = timeout.view (which is the same for all timeouts in
\* the same TC). Subsequent timeouts with HIGHER QC views cannot beat this
\* inflated winning_view. So the first match wins, not the highest.
\*
\* We model this by allowing the leader to pick ANY sender with non-zero
\* QC evidence, not just the one with the highest QC view.
BuggyGeneratePrepareFromTC(s, sl, v) ==
    /\ s \in Honest
    /\ Leader(sl, v) = s
    /\ views[s][sl] = v
    /\ v > 1
    /\ LET prevV == v - 1
           senders == timeoutSent[sl][prevV]
       IN
       /\ IsQuorum(senders)
       /\ \E val \in Values \cup {Nil} :
            \* Case 1: No evidence → propose freely
            /\ \/ (/\ \A s2 \in senders : timeoutHighQCView[sl][prevV][s2] = 0
                   /\ \A s2 \in senders : timeoutHighPropView[sl][prevV][s2] = 0
                   /\ val \in Values)
               \* Case 2 (DA-5 BUGGY): Any sender with QC evidence can be chosen,
               \* not just the one with the highest QC view.
               \/ (/\ \E s2 \in senders : timeoutHighQCView[sl][prevV][s2] > 0
                   /\ \E s2 \in senders :
                       /\ timeoutHighQCView[sl][prevV][s2] > 0
                       /\ val = timeoutHighQCValue[sl][prevV][s2])
               \* Case 3: f+1 matching Prepares override
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

\* ============================================================================
\* MC WRAPPERS (counter-bounded)
\* ============================================================================

MCByzantineTimeout(s, sl, v) ==
    /\ faultCounters.byzantine < MaxByzantineLimit
    /\ ByzantineTimeout(s, sl, v)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantine = @ + 1]

MCByzantineVotePrepare(s, sl, v, val) ==
    /\ faultCounters.byzantine < MaxByzantineLimit
    /\ ByzantineVotePrepare(s, sl, v, val)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantine = @ + 1]

MCByzantineVoteConfirm(s, sl, v, val) ==
    /\ faultCounters.byzantine < MaxByzantineLimit
    /\ ByzantineVoteConfirm(s, sl, v, val)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantine = @ + 1]

MCBuggyGeneratePrepareFromTC(s, sl, v) ==
    /\ BuggyGeneratePrepareFromTC(s, sl, v)
    /\ UNCHANGED faultVars

\* ============================================================================
\* SPEC 1: DA-2+DA-3 hunting (correct GeneratePrepareFromTC)
\* ============================================================================

MCHuntDA23AsyncNext(s) ==
    \/ \E sl \in Slot, v \in View, val \in Values :
        \/ MCSendPrepare(s, sl, v, val)
        \/ MCFixedSendConfirm(s, sl, v, val)
        \/ MCFixedSendCommit(s, sl, v, val)
        \/ MCFixedSendFastCommit(s, sl, v, val)
    \/ \E sl \in Slot, v \in View :
        \/ MCReceivePrepare(s, sl, v)
        \/ MCReceiveConfirm(s, sl, v)
        \/ MCReceiveCommit(s, sl, v)
        \/ MCAdvanceView(s, sl, v)
        \/ MCGeneratePrepareFromTC(s, sl, v)
    \/ \E sl \in Slot :
        \/ MCEnterSlot(s, sl)
        \/ MCSendTimeout(s, sl)

MCHuntDA23ByzantineNext ==
    \/ \E s \in Byzantine, sl \in Slot, v \in View, val \in Values :
        \/ MCByzantinePrepare(s, sl, v, val)
        \/ MCFixedByzantineConfirm(s, sl, v, val)
        \/ MCFixedByzantineCommit(s, sl, v, val)
        \/ MCByzantineVotePrepare(s, sl, v, val)
        \/ MCByzantineVoteConfirm(s, sl, v, val)
    \/ \E s \in Byzantine, sl \in Slot, v \in View :
        MCByzantineTimeout(s, sl, v)

MCHuntDA23Next ==
    \/ \E s \in Server : MCHuntDA23AsyncNext(s)
    \/ MCHuntDA23ByzantineNext
    \/ MCNextLose

MCHuntDA23Spec == MCInit /\ [][MCHuntDA23Next]_mc_vars

\* ============================================================================
\* SPEC 2: DA-5 hunting (buggy GeneratePrepareFromTC + DA-2+DA-3)
\* ============================================================================

MCHuntDA5AsyncNext(s) ==
    \/ \E sl \in Slot, v \in View, val \in Values :
        \/ MCSendPrepare(s, sl, v, val)
        \/ MCFixedSendConfirm(s, sl, v, val)
        \/ MCFixedSendCommit(s, sl, v, val)
        \/ MCFixedSendFastCommit(s, sl, v, val)
    \/ \E sl \in Slot, v \in View :
        \/ MCReceivePrepare(s, sl, v)
        \/ MCReceiveConfirm(s, sl, v)
        \/ MCReceiveCommit(s, sl, v)
        \/ MCAdvanceView(s, sl, v)
        \/ MCBuggyGeneratePrepareFromTC(s, sl, v)
    \/ \E sl \in Slot :
        \/ MCEnterSlot(s, sl)
        \/ MCSendTimeout(s, sl)

MCHuntDA5Next ==
    \/ \E s \in Server : MCHuntDA5AsyncNext(s)
    \/ MCHuntDA23ByzantineNext
    \/ MCNextLose

MCHuntDA5Spec == MCInit /\ [][MCHuntDA5Next]_mc_vars

====
