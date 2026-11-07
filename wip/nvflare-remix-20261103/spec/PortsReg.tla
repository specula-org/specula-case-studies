------------------------------ MODULE PortsReg ------------------------------
\* Port shape of the REG group (v8): the SP's client registry (ClientManager)
\* and its cleanup thread (FederatedServer.client_cleanup). Owned by Reg.
\* pReg:
\*   tok[c]         : current token generation of site c (a re-login adds 1;
\*                    the job's participants hold generation 1, its start token)
\*   reg[c]         : the current token is registered (FALSE after a logout)
\*   stale[c]       : the current token's heartbeats stopped (older than
\*                    heart_beat_timeout)
\*   notified       : set of <<site, generation>> for which notify_dead_client
\*                    sent HANDLE_DEAD_JOB to this job's SJ
\*   cleanupCrashed : "no", or how the cleanup thread died ("relogin": T2,
\*                    "jobExit": T3); dead clients are never removed again
EXTENDS Consts
\* jobExitRace: another job's SJ exits while notify_dead_client iterates
\* run_processes without engine.lock (T3; measured window about 0.3 ms).
RegFaults == {"jobExitRace"}
RegPortInit == [tok |-> [c \in Sites |-> 1], reg |-> [c \in Sites |-> TRUE],
                stale |-> [c \in Sites |-> FALSE], notified |-> {}, cleanupCrashed |-> "no"]
\* bound on re-logins per site (CP restart once, outage reconnects)
MaxTok == 3
=============================================================================
