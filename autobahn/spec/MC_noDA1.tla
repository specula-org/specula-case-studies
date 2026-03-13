--------------------------- MODULE MC_noDA1 ---------------------------
(*
 * Model checking specification with DA-1 FIXED.
 *
 * DA-1 fix: QC binds to the specific proposal value.
 * - PrepareQC for value val requires 2f+1 servers that voted for val
 * - ConfirmQC for value val requires 2f+1 servers that voted for val
 * - Byzantine nodes can only forge Commit/Confirm for values that
 *   actually have per-value quorum
 *
 * Goal: Check whether DA-5 (view change winning_view bug) or other
 * bugs independently break safety WITHOUT DA-1.
 *)

EXTENDS MC

\* Access the base spec operators
noDA1 == INSTANCE base

\* ============================================================================
\* FIXED ACTIONS (DA-1 fixed: QC binds to value)
\* ============================================================================

\* SendConfirm: requires per-value PrepareQC (not just any 2f+1 votes)
FixedSendConfirm(s, sl, v, val) ==
    /\ s \in Honest
    /\ noDA1!IsQuorumFor(sl, v, val)              \* 2f+1 voted for THIS value
    /\ ~noDA1!IsFastQuorumFor(sl, v, val)         \* Not fast quorum for this val
    /\ val = highPropValue[s][sl]
    /\ val /= Nil
    /\ messages' = messages \cup
        {[mtype |-> ConfirmMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* SendFastCommit: requires per-value fast PrepareQC
FixedSendFastCommit(s, sl, v, val) ==
    /\ s \in Honest
    /\ noDA1!IsFastQuorumFor(sl, v, val)          \* 3f+1 voted for THIS value
    /\ val = highPropValue[s][sl]
    /\ val /= Nil
    /\ messages' = messages \cup
        {[mtype |-> CommitMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* SendCommit: requires per-value ConfirmQC
FixedSendCommit(s, sl, v, val) ==
    /\ s \in Honest
    /\ noDA1!IsConfirmQuorumFor(sl, v, val)       \* 2f+1 confirmed THIS value
    /\ val = highQCValue[s][sl]
    /\ val /= Nil
    /\ messages' = messages \cup
        {[mtype |-> CommitMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* ByzantineConfirm: Byzantine can only forge for values with actual PrepareQC
FixedByzantineConfirm(s, sl, v, val) ==
    /\ s \in Byzantine
    /\ noDA1!IsQuorumFor(sl, v, val)              \* Must have real per-value QC
    /\ val \in proposed[sl][v]
    /\ messages' = messages \cup
        {[mtype |-> ConfirmMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* ByzantineCommit: Byzantine can only forge for values with actual QC
FixedByzantineCommit(s, sl, v, val) ==
    /\ s \in Byzantine
    /\ \/ noDA1!IsConfirmQuorumFor(sl, v, val)
       \/ noDA1!IsFastQuorumFor(sl, v, val)
    /\ val \in proposed[sl][v]
    /\ messages' = messages \cup
        {[mtype |-> CommitMsg, mslot |-> sl, mview |-> v, mvalue |-> val]}
    /\ UNCHANGED <<serverVars, evidenceVars, decisionVars,
                   voteVars, timeoutVars, proposalVars>>

\* ============================================================================
\* MC WRAPPERS (counter-bounded versions of fixed actions)
\* ============================================================================

MCFixedSendConfirm(s, sl, v, val) ==
    /\ FixedSendConfirm(s, sl, v, val)
    /\ UNCHANGED faultVars

MCFixedSendFastCommit(s, sl, v, val) ==
    /\ FixedSendFastCommit(s, sl, v, val)
    /\ UNCHANGED faultVars

MCFixedSendCommit(s, sl, v, val) ==
    /\ FixedSendCommit(s, sl, v, val)
    /\ UNCHANGED faultVars

MCFixedByzantineConfirm(s, sl, v, val) ==
    /\ faultCounters.byzantine < MaxByzantineLimit
    /\ FixedByzantineConfirm(s, sl, v, val)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantine = @ + 1]

MCFixedByzantineCommit(s, sl, v, val) ==
    /\ faultCounters.byzantine < MaxByzantineLimit
    /\ FixedByzantineCommit(s, sl, v, val)
    /\ faultCounters' = [faultCounters EXCEPT !.byzantine = @ + 1]

\* ============================================================================
\* NEXT STATE (replaces MC's MCNext with fixed actions)
\* ============================================================================

MCFixedNextAsync(s) ==
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

MCFixedNextByzantine ==
    \E s \in Byzantine, sl \in Slot, v \in View, val \in Values :
        \/ MCByzantinePrepare(s, sl, v, val)
        \/ MCFixedByzantineConfirm(s, sl, v, val)
        \/ MCFixedByzantineCommit(s, sl, v, val)

MCFixedNext ==
    \/ \E s \in Server : MCFixedNextAsync(s)
    \/ MCFixedNextByzantine
    \/ MCNextLose

\* ============================================================================
\* SPECIFICATION
\* ============================================================================

MCFixedSpec == MCInit /\ [][MCFixedNext]_mc_vars

====
