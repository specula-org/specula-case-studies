#!/usr/bin/env python3
"""Project raw implementation observations into the documented trace schema.

The only imported spec metadata is event names, argument names and field names.
No guard, transition expression, TLC state, or model update is evaluated here.
All ownership queues, allocation payloads, statuses, reply results, launch
bindings and process maps originate in the raw source probes. PCs label the
observed source continuation; counters count hook occurrences and free calls.
"""
import copy
import json
import math
from pathlib import Path
import sys

H = Path(__file__).resolve().parent.parent
SCHEMA = json.loads((H/'src/event-schema.json').read_text())
SITES = ['site-1', 'site-2']
ATTEMPTS = 11


def status(s):
    return {'FINISHED:COMPLETED':'COMPLETED', 'FINISHED:ABORTED':'ABORTED',
            'FINISHED:FAILED_TO_RUN':'FAILED_TO_RUN', 'FINISHED:CANT_SCHEDULE':'CANT_SCHEDULE', 'FINISHED:EXECUTION_EXCEPTION':'FAILED',
            'FINISHED:ABNORMAL':'FAILED'}.get(s, s)


def empty_client():
    return dict(pc='idle', handle='none', alive=False, spawned=False, binding=[],
                waiter=False, cleanup='none', logical='NOT_STARTED', abortRequested=False,
                terminateRequested=False, pendingAbort=False, attached=False,
                exitObserved=False, exitCode='ok', deployed=False)


def empty_job():
    return dict(status='SUBMITTED', checked='SUBMITTED', dispatch=[], deployed=[], active=[], pending=[],
                outcomeKey=False, serverAlive=False, serverSpawned=False, serverRegistered=False,
                serverWaiter=False, serverFailed=False, serverStop=False, serverTerminated=False,
                running=False, runAborted=False, abortAck=False, adminPC='idle', adminRead='SUBMITTED',
                completion='idle', finishStatus='COMPLETED', archiveFailed=False, terminalPublished=False,
                resurrected=False, completedRemoved=False)


class Observer:
    def __init__(self, receipt):
        self.receipt = receipt
        self.alias = {jid: f'job-{i+1}' for i,jid in enumerate(receipt['job_ids'])}
        self.js = list(self.alias.values())
        self.tokens = [(j,a) for j in self.js for a in range(1,ATTEMPTS+1)]
        self.uuid = {}
        self.requests = {}
        self.streams = {}
        self.core = {}
        self.messages = []
        self.errors = []
        self.records = []
        self.ledger = []
        self.pid_site = {}
        self.empty_pass = False
        self.wait_start = {}
        self.history_time = {}
        self.scheduler = dict(pc='idle', current='', candidates=[], issued={j:0 for j in self.js},
            count={j:0 for j in self.js}, persisted={j:0 for j in self.js}, history={j:[] for j in self.js},
            cooldown={j:False for j in self.js}, scheduled=[], considered={j:0 for j in self.js},
            result='none', failedPending=[], blockedPending=[], returnTo='idle')
        self.jobs = {j:empty_job() for j in self.js}
        self.rm = {s:{'free':[0], 'tokens':[
            dict(job=j, attempt=a, reserved=[], ttl=0, allocated=[], payload=[], releases=0)
            for j,a in self.tokens]} for s in SITES}
        self.client = {s:[dict(job=j,attempt=a,value=empty_client()) for j,a in self.tokens] for s in SITES}
        self.rpc = {s:[dict(job=j,attempt=a,value=dict(check='idle',deploy='idle',start='idle',cancel='idle'))
                      for j,a in self.tokens] for s in SITES}
        self.resourceEnv = {s:[] for s in SITES}

    def token(self, j):
        return (j, self.scheduler['issued'][j])

    def row(self, field, s, t):
        rows = getattr(self,field)[s]
        if field == 'rm':
            rows = rows['tokens']
        return next(x for x in rows if (x['job'],x['attempt'])==tuple(t))

    def value(self, field, s, t):
        return self.row(field,s,t)['value']

    def message(self, kind, s, t):
        return dict(kind=kind, site=s, job=t[0], attempt=t[1])

    def add(self, kind,s,t):
        m=self.message(kind,s,t)
        if m in self.messages:
            self.errors.append(f'duplicate abstract envelope {m}')
        self.messages.append(m)  # retain multiplicity so the strict decoder can reject it

    def remove(self, kind,s,t):
        m=self.message(kind,s,t)
        if m not in self.messages:
            self.errors.append(f'no observed send for receive {m}')
        else:
            self.messages.remove(m)

    def emit(self, name, raw, j=None,s=None,t=None,elapsed=0):
        schema=SCHEMA[name]
        args={k: {'j':j,'s':s,'t':list(t) if t else None}[k] for k in schema['args']}
        fields={k: self.messages if k=='network' else getattr(self,k) for k in schema['fields']}
        out=dict(tag='trace',ts=raw['ts'],event=name,node=s if schema['node']=='s' else 'server',
                 args=args,elapsedSeconds=int(elapsed),post=copy.deepcopy(fields))
        self.records.append(out)
        self.ledger.append(dict(event_line=len(self.records)+1,raw_line=raw['_line'],pid=raw['pid'],
                                tid=raw['tid'],seq=raw['seq'],capture_start_ns=raw['capture_start_ns']))

    def capture_rm(self,d,s):
        actual=d['rm']
        self.rm[s]['free']=list(actual['free']['gpu'])
        for row in self.rm[s]['tokens']:
            row['reserved']=[]
            row['ttl']=0
        for uuid,(payload,ttl) in actual['reserved'].items():
            if uuid not in self.uuid:
                raise ValueError(f'uncorrelated reservation {uuid}')
            site,t=self.uuid[uuid]
            assert site==s
            row=self.row('rm',s,t)
            row['reserved']=payload['gpu']
            # At t==1, the implementation puts the local decremented zero in
            # tokens_to_remove while retaining 1 in its map until pop.
            row['ttl']=0 if uuid in d.get('tokens_to_remove',[]) else ttl

    def parse(self, raw):
        n=raw['event'];d=raw['capture'];q=self.scheduler
        s=d.get('site') or self.pid_site.get(raw['pid'])
        if s in SITES+['server']:
            self.pid_site[raw['pid']]=s
        jid=d.get('job_id') or d.get('jid') or (d.get('job') or {}).get('job_id') or d.get('context_job')
        jid=jid or (d.get('request') or {}).get('job') or (d.get('ready_job') or {}).get('job_id')
        if (n.startswith('DefaultJobScheduler') and n != 'DefaultJobSchedulerJobStarted') or n in ('BackoffObservation','SendCheck'):
            jid=(d.get('job') or {}).get('job_id') or jid
        j=self.alias.get(jid)
        t=self.token(j) if j else None
        if d.get('token') in self.uuid:
            s,t=self.uuid[d['token']];j=t[0]
        if n=='DefaultJobSchedulerBeginPass':
            candidates=[self.alias[x['job_id']] for x in d['job_candidates']]
            self.empty_pass=not candidates
            if self.empty_pass:
                return
            q['candidates']=candidates;q['pc']='scan'
        elif n in ('DefaultJobSchedulerEndPass','DefaultJobSchedulerReturnPass') and self.empty_pass:
            return
        elif n=='DefaultJobSchedulerEndPass':
            q['pc']='persistFailed';q['returnTo']='idle'
        elif n=='DefaultJobSchedulerReturnPass':
            q['pc']=q['returnTo']
        elif n=='DefaultJobSchedulerTryJob':
            q['current']=j;q['issued'][j]+=1;q['considered'][j]+=1;q['pc']='sendCheck'
        elif n=='BackoffObservation':
            if not q['cooldown'][j]:
                return
            q['cooldown'][j]=False
            self.emit('DefaultJobSchedulerBackoffElapsed',raw,j=j,
                      elapsed=math.floor(d['time_since_last_schedule']))
            return
        elif n=='DefaultJobSchedulerSkipBackoff':
            q['candidates'].remove(j)
        elif n=='DefaultJobSchedulerEvaluateResources':
            self.jobs[j]['dispatch']=sorted(d['sites_dispatch_info'])
            minimum=2 if self.receipt['scenario']=='delayed_start' else 1
            success=d['num_sites_ok']>=minimum and not d['required_sites_not_enough_resource']
            q['result']='scheduled' if success else 'no_resource'
            q['pc']='history' if success else 'cancelSend'
        elif n=='DefaultJobSchedulerUpdateHistory':
            meta=d['job']['meta'];q['count'][j]=meta['schedule_count']
            q['history'][j]=['scheduled' if x.endswith(': scheduled') else 'no_resource'
                             for x in meta['schedule_history']]
            q['cooldown'][j]=True
            q['failedPending']=[self.alias[x['job_id']] for x in d['failed_jobs']]
            q['blockedPending']=[self.alias[x['job_id']] for x in d['blocked_jobs']]
            success=d['rc']==0
            q['pc']='persistFailed' if success else 'scan'
            q['returnTo']='checkSubmitted' if success else 'idle'
            if not success:q['candidates'].remove(j)
        elif n=='DefaultJobSchedulerAdmissionException':
            q['pc']='persistFailed';q['returnTo']='idle';q['candidates']=[]
        elif n=='DefaultJobSchedulerPersistFailed':
            q['persisted'][j]=d['job']['meta']['schedule_count']
            q['failedPending'].remove(j)
        elif n=='DefaultJobSchedulerCancelReturned':
            q['pc']='history'
        elif n in ('SendCheck','SendDeploy','SendStart','SendCancel'):
            kind=n[4:]
            names=d.get('client_names',{})
            for req in d.get('requests',[]):
                site=names[req['client_token']]
                if req.get('token') in self.uuid:
                    _,tt=self.uuid[req['token']]
                else:
                    jj=self.alias.get(req['job']) or q['current'];tt=self.token(jj)
                self.requests[(req['id'],site)]=(kind,tt)
                self.add(kind,site,tt)
                self.value('rpc',site,tt)[kind.lower()]='waiting'
            q['pc']={'Check':'checkWait','Deploy':'deployWait','Start':'startWait','Cancel':'cancelWait'}[kind]
            name={'Check':'ServerEngineCheckClientResources','Deploy':'JobRunnerDeployJob',
                  'Start':'ServerEngineStartClientJob','Cancel':'ServerEngineCancelClientResources'}[kind]
            self.emit(name,raw);return
        elif n=='AdminWaitBegin':
            self.wait_start[(raw['pid'],raw['tid'])]=raw['ts'];return
        elif n=='CellWaiterOpened':
            w=d['stream_waiter'];self.streams[w['id']]=(w['admin_id'],w['target']);return
        elif n=='CoreWaiterOpened':
            for w in d['core_waiters']:
                self.core[(w['id'],w['target'])]=(w['admin_id'],w['target'])
            return
        elif n in ('CoreReplyAccepted','CoreLateReplyDiscarded'):
            r=d['core_reply'];key=self.core.get((r['id'],r['target']))
            if key not in self.requests:return
            kind,t=self.requests[key];s=key[1]
            ok=(r['body']['__headers__'].get('_is_resource_enough',False) if kind=='Check' else
                not (isinstance(r['body'],str) and r['body'].startswith('NVFLARE_ERROR')))
            suffix=('OK' if ok else 'No') if kind!='Cancel' else 'Ack'
            self.remove(kind+suffix,s,t)
            slot=self.value('rpc',s,t)
            if slot[kind.lower()]=='waiting':slot[kind.lower()]='ok' if ok else 'no'
            self.emit('ServerEngineReceive'+kind+suffix,raw,s=s,t=t);return
        elif n=='CellLateReplyDiscarded':
            key=self.streams.get(d['stream_id'])
            if key not in self.requests:return
            kind,t=self.requests[key];s=key[1]
            candidates=[m for m in self.messages if m['site']==s and (m['job'],m['attempt'])==t
                        and m['kind'] in (kind+'OK',kind+'No',kind+'Ack')]
            if len(candidates)!=1:raise ValueError(f'cannot correlate late reply {key}')
            m=candidates[0];self.remove(m['kind'],s,t)
            self.emit('ServerEngineReceive'+m['kind'],raw,s=s,t=t);return
        elif n=='AdminReply':
            if raw['source'][0]['file']=='private/fed/server/admin.py':
                return  # reply-dict projection, same already observed waiter result
            r=d['reply'];s=r['site'];key=(r['request_id'],s)
            if key not in self.requests:
                if r['topic']=='train.abort':return
                raise ValueError(f'uncorrelated admin reply {r}')
            kind,t=self.requests[key];j=t[0]
            if r['present']:
                if key in self.core.values():return  # already observed at the actual waiter mutation
                if kind=='Check':ok=r['body']['__headers__'].get('_is_resource_enough',False)
                else:ok=not(isinstance(r['body'],str) and r['body'].startswith('NVFLARE_ERROR'))
                suffix=('OK' if ok else 'No') if kind!='Cancel' else 'Ack'
                self.remove(kind+suffix,s,t)
                slot=self.value('rpc',s,t)
                if slot[kind.lower()]=='waiting':slot[kind.lower()]='ok' if ok else 'no'
                self.emit('ServerEngineReceive'+kind+suffix,raw,s=s,t=t)
            else:
                elapsed=(raw['ts']-self.wait_start[(raw['pid'],raw['tid'])])//1_000_000_000
                for site in SITES:
                    slot=self.value('rpc',site,t)
                    if slot[kind.lower()]=='waiting':slot[kind.lower()]='timeout'
                self.emit('Admin'+kind+'Timeout',raw,t=t,elapsed=elapsed)
            return
        elif n=='CheckResourceProcessorReserve':
            self.uuid[d['token']]=(s,t)
            self.capture_rm(d,s)
            self.remove('Check',s,t);self.add('CheckOK',s,t)
        elif n=='ResourceCheckReturned':
            if d['is_resource_enough']:return
            self.remove('Check',s,t);self.add('CheckNo',s,t)
            self.emit('CheckResourceProcessorUnavailable',raw,s=s,t=t);return
        elif n=='AutoCleanResourceManagerTick':
            if not d['rm']['reserved']:return
            self.capture_rm(d,s)
            self.emit(n,raw,s=s,elapsed=d['tick_elapsed_ns']//1_000_000_000);return
        elif n=='AutoCleanResourceManagerFinishExpiry':
            self.capture_rm(d,s)
        elif n=='CancelResourceProcessorCancel':
            self.capture_rm(d,s)
            self.remove('Cancel',s,t);self.add('CancelAck',s,t)
        elif n=='StartJobProcessorAllocate':
            self.capture_rm(d,s)
            row=self.row('rm',s,t);row['allocated']=d['result']['gpu'];row['payload']=d['result']['gpu']
            self.value('client',s,t)['pc']='allocated';self.remove('Start',s,t)
        elif n=='StartJobProcessorRejectToken':
            self.value('client',s,t)['pc']='error';self.remove('Start',s,t);self.add('StartNo',s,t)
        elif n=='ClientDeploySuccess':
            self.value('client',s,t)['deployed']=True
            self.remove('Deploy',s,t);self.add('DeployOK',s,t)
        elif n=='ClientDeployError':
            self.remove('Deploy',s,t);self.add('DeployNo',s,t)
        elif n=='ListResourceConsumerConsume':
            self.resourceEnv[s]=[int(x) for x in d['cuda'].split(',') if x]
            self.value('client',s,t)['pc']='consumed'
        elif n=='ClientEngineStartAppCheck':
            self.value('client',s,t)['pc']='checked'
        elif n=='JobExecutorRegisterPendingHandle':
            c=self.value('client',s,t);entry=d['client_processes'][jid]
            c.update(pc='registered',handle=entry['handle'],logical='STARTING')
        elif n=='ProcessJobLauncherSnapshotEnvironment':
            if s=='server':return
            self.value('client',s,t).update(pc='snapshotted',binding=[int(x) for x in d['copied_cuda'].split(',') if x])
        elif n=='ProcessJobLauncherSpawn':
            if s=='server':return
            assert d['spawn_pid']>0
            self.value('client',s,t).update(pc='spawned',alive=True,spawned=True)
        elif n=='ProcessJobLauncherSpawnException':
            self.value('client',s,t).update(pc='rollback',handle='none')
        elif n=='JobExecutorPrepareException':
            self.value('client',s,t)['pc']='rollback'
        elif n=='PendingJobHandleAttach':
            c=self.value('client',s,t)
            c.update(pc='attachedAbort' if d['heartbeat_cleanup'] is not None else 'attached',
                     handle=d['client_processes'][jid]['handle'],attached=True)
        elif n=='JobExecutorApplyPendingAbort':
            self.value('client',s,t).update(pc='attached',terminateRequested=True)
        elif n=='JobExecutorAfterJobLaunchEvent':
            self.value('client',s,t)['pc']='afterEvent'
        elif n=='JobExecutorInstallCleanupWaiter':
            self.value('client',s,t).update(pc='replyReady',waiter=True,cleanup='wait')
        elif n=='StartProcessorReply':
            if isinstance(d.get('result'),str) and d['result'].startswith('NVFLARE_ERROR'):return
            self.value('client',s,t)['pc']='returned';self.add('StartOK',s,t)
            self.emit('StartJobProcessorReplySuccess',raw,s=s,t=t);return
        elif n=='JobExecutorNotifyStatus':
            value={0:'NOT_STARTED',1:'STARTING',2:'STARTED',3:'STOPPED'}[d['job_status']]
            self.value('client',s,t)['logical']=value
            self.emit('JobExecutorNotifyStarted' if value=='STARTED' else 'JobExecutorNotifyStopped',raw,s=s,t=t);return
        elif n=='ClientChildExitObserved':
            self.value('client',s,t)['alive']=False
            self.emit('ClientChildExit',raw,s=s,t=t);return
        elif n=='JobExecutorWaitChildExit':
            self.value('client',s,t).update(exitObserved=True,cleanup='report')
        elif n=='JobExecutorReportOutcome':
            self.value('client',s,t)['cleanup']='reportWait'
            self.add('OutcomeOK' if d['failure_reason'] is None else 'OutcomeFailed',s,t)
        elif n in ('JobExecutorOutcomeReportReturned','JobExecutorOutcomeReportException'):
            self.value('client',s,t)['cleanup']='free'
        elif n=='ResourceFree':
            self.capture_rm(d,s)
            row=self.row('rm',s,t);row['allocated']=[];row['releases']+=1
            cleanup=any(x['function']=='_wait_child_process_finish' for x in raw['source'])
            if cleanup:
                self.value('client',s,t)['cleanup']='pop'
                self.emit('JobExecutorFreeAfterExit',raw,s=s,t=t)
            else:
                self.value('client',s,t)['pc']='error';self.add('StartNo',s,t)
                self.emit('StartJobProcessorRollback',raw,s=s,t=t)
            return
        elif n=='JobExecutorRemoveProcess':
            assert jid not in d['client_processes']
            self.value('client',s,t).update(handle='none',cleanup='event')
        elif n=='JobExecutorJobCompletedEvent':
            self.value('client',s,t)['cleanup']='done'
        elif n=='JobRunnerCheckStatus':
            read=status(d['reload_job']['meta']['status']);self.jobs[j]['checked']=read
            submitted=d['job_run_status']=='SUBMITTED'
            q['pc']=('deploySend' if submitted else 'serverSpawn') if read==d['job_run_status'] else 'idle'
            self.emit('JobRunnerCheckSubmitted' if submitted else 'JobRunnerCheckDispatched',raw);return
        elif n=='JobRunnerEvaluateDeployment':
            self.jobs[j]['deployed']=sorted(set(d['client_token_to_name'].values())-set(d['failed_clients']))
            q['pc']='failRemove' if d['abort_job'] else 'writeDispatched'
        elif n=='JobRunnerWriteDispatched':
            self.jobs[j]['status']='DISPATCHED';q['pc']='persistDeploy'
        elif n=='JobRunnerPersistDeploy':
            q['persisted'][j]=d['ready_job']['meta']['schedule_count'];q['pc']='checkDispatched'
        elif n=='ServerEngineSpawnJob':
            self.jobs[j].update(serverAlive=True,serverSpawned=True);q['pc']='serverRegister'
        elif n=='ServerEngineRegisterJob':
            self.jobs[j]['serverRegistered']=jid in d['server_processes'];q['pc']='serverWaiter'
        elif n=='ServerEngineInstallWaiter':
            self.jobs[j]['serverWaiter']=True;q['pc']='pendingOutcomes'
        elif n=='JobRunnerSetPendingOutcomes':
            self.jobs[j]['pending']=sorted(d['pending_outcomes'][jid]);self.jobs[j]['outcomeKey']=True
            q['pc']='startSend'
        elif n=='JobRunnerEvaluateStartReplies':
            self.jobs[j]['active']=sorted(d['active_client_sites']);q['pc']='filterOutcomes'
        elif n=='JobRunnerStartReplyError':
            self.jobs[j]['active']=sorted(d['active_client_sites']);q['pc']='failRemove'
            self.emit('JobRunnerEvaluateStartReplies',raw);return
        elif n=='JobRunnerFilterPendingOutcomes':
            self.jobs[j]['pending']=sorted(d['pending_outcomes'][jid]);q['pc']='startedEvent'
        elif n=='DefaultJobSchedulerJobStarted':
            q['scheduled']=[self.alias[x] for x in d['scheduled_jobs']];q['pc']='registerRunning'
        elif n=='JobRunnerRegisterRunning':
            self.jobs[j]['running']=jid in d['running_jobs'];q['pc']='writeRunning'
        elif n=='JobRunnerWriteRunning':
            self.jobs[j]['status']='RUNNING'
            self.jobs[j]['resurrected'] |= self.jobs[j]['terminalPublished'];q['pc']='idle'
        elif n=='JobRunnerStartupException':
            previous=q['pc'];q['pc']='failRemove'
            if previous=='failRemove':return
            if previous=='startWait':
                # check_client_replies raised before active participant selection.
                # Do not manufacture a source active-client list from model logic.
                self.emit('JobRunnerEvaluateStartReplies',raw)
            else:
                self.emit('JobRunnerDeploymentException' if previous in ('deploySend','deployWait')
                          else 'JobRunnerStartupStoreError',raw)
            return
        elif n=='JobRunnerFailureRemove':
            self.jobs[j].update(running=jid in d['running_jobs'],pending=sorted(d['pending_outcomes'].get(jid,[])),
                                outcomeKey=jid in d['pending_outcomes'])
            q['pc']='failStop'
        elif n=='JobRunnerFailureStop':
            self.jobs[j]['serverStop']=jid in d['server_processes']
            q['pc']='failStatus'
        elif n=='JobRunnerFailureStatus':
            self.jobs[j]['status']='FAILED_TO_RUN';q['pc']='failEvent'
        elif n=='JobCommandAbortRead':
            self.jobs[j].update(adminRead=status(d['job_status']),adminPC='read')
        elif n=='JobCommandAbortPreRunWrite':
            self.jobs[j].update(status='ABORTED',adminPC='ackPreRun')
        elif n=='JobCommandAbortPreRunAcknowledge':
            self.jobs[j].update(abortAck=True,adminPC='idle')
        elif n=='JobCommandAbortAlreadyTerminal':
            self.jobs[j]['adminPC']='idle'
        elif n=='JobCommandAbortRunning':
            self.jobs[j].update(serverStop=jid in d['server_processes'],adminPC='markAborted')
        elif n=='SendStop':
            for site in d['client_sites']:self.add('Stop',site,t)
            self.errors.append(f'raw {raw["_line"]}: actual Stop send precedes blocking stop return; model needs split action')
            return
        elif n=='JobRunnerMarkAborted':
            self.jobs[j].update(runAborted=d['job']['run_aborted'],adminPC='idle')
        elif n=='ClientEngineAbortApp':
            c=self.value('client',s,t);entry=d['client_processes'].get(jid)
            if entry:
                c['abortRequested']=entry['abort_requested']
                c['pendingAbort'] |= entry['pending_abort'] is not None
                c['terminateRequested'] |= entry['handle']=='attached' and entry['status']==1
            # Without the separately observed send, report the missing hook;
            # do not silently synthesize a Stop envelope.
            self.remove('Stop',s,t)
        elif n=='JobExecutorTerminateAfterGrace':
            self.value('client',s,t)['terminateRequested']=True
            self.emit(n,raw,s=s,t=t,elapsed=math.floor(d['observed_elapsed_s']));return
        elif n=='ServerChildExitObserved':
            self.jobs[j]['serverAlive']=False;self.emit('ServerChildExit',raw,j=j);return
        elif n=='ServerEngineObserveExit':
            self.jobs[j]['serverRegistered']=jid in d['server_processes']
        elif n=='ServerEngineReceiveOutcome':
            s=d['client_name'];t=self.token(j)
            if any(f['function']=='_resolve_missing_client_outcome' for f in raw['source']):
                self.errors.append(f'raw {raw["_line"]}: heartbeat resolves missing client outcome without an Outcome message; missing model action')
            self.remove('OutcomeOK',s,t)
            self.jobs[j]['pending']=sorted(d['pending_outcomes'].get(jid,[]))
        elif n in ('JobRunnerCompletionReady','JobRunnerCompletionWaiting'):
            x=self.jobs[j]
            waiting=n.endswith('Waiting')
            if x['completion']=='outcomeWait' and not waiting:
                x['completion']='classify';self.emit('JobRunnerOutcomesResolved',raw,j=j)
            elif x['completion']=='idle':
                x['completion']='outcomeWait' if waiting else 'classify'
                self.emit('JobRunnerSelectCompletion',raw,j=j)
            return
        elif n=='JobRunnerClassifyCompletion':
            self.jobs[j].update(finishStatus=status(d['finished_states'][jid]['status']),completion='archive')
        elif n=='JobRunnerArchiveSuccess':
            self.jobs[j]['completion']='publish'
        elif n=='JobRunnerPublishTerminal':
            self.jobs[j].update(status=status(d['status']),terminalPublished=True,completion='remove')
        elif n=='JobRunnerRemoveCompleted':
            self.jobs[j].update(running=jid in d['running_jobs'],pending=sorted(d['pending_outcomes'].get(jid,[])),
                outcomeKey=jid in d['pending_outcomes'],completedRemoved=True,
                completion='abortedEvent' if status(d['status'])=='ABORTED' else 'completedEvent')
        elif n=='SchedulerJobRemoved':
            q['scheduled']=[self.alias[x] for x in d['scheduled_jobs']]
            if d['event_type']=='_job_completed':
                self.jobs[j]['completion']='done';self.emit('DefaultJobSchedulerJobCompleted',raw,j=j)
            elif self.jobs[j]['completedRemoved']:
                self.jobs[j]['completion']='completedEvent';self.emit('DefaultJobSchedulerJobAbortedOnCompletion',raw,j=j)
            else:
                q['pc']='idle';self.emit('DefaultJobSchedulerJobAbortedOnStartFailure',raw)
            return
        else:
            # Non-semantic probes remain in provenance. Never relabel an unknown
            # semantic action as a matched action or invent a missing transition.
            return
        self.emit(n,raw,j=j,s=s,t=t)

    def run(self):
        rows=[json.loads(line) for line in Path(self.receipt['raw']).read_text().splitlines()]
        for raw in rows:
            site=raw['capture'].get('site')
            if site in SITES+['server']:self.pid_site[raw['pid']]=site
        for i,raw in enumerate(rows,1):
            raw['_line']=i
            if raw['ts']>self.receipt['finish_ns']:
                continue  # fixture teardown is outside this scenario's observation interval
            self.parse(raw)
        meta=next(iter(self.receipt['status'].values()))
        manifest=dict(tag='config',sourceRevision=self.receipt['sourceRevision'],
            resourceManager='ListResourceManager',resourceConsumer='ListResourceConsumer',launcher='ProcessJobLauncher',
            jobOrder=self.js,sites=SITES,pool=[0],requiredSites=meta.get('mandatory_clients',[]),
            minSites=meta['min_clients'],strictStart=False,maxJobs=2,maxScheduleCount=10,minScheduleInterval=10,
            maxScheduleInterval=600,attemptSlots=ATTEMPTS,reservationTTL=30,outcomeGrace=900,archiveGrace=60,demandPerJobSite=1)
        name=self.receipt['scenario']
        path=H.parent/'traces'/f'{name}.ndjson'
        with path.open('w') as out:
            for row in [manifest]+self.records:out.write(json.dumps(row,separators=(',',':'))+'\n')
        sidecar=dict(receipt=self.receipt,job_aliases=self.alias,token_aliases=self.uuid,
                     core_waiters=[{'waiter':k[0],'site':k[1],'request_id':v[0]} for k,v in self.core.items()],
                     hooks=self.ledger,projection_errors=self.errors)
        (H.parent/'traces'/f'{name}.provenance.json').write_text(json.dumps(sidecar,indent=2))
        print(f'{name}: {len(self.records)} semantic events; {len(self.errors)} projection errors')
        return not self.errors


if __name__=='__main__':
    receipts=sys.argv[1:] or sorted((H/'logs').glob('*.receipt.json'))
    ok=True
    for path in receipts:ok=Observer(json.loads(Path(path).read_text())).run() and ok
    sys.exit(0 if ok else 2)
