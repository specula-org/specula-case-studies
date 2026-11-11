------------------------------ MODULE PortsReg ------------------------------
\* Port shape of the REG group (v8): the SP's client registry (ClientManager)
\* and its cleanup thread (FederatedServer.client_cleanup). Owned by Reg.
\* pReg:
\* tok[c] : current token generation of site c (a re-login adds 1;
\* the job's participants hold generation 1, its start token)
\* reg[c] : the current token is registered (FALSE after a logout)
\* stale[c] : the current token's heartbeats stopped (older than
\* heart_beat_timeout)
\* notified : set of <<site, generation>> for which notify_dead_client
\* sent HANDLE_DEAD_JOB to this job's SJ
\* cleanupCrashed : "no", or the ledger id of the operation that ended the cleanup
\* thread; dead clients are never removed again
EXTENDS Consts
\* jobExitRace: another job's SJ exits while notify_dead_client iterates
\* run_processes without engine.lock.
\* regIterRace: a client registers or re-logs in while the cleanup pass iterates the
\* registry's client dict without its lock (fed_server.py:313; window: the iteration).
RegFaults == {"jobExitRace", "regIterRace"}
RegPortInit == [tok |-> [c \in Sites |-> 1], reg |-> [c \in Sites |-> TRUE],
                stale |-> [c \in Sites |-> FALSE], notified |-> {}, cleanupCrashed |-> "no",
                \* unmatched: participants re-logged in while the job ran (the job sync matches only
                \* the participant token, so their dead job is never reported)
                unmatched |-> {}]
\* bound on re-logins per site (CP restart once, outage reconnects)
MaxTok == 3
=============================================================================
