# Preserve caller-side wf_lock acquisition, activity reporting and wait-for-comm windows.
parts[0]=parts[0].replace('"check", "queued",', '"check", "checking", "queued",')
parts[0]=parts[0].replace('EmptyComm ==', 'EmptyRunner == [kind |-> "free", pc |-> "idle", client |-> "", id |-> NoId, attempt |-> 0]\nEmptyComm ==')
parts[0]=parts[0].replace('comm |-> EmptyComm, aggr |->', 'comm |-> EmptyComm, runner |-> EmptyRunner, requested |-> {}, aggr |->')
parts[0]=parts[0].replace('mon |-> [pc |-> "idle", pending |-> {}, deadView |-> {}]', 'mon |-> [pc |-> "idle", pending |-> {}, deadView |-> {}, reportAges |-> [c \\in Clients |-> 0]]')
parts[0]=parts[0].replace('RunnerLockFree == s.comm.kind \\notin {"request", "submit"}', 'RunnerLockFree == s.runner.kind = "free"')
def edit_action(name, fn, source=None, trigger=None, fault='keep'):
 for i,piece in enumerate(parts):
  if '\n'+name+'(' in piece or '\n'+name+' ==' in piece: parts[i]=fn(piece)
 for a in actions:
  if a['name']==name:
   if source: a['source']=source
   if trigger:a['trigger']=trigger
   if fault!='keep':a['fault']=fault
edit_action('WFCommScheduleTask',lambda x:x.replace('/\\ s.wf.pc = "schedule"','/\\ s.wf.pc = "schedule"\n    /\\ (s.comm.kind /= "monitor" \\/ s.comm.pc = "exitCleanup")'))
edit_action('WFCommProcessTaskRequest',lambda x:x.replace('/\\ s.wf.open /\\ s.comm.kind = "free" /\\ s.wf.round \\in Tasks',
 '/\\ s.wf.open /\\ s.comm.kind = "free" /\\ s.wf.round \\in Tasks\n    /\\ s.runner.kind = "request" /\\ s.runner.pc = "commWait" /\\ s.runner.client = c'))
edit_action('WFCommResendTask',lambda x:x.replace('/\\ s.wf.open /\\ s.comm.kind = "free" /\\ LiveMap(id)',
 '/\\ s.wf.open /\\ s.comm.kind = "free" /\\ LiveMap(id)\n    /\\ s.runner.kind = "request" /\\ s.runner.pc = "commWait" /\\ s.runner.client = id[2]'),fault=None)
for name in ['WFCommPublishClientTask','WFCommTaskTryAgain','WFCommStampReceipt','WFCommDropSubmission']:
 edit_action(name,lambda x:x.replace('!.comm = EmptyComm]', '!.comm = EmptyComm, !.runner = EmptyRunner]'))
edit_action('ClientRetryResult',lambda x:x,fault=None)
edit_action('ClientCheckTask',lambda x:x.replace('s.net[id[1]][id[2]][n] = "check"','s.net[id[1]][id[2]][n] = "checking"'))
# Replace ingress action: caller wf_lock spans activity reporting and communicator wait.
for i,piece in enumerate(parts):
 if '\nServerRunnerProcessSubmission(' in piece:
  parts[i]=r'''
\* nvflare/private/fed/server/server_runner.py:460-475.
\* S2/S4: runner admission is checked once under wf_lock; abort sets status=done.
ServerRunnerProcessSubmission(id, n) ==
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "queued"
    /\ RunnerLockFree
    /\ s' = [s EXCEPT !.runner = [EmptyRunner EXCEPT !.kind = "submit",
              !.pc = IF s.wf.open /\ ~s.wf.abort THEN "activity" ELSE "closed",
              !.id = id, !.attempt = n]]
'''
  break
for a in actions:
 if a['name']=='ServerRunnerProcessSubmission':
  a['source']='nvflare/private/fed/server/server_runner.py:460-475'
  a['trigger']='S2/S4: acquire caller wf_lock and check runner admission once; abort has set runner status=done.'
edit_action('WFCommMonitorBegin',lambda x:x.replace('!.mon.pending = Clients]', '!.mon.pending = Clients,\n              !.mon.reportAges = [c \\in Clients |-> s.dead[c].age]]'))
edit_action('WFCommCheckDeadClient',lambda x:x.replace('s.dead[c].age = 2','s.mon.reportAges[c] = 2'))
A('ServerRunnerTaskRequestActive',['c'], 'nvflare/private/fed/server/server_runner.py:298,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259',
  'S1/S5: request activity clears dead state before the separate get-task lock acquisition; capture only task-relevant polls.',r'''
    /\ s.wf.open /\ RunnerLockFree /\ s.mon.pc /= "dead" /\ c \in Selected
    /\ c \notin s.requested
    /\ \E t \in Tasks : s.task[t].standing /\ ~s.ct[t][c].receipt
    /\ s' = [s EXCEPT !.dead[c] = [reported |-> FALSE, age |-> 0, disconnected |-> FALSE],
                     !.requested = @ \cup {c}]
''')
A('ServerRunnerAcquireTaskRequest',['c'], 'nvflare/private/fed/server/server_runner.py:385-395',
  'S1/S4: acquire wf_lock before waiting for communicator; monitor may still own communicator.',r'''
    /\ c \in s.requested /\ RunnerLockFree
    /\ s' = [s EXCEPT !.requested = @ \ {c},
          !.runner = [EmptyRunner EXCEPT !.kind = "request", !.pc = "commWait", !.client = c]]
''')
A('WFCommTaskUnavailable',[], 'nvflare/private/fed/server/server_runner.py:386-395; nvflare/apis/impl/wf_comm_server.py:220-272; nvflare/apis/impl/task_manager.py:61-70',
  'S1/S4: stale task-relevant poll finds no eligible task after waiting; unmodeled no-op polling is not silently allowed to change state.',r'''
    /\ s.runner.kind = "request" /\ s.comm.kind = "free"
    /\ ~\E t \in Tasks : s.wf.open /\ s.task[t].standing /\ s.task[t].status = "LIVE"
                         /\ ~s.ct[t][s.runner.client].receipt
                         /\ (~s.ct[t][s.runner.client].assigned \/
                              (s.ct[t][s.runner.client].delivery = "failed" /\
                               s.ct[t][s.runner.client].result = "none"))
    /\ s' = [s EXCEPT !.runner = EmptyRunner]
''')
A('ServerRunnerCheckTaskActive',['id','n'], 'nvflare/private/fed/server/server_runner.py:585-605,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259',
  'S2/S5: task-check activity reporting releases wf_lock before the separate mapping lookup.',r'''
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "check"
    /\ RunnerLockFree /\ s.mon.pc /= "dead"
    /\ s' = [s EXCEPT !.net[id[1]][id[2]][n] = "checking",
          !.dead[id[2]] = IF s.wf.open THEN [reported |-> FALSE, age |-> 0, disconnected |-> FALSE] ELSE @]
''')
A('ServerRunnerSubmissionActive',[], 'nvflare/private/fed/server/server_runner.py:463-475,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259',
  'S2/S5: admitted submission clears disconnect state while retaining caller wf_lock; dead-report checks may run independently before communicator is acquired.',r'''
    /\ s.runner.kind = "submit" /\ s.runner.pc = "activity" /\ s.mon.pc /= "dead"
    /\ s' = [s EXCEPT !.dead[s.runner.id[2]] = [reported |-> FALSE, age |-> 0, disconnected |-> FALSE],
                     !.runner.pc = "commWait"]
''')
A('WFCommAcquireSubmission',[], 'nvflare/private/fed/server/server_runner.py:559-565; nvflare/apis/impl/wf_comm_server.py:434-451',
  'S2/S3: acquire communicator after caller admission; a newly triggered abort does not retroactively revoke the admitted handler.',r'''
    /\ s.runner.kind = "submit" /\ s.runner.pc = "commWait" /\ s.comm.kind = "free"
    /\ s' = [s EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "submit", !.pc = "dispatch",
                   !.id = s.runner.id, !.attempt = s.runner.attempt], !.runner.pc = "busy"]
''')
A('ServerRunnerDropClosedSubmission',[], 'nvflare/private/fed/server/server_runner.py:463-470; nvflare/private/fed/server/server_commands.py:242-246',
  'S2/S4: closed/done runner returns before activity or communicator dispatch; command ACK remains distinct.',r'''
    /\ s.runner.kind = "submit" /\ s.runner.pc = "closed"
    /\ s' = [s EXCEPT !.net[s.runner.id[1]][s.runner.id[2]][s.runner.attempt] = "handled",
                     !.runner = EmptyRunner]
''')
