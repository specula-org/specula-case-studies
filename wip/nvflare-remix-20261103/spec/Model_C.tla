------------------------------ MODULE Model_C ------------------------------
\* Group Model, COARSE variant (v11, profile sjModel; DESIGN 16.5). Process: SJ.
\* Answers the workflow's accept / aggregate / save calls with outcome classes
\* only (no numeric content). No private state.
\* Anchors: dxo_aggregator.py:134-208; weighted_aggregation_helper.py:192-285;
\*          fedavg.py:300-400; base_model_controller.py:452-462;
\*          pt/file_model_persistor.py:308-360; np/np_model_persistor.py:103-114.
EXTENDS Ports
VARIABLE model_c

Init == model_c = 0
InitValue == 0

MC == pWfSJ.mcall
\* a call is outstanding: not answered yet (ret carries the call number)
\* IF, not \/: TLC explores both disjuncts of an action (ret may be None)
Pending == /\ SJModel /\ SJAlive /\ MC /= None
           /\ IF pModel.ret = None THEN TRUE ELSE pModel.ret.n /= MC.n
Ret(o) == [n |-> MC.n, out |-> o]

\* accept: eligibility checks (round, duplicate, shape, kind) reject without
\* touching the accumulator; helper.add mutates key by key, so an exception
\* mid-loop leaves part of the contribution in the totals (no rollback) and no
\* history entry (the same contributor may be added again).
DoAccept ==
    /\ Pending /\ MC.op = "accept"
    /\ LET r == MC.round
           c == MC.site
       IN \/ /\ pModel.acc[r][c] /= "accepted"
             /\ pModel' = [pModel EXCEPT !.ret = Ret("accepted"), !.acc[r][c] = "accepted"]
          \/ /\ pModel' = [pModel EXCEPT !.ret = Ret("rejected"),
                                         !.acc[r][c] = IF @ = "none" THEN "rejected" ELSE @]
          \/ /\ "acceptRaise" \in Faults /\ pModel.acc[r][c] /= "accepted"
             /\ pModel' = [pModel EXCEPT !.ret = Ret("partial"), !.acc[r][c] = "partial",
                                         !.poisoned = @ \cup {r}]
    /\ UNCHANGED <<model_c, net>>

AggOf(r) == IF r \in pModel.poisoned THEN "poisoned"
            ELSE IF \E c \in Sites : pModel.acc[r][c] = "accepted" THEN "clean" ELSE "empty"
\* aggregate: the result of whatever the totals hold; division over mismatched
\* per-key counts may itself raise after a partial accept.
DoAggregate ==
    /\ Pending /\ MC.op = "aggregate"
    /\ \/ /\ pModel' = [pModel EXCEPT !.ret = Ret(AggOf(MC.round)), !.agg[MC.round] = AggOf(MC.round)]
       \/ /\ "acceptRaise" \in Faults /\ MC.round \in pModel.poisoned
          /\ pModel' = [pModel EXCEPT !.ret = Ret("raise")]
    /\ UNCHANGED <<model_c, net>>

KindOf(r) == CASE pModel.agg[r] = "poisoned" -> "poisoned"
               [] pModel.agg[r] = "empty" -> "stale"
               [] OTHER -> "clean"
\* save: staged (PT: failure before or after the replace) or direct (NP: a
\* failure midway leaves a corrupt file); the workflow sees the exception.
DoSave ==
    /\ Pending /\ MC.op = "save"
    /\ LET r == MC.round IN
       \/ pModel' = [pModel EXCEPT !.ret = Ret("ok"), !.artifact = [round |-> r, kind |-> KindOf(r)]]
       \/ /\ "saveFail" \in Faults
          /\ \E a \in {pModel.artifact, [round |-> r, kind |-> KindOf(r)], [round |-> r, kind |-> "corrupt"]} :
               pModel' = [pModel EXCEPT !.ret = Ret("fail"), !.artifact = a]
    /\ UNCHANGED <<model_c, net>>

Next == DoAccept \/ DoAggregate \/ DoSave
=============================================================================
