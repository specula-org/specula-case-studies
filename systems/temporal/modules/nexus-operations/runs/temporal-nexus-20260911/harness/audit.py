#!/usr/bin/env python3
"""Check raw-observation integrity without evaluating or reproducing model actions."""
import collections,copy,datetime,hashlib,json,pathlib,re,sys
H=pathlib.Path(__file__).resolve().parent
T=H.parent/'traces'

def check(rows):
    assert rows, 'empty recording'
    assert rows[0]['event']=='Init', 'missing Init'
    cfg=rows[0]['raw']
    assert cfg['sourceRevision']=='0c010ce5fe8c0180aa7573c72fe8fc87c6df7025'
    assert cfg['recordingKind']=='implementation-raw'
    assert cfg['backend']=='sqlite' and cfg['connect_attributes']=={'mode':'memory','cache':'shared'}
    assert cfg['route']=='legacy-hsm' and cfg['transitionHistory'] and cfg['cancelAckEvents']
    assert cfg['outboundBatchSize']>0 and not cfg['chasmWorkflowOperations'] and cfg['chasmRollout']==0
    assert any(x['event']=='ScenarioEnd' for x in rows), 'missing completion marker'
    required={
     'early_callback':['StartSaveRejected'],
     'response_loss':['LoseResponse','handleStartOperationErrorRetryable'],
     'start_retry':['EndpointStartFailure','executeBackoffTask'],
     'definite_failure':['PersistenceFault'], 'execute_timeout':['PersistenceFaultUnderlyingResult','LoseShard','ReacquireShard'],
     'start_definite_failure':['PersistenceFault'], 'start_execute_timeout':['PersistenceFaultUnderlyingResult','LoseShard','ReacquireShard'],
     'deferred_cancel':['HandleCancelCommand','saveCancelationResultAck','RefreshWorkflowTasks','executeOperationTimeout'],
     'timeout_capacity':['HandleScheduleCommandLimit','executeOperationTimeout'],
     'below_min':['executeInvocationTaskBelowMin','handleStartOperationErrorBelowMin'],
     'cancel_retry':['EndpointCancelFailure','executeCancelationBackoffTask','saveCancelationResultAck'],
     'cancel_refused':['EndpointCancelFailure','saveCancelationResultFailed'],
     'cancel_below_min':['executeCancelationTaskBelowMin','saveCancelationResultFailed'],
     'stale_timer':['SkipStaleTimer'],
    }
    observed={r['event'] for r in rows}
    assert set(required.get(cfg['scenario'],[]))<=observed, 'scenario did not trigger its required boundaries'
    previous=None
    sends=[]; accepted=[]; cancel_sends=[]; cancel_outcomes=[]; loads={}; queue=collections.defaultdict(list); durable={}
    staged={}; commits=collections.defaultdict(list)
    for ordinal,row in enumerate(rows,1):
        assert row['tag']=='trace', 'missing trace tag'
        assert row['sequence']==ordinal, 'missing, reordered, or duplicate raw receipt'
        ts=datetime.datetime.fromisoformat(row['ts'].replace('Z','+00:00'))
        assert ts.year>=2026, 'timestamp is not from the real clock'
        assert previous is None or ts>=previous, 'clock order'
        previous=ts
        event=row['event']; r=row['raw'] or {}; key=(row['namespace'],row['workflow'],row['run'])
        if event=='executeInvocationTask':
            sends.append(row)
        elif event in ('EndpointAccept','EndpointStartFailure'):
            assert len(accepted)<len(sends),'endpoint outcome without send'
            sent=sends[len(accepted)]['raw']
            options=sent['observation']['options']; endpoint=r['options']
            assert options['RequestID']==endpoint['RequestID'], 'wire request ID mismatch'
            sourceHeaders={k.lower():v for k,v in options['CallbackHeader'].items()}
            destHeaders={k.lower():v for k,v in endpoint['CallbackHeader'].items()}
            assert sourceHeaders==destHeaders, 'wire callback header mismatch'
            if 'callback_ref' in r:
                assert r['callback_ref']['request_id']==options['RequestID'],'decoded callback request ID mismatch'
                assert r['callback_ref']['ref']['machine_initial_versioned_transition']==sent['ref']['machine_initial_versioned_transition'], 'wire initial ref mismatch'
            accepted.append(row)
        elif event=='executeCancelationTask':
            cancel_sends.append(row)
        elif event in ('EndpointCancelAck','EndpointCancelFailure'):
            assert len(cancel_outcomes)<len(cancel_sends),'cancel outcome without a request'
            sent=cancel_sends[len(cancel_outcomes)]['raw']['observation']
            assert sent['token']==r['token'],'cancel wire token mismatch'
            cancel_outcomes.append(row)
        elif event=='PersistenceWriteRequest':
            staged[key]=r
        elif event=='PersistenceReadback':
            if r.get('readback_id'): loads[r['readback_id']]=r
        elif event=='QueueRead' and r.get('readback_id'):
            queue[r['readback_id']].append({k:r[k] for k in ('task','category','task_id','visibility_time')})
        elif event=='UpdateWorkflowExecution':
            assert r['read_error'] is None and not r.get('queue_error'),'incomplete backend readback'
            readID=r['readback_id']
            assert readID in loads,'missing independent persistence receipt'
            assert r['state']==loads[readID]['state'],'database evidence mismatch'
            assert r['db_record_version']==loads[readID]['db_record_version'],'database version mismatch'
            expected=sorted(queue[readID],key=lambda x:(x['category'],x['task_id']))
            actual=sorted(r['queue_rows'],key=lambda x:(x['category'],x['task_id']))
            assert actual==expected,'queue evidence mismatch'
            if r['write_error'] is None:
                assert r['expected_new_version']==r['db_record_version'],'successful write version mismatch'
                # Compare the independently read HSM/timer tree to the submitted write.
                info=r['state']['mutable_state']['execution_info']
                assert info['sub_state_machines_by_type']==staged[key]['execution_info']['sub_state_machines_by_type'],'persisted HSM mismatch'
                assert info['state_machine_timers']==staged[key]['execution_info']['state_machine_timers'],'persisted timers mismatch'
                commits[key].append(row['sequence'])
            durable[key]=r['state']
        elif event=='ReceiveCompletionReply' and r['error'] is None:
            assert key in durable,'Accepted without a durable receipt'
            # Each callback here is a success completion. Deletion is independently read.
            assert not durable[key]['operations'],'Accepted before completion commit'
        elif event=='ScenarioEnd':
            assert r['start_calls']==len(accepted), 'endpoint start ledger incomplete'
            assert r['cancel_calls']==len(cancel_outcomes),'endpoint cancellation ledger incomplete'
    assert len(sends)==len(accepted),'outgoing sends lack endpoint observations'
    assert len(cancel_sends)==len(cancel_outcomes),'cancel sends lack endpoint observations'
    assert len(sends)==sum(r['event']=='ReceiveStartResponse' for r in rows),'outgoing calls did not finish'
    assert sum(r['event']=='SendCompletionCallback' for r in rows)==sum(r['event']=='ReceiveCompletionReply' for r in rows),'callback receipts incomplete'
    assert all(x['raw'].get('read_error') is None for x in rows if x['event']=='UpdateWorkflowExecution')
    return {'rows':len(rows),'events':dict(collections.Counter(x['event'] for x in rows)),
            'workflow_runs':sorted({(x['workflow'],x['run']) for x in rows if x['workflow']}),
            'successful_write_receipts':sum(map(len,commits.values())),
            'endpoint_outcomes':len(accepted)}

def negatives(data):
    out=H/'evidence'/'negative-controls';out.mkdir(parents=True,exist_ok=True)
    controls=[]
    def one(name,scenario,mutate):
        rows=copy.deepcopy(data[scenario]);mutate(rows)
        path=out/f'{name}.ndjson'
        path.write_text(''.join(json.dumps(r,separators=(',',':'))+'\n' for r in rows))
        try: check(rows)
        except (AssertionError,KeyError,TypeError,ValueError) as e:
            controls.append({'name':name,'source':scenario,'status':'REJECTED','reason':str(e),'path':str(path)})
        else: raise AssertionError(f'negative control accepted: {name}')
    def first(rows,event):return next(r for r in rows if r['event']==event)
    one('wire-request-id','healthy_async',lambda rs:first(rs,'executeInvocationTask')['raw']['observation']['options'].__setitem__('RequestID','incorrect-observation'))
    one('wire-initial-ref','healthy_async',lambda rs:first(rs,'executeInvocationTask')['raw']['ref']['machine_initial_versioned_transition'].__setitem__('transition_count','999999'))
    def remove_timer(rs):
        row=next(r for r in rs if r['event']=='UpdateWorkflowExecution' and r['raw']['state']['mutable_state']['execution_info']['state_machine_timers'])
        row['raw']['state']['mutable_state']['execution_info']['state_machine_timers']=[]
    one('missing-persisted-timer','healthy_timeout',remove_timer)
    one('queue-evidence','healthy_async',lambda rs:first(rs,'UpdateWorkflowExecution')['raw'].__setitem__('queue_rows',[]))
    one('database-evidence','healthy_async',lambda rs:first(rs,'UpdateWorkflowExecution')['raw'].__setitem__('db_record_version',99999))
    def false_accept(rs):
        idx=next(i for i,r in enumerate(rs) if r['event']=='UpdateWorkflowExecution' and r['raw']['write_error'])
        caller=copy.deepcopy(first(rs,'ReceiveCompletionReply'));caller['raw']['error']=None;caller['ts']=rs[idx]['ts']
        rs.insert(idx+1,caller)
        for n,row in enumerate(rs,1):row['sequence']=n
    one('accepted-after-definite-noncommit','definite_failure',false_accept)
    one('removed-event','healthy_async',lambda rs:rs.pop(5))
    one('unmatched-suffix','healthy_async',lambda rs:rs.append(copy.deepcopy(rs[2])))
    one('empty','healthy_async',lambda rs:rs.clear())
    (H/'evidence'/'negative-controls.json').write_text(json.dumps({'kind':'deliberately-corrupted raw observations; never implementation traces','results':controls},indent=2)+'\n')
    return controls

def main():
    files=sorted(T.glob('*.ndjson'));assert files
    data={p.stem:[json.loads(x) for x in p.read_text().splitlines()] for p in files}
    report={}
    for p in files:
        report[p.stem]={**check(data[p.stem]),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
    controls=negatives(data)
    trace=(H.parent/'spec'/'Trace.tla').read_text()
    expected=set(re.findall(r'IsEvent\("([^"]+)"\)',trace))
    observed=set().union(*(set(x['events']) for x in report.values()))
    assert "s' = DecodeState(logline.post)" in trace,'L2 full-state check absent'
    assert 'ValidatePostState ==\n    TRUE' not in trace,'L2 stub'
    report_object={'recording_kind':'implementation-raw','raw_integrity':'PASS','scenario_count':len(report),
     'negative_controls_rejected':len(controls),'scenarios':report,
     'observed_spec_event_names':sorted(expected&observed),'unobserved_spec_event_names':sorted(expected-observed),
     'raw_receipt_names':sorted(observed-expected),
     'L2_spec_check':'full equality of every semantic post field; every action wrapper invokes ValidatePostState',
     'strict_trace_ready':False,'strict_trace_gap':'Raw receipts have not been joined into the complete semantic post schema. No completeness assertion or model-derived state is manufactured.'}
    (H/'evidence'/'trace-audit.json').write_text(json.dumps(report_object,indent=2)+'\n')
    print(f'{len(report)} raw recordings checked; {len(controls)} corrupted-observation controls rejected; {len(expected&observed)}/{len(expected)} spec event names observed. Strict Trace replay remains INCOMPLETE.')
if __name__=='__main__':main()
