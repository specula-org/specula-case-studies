------------------------------ MODULE Reg_C ------------------------------
\* Group Reg, COARSE variant (v8). Same port effects as Reg_F without the
\* cleanup pass structure: any registered stale token may be logged out and its
\* job notified; the thread may die after a re-login of a stale token (T2) or,
\* with jobExitRace, while a logout is pending (T3). Over-approximates Reg_F.
EXTENDS Ports
VARIABLE reg_c

\* pending: the token being logged out (notify not done yet); crashOK: a stale
\* token was replaced by a re-login (the cleanup pass may have listed it)
InitValue == [pending |-> {}, crashOK |-> FALSE]
Init == reg_c = InitValue

R == pReg
S == reg_c
Tok(c) == <<c, R.tok[c]>>
JobListed == pJobSP.sjLaunched /\ SJAlive
Alive == R.cleanupCrashed = "no"

GoStale(c) ==
    /\ R.reg[c] /\ ~R.stale[c]
    /\ "deadClient" \in Faults
    /\ pReg' = [R EXCEPT !.stale[c] = TRUE]
    /\ UNCHANGED reg_c

ReLogin(c) ==
    /\ R.tok[c] < MaxTok
    /\ \/ CPRestarted(c) /\ R.tok[c] = 1
       \/ "deadClient" \in Faults /\ (R.stale[c] \/ ~R.reg[c])
    /\ pReg' = [R EXCEPT !.tok[c] = @ + 1, !.reg[c] = TRUE, !.stale[c] = FALSE]
    \* crashOK: a stale token waiting behind another logout was replaced (T2)
    /\ \/ UNCHANGED reg_c
       \/ R.reg[c] /\ R.stale[c] /\ S.pending /= {} /\ reg_c' = [S EXCEPT !.crashOK = TRUE]

\* fed_server.py:1013-1084 (_sync_client_jobs): a heartbeat from the participant
\* token (generation 1) no longer lists the job while it runs on the server:
\* HANDLE_DEAD_JOB to its SJ. A restarted CP's new token matches no participant (R2).
HeartbeatSyncNotify(c) ==
    /\ R.reg[c] /\ ~R.stale[c] /\ R.tok[c] = 1 /\ JobListed
    /\ CurLaunch(c) > 0 /\ CJGone(c, CurLaunch(c)) /\ <<c, 1>> \notin R.notified
    /\ pReg' = [R EXCEPT !.notified = @ \cup {<<c, 1>>}]
    /\ UNCHANGED reg_c

NotifyOf(t) == R.notified \cup (IF t[2] = 1 /\ JobListed THEN {t} ELSE {})

\* first logout of a pass (no logout pending)
Logout(c) ==
    /\ Alive /\ S.pending = {} /\ R.reg[c] /\ R.stale[c]
    /\ pReg' = [R EXCEPT !.reg[c] = FALSE]
    /\ reg_c' = [S EXCEPT !.pending = {Tok(c)}, !.crashOK = FALSE]

\* the pending logout's notification, the pass ends
Notify(t) ==
    /\ t \in S.pending
    /\ pReg' = [R EXCEPT !.notified = NotifyOf(t)]
    /\ reg_c' = [S EXCEPT !.pending = {}]

\* the pending logout's notification, then the next stale token's logout
NotifyLogout(t, c) ==
    /\ t \in S.pending /\ R.reg[c] /\ R.stale[c]
    /\ pReg' = [R EXCEPT !.notified = NotifyOf(t), !.reg[c] = FALSE]
    /\ reg_c' = [S EXCEPT !.pending = {Tok(c)}]

\* the pending logout's notification, then a replaced token: the thread dies (T2)
NotifyCrash(t) ==
    /\ t \in S.pending /\ S.crashOK
    /\ pReg' = [R EXCEPT !.notified = NotifyOf(t), !.cleanupCrashed = "relogin"]
    /\ reg_c' = [S EXCEPT !.pending = {}, !.crashOK = FALSE]

RaceCrash ==
    /\ Alive /\ S.pending /= {} /\ "jobExitRace" \in Faults /\ "otherJob" \in Profile
    /\ pReg' = [R EXCEPT !.cleanupCrashed = "jobExit"]
    /\ reg_c' = [S EXCEPT !.pending = {}, !.crashOK = FALSE]

Next ==
    \/ \E c \in Sites : GoStale(c)
    \/ \E c \in Sites : ReLogin(c)
    \/ \E c \in Sites : HeartbeatSyncNotify(c)
    \/ \E c \in Sites : Logout(c)
    \/ \E c \in Sites, g \in 1..MaxTok : Notify(<<c, g>>)
    \/ \E c \in Sites, g \in 1..MaxTok, d \in Sites : NotifyLogout(<<c, g>>, d)
    \/ \E c \in Sites, g \in 1..MaxTok : NotifyCrash(<<c, g>>)
    \/ RaceCrash
=============================================================================
