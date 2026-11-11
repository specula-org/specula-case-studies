------------------------------ MODULE Reg_C ------------------------------
\* Group Reg, COARSE variant (v8). Same port effects as Reg_F without the
\* cleanup pass structure: any registered stale token may be logged out and its
\* job notified; the thread may die after a re-login of a stale token or,
\* with jobExitRace, while a logout is pending. Over-approximates Reg_F.
EXTENDS Ports
VARIABLE reg_c

\* pending: the token being logged out (notify not done yet); crashOK: a stale
\* token was replaced by a re-login (the cleanup pass may have listed it)
InitValue == [pending |-> {}, crashOK |-> FALSE, spSeen |-> FALSE, listed |-> {}]
Init == reg_c = InitValue

R == pReg
S == reg_c
Tok(c) == <<c, R.tok[c]>>
JobListed == pJobSP.sjLaunched /\ SJAlive
Alive == R.cleanupCrashed = "no"

\* @L Reg.hb.stale
GoStale(c) ==
    /\ R.reg[c] /\ ~R.stale[c]
    /\ "deadClient" \in Faults
    /\ pReg' = [R EXCEPT !.stale[c] = TRUE]
    /\ UNCHANGED reg_c

\* @L Reg.mgr.authenticate, Reg.mgr.tokens
ReLogin(c) ==
    /\ R.tok[c] < MaxTok
    /\ \/ CPRestarted(c) /\ R.tok[c] = 1
       \/ "deadClient" \in Faults /\ (R.stale[c] \/ ~R.reg[c])
    \* cause record: a participant token replaced while its job runs and before its dead job was reported
    /\ pReg' = [R EXCEPT !.tok[c] = @ + 1, !.reg[c] = TRUE, !.stale[c] = FALSE,
                         !.unmatched = IF R.tok[c] = 1 /\ JobListed /\ <<c, 1>> \notin R.notified THEN @ \cup {c} ELSE @]
    \* crashOK: a stale token waiting behind another logout was replaced
    /\ \/ UNCHANGED reg_c
       \/ /\ R.reg[c] /\ R.stale[c] /\ S.pending /= {} /\ Tok(c) \in S.listed /\ Tok(c) \notin S.pending
          /\ reg_c' = [S EXCEPT !.crashOK = TRUE]

\* fed_server.py:1013-1084 (_sync_client_jobs): a heartbeat from the participant
\* token (generation 1) no longer lists the job while it runs on the server:
\* HANDLE_DEAD_JOB to its SJ. A restarted CP's new token matches no participant.
\* @L Reg.hb.jobSync
HeartbeatSyncNotify(c) ==
    /\ R.reg[c] /\ ~R.stale[c] /\ R.tok[c] = 1 /\ JobListed
    /\ CurLaunch(c) > 0 /\ CJGone(c, CurLaunch(c)) /\ <<c, 1>> \notin R.notified
    /\ pReg' = [R EXCEPT !.notified = @ \cup {<<c, 1>>}]
    /\ UNCHANGED reg_c

NotifyOf(t) == R.notified \cup (IF t[2] = 1 /\ JobListed THEN {t} ELSE {})

\* first logout of a pass (no logout pending)
\* @L Reg.cleanup.loop
Logout(c) ==
    /\ Alive /\ S.pending = {} /\ R.reg[c] /\ R.stale[c]
    /\ pReg' = [R EXCEPT !.reg[c] = FALSE]
    \* the pass's list: every registered stale token at the start of the pass
    /\ reg_c' = [S EXCEPT !.pending = {Tok(c)}, !.crashOK = FALSE,
                         !.listed = {Tok(d) : d \in {x \in Sites : R.reg[x] /\ R.stale[x]}}]

\* the pending logout's notification, the pass ends
\* @L Reg.cleanup.loop
Notify(t) ==
    /\ t \in S.pending
    /\ pReg' = [R EXCEPT !.notified = NotifyOf(t)]
    /\ reg_c' = [S EXCEPT !.pending = {}]

\* the pending logout's notification, then the next stale token's logout
\* @L Reg.cleanup.loop
NotifyLogout(t, c) ==
    /\ t \in S.pending /\ R.reg[c] /\ R.stale[c] /\ Tok(c) \in S.listed
    /\ pReg' = [R EXCEPT !.notified = NotifyOf(t), !.reg[c] = FALSE]
    /\ reg_c' = [S EXCEPT !.pending = {Tok(c)}]

\* the pending logout's notification, then a replaced token: the thread dies
\* @L Reg.cleanup.logoutNone
NotifyCrash(t) ==
    /\ t \in S.pending /\ S.crashOK
    /\ pReg' = [R EXCEPT !.notified = NotifyOf(t), !.cleanupCrashed = "Reg.cleanup.logoutNone"]
    /\ reg_c' = [S EXCEPT !.pending = {}, !.crashOK = FALSE]

\* the cleanup pass iterates the registry's client dict without its lock while a
\* client registers or re-logs in (R-concurrent): the iteration raises and the
\* thread dies (fed_server.py:309-321, client_manager.py:166-180,431)
ReLoginOK(c) == /\ R.tok[c] < MaxTok
                /\ \/ CPRestarted(c) /\ R.tok[c] = 1
                   \/ "deadClient" \in Faults /\ (R.stale[c] \/ ~R.reg[c])
\* @L Reg.cleanup.iterate
IterCrash ==
    /\ "regIterRace" \in Faults /\ Alive /\ S.pending = {}
    /\ \E c \in Sites : R.reg[c] /\ R.stale[c]
    /\ \E d \in Sites : ReLoginOK(d)
    /\ pReg' = [R EXCEPT !.cleanupCrashed = "Reg.cleanup.iterate"]
    /\ UNCHANGED reg_c

\* SP restart: the registry is in memory; every client logs in again with a new
\* token and the cleanup thread is a new one (spSeen: applied once)
\* @L Reg.mgr.tokens, Reg.proc.restart
SPRestart ==
    /\ SPRestarted /\ ~S.spSeen
    /\ pReg' = [tok |-> [c \in Sites |-> IF R.tok[c] < MaxTok THEN R.tok[c] + 1 ELSE R.tok[c]],
                reg |-> [c \in Sites |-> TRUE], stale |-> [c \in Sites |-> FALSE],
                notified |-> R.notified, cleanupCrashed |-> "no", unmatched |-> R.unmatched]
    /\ reg_c' = [S EXCEPT !.pending = {}, !.crashOK = FALSE, !.spSeen = TRUE]

\* @L Reg.cleanup.notifyIterate
RaceCrash ==
    /\ Alive /\ S.pending /= {} /\ "jobExitRace" \in Faults /\ "otherJob" \in Profile
    /\ pReg' = [R EXCEPT !.cleanupCrashed = "Reg.cleanup.notifyIterate"]
    /\ reg_c' = [S EXCEPT !.pending = {}, !.crashOK = FALSE]

Next ==
    \/ \E c \in Sites : GoStale(c)
    \/ \E c \in Sites : ReLogin(c)
    \/ \E c \in Sites : HeartbeatSyncNotify(c)
    \/ \E c \in Sites : Logout(c)
    \/ \E c \in Sites, g \in 1..MaxTok : Notify(<<c, g>>)
    \/ \E c \in Sites, g \in 1..MaxTok, d \in Sites : NotifyLogout(<<c, g>>, d)
    \/ \E c \in Sites, g \in 1..MaxTok : NotifyCrash(<<c, g>>)
    \/ RaceCrash \/ IterCrash \/ SPRestart
=============================================================================
