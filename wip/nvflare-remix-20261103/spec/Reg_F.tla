------------------------------ MODULE Reg_F ------------------------------
\* Group Reg, FINE variant (v8): ClientManager.authenticate / remove_client and
\* the client_cleanup thread, pin c411a201 (notes/reg-impl.md).
\*   client_manager.py:193-209 (remove_client), 320-345 (re-login pops the old
\*   token without notify); fed_server.py:290-335 (client_cleanup,
\*   remove_dead_clients, logout_client; no handler), 1105-1122
\*   (notify_dead_client iterates run_processes without engine.lock).
EXTENDS Ports
VARIABLE reg_f

\* pc: "idle" | "notify" (logging out cur; listed: tokens still to do) | "crashed"
InitValue == [pc |-> "idle", listed |-> {}, cur |-> None]
Init == reg_f = InitValue

R == pReg
S == reg_f
Tok(c) == <<c, R.tok[c]>>
Valid(t) == R.reg[t[1]] /\ R.tok[t[1]] = t[2]
\* run_processes holds this job while its SJ runs (popped after the exit)
JobListed == pJobSP.sjLaunched /\ SJAlive

\* Heartbeats of the current token stop for longer than heart_beat_timeout
\* (60-600 s): the client hangs or is cut off (fault deadClient). A crashed CP
\* restarts and logs in again within seconds, long before its old token is stale,
\* so a CP restart alone never makes the old token stale (timing, notes/timing-inventory.md).
GoStale(c) ==
    /\ R.reg[c] /\ ~R.stale[c]
    /\ "deadClient" \in Faults
    /\ pReg' = [R EXCEPT !.stale[c] = TRUE]
    /\ UNCHANGED reg_f

\* client_manager.py:330-339: a registration of the same name pops the old token
\* (no notify_dead_client) and adds a fresh one. The restarted CP logs in (R2);
\* a client cut off by an outage reconnects (stale) or comes back after logout.
ReLogin(c) ==
    /\ R.tok[c] < MaxTok
    /\ \/ CPRestarted(c) /\ R.tok[c] = 1
       \/ "deadClient" \in Faults /\ (R.stale[c] \/ ~R.reg[c])
    /\ pReg' = [R EXCEPT !.tok[c] = @ + 1, !.reg[c] = TRUE, !.stale[c] = FALSE]
    /\ UNCHANGED reg_f

\* fed_server.py:1013-1084 (_sync_client_jobs): a heartbeat from the participant
\* token (generation 1) no longer lists the job while it runs on the server:
\* HANDLE_DEAD_JOB to its SJ. A restarted CP's new token matches no participant (R2).
HeartbeatSyncNotify(c) ==
    /\ R.reg[c] /\ ~R.stale[c] /\ R.tok[c] = 1 /\ JobListed
    /\ CurLaunch(c) > 0 /\ CJGone(c, CurLaunch(c)) /\ <<c, 1>> \notin R.notified
    /\ pReg' = [R EXCEPT !.notified = @ \cup {<<c, 1>>}]
    /\ UNCHANGED reg_f

\* fed_server.py:309-321: list the tokens whose heartbeat is older than the
\* timeout and log out the first one at once (microseconds later in the same
\* thread, no re-login lands in between).
CleanupList(c0) ==
    LET L == {Tok(c) : c \in {d \in Sites : R.reg[d] /\ R.stale[d]}} IN
    /\ S.pc = "idle" /\ R.reg[c0] /\ R.stale[c0]
    /\ pReg' = [R EXCEPT !.reg[c0] = FALSE]
    /\ reg_f' = [S EXCEPT !.pc = "notify", !.cur = Tok(c0), !.listed = L \ {Tok(c0)}]

\* fed_server.py:1105-1122: notify_dead_client(cur) sends HANDLE_DEAD_JOB to each
\* run process whose PARTICIPANTS hold the token (this job: generation 1, while
\* it is listed). This takes seconds (fail_run, sends): the window in which a
\* listed client re-registers.
NotifyCur == R.notified \cup (IF S.cur[2] = 1 /\ JobListed THEN {S.cur} ELSE {})

\* the pass ends
CleanupNotifyLast ==
    /\ S.pc = "notify" /\ S.listed = {}
    /\ pReg' = [R EXCEPT !.notified = NotifyCur]
    /\ reg_f' = [S EXCEPT !.pc = "idle", !.cur = None]

\* fed_server.py:316-329: the loop goes on to the next listed token at once.
\* remove_client returns None for a token popped by a re-login meanwhile, and
\* notify_dead_client(None) dereferences client.name: the thread dies (T2).
CleanupNotifyNext(t) ==
    /\ S.pc = "notify" /\ t \in S.listed
    /\ IF Valid(t)
       THEN /\ pReg' = [R EXCEPT !.notified = NotifyCur, !.reg[t[1]] = FALSE]
            /\ reg_f' = [S EXCEPT !.cur = t, !.listed = @ \ {t}]
       ELSE /\ pReg' = [R EXCEPT !.notified = NotifyCur, !.cleanupCrashed = "relogin"]
            /\ reg_f' = [S EXCEPT !.pc = "crashed", !.cur = None]

\* T3: another job's SJ exit pops run_processes during the iteration; the next
\* iteration step raises "dictionary changed size during iteration".
CleanupNotifyRace ==
    /\ S.pc = "notify" /\ "jobExitRace" \in Faults /\ "otherJob" \in Profile
    /\ pReg' = [R EXCEPT !.cleanupCrashed = "jobExit"]
    /\ reg_f' = [S EXCEPT !.pc = "crashed", !.cur = None]

\* ---- refinement mapping to Reg_C (pending logout, re-login of a listed token)
AbsC == [pending |-> IF S.pc = "notify" THEN {S.cur} ELSE {},
         crashOK |-> S.pc = "notify" /\ \E t \in S.listed : ~Valid(t)]
AbsCInit == [pending |-> {}, crashOK |-> FALSE]

Next ==
    \/ \E c \in Sites : GoStale(c)
    \/ \E c \in Sites : ReLogin(c)
    \/ \E c \in Sites : HeartbeatSyncNotify(c)
    \/ \E c \in Sites : CleanupList(c)
    \/ CleanupNotifyLast
    \/ \E c \in Sites, g \in 1..MaxTok : CleanupNotifyNext(<<c, g>>)
    \/ CleanupNotifyRace
=============================================================================
