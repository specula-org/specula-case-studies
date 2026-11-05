---------------------------- MODULE Env_RunCJ ----------------------------
\* Environment ASSUMPTION of the RunCJ group (assume-guarantee, DESIGN.md §2.1).
\* Two forms that must describe the same transitions on RunCJ's reads:
\*   EnvNext    generator form: concrete port updates, explored by the harness
\*   EnvAllowed checker form: a predicate on (Reads, Reads'), discharged as
\*              AG_RunCJ (spec/AG.tla) in mixes
\* RunCJ reads (RunCJ_F / RunCJ_C, both variants):
\*   CJAlive(c, l)      pJobCP[c].launch, own exit, CJFatal (no variant writes a
\*                      CJ-side fatal flag today: the assumption forbids it, so a
\*                      future one shows up as a discharge violation)
\*   pJobCP[c].killed   DieOfKill (process_launcher.py:60-93)
\*   END_RUN inbox      ReceiveEndRun (client_runner.py:1084-1089), sent by WfSJ,
\*                      possibly lost (Net_L, "netLoss")
\*   T1 timing          pWfSJ.dsShutdown, SJGone (PortsJob!CJTeardownTimingOK)
\*   PaySrcShutDone     pPaySrc[c][l].tx[a].registered / .shut (call-return of
\*                      DownloadService.shutdown, client_runner.py:817)
\* Guarantee assumed from PaySrc: a transaction is registered only while its
\* CJ is alive, and torn down (shut) only after RunCJ declared dsDown.
EXTENDS Ports

EndRuns(c) == {k \in DOMAIN net : InInbox(k, CJ(c), "END_RUN")}
Regs(c, l) == {a \in Attempts : pPaySrc[c][l].tx[a].registered /= None}
Shuts(c, l) == {a \in Attempts : pPaySrc[c][l].tx[a].shut}

Reads == [site |-> [c \in Sites |->
            [launch |-> CurLaunch(c), killed |-> pJobCP[c].killed, endRun |-> EndRuns(c),
             fatal |-> [l \in Launches |-> CJFatal(c, l)],
             regs |-> [l \in Launches |-> Regs(c, l)],
             shuts |-> [l \in Launches |-> Shuts(c, l)]]],
          dsShut |-> pWfSJ.dsShutdown, sjGone |-> SJGone]

\* ---------- generator form (harness)
EnvLaunch(c) ==
    /\ CurLaunch(c) < MaxLaunch /\ (CurLaunch(c) = 0 \/ ~CJAlive(c, CurLaunch(c)))
    /\ pJobCP' = [pJobCP EXCEPT ![c].launch = @ + 1]
    /\ UNCHANGED <<pJobSP, pWfSJ, pPaySrc, net>>
EnvKill(c, l) ==
    /\ l <= CurLaunch(c) /\ l \notin pJobCP[c].killed
    /\ pJobCP' = [pJobCP EXCEPT ![c].killed = @ \cup {l}]
    /\ UNCHANGED <<pJobSP, pWfSJ, pPaySrc, net>>
EnvEndRun(c) ==
    /\ SJAlive
    /\ net' = Send(net, Msg("END_RUN", SJ, CJ(c), <<JobId, c>>, None))
    /\ UNCHANGED <<pJobCP, pJobSP, pWfSJ, pPaySrc>>
EnvLoseEndRun(c, k) ==
    /\ "netLoss" \in Faults /\ k \in EndRuns(c)
    /\ net' = [net EXCEPT ![k].lost = TRUE]
    /\ UNCHANGED <<pJobCP, pJobSP, pWfSJ, pPaySrc>>
EnvSJLaunch ==
    /\ ~pJobSP.sjLaunched
    /\ pJobSP' = [pJobSP EXCEPT !.sjLaunched = TRUE]
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "running"]
    /\ UNCHANGED <<pJobCP, pPaySrc, net>>
EnvSJDSShutdown ==
    /\ SJAlive /\ ~pWfSJ.dsShutdown
    /\ pWfSJ' = [pWfSJ EXCEPT !.dsShutdown = TRUE]
    /\ UNCHANGED <<pJobCP, pJobSP, pPaySrc, net>>
EnvSJExit ==
    /\ SJAlive
    /\ pWfSJ' = [pWfSJ EXCEPT !.sj = "exited"]
    /\ UNCHANGED <<pJobCP, pJobSP, pPaySrc, net>>
EnvRegister(c, l, a) ==
    /\ CJAlive(c, l) /\ pPaySrc[c][l].tx[a].registered = None
    /\ pPaySrc' = SrcTxSet(pPaySrc, c, l, a, [pPaySrc[c][l].tx[a] EXCEPT !.registered =
          [ref |-> <<"ref", c, l, a>>, source |-> CJ(c), launch |-> l, value |-> 0]])
    /\ UNCHANGED <<pJobCP, pJobSP, pWfSJ, net>>
EnvShut(c, l, a) ==
    /\ CJAlive(c, l) /\ Flag(pRunCJ[c][l], "dsDown")
    /\ pPaySrc[c][l].tx[a].registered /= None /\ ~pPaySrc[c][l].tx[a].shut
    /\ pPaySrc' = SrcTxSet(pPaySrc, c, l, a, [pPaySrc[c][l].tx[a] EXCEPT !.shut = TRUE])
    /\ UNCHANGED <<pJobCP, pJobSP, pWfSJ, net>>
EnvNext == \/ EnvSJLaunch \/ EnvSJDSShutdown \/ EnvSJExit
           \/ \E c \in Sites : EnvLaunch(c) \/ EnvEndRun(c) \/ \E k \in EndRuns(c) : EnvLoseEndRun(c, k)
           \/ \E c \in Sites, l \in Launches : EnvKill(c, l)
           \/ \E c \in Sites, l \in Launches, a \in Attempts : EnvRegister(c, l, a) \/ EnvShut(c, l, a)
EnvVars == <<pJobCP, pJobSP, pWfSJ, pPaySrc, net>>

\* ---------- checker form (discharge): every observed change of a read is one
\* of the generator's moves (simultaneous independent changes are a
\* sequentialization the harness also explores).
SiteOK(c) ==
    LET r == Reads.site[c]  r2 == Reads'.site[c] IN
    /\ r2.launch = r.launch
       \/ (r2.launch = r.launch + 1 /\ r.launch < MaxLaunch /\ (r.launch = 0 \/ ~CJAlive(c, r.launch)))
    /\ r.killed \subseteq r2.killed /\ \A l \in r2.killed \ r.killed : l <= r.launch \/ l <= r2.launch
    /\ \A k \in r2.endRun \ r.endRun : net'[k].msg.from = SJ /\ SJAlive
    /\ \A k \in r.endRun \ r2.endRun : "netLoss" \in Faults
    /\ r2.fatal = r.fatal
    /\ \A l \in Launches :
         /\ r.regs[l] \subseteq r2.regs[l] /\ (r2.regs[l] /= r.regs[l] => CJAlive(c, l))
         /\ r.shuts[l] \subseteq r2.shuts[l]
         /\ \A a \in r2.shuts[l] \ r.shuts[l] :
              a \in r.regs[l] /\ CJAlive(c, l) /\ Flag(pRunCJ[c][l], "dsDown")
EnvAllowed ==
    /\ \A c \in Sites : SiteOK(c)
    /\ Reads'.dsShut = Reads.dsShut \/ (~Reads.dsShut /\ Reads'.dsShut /\ SJAlive)
    /\ Reads'.sjGone = Reads.sjGone \/ (~Reads.sjGone /\ Reads'.sjGone)
=============================================================================
