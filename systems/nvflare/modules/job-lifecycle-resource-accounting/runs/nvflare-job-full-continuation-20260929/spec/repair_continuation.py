#!/usr/bin/env python3
"""Reproducible Phase 3 semantic repair of the preserved continuation-r0 suite.

This modifies verification artifacts only. Source evidence and limitations are
recorded in continuation-audit.md and changelog.md.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
OLD = ROOT / 'history/continuation-r0'
s = (OLD / 'base.tla').read_text()
mc = (OLD / 'MC.tla').read_text()
tr = (OLD / 'Trace.tla').read_text()
var_text = s.split('VARIABLES\n', 1)[1].split('\nstoreVars', 1)[0]
variables = re.findall(r'^    (\w+),?', var_text, re.M)
variables.append('micro')
actions = set(re.findall(r'B!(\w+)', mc)) - {'CheckRepliesLost', 'StartRepliesLost'}
new_actions = []


def get(name):
    m = re.search(r'^' + name + r'(?:\([^\n]*\))?\s*==[^\n]*(?:\n(?!\n|[A-Za-z_]\w*(?:\([^\n]*\))?\s*==)[^\n]*)*', s, re.M)
    if not m:
        raise ValueError(name)
    return m


def replace(name, text):
    global s
    m = get(name)
    s = s[:m.start()] + text.rstrip() + s[m.end():]


def action(name, params, body, assigned, new=False, comment=''):
    unchanged = [v for v in variables if v not in assigned]
    groups = [', '.join(unchanged[i:i+9]) for i in range(0, len(unchanged), 9)]
    body = body.strip('\n')
    if body.lstrip().startswith('\\/'):
        body = '    /\\ (\n' + '\n'.join('    ' + line for line in body.splitlines()) + '\n       )'
    text = f'{name}{params} ==\n' + body + '\n    /\\ UNCHANGED <<' + ',\n                   '.join(groups) + '>>'
    if new:
        new_actions.append((name, params, comment, text))
    else:
        replace(name, text)


# New behavior state is frozen by every old action unless explicitly repaired.
for name in sorted(actions):
    m = get(name)
    replace(name, m.group(0) + '\n    /\\ UNCHANGED micro')
s = s.replace('VARIABLES\n', 'VARIABLES\n    micro,         \\* source-visible intermediate state; see MicroInit\n', 1)
s = s.replace('vars == <<storeVars,', 'vars == <<micro, storeVars,', 1)
s = s.replace('behVars == <<status,', 'behVars == <<micro, status,', 1)
init = r'''MicroInit ==
    [wfcRead |-> [j \in Jobs |-> FALSE], wfcHad |-> [j \in Jobs |-> FALSE],
     reaped |-> [c \in Clients |-> [j \in Jobs |-> FALSE]],
     removals |-> [j \in Jobs |-> 0],
     sjBooted |-> [j \in Jobs |-> FALSE],
     cjSynced |-> [c \in Clients |-> [j \in Jobs |-> FALSE]],
     delAdm |-> [j \in Jobs |-> AdmIdle],
     reports |-> [c \in Clients |-> [j \in Jobs |-> [pc |-> "Idle", accepted |-> FALSE]]]]
'''
s = s.replace('Init ==\n', init + '\nInit ==\n    /\\ micro = MicroInit\n', 1)

# V01: per-object scan reads retain their own status/count snapshots.
action('RunnerScanReadOne', '(j)', r'''
    /\ rpc.pc = "ScanRead"
    /\ j \in rpc.listed
    /\ status[j] # DELETED
    /\ rpc' = [rpc EXCEPT !.listed = @ \ {j}, !.cnt[j] = pCount[j],
                         !.queue = IF status[j] = SUBMITTED THEN Append(@, j) ELSE @]
    /\ tagged' = IF status[j] = SUBMITTED THEN tagged ELSE tagged \cup {j}
''', {'rpc', 'tagged'}, True, 'V01 JD:524-529: read/filter one listed job; file-tag failures remain outside this projection.')
action('RunnerScanRead', '', r'''
    /\ rpc.pc = "ScanRead"
    /\ rpc.listed = {}
    /\ LET q == SelectSeq(JobOrder, LAMBDA j : j \in {rpc.queue[i] : i \in DOMAIN rpc.queue})
       IN rpc' = IF Cardinality(slots) >= MaxJobs \/ q = <<>> THEN RpcIdle
                 ELSE [RpcIdle EXCEPT !.pc = "TryNext", !.queue = q, !.cnt = rpc.cnt]
''', {'rpc'})

# Normal SJ execution requires the parent participant-list handshake first.
action('SjBootstrap', '(j)', r"""
    /\ sj[j] = "Running" /\ ~micro.sjBooted[j]
    /\ rp[j] # None /\ rp[j].parts # {}
    /\ micro' = [micro EXCEPT !.sjBooted[j] = TRUE]
""", {'micro'}, True,
'V03 server_app_runner.py:82 and SE:828-846 wait for a nonempty parent participant list, not for CJs to start.')
b = get('SjFinish').group(0).replace('    /\\ <<ee, rc>>',
    '    /\\ (rc = 0) => micro.sjBooted[j]\n    /\\ <<ee, rc>>')
replace('SjFinish', b)

b = get('SjHandleAbort').group(0).replace('IF sj[j] = "Running"',
    'IF sj[j] = "Running" /\\ micro.sjBooted[j]')
replace('SjHandleAbort', b)

# V03/C5: on the modeled flat client topology, normal ClientRunner return
# follows an actual successful SYNC_RUNNER response while the SJ runner exists.
# STARTED notification precedes this sync and must remain possible earlier.
action('CjSyncRunner', '(c, j)', r'''
    /\ cpAlive[c] /\ cjProc[c][j] = "Alive"
    /\ cjReg[c][j] # None /\ cjReg[c][j].st = STARTED
    /\ sj[j] = "Running" /\ micro.sjBooted[j]
    /\ ~micro.cjSynced[c][j]
    /\ micro' = [micro EXCEPT !.cjSynced[c][j] = TRUE]
''', {'micro'}, True,
'V03 client_app_runner:71-80; ClientRunner.init_run:743-778; ServerRunner:113-128. Flat client routing only.')
replace('CjNotifyStopped', get('CjNotifyStopped').group(0).replace(
    '    /\\ cpAlive[c]', '    /\\ cpAlive[c] /\\ micro.cjSynced[c][j]'))
replace('CjExit', get('CjExit').group(0).replace(
    '    /\\ rc = 0 =>', '    /\\ rc = 0 => micro.cjSynced[c][j]\n    /\\ rc = 0 =>'))
replace('CjHandleAbort', get('CjHandleAbort').group(0).replace(
    'cjReg[c][j].st = STARTED', 'cjReg[c][j].st = STARTED /\\ micro.cjSynced[c][j]'))

# C7: a CJ that has notified STARTED but cannot sync with an already-exited
# SJ takes the configured init_run timeout. This is reactive progress, not a
# separately injected crash, so MC's MaxCjError must not suppress it. Select
# ordinary exception cleanup here; stuck callbacks/typed rc-file variants are
# explicit coverage limits. Existing generic exit choices remain unchanged.
action('CjSyncTimeout', '(c, j)', r'''
    /\ cpAlive[c] /\ cjProc[c][j] = "Alive"
    /\ cjReg[c][j] # None /\ cjReg[c][j].st = STARTED
    /\ sj[j] = "Exited" /\ ~micro.cjSynced[c][j]
    /\ cjProc' = [cjProc EXCEPT ![c][j] = "Exited"]
    /\ cjRC' = [cjRC EXCEPT ![c][j] = RC_EXEC_ERR]
    /\ grp' = [grp EXCEPT ![c][j] = FALSE]
    /\ using' = [using EXCEPT ![c][j] = {}]
''', {'cjProc', 'cjRC', 'grp', 'using'}, True,
'C7 ClientRunner:689-690/739-778 and worker_process:123-130: failed sync raises after the configured deadline; ordinary cleanup, no numeric timing theorem.')

# V03: launch, registration, pending initialization, and per-site START send.
action('RunnerLaunchSJ', '', r'''
    /\ rpc.pc = "StartSJ"
    /\ rp[rpc.ready] = None
    /\ LET j == rpc.ready IN
       /\ sj' = [sj EXCEPT ![j] = "Running"]
       /\ sjRC' = [sjRC EXCEPT ![j] = 0]
       /\ launches' = [launches EXCEPT ![j] = @ + 1]
       /\ postAckLaunch' = [postAckLaunch EXCEPT ![j] = @ \/ ackAbort[j]]
       /\ rpc' = [rpc EXCEPT !.pc = "RegisterSJ", !.sreq = rpc.dep \cap sessions]
''', {'sj', 'sjRC', 'launches', 'postAckLaunch', 'rpc'}, True, 'V03 SE:315 launches before SE:321-328 registers the handle and starts its waiter.')
action('RunnerRegisterSJ', '', r'''
    /\ rpc.pc = "RegisterSJ"
    /\ LET j == rpc.ready
           parts == IF rpc.sreq = {} THEN sessions ELSE rpc.sreq
       IN /\ rp' = [rp EXCEPT ![j] = NewRec(parts)]
          /\ shared' = [shared EXCEPT ![j] = FALSE]
          /\ wfc' = [wfc EXCEPT ![j] = TRUE]
          /\ wfcStale' = [wfcStale EXCEPT ![j] = None]
          /\ micro' = [micro EXCEPT !.wfcRead[j] = FALSE, !.wfcHad[j] = FALSE]
          /\ rpc' = [rpc EXCEPT !.pc = "InitOutcomes"]
''', {'rp','shared','wfc','wfcStale','micro','rpc'}, True, 'V03 SE:321-328; no waiter reads a handle before its registration.')
action('RunnerInitOutcomes', '', r'''
    /\ rpc.pc = "InitOutcomes"
    /\ pending' = [pending EXCEPT ![rpc.ready] = rpc.dep]
    /\ rpc' = [rpc EXCEPT !.pc = "SendStart", !.chk = rpc.dep, !.sreq = {}]
''', {'pending','rpc'}, True, 'V03 JR:308-310 initializes pending outcomes after server start returns.')
action('RunnerSendStart', '(c)', r'''
    /\ rpc.pc = "SendStart"
    /\ c \in rpc.chk
    /\ rpc' = [rpc EXCEPT !.chk = @ \ {c}, !.sreq = IF c \in sessions THEN @ \cup {c} ELSE @]
''', {'rpc'}, True, 'V03 SE:1070-1080 builds requests one site at a time; delivery starts only after the map is complete.')
action('RunnerStartServerApp', '', r'''
    \/ /\ rpc.pc = "StartSJ" /\ rp[rpc.ready] # None
       /\ rpc' = [rpc EXCEPT !.pc = "ExceptStop"]
       /\ UNCHANGED msgs
    \/ /\ rpc.pc = "SendStart" /\ rpc.chk = {}
       /\ rpc' = [rpc EXCEPT !.pc = "StartWait"]
       /\ msgs' = Send(msgs, {StartReq(rpc.ready, c, rpc.att) : c \in {x \in rpc.sreq : cpAlive[x]}})
''', {'rpc','msgs'})
# The request map is complete before _send_admin_requests starts delivery.

# V05: separate delete and abort command contexts permit same-job overlap.
for name in ['AdminDeleteAuthorize', 'AdminDeleteExec']:
    body = get(name).group(0)
    body = body.replace('adm[j]', 'micro.delAdm[j]')
    body = body.replace("adm' = [adm EXCEPT ![j]", "micro' = [micro EXCEPT !.delAdm[j]")
    body = body.replace('    /\\ UNCHANGED micro', '    /\\ UNCHANGED adm')
    replace(name, body)

# V07: waiter reads only after actual process exit, and retains that exact read.
action('SpWaitRead', '(j)', r'''
    /\ wfc[j] /\ sj[j] = "Exited" /\ ~micro.wfcRead[j]
    /\ micro' = [micro EXCEPT !.wfcRead[j] = TRUE, !.wfcHad[j] = rp[j] # None]
''', {'micro'}, True, 'V07 SE:204-205: process.wait returns before the dictionary reference is read.')
action('SpWaitForComplete', '(j)', r'''
    /\ wfc[j] /\ sj[j] = "Exited" /\ micro.wfcRead[j]
    /\ LET rec == IF rp[j] # None THEN rp[j] ELSE wfcStale[j]
       IN /\ exc' = IF micro.wfcHad[j] /\ rec # None /\ sjRC[j] # 0 /\ exc[j] = None
                     THEN [exc EXCEPT ![j] = [rec EXCEPT !.rc = sjRC[j]]] ELSE exc
          /\ rp' = IF micro.wfcHad[j] THEN [rp EXCEPT ![j] = None] ELSE rp
          /\ shared' = IF micro.wfcHad[j] THEN [shared EXCEPT ![j] = FALSE] ELSE shared
    /\ wfc' = [wfc EXCEPT ![j] = FALSE]
    /\ sjRC' = [sjRC EXCEPT ![j] = 0]
    /\ wfcStale' = [wfcStale EXCEPT ![j] = None]
    /\ micro' = [micro EXCEPT !.wfcRead[j] = FALSE, !.wfcHad[j] = FALSE]
''', {'exc','rp','shared','wfc','sjRC','wfcStale','micro'})
s = s.replace('IF wfc[j] THEN rp[j] ELSE None', 'IF micro.wfcRead[j] /\\ micro.wfcHad[j] THEN rp[j] ELSE None')

# Source termination and dictionary pop are separated by an engine lock boundary.
action('SpTerminateRun', '(j)', r"""
    /\ rmp[j] > 0
    /\ rmp' = [rmp EXCEPT ![j] = @ - 1]
    /\ micro' = [micro EXCEPT !.removals[j] = @ + 1]
    /\ sj' = [sj EXCEPT ![j] = IF @ = "Running" THEN "Exited" ELSE @]
    /\ sjRC' = IF sj[j] = "Running" THEN [sjRC EXCEPT ![j] = RC_EXEC_ERR] ELSE sjRC
    /\ sjErr' = IF sj[j] = "Running" THEN [sjErr EXCEPT ![j] = TRUE] ELSE sjErr
""", {'rmp','micro','sj','sjRC','sjErr'}, True,
'SE:402-409: captured local-process handle termination precedes the locked dictionary pop.')
action('SpRemoveRunProcesses', '(j)', r"""
    /\ micro.removals[j] > 0
    /\ micro' = [micro EXCEPT !.removals[j] = @ - 1]
    /\ wfcStale' = IF rp[j] # None /\ micro.wfcRead[j] /\ micro.wfcHad[j]
                    THEN [wfcStale EXCEPT ![j] = rp[j]] ELSE wfcStale
    /\ rp' = [rp EXCEPT ![j] = None]
    /\ shared' = [shared EXCEPT ![j] = FALSE]
""", {'micro','wfcStale','rp','shared'})

# V07: synchronous REPORT can be handled before free/pop, after OS reaping.
action('CpReapChild', '(c, j)', r'''
    /\ cpAlive[c] /\ waiter[c][j] /\ cjProc[c][j] = "Exited"
    /\ cjReg[c][j] # None /\ ~micro.reaped[c][j]
    /\ LET e == cjReg[c][j]
           rc == IF cjRC[c][j] = RC_EXEC_ERR /\ ~e.abortReq
                 THEN (IF e.st = STARTING THEN RC_INFRA ELSE IF e.st = STARTED THEN RC_EXCEPTION ELSE RC_EXEC_ERR)
                 ELSE cjRC[c][j]
       IN msgs' = Send(msgs, {Report(j,c,rc)})
    /\ micro' = [micro EXCEPT !.reaped[c][j] = TRUE]
''', {'msgs','micro'}, True, 'V07 CX:628-674: reap, rc snapshot, synchronous report before free/pop.')
action('CpChildFinished', '(c, j)', r'''
    /\ cpAlive[c] /\ waiter[c][j] /\ micro.reaped[c][j]
    /\ cjProc[c][j] = "Exited" /\ cjReg[c][j] # None
    /\ free' = [free EXCEPT ![c] = AddUnits(@, alloc[c][j])]
    /\ alloc' = [alloc EXCEPT ![c][j] = {}]
    /\ cjReg' = [cjReg EXCEPT ![c][j] = None]
    /\ waiter' = [waiter EXCEPT ![c][j] = FALSE]
    /\ using' = IF grp[c][j] THEN using ELSE [using EXCEPT ![c][j] = {}]
    /\ cjRC' = [cjRC EXCEPT ![c][j] = 0]
''', {'free','alloc','cjReg','waiter','using','cjRC'})
replace('KillGroup', r'''KillGroup(c, j) ==
    IF micro.reaped[c][j]
    THEN UNCHANGED cjVars
    ELSE /\ cjProc' = [cjProc EXCEPT ![c][j] = IF @ = "Alive" THEN "Exited" ELSE @]
         /\ cjRC' = [cjRC EXCEPT ![c][j] = IF cjProc[c][j] = "Alive" THEN RC_EXEC_ERR ELSE @]
         /\ grp' = [grp EXCEPT ![c][j] = FALSE]
         /\ using' = [using EXCEPT ![c][j] = {}]''')

# V10: parent exit loses the resource ledger but does not kill OS descendants.
action('ClientCrash', '(c)', r'''
    /\ cpAlive[c]
    /\ cpAlive' = [cpAlive EXCEPT ![c] = FALSE]
    /\ msgs' = Keep(msgs, {m \in DOMAIN msgs : ~(m.cl = c /\ m.type \in ClientBound)})
''', {'cpAlive','msgs'})
action('CjParentExit', '(c, j)', r'''
    /\ ~cpAlive[c] /\ cjProc[c][j] = "Alive"
    /\ cjProc' = [cjProc EXCEPT ![c][j] = "Exited"]
    /\ using' = IF grp[c][j] THEN using ELSE [using EXCEPT ![c][j] = {}]
''', {'cjProc','using'}, True, 'V10 cooperative watchdog termination is possible, not assumed fair while notification can spin.')
s = s.replace('    \\/ ~cpAlive[c]\n    \\/ /\\ cjProc[c][j] # "Alive" /\\ ~grp[c][j] /\\ alloc[c][j] = {} /\\ cst[c][j] = None\n       /\\ \\A r \\in resv[c] : r.job # j',
              '    /\\ cjProc[c][j] # "Alive" /\\ ~grp[c][j]\n    /\\ (~cpAlive[c] \\/ (alloc[c][j] = {} /\\ cst[c][j] = None /\\ (\\A r \\in resv[c] : r.job # j)))')

# More repairs are appended below before materialization.

# V04: completion reads/barrier/marker/record/latch use different critical sections.
replace('CmpIdle', 'CmpIdle == [pc |-> "Idle", job |-> None, failed |-> FALSE, aborted |-> FALSE, hadExc |-> FALSE]')
# Existing terminal transitions must preserve the extended record shape.
s = s.replace('[pc |-> "Remove", job |-> j]', '[cpc EXCEPT !.pc = "Remove"]')
s = s.replace('[pc |-> "Dead", job |-> None]', '[CmpIdle EXCEPT !.pc = "Dead"]')
action('CmpReadServer', '(j)', r'''
    /\ cpc.pc = "Idle" /\ j \in runningJobs /\ rp[j] = None
    /\ cpc' = [CmpIdle EXCEPT !.pc = "Pending", !.job = j,
                            !.failed = Classify(exc[j]) \in {EXEC_EXC, ABNORMAL}]
''', {'cpc'}, True, 'V04 JR:445-454: the process-table test and first classification precede the pending barrier.')
action('CmpReadPending', '', r'''
    /\ cpc.pc = "Pending"
    /\ LET j == cpc.job IN
       /\ cpc.failed \/ pending[j] = None \/ pending[j] = {} \/ runAborted[j]
       /\ pending' = IF cpc.failed THEN [pending EXCEPT ![j] = None] ELSE pending
    /\ cpc' = [cpc EXCEPT !.pc = "AbortRead"]
''', {'pending','cpc'}, True, 'V04 JR:455-476: pending/deadline work under runner.lock; skipped loop passes stutter.')
action('CmpOutcomeDeadline', '(j)', r'''
    /\ cpc.pc = "Pending" /\ cpc.job = j /\ ~cpc.failed
    /\ pending[j] # None /\ pending[j] # {} /\ ~runAborted[j]
    /\ pending' = [pending EXCEPT ![j] = {}]
    /\ cpc' = [cpc EXCEPT !.pc = "AbortRead"]
''', {'pending','cpc'})
action('CmpReadAbort', '', r'''
    /\ cpc.pc = "AbortRead"
    /\ cpc' = [cpc EXCEPT !.pc = "OutcomeRead", !.aborted = runAborted[cpc.job]]
''', {'cpc'}, True, 'V04 JR:484-489 reads the Job marker outside the pending lock, before status lookup.')
action('CmpReadOutcome', '', r'''
    /\ cpc.pc = "OutcomeRead"
    /\ LET j == cpc.job
           has == ~cpc.aborted /\ latched[j] = None /\ exc[j] # None
       IN /\ cpc' = [cpc EXCEPT !.pc = "Latch", !.hadExc = has]
          /\ msgs' = IF has THEN Send(msgs, AbortMsgs(j, exc[j].parts \cap sessions, FALSE)) ELSE msgs
''', {'cpc','msgs'}, True, 'V04 JR:575-585 retains the exception dictionary across optional client abort RPCs.')
action('CmpFinalizeBegin', '(j)', r'''
    /\ cpc.pc = "Latch" /\ cpc.job = j
    /\ latched' = IF latched[j] # None THEN latched
                   ELSE [latched EXCEPT ![j] = IF cpc.aborted THEN ABORTED
                         ELSE IF cpc.hadExc THEN Classify(exc[j]) ELSE COMPLETED]
    /\ latchInStopWin' = [latchInStopWin EXCEPT ![j] = @ \/
                          (latched[j] = None /\ ~cpc.aborted /\ adm[j].pc = "MarkAborted")]
    /\ cpc' = [cpc EXCEPT !.pc = "Publish"]
''', {'latched','latchInStopWin','cpc'})

# V04: receiving a report, authoritative failure recording, RPC cleanup, and
# final resolve are distinct. Each CP has at most one terminal report per job.
action('SpAcceptJobFailure', '(m)', r'''
    /\ m \in DOMAIN msgs /\ m.type = "REPORT"
    /\ micro.reports[m.cl][m.job].pc = "Idle"
    /\ LET accepted == m.cl \in sessions /\ pending[m.job] # None /\ m.cl \in pending[m.job]
       IN micro' = [micro EXCEPT !.reports[m.cl][m.job] = [pc |-> "Handle", accepted |-> accepted]]
''', {'micro'}, True, 'V04 FS:916-940 token and pending checks happen before fail_run obtains its locks.')
action('SpHandleJobFailure', '(m)', r'''
    /\ m \in DOMAIN msgs /\ m.type = "REPORT"
    /\ micro.reports[m.cl][m.job].pc = "Handle"
    /\ LET j == m.job
           accepted == micro.reports[m.cl][j].accepted
           authoritative == accepted /\ m.code \in {RC_CONFIG,RC_EXCEPTION,RC_INFRA,RC_ABORTED}
           unsafe == accepted /\ m.code = RC_UNSAFE
           active == authoritative /\ FailRunActive(j)
           code == IF m.code = RC_CONFIG THEN RC_EXCEPTION ELSE m.code
       IN /\ failAccepted' = [failAccepted EXCEPT ![j] = @ \/ authoritative \/ unsafe]
          /\ failRunRec' = [failRunRec EXCEPT ![j] = @ \/ active]
          /\ exc' = IF active THEN [exc EXCEPT ![j] = FailRunRec(j,code)] ELSE exc
          /\ rp' = IF active THEN [rp EXCEPT ![j] = FailRunRp(j,code)] ELSE rp
          /\ shared' = IF active THEN [shared EXCEPT ![j] = FailRunShared(j)] ELSE shared
          /\ pending' = IF active THEN [pending EXCEPT ![j] = None] ELSE pending
          /\ micro' = [micro EXCEPT !.reports[m.cl][j].pc =
                       IF unsafe THEN "UnsafeStop" ELSE IF active THEN "Stop" ELSE "Resolve"]
''', {'failAccepted','failRunRec','exc','rp','shared','pending','micro'}, True, 'V04 JR:815-841 records failure and removes pending under locks; cleanup follows outside.')
action('SpFailureStop', '(m)', r'''
    /\ m \in DOMAIN msgs /\ m.type = "REPORT"
    /\ micro.reports[m.cl][m.job].pc \in {"Stop","UnsafeStop"}
    /\ msgs' = Send(msgs, StopRunMsgs(m.job))
    /\ rmp' = [rmp EXCEPT ![m.job] = StopRunRmp(m.job)]
    /\ micro' = [micro EXCEPT !.reports[m.cl][m.job].pc = IF @ = "UnsafeStop" THEN "Mark" ELSE "Resolve"]
''', {'msgs','rmp','micro'}, True, 'V04 JR:843 / stop_run: cleanup RPCs precede any unsafe-stop marker write.')
action('SpFailureMark', '(m)', r'''
    /\ m \in DOMAIN msgs /\ m.type = "REPORT"
    /\ micro.reports[m.cl][m.job].pc = "Mark"
    /\ runAborted' = IF m.job \in runningJobs THEN [runAborted EXCEPT ![m.job] = TRUE] ELSE runAborted
    /\ micro' = [micro EXCEPT !.reports[m.cl][m.job].pc = "Resolve"]
''', {'runAborted','micro'}, True, 'V04 JR:800-811 marks only an object still in running_jobs.')
action('SpProcessJobFailure', '(m)', r'''
    /\ m \in DOMAIN msgs /\ m.type = "REPORT"
    /\ micro.reports[m.cl][m.job].pc = "Resolve"
    /\ pending' = IF micro.reports[m.cl][m.job].accepted /\ pending[m.job] # None
                   THEN [pending EXCEPT ![m.job] = @ \ {m.cl}] ELSE pending
    /\ msgs' = Consume(msgs,m)
    /\ micro' = [micro EXCEPT !.reports[m.cl][m.job] = [pc |-> "Idle", accepted |-> FALSE]]
''', {'pending','msgs','micro'})
# Once received, a report is retained as a handler-local message, not losable.
loss = get('LoseMsg').group(0).replace('    /\\ msgs\' =',
    '    /\\ m.type = "REPORT" => micro.reports[m.cl][m.job].pc = "Idle"\n    /\\ msgs\' =')
replace('LoseMsg', loss)

# Audit known terminal writes by exact writer/from/to. This is only a search
# residual: each excluded writer is also checked separately with strict probes.
replace('KnownOverwrite', r"""KnownOverwrite(o) ==
    \/ o.w = "SetDispatched" /\ o.from = ABORTED /\ o.to = DISPATCHED
    \/ o.w = "MetaWrite" /\ o.from = ABORTED /\ o.to = DISPATCHED
    \/ o.w = "SetRunning" /\ o.from \in Terminal /\ o.to = RUNNING
    \/ o.w = "RefreshWrite" /\ o.from = ABORTED /\ o.to = SUBMITTED
    \/ o.w = "SetCantSched" /\ o.from = ABORTED /\ o.to = CANT_SCHED
    \/ o.w = "ExceptSetFailed" /\ o.from = ABORTED /\ o.to = FAILED_TO_RUN
    \/ o.w = "AdminAbortWrite" /\ o.from \in Terminal /\ o.to = ABORTED
    \/ o.w = "CmpPublish" /\ o.from = ABORTED /\ o.to \in Terminal""")

# Safety normal operations must not vanish at an artificial heartbeat/attempt cap.
mc = mc.replace('MCHeartbeat(c) == Under("hb", MaxHeartbeat) /\\ B!Heartbeat(c) /\\ Bump("hb")',
                'MCHeartbeat(c) == B!Heartbeat(c) /\\ UNCHANGED faultVars')
mc = mc.replace('MCRunnerBackoffSkip == Under("backoff", MaxBackoff) /\\ B!RunnerBackoffSkip /\\ Bump("backoff")',
                'MCRunnerBackoffSkip == B!RunnerBackoffSkip /\\ UNCHANGED faultVars')

# Complete the reference/MC transition relation and type domains.
s = s.replace('"StartSJ", "StartWait", "InsertRunning"',
              '"StartSJ", "RegisterSJ", "InitOutcomes", "SendStart", "StartWait", "InsertRunning"')
s = s.replace('cpc.pc \\in {"Idle", "Publish", "Remove", "Dead"}',
              'cpc.pc \\in {"Idle", "Pending", "AbortRead", "OutcomeRead", "Latch", "Publish", "Remove", "Dead"}')
s = s.replace('"MetaRead", "MetaWrite", "ChkDispatched", "StartSJ", "StartWait"',
              '"MetaRead", "MetaWrite", "ChkDispatched", "StartSJ", "RegisterSJ", "InitOutcomes", "SendStart", "StartWait"')

def disjunction(names, prefix=''):
    lines = []
    for name, params, _comment, _body in names:
        if params == '(j)':
            value = r'\E j \in Jobs : ' + prefix + name + params
        elif params == '(c)':
            value = r'\E c \in Clients : ' + prefix + name + params
        elif params == '(c, j)':
            value = r'\E c \in Clients, j \in Jobs : ' + prefix + name + params
        elif params == '(m)':
            value = r'\E m \in DOMAIN msgs : ' + prefix + name + params
        else:
            value = prefix + name + params
        lines.append('    \\/ ' + value)
    return '\n'.join(lines)

defs = '\n\n'.join('(* ' + c + ' *)\n' + a for _,_,c,a in new_actions)
s = s.replace('Next == RunnerNext', defs + '\n\nMicroNext ==\n' + disjunction(new_actions) + '\n\nNext == MicroNext \\/ RunnerNext')
# Fairness on finite microstep chains; parent-death exit intentionally has none.
fair = '\n'.join('    /\\ WF_vars(' + line.strip()[3:] + ')' for line in disjunction(
    [a for a in new_actions if a[0] != 'CjParentExit']).splitlines())
s = s.replace('FairSpec == Spec /\\ Fairness',
              'MicroFairness ==\n' + fair + '\n\nFairSpec == Spec /\\ Fairness /\\ MicroFairness')
mcdefs = '\n'.join('MC' + n + p + ' == B!' + n + p + ' /\\ UNCHANGED faultVars' for n,p,_,_ in new_actions)
mc = mc.replace('MCNextCore ==', mcdefs + '\n\nMCMicroNext ==\n' + disjunction(new_actions,'MC') + '\n\nMCNextCore ==\n    \\/ MCMicroNext')
mc = mc.replace('/\\ Fairness\n', '/\\ Fairness /\\ MicroFairness\n')

# Compatibility of coarse Phase 2.5 events with the finer model: hidden steps
# are restricted to the matching macro operation and job/message. These do not
# claim that the trace suite observes the newly exposed interleavings.
silent = r'''TraceSilent ==
    /\ l <= Len(TraceLog)
    /\ (\/ /\ E.name = "RunnerScanRead"
             /\ \E j \in Jobs : RunnerScanReadOne(j)
        \/ /\ E.name = "RunnerStartServerApp"
             /\ (RunnerLaunchSJ \/ RunnerRegisterSJ \/ RunnerInitOutcomes \/
                  (\E c \in Clients : RunnerSendStart(c)))
        \/ /\ E.name \in {"CmpFinalizeBegin", "CmpOutcomeDeadline"}
             /\ (CmpReadServer(TV(E.job)) \/ CmpReadPending \/ CmpReadAbort \/ CmpReadOutcome)
        \/ /\ E.name = "SjFinish"
             /\ SjBootstrap(TV(E.job))
        \/ /\ E.name \in {"CjNotifyStopped", "CjHandleAbort", "CjExit"}
             /\ (SjBootstrap(TV(E.job)) \/ CjSyncRunner(TV(E.cl), TV(E.job)))
        \/ /\ E.name \in {"SjFinish", "SjCrash"}
             /\ (SjBootstrap(TV(E.job)) \/ (\E c \in Clients : CjSyncRunner(c, TV(E.job))))
        \/ /\ E.name = "SjHandleAbort"
             /\ \E m \in DOMAIN msgs : MsgMatches(m) /\ SjBootstrap(m.job)
        \/ /\ E.name = "SjHandleAbort"
             /\ \E m \in DOMAIN msgs : MsgMatches(m) /\
                  (\E c \in Clients : CjSyncRunner(c, m.job))
        \/ /\ E.name = "SpRemoveRunProcesses"
             /\ (SjBootstrap(TV(E.job)) \/ (\E c \in Clients : CjSyncRunner(c, TV(E.job)))
                 \/ ((sj[TV(E.job)] = "Running" => TraceSyncBeforeExit(TV(E.job))) /\ SpTerminateRun(TV(E.job))))
        \/ /\ E.name = "CpChildFinished"
             /\ CpReapChild(TV(E.cl),TV(E.job))
        \/ /\ E.name = "SpWaitForComplete"
             /\ SpWaitRead(TV(E.job))
        \/ /\ E.name = "SpProcessJobFailure"
             /\ \E m \in DOMAIN msgs : MsgMatches(m) /\
                  (SpAcceptJobFailure(m) \/ SpHandleJobFailure(m) \/ SpFailureStop(m) \/ SpFailureMark(m)))
    /\ UNCHANGED l
'''
# TraceMatched quantifies all wrapper branches. Required hidden syncs must occur
# before the SJ's last opportunity to acknowledge them; otherwise an avoidable
# dead branch would fail a feasible trace. Lookahead selects necessary witnesses
# only; every logged event still checks its full post-state and advances once.
sync_witness = r'''
TraceNeedsSync(c, j) ==
    \E k \in l..Len(TraceLog) :
        LET t == TraceLog[k].event IN
        /\ t.name \in {"CjNotifyStopped", "CjExit", "CjHandleAbort"}
        /\ TV(t.job) = j /\ TV(t.cl) = c
        /\ (t.name = "CjNotifyStopped" \/ (t.name = "CjExit" /\ t.arg.rc = 0)
            \/ (t.name = "CjHandleAbort" /\ t.state.clients[t.cl].alive
                /\ t.state.clients[t.cl].jobs[t.job].registration.st = "STOPPED"))

TraceSyncBeforeExit(j) == \A c \in Clients : TraceNeedsSync(c,j) => micro.cjSynced[c][j]
TraceSyncIfExiting(j) == (sj[j] = "Running" /\ S.jobs[j].sj = "Exited") => TraceSyncBeforeExit(j)
'''
tr = tr.replace('MsgMatches(m) ==', sync_witness + '\nMsgMatches(m) ==')
tr = tr.replace('TraceInit ==', silent + '\nTraceInit ==')
tr = tr.replace('/\\ SjFinish(TV(E.job),', '/\\ TraceSyncBeforeExit(TV(E.job)) /\\ SjFinish(TV(E.job),')
tr = tr.replace('/\\ SjCrash(TV(E.job))', '/\\ TraceSyncBeforeExit(TV(E.job)) /\\ SjCrash(TV(E.job))')
tr = tr.replace('MsgEv("SjHandleAbort", SjHandleAbort)',
    'MsgEv("SjHandleAbort", LAMBDA m : TraceSyncIfExiting(m.job) /\\ SjHandleAbort(m))')
tr = tr.replace('TraceNext ==\n', 'TraceNext ==\n    \\/ TraceSilent\n')
# Explicit waiter-read events will be emitted by the refreshed instrumentation.
tr = tr.replace('SpWaitForCompleteLogged ==',
                'SpWaitReadLogged ==\n    /\\ JobEv("SpWaitRead") /\\ SpWaitRead(TV(E.job)) /\\ ValidatePostState /\\ StepTrace\n\nSpWaitForCompleteLogged ==')
tr = tr.replace('    \\/ SpWaitForCompleteLogged', '    \\/ SpWaitReadLogged \\/ SpWaitForCompleteLogged')
tr = tr.replace('/\\ SpWaitRead(TV(E.job)) /\\ ValidatePostState',
                '/\\ SpWaitRead(TV(E.job)) /\\ micro\'.wfcHad[TV(E.job)] = E.arg.record_present /\\ ValidatePostState')

# Equivalent distribution removes a known static-analyzer CFG ambiguity.
s = s.replace(r"""    \/ \E c \in Clients, j \in Jobs :
          CpStartRegister(c, j) \/ CpStartLaunch(c, j) \/ CpStartLaunchFail(c, j)
          \/ CpTerminateJob(c, j) \/ CpChildFinished(c, j)""", r"""    \/ (\E c \in Clients, j \in Jobs : CpStartRegister(c, j))
    \/ (\E c \in Clients, j \in Jobs : CpStartLaunch(c, j))
    \/ (\E c \in Clients, j \in Jobs : CpStartLaunchFail(c, j))
    \/ (\E c \in Clients, j \in Jobs : CpTerminateJob(c, j))
    \/ (\E c \in Clients, j \in Jobs : CpChildFinished(c, j))""")
s = s.replace('   The read itself is not observable: both outcomes are allowed.',
              '   SpWaitRead explicitly records the post-exit dictionary read before either outcome.')
s = s.replace('       /\\ rpc.pc \\in {"SetDispatched", "MetaRead", "MetaWrite", "ChkDispatched", "StartSJ"}',
              '       /\\ rpc.pc \\in {"SetDispatched", "MetaRead", "MetaWrite", "ChkDispatched", "StartSJ", "RegisterSJ", "InitOutcomes", "SendStart"}')

# Remove misleading global claims; the audited projection has explicit limits.
s = s.replace('(* client parents (CP): every handler is split at the check-then-act and   *)\n(* blocking-I/O boundaries the code keeps separate (modeling brief S1-S5). *)',
              '(* client parents (CP). Continuation repairs expose selected source       *)\n(* windows; remaining projection limits are in continuation-audit.md.      *)')
s = s.replace('   Launch, registration and the START fan-out are one step: no reader of the intermediate state exists\n   before any CJ is started.', '   Continuation: this is the end event; preceding micro-actions expose launch, registration and fanout.')
s = s.replace('(* CP process crash / exit: in-memory CP state is gone; CJs stop on parent death (app/utils.py:45-50);',
              '(* CP process crash / exit: in-memory CP state is gone; child termination is a separate possible step;')

s = s.replace(r'\E c \in Clients, j \in Jobs :', r'\E c \in Clients : \E j \in Jobs :')
s = s.replace('terminal status once.  The run_aborted read (:486) and the classification (:585) are one step: the only\n   blocking call between them (abort_client_run, :584) exists only when an exception record is present.',
    'terminal status once. Continuation microsteps separate the marker read, exception lookup,\n   optional abort RPC, and classification/latch; this is the last step only.')
s = s.replace('The read itself is not observable: both outcomes are allowed.',
    'SpWaitRead explicitly records the actual post-exit lookup before either outcome.')
s = s.replace('no SJ cell: the command fails', 'no active server runner: acknowledgment has no stop effect')
mc = mc.replace('MaxHeartbeat,     \\* Heartbeat (safety configs); liveness configs use MCLiveSpec (unbounded, fair)',
    'MaxHeartbeat,     \\* legacy cfg compatibility; heartbeats are now unbounded in all specs')
# MC-E residual: marker can be written after CmpReadAbort but before the latch.
# This oracle-only tolerance remains paired with the strict stop-success probe.
s = s.replace(r'(~sjAbortHandled[j] \/ latchInStopWin[j])',
              r'(~sjAbortHandled[j] \/ latchInStopWin[j] \/ runAborted[j])')
# C8: dead CP state is retained for ownership analysis, but cannot produce a
# missing START reply. SE:1082 / admin.py:314-337 still return at the request
# deadline even if allocation/registration was in flight when the CP died.
# Treat that timeout as ordinary reactive progress, independently of the
# injected early-timeout budget. Keep queued replies from a now-dead CP usable.
replace('StartRepliesLost', r'''StartRepliesLost == \A c \in rpc.sreq \ {m.cl : m \in StartReps} :
    ~cpAlive[c] \/ (StartReq(rpc.ready, c, rpc.att) \notin DOMAIN msgs /\ cst[c][rpc.ready] = None)''')
(ROOT/'base.tla').write_text(s)
# Strict writer-specific probes prevent broad residuals from being the only
# evidence for a known category. These operators do not affect behavior.
probes = r"""
RecordedExecutionErrorNotMasked == \A j \in Jobs : status[j] = COMPLETED => ~exeErrRec[j]
NoAdminAbortOverwrite == \A o \in ovw : o.w # "AdminAbortWrite"
NoCompletionOverwrite == \A o \in ovw : o.w # "CmpPublish"
NoCantSchedOverwrite == \A o \in ovw : o.w # "SetCantSched"
NoStartFailureOverwrite == \A o \in ovw : o.w # "ExceptSetFailed"
NoDeployMetaOverwrite == \A o \in ovw : o.w # "MetaWrite"
NoDeletedTrackedSlot == \A j \in slots :
    ~(status[j] = DELETED /\ j \in runningJobs /\ rpc.ready # j
      /\ ~(cpc.pc = "Remove" /\ cpc.job = j))
NoStoppedSuccess == \A j \in Jobs :
    ~(status[j] = COMPLETED /\ sjAbortHandled[j] /\ ackStop[j])
NoStartKeyError == \A j \in Jobs : startFailCause[j] # "keyerror"
(* Finite-batch expiry contract under fair cleanup ticks, not prompt cancel. *)
ReservationDrain == \A c \in Clients : (resv[c] # {}) ~> (resv[c] = {} \/ ~cpAlive[c])
"""
mc = mc.rsplit('====',1)[0] if False else mc
last = mc.rfind('\n====')
mc = mc[:last] + '\n' + probes + mc[last:]
(ROOT/'MC.tla').write_text(mc)
(ROOT/'Trace.tla').write_text(tr)
print('wrote', len(new_actions), 'new actions,', len(variables), 'variables')
