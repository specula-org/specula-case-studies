----------------------------- MODULE Env_Pay -----------------------------
\* Environment ASSUMPTION of the payload groups PaySrc and PayRcv (assume-
\* guarantee, DESIGN.md §2.1). The generator form is the chaotic environment
\* PayEnv written by scripts/pay_ref.py (its harness also checks EnvSound:
\* every generated step satisfies EnvAllowed). This module is the checker
\* form, discharged as AG_Pay (spec/AG.tla) in mixes.
\* Reads (PaySrc_F/C, PayRcv_F/C):
\*   PaySrc: CJAlive(c, l), pRunCJ[c][l].dsDown, pTaskCJ[c][l].submission
\*   PayRcv: SJAlive, pWfSJ.dsShutdown, pCommSJ.envelopes[c], PeerFailureCJ
\*           (a function of CJAlive and the transportFail fault)
\* Guarantees assumed from the neighbors:
\*   - a CJ launch appears only after the previous one is gone (CP);
\*   - dsDown / dsShutdown are declared by a live process, once;
\*   - a submission changes only while its CJ is alive (TaskCJ);
\*   - an envelope is exposed by a live SJ and references only transactions
\*     that are already registered (CommSJ, after TaskCJ sent RESULT_ENVELOPE).
EXTENDS Ports

Sub(c, l) == pTaskCJ[c][l].submission
Env(c) == pCommSJ.envelopes[c]
RegRefs(c) == {pPaySrc[c][l].tx[a].registered.ref :
                 <<l, a>> \in {<<l2, a2>> \in Launches \X Attempts : pPaySrc[c][l2].tx[a2].registered /= None}}

Reads == [cj |-> [c \in Sites |-> [l \in Launches |->
            [alive |-> CJAlive(c, l), dsDown |-> pRunCJ[c][l].dsDown, sub |-> Sub(c, l)]]],
          env |-> [c \in Sites |-> Env(c)],
          sjAlive |-> SJAlive, dsShut |-> pWfSJ.dsShutdown]

CJOK(c, l) ==
    LET r == Reads.cj[c][l]  r2 == Reads'.cj[c][l] IN
    /\ r2.alive = r.alive \/ (r.alive /\ ~r2.alive)
       \/ (~r.alive /\ r2.alive /\ CurLaunch(c) < l /\ CurLaunch(c)' = l
           /\ (CurLaunch(c) = 0 \/ ~CJAlive(c, CurLaunch(c))))
    /\ r2.dsDown = r.dsDown \/ (~r.dsDown /\ r2.dsDown /\ r.alive)
    /\ r2.sub = r.sub \/ r.alive
EnvOK(c) ==
    Reads'.env[c] = Reads.env[c]
    \/ /\ Reads.sjAlive
       /\ Reads'.env[c] = None \/ \A x \in Reads'.env[c].refs : x.ref \in RegRefs(c)
EnvAllowed ==
    /\ \A c \in Sites, l \in Launches : CJOK(c, l)
    /\ \A c \in Sites : EnvOK(c)
    /\ Reads'.sjAlive = Reads.sjAlive \/ (Reads.sjAlive /\ ~Reads'.sjAlive)
       \/ (~Reads.sjAlive /\ Reads'.sjAlive /\ ~pJobSP.sjLaunched)
    /\ Reads'.dsShut = Reads.dsShut \/ (~Reads.dsShut /\ Reads'.dsShut /\ Reads.sjAlive)
=============================================================================
