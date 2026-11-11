------------------------------ MODULE Swarm_C ------------------------------
\* Group Swarm, COARSE variant (v11, profile swarm; DESIGN 16.8). Process: CJ,
\* per site. The client controller of Swarm learning: config / start replies to
\* the server's tasks, scatter of learn tasks, local learning (the learn
\* executor's outcome only), submission to the round's aggregator, the
\* aggregator's gatherer, status reports, end of workflow. Anchors in PortsSwarm.
\* Private: swarm_c[c][l] = message keys handled.
EXTENDS Ports
VARIABLE swarm_c

Init == swarm_c = [c \in Sites |-> [l \in Launches |-> {}]]
InitValue == [c \in Sites |-> [l \in Launches |-> {}]]

S(c, l) == pSwarm[c][l]
Upd(c, l, r) == [pSwarm EXCEPT ![c][l] = r]
Up(c, l) == SwarmOn /\ CJAlive(c, l) /\ ~S(c, l).stopped
In(c, l) == pTaskCJ[c][l].input
InRound(c, l) == IF In(c, l) = None THEN 0 ELSE In(c, l).assignment.attempt
Handled(c, l, k) == k \in swarm_c[c][l]
Mark(c, l, k) == swarm_c' = [swarm_c EXCEPT ![c][l] = @ \cup {k}]
Err(r) == [r EXCEPT !.report.error = TRUE]
\* message ids carry the sender's CJ launch: a relaunched CJ sends new messages (v11 fix
\* after the 90-minute run: the same id with a different body broke net immutability)
LearnMsg(a, l, d, r, g) == Msg("SWARM_LEARN", CJ(a), CJ(d), <<JobId, a, l, d, r>>, [round |-> r, aggr |-> g])
\* sending a learn task fails on a lost / timed-out aux request or a dead peer
SendFailPossible(d) == "swarmMsgFail" \in Faults \/ PeerFailureCJ(d, CurLaunch(d))

\* config task (process_config): reply OK
\* @L Swarm.ctl.config
Configure(c, l) ==
    /\ Up(c, l) /\ InRound(c, l) = 1 /\ S(c, l).reply = None
    /\ pSwarm' = Upd(c, l, [S(c, l) EXCEPT !.cfg = TRUE, !.reply = [round |-> 1, rc |-> "OK"]])
    /\ UNCHANGED <<swarm_c, net>>

\* _scatter for round r with aggregator g: queue the learn task locally (every
\* site is a trainer and an aggregator candidate) and broadcast it to the others
Scatter(c, l, r, g, rec) ==
    /\ net' = SendAll(net, {LearnMsg(c, l, d, r, g) : d \in Sites \ {c}})
    /\ pSwarm' = Upd(c, l, [rec EXCEPT !.learn = [r |-> r, st |-> "busy", aggr |-> g],
                                       !.gather = IF g = c THEN [r |-> r, replied |-> {}, gathered |-> {}, done |-> FALSE, raced |-> {}]
                                                  ELSE @,
                                       !.report.round = IF r > @ THEN r ELSE @])

\* start task (starting client only): start_workflow scatters round 1
\* @L Swarm.ctl.start
StartWf(c, l) ==
    /\ Up(c, l) /\ c = Starter /\ S(c, l).cfg /\ InRound(c, l) = 2
    /\ S(c, l).reply /= None /\ S(c, l).reply.round = 1 /\ S(c, l).learn.st = "none"
    /\ \E g \in Sites :
         Scatter(c, l, 1, g, [S(c, l) EXCEPT !.reply = [round |-> 2, rc |-> "OK"]])
    /\ UNCHANGED swarm_c
\* send_learn_task fails: error report, start replies EXECUTION_EXCEPTION
\* @L Swarm.ctl.start
StartFail(c, l) ==
    /\ Up(c, l) /\ c = Starter /\ S(c, l).cfg /\ InRound(c, l) = 2
    /\ S(c, l).reply /= None /\ S(c, l).reply.round = 1
    /\ \E d \in Sites \ {c} : SendFailPossible(d)
    /\ pSwarm' = Upd(c, l, Err([S(c, l) EXCEPT !.reply = [round |-> 2, rc |-> "EXECUTION_EXCEPTION"]]))
    /\ UNCHANGED <<swarm_c, net>>

\* a learn task arrives (_process_learn_request -> set_learn_task)
\* @L Swarm.ctl.learnTask
RecvLearn(c, l, k) ==
    /\ Up(c, l) /\ InInbox(k, CJ(c), "SWARM_LEARN") /\ ~Handled(c, l, k)
    /\ LET r == M(k).body.round
           g == M(k).body.aggr
           s == S(c, l)
       IN /\ Mark(c, l, k)
          /\ UNCHANGED net
          /\ IF s.learn.st /= "busy"
             THEN pSwarm' = Upd(c, l, [s EXCEPT !.learn = [r |-> r, st |-> "busy", aggr |-> g],
                                   !.gather = IF g = c THEN [r |-> r, replied |-> {}, gathered |-> {}, done |-> FALSE, raced |-> {}]
                                              ELSE @,
                                   !.report.round = IF r > @ THEN r ELSE @])
             \* busy: rejected (the scatterer reports an error), or with
             \* allow_busy_task the current task is aborted and the client's own
             \* controller handles ABORT_TASK as a stop
             ELSE \/ pSwarm' = Upd(c, l, Err(s))
                  \/ /\ "busyReplace" \in Faults
                     /\ pSwarm' = Upd(c, l, [s EXCEPT !.learn.st = "aborted", !.stopped = TRUE, !.stopBy = "event"])

\* the learn executor runs the round's training
\* @L Swarm.ctl.learn
Learn(c, l) ==
    /\ Up(c, l) /\ S(c, l).learn.st = "busy"
    /\ \/ pSwarm' = Upd(c, l, [S(c, l) EXCEPT !.learn.st = "trained"])
       \/ /\ "learnFail" \in Faults
          /\ pSwarm' = Upd(c, l, Err([S(c, l) EXCEPT !.learn.st = "failed"]))
    /\ UNCHANGED <<swarm_c, net>>

\* submit the result to the round's aggregator (local call when it is this site)
\* @L Swarm.ctl.submit
Submit(c, l) ==
    /\ Up(c, l) /\ S(c, l).learn.st = "trained"
    /\ LET L == S(c, l).learn IN
       IF L.aggr = c
       THEN /\ S(c, l).gather /= None /\ S(c, l).gather.r = L.r /\ ~S(c, l).gather.done
            /\ pSwarm' = Upd(c, l, [S(c, l) EXCEPT !.learn.st = "done", !.gather.replied = @ \cup {c}])
            /\ UNCHANGED net
       ELSE \/ /\ net' = Send(net, Msg("SWARM_SUBMIT", CJ(c), CJ(L.aggr), <<JobId, c, l, L.aggr, L.r>>,
                                       [round |-> L.r, rc |-> "OK"]))
               /\ pSwarm' = Upd(c, l, [S(c, l) EXCEPT !.learn.st = "done"])
            \/ /\ SendFailPossible(L.aggr)
               /\ pSwarm' = Upd(c, l, Err([S(c, l) EXCEPT !.learn.st = "failed"]))
               /\ UNCHANGED net
    /\ UNCHANGED swarm_c

\* aggregator: a submission is recorded as replied (reply_time) ...
\* @L Swarm.gather.reply
GatherReply(c, l, k) ==
    /\ Up(c, l) /\ InInbox(k, CJ(c), "SWARM_SUBMIT") /\ ~Handled(c, l, k)
    /\ Mark(c, l, k)
    /\ LET G == S(c, l).gather
           d == CHOOSE x \in Sites : CJ(x) = M(k).from
       IN IF G /= None /\ G.r = M(k).body.round /\ ~G.done
          THEN pSwarm' = Upd(c, l, [S(c, l) EXCEPT !.gather.replied = @ \cup {d}])
          \* no gatherer for that round: the submitter gets an error
          ELSE UNCHANGED pSwarm
    /\ UNCHANGED net
\* ... and enters aggregator.accept in a separate step
\* @L Swarm.gather.reply
GatherAccept(c, l) ==
    /\ Up(c, l) /\ S(c, l).gather /= None
    /\ \E d \in S(c, l).gather.replied \ S(c, l).gather.gathered :
         pSwarm' = Upd(c, l, [S(c, l) EXCEPT !.gather.gathered = @ \cup {d}])
    /\ UNCHANGED <<swarm_c, net>>

\* is_done: every trainer replied (an accept may still be running), or the
\* gather timed out; _end_gather aggregates what entered accept, then the next
\* round is scattered (new aggregator) or the final result is distributed.
\* @L Swarm.gather.done, Timing.gatherRace
GatherDone(c, l) ==
    /\ Up(c, l) /\ S(c, l).gather /= None /\ ~S(c, l).gather.done
    /\ \/ /\ S(c, l).gather.replied = Sites
          /\ TimingOK(Faults, "gatherRace", S(c, l).gather.gathered = S(c, l).gather.replied)
       \/ "gatherTimeout" \in Faults
    /\ LET G == S(c, l).gather
           \* cause record: contributions replied but still inside accept when the gather closed
           s1 == [S(c, l) EXCEPT !.gather.done = TRUE, !.aggregated[G.r] = G.gathered,
                                 !.gather.raced = G.replied \ G.gathered]
       IN IF G.r = SwarmRounds
          THEN /\ pSwarm' = Upd(c, l, [s1 EXCEPT !.report.allDone = TRUE])
               /\ UNCHANGED net
          ELSE \/ /\ s1.learn.st \in {"done", "none"}
                  /\ \E g \in Sites : Scatter(c, l, G.r + 1, g, s1)
               \/ /\ \E d \in Sites \ {c} : SendFailPossible(d)
                  /\ pSwarm' = Upd(c, l, Err(s1))
                  /\ UNCHANGED net
    /\ UNCHANGED swarm_c

\* status report on the next task pull (one message per change)
\* @L Swarm.ctl.status
SendStatus(c, l) ==
    /\ SwarmOn /\ CJAlive(c, l) /\ ~S(c, l).ended /\ S(c, l).report /= S(c, l).sentRep
    /\ net' = Send(net, Msg("SWARM_STATUS", CJ(c), SJ, <<JobId, c, l, S(c, l).sent + 1>>, S(c, l).report))
    /\ pSwarm' = Upd(c, l, [S(c, l) EXCEPT !.sent = @ + 1, !.sentRep = S(c, l).report])
    /\ UNCHANGED swarm_c

\* END_RUN at the CJ: asked_to_stop, the current learn task is aborted
\* @L Swarm.ctl.end
StopOnEndRun(c, l) ==
    /\ Up(c, l) /\ \E k \in DOMAIN net : InInbox(k, CJ(c), "END_RUN")
    /\ pSwarm' = Upd(c, l, [S(c, l) EXCEPT !.stopped = TRUE, !.stopBy = IF @ = "none" THEN "endRun" ELSE @,
                                           !.learn.st = IF @ = "busy" THEN "aborted" ELSE @])
    /\ UNCHANGED <<swarm_c, net>>

\* the server's end-workflow request: workflow_done, reply OK
\* @L Swarm.ctl.end
RecvEndWf(c, l, k) ==
    /\ SwarmOn /\ CJAlive(c, l) /\ InInbox(k, CJ(c), "SWARM_END_WF") /\ ~Handled(c, l, k)
    /\ Mark(c, l, k)
    /\ pSwarm' = Upd(c, l, [S(c, l) EXCEPT !.ended = TRUE, !.stopped = TRUE,
                                           !.stopBy = IF @ = "none" THEN "endWf" ELSE @])
    /\ net' = Send(net, Msg("SWARM_END_REPLY", CJ(c), SJ, <<JobId, c, l>>, "OK"))

Next ==
    \/ \E c \in Sites, l \in Launches :
         \/ Configure(c, l) \/ StartWf(c, l) \/ StartFail(c, l) \/ Learn(c, l) \/ Submit(c, l)
         \/ GatherAccept(c, l) \/ GatherDone(c, l) \/ SendStatus(c, l) \/ StopOnEndRun(c, l)
    \/ \E c \in Sites, l \in Launches, k \in DOMAIN net :
         RecvLearn(c, l, k) \/ GatherReply(c, l, k) \/ RecvEndWf(c, l, k)
=============================================================================
