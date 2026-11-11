------------------------------ MODULE PortsSwarm ------------------------------
\* Port shape, message kinds and faults of the SWARM group (v11, profile swarm;
\* DESIGN 16.8): the client side of client-controlled Swarm learning (CCWF),
\* pin c411a201:
\* ccwf/client_ctl.py:179-206 (ABORT_TASK / END_RUN -> asked_to_stop),
\* :417-487 (set_learn_task, busy replacement, _do_learn), :497-517
\* (update_status), :601-633 (send_learn_task: any failure is an error report);
\* ccwf/swarm_client_ctl.py:116-290 (Gatherer: reply_time before accept, done on
\* all-replied / timeout / min responses), :555-662 (start_workflow,
\* _scatter, _monitor_gather), :662-720 (_end_gather -> next round or final),
\* :1030-1192 (do_learn_task: gatherer, learn, submit to the aggregator).
\* Messages (CJ<->CJ aux; status reports ride on the client's task pulls):
\* SWARM_LEARN CJ(a)->CJ(d) id <<JobId, a, l, d, r>> body [round, aggr]
\* SWARM_SUBMIT CJ(d)->CJ(g) id <<JobId, d, l, g, r>> body [round, rc]
\* SWARM_STATUS CJ(c)->SJ id <<JobId, c, l, n>> body [round, allDone, error]
\* SWARM_END_REPLY CJ(c)->SJ id <<JobId, c, l>> body "OK"
\* (l = the sender's CJ launch)
\* (SWARM_END_WF SJ->CJ(c) id <<JobId, c>>, owned by WfSJ)
\* pSwarm[c][l]:
\* cfg : configured by the server's config task
\* reply : None or [round, rc]: the client controller executor's reply to the
\* server task of that round (1 = config, 2 = start)
\* stopped : asked_to_stop
\* learn : [r, st, aggr]; st none | busy | trained | done | failed | aborted
\* gather : None or [r, replied, gathered, done] (aggregator of round r)
\* aggregated: [round |-> sites] whose contributions entered the aggregate
\* report : [round, allDone, error]; sent / sentRep: status messages sent and
\* the last report sent
\* ended : the server's END_WF arrived (workflow_done)
EXTENDS Consts
\* gatherRace: the gather closes on "all replied" while a replied contribution is still in accept
SwarmFaults == {"swarmMsgFail", "learnFail", "busyReplace", "gatherTimeout", "gatherRace"}
SwarmKinds == {"SWARM_LEARN", "SWARM_SUBMIT", "SWARM_STATUS", "SWARM_END_REPLY"}
SwarmOn == WfPolicy = "swarm"
SwarmRounds == MaxAttempt
\* the configured starting client
Starter == CHOOSE c \in Sites : TRUE
NoReport == [round |-> 0, allDone |-> FALSE, error |-> FALSE]
\* stopBy: the cause recorded with a stop (STANDARD 7, S7StopHasSource): endRun | endWf (requests from the
\* SJ) | event (an event the controller itself fired and its own handler took as a stop)
SwarmRec == [cfg |-> FALSE, reply |-> None, stopped |-> FALSE, stopBy |-> "none",
             learn |-> [r |-> 0, st |-> "none", aggr |-> None], gather |-> None,
             aggregated |-> [r \in 1..SwarmRounds |-> None],
             report |-> NoReport, sent |-> 0, sentRep |-> NoReport, ended |-> FALSE]
SwarmPortInit == IF ~SwarmOn THEN 0 ELSE [c \in Sites |-> [l \in Launches |-> SwarmRec]]
=============================================================================
