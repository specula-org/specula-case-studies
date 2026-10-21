#!/usr/bin/env python3
"""Decode observations, preserving per-stream order and production lock handoffs.

This decoder never calls model actions. Branch locals and protected vector views
supply every post-state field. Iterator and callback suffixes are observation
views, reconstructed only from their recorded visits and returned results.
"""
import collections, hashlib, itertools, json, os, pathlib, re, subprocess
H=pathlib.Path(__file__).resolve().parent
OUT=H.parent
EVENTS={int(k):v for k,v in json.loads((H/'events.json').read_text()).items()}
PIN='0c60537098f4c2949ad2d382aaf499de72263d76'
TREE='4693fdec88cd7da14bed4f1541eba593f123059c'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def result(n):return {0:'OK',10001:'EAGAIN',10002:'ETIMEDOUT',10003:'ERESTARTSYS'}.get(n,'INVALID')
def own(kind,value=0):return [kind,value]
def key(n):
    if n not in (1,2,3):raise ValueError(f'unscoped key {n}')
    return 'ABC'[n-1]
def queue(q):
    n=next((i for i,g in enumerate(q) if not g),len(q))
    if any(q[n:]):raise ValueError('Unscoped generation or hole in protected queue view')
    return q[:n]
def normalize(log):
    lines=log.read_text(errors='replace').splitlines()
    begins=[l for l in lines if l.startswith('SPECULA_BEGIN ')]
    assert len(begins)==1,(log,begins)
    _,case,ncpu,nbuckets=begins[0].split();case=int(case);ncpu=int(ncpu);nbuckets=int(nbuckets)
    assert ncpu>=2
    assert f'SPECULA_END {case}' in lines
    assert f'SPECULA_USER_DONE {case}' in lines
    raw=[]; keys={}; buffers={};final_counts={};threads={}
    for line in lines:
        if line.startswith('SPECULA_THREAD '):
            _,p,tid=line.split();threads[f'p{p}']=int(tid)
        if line.startswith('SPECULA_KEY '):
            _,k,a,b,v,w=line.split();keys[key(int(k))]=dict(address=int(a),bucket=int(b),vmar=int(v),initial=int(w))
        if line.startswith('SPECULA_BUFFER '):
            _,p,n,lost=line.split();buffers[int(p)]=(int(n),int(lost));assert int(lost)==0
        if line.startswith('SPECULA_FINAL_COUNT '):
            _,p,n=line.split();final_counts[int(p)]=int(n)
        if line.startswith('SPECULA_RAW '):
            nums=list(map(int,line.split()[1:]));assert len(nums)==34
            p,seq,*r=nums;event=EVENTS[r[0]]
            raw.append(dict(pid=f'p{p}',stream=p,raw_seq=seq,event=event,start=r[1],end=r[2],cpu=r[3],id=r[4],data=r[6:6+r[5]],q=queue(r[16:32])))
    assert raw
    identity=json.loads((H/'logs/instrumentation-identity.json').read_text())
    assert f'SPECULA_ID {identity["build_id"]}' in lines
    images=(H/'logs'/f'images-{case}.sha256').read_text().strip().splitlines()
    assert images,'No built kernel image hash'
    for p,(n,lost) in buffers.items():
        assert final_counts[p]==n,'Late trace write after freeze'
        rows=[r for r in raw if r['stream']==p]
        assert [r['raw_seq'] for r in rows]==list(range(1,n+1))
    assert len({v['vmar'] for v in keys.values()})==1
    assert all(v['address']%4==0 for v in keys.values())
    # Raw files retain the measured intervals, including every auxiliary observation.
    rawdir=H/'raw'/f'case-{case:02}';rawdir.mkdir(parents=True,exist_ok=True)
    for p in buffers:
        rows=[dict(tag='trace',**r) for r in raw if r['stream']==p]
        if rows:(rawdir/f'p{p}.ndjson').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    sync_edges=[]
    waits={};calls={};duration_by_pid={};events=[];lock_acquires=[];lock_releases={};heap=[];timer_acquires=[];timer_releases={}
    clock_reads=[r['data'][1] if r['event'] in ('TimerSetClock','PauseTimeoutClock') else r['data'][0] for r in raw if r['event'] in ('TimerSetClock','PauseTimeoutClock','TimerCollectClock','ClockAdvance')]
    origin=min(clock_reads,default=0)
    unpark=[r for r in raw if r['event'] in ('FutexWakeUnpark','TimerCallbackUnpark')]
    total_stores=0
    for pid,rows_iter in itertools.groupby(raw,key=lambda r:r['pid']):
        rows=list(rows_iter);local_wait={};local_call={};batch=None;ready=[];pending=[];sample=0
        for ri,r in enumerate(rows):
            n=r['event'];d=r['data'];ident=r['id'];g=None;c=None;st=None;args=None
            if n in ('HarnessJoin','HarnessEnrolled'):
                sync_edges.append((pid,r['raw_seq'],n,d));continue
            if n=='WaitInput':duration_by_pid[pid]=dict(timed=bool(d[0]),ticks=d[1]);continue
            if n in ('QueueView','TimerContext','KeyIdentity','ControlInput','UserWord','Attempt','HeapView'):
                assert not d or d[0]!=19999,(case,n,'overflow')
                continue
            if n=='ParkReturn':
                g=d[0];w=local_wait[g];park=w['park']
                if park['data'][1]:continue
                possible=[u for u in unpark if u['data'][0]==g and u['start']<=r['end'] and u['end']>=park['start']]
                if possible:continue
                n='WaiterSpuriousReturn';r=dict(r,event=n)
            if n=='SysFutexWait':
                g,k,b,v=d;v &= 0xffffffff
                w=dict(key=key(k),bucket=b,duration=duration_by_pid[pid],pid=pid)
                waits[g]=w;local_wait[g]=w
                args=dict(g=g,k=w['key'],v=v,d=w['duration'])
                st=dict(pc='lock',key=w['key'],original=b,expected=v,duration=w['duration'],entryKey=w['key'],owner=own('local'))
            elif n=='SysFutexControl':
                c=ident;kind,src,dst,nw,nm,effective,sb,db=d
                o=dict(kind='requeue' if kind else 'wake',src=key(src),dst=key(dst),sb=sb,db=db,moves=0,index=1,pid=pid,actor=pid)
                calls[c]=o;local_call[c]=o
                args=dict(c=c,a=pid,kind=o['kind'],src=o['src'],dst=o['dst'],nw=nw,nm=nm)
                st=dict(pc='lockFirst',actor=[pid],kind=o['kind'],src=o['src'],dst=o['dst'],rawWake=nw,rawMove=nm,effective=effective,activeCall=c)
            elif n.startswith('TimerCollect'):
                if n=='TimerCollectClock':
                    batch=r['raw_seq'];sample=d[0]-origin;ready=[];args=dict(t=sample,batch=0)
                    st=dict(active=True,sample=sample,now=sample,ready=[])
                elif n=='TimerCollect':
                    g=d[0];assert d[1]==batch
                    ready=r['q'];args=dict(g=g,batch=0)
                    st=dict(callback='done' if d[3] else 'collected',timerState='cancelled' if d[3] else 'expired',sample=d[2]-origin,ready=ready.copy())
                else:
                    assert d[0]==batch
                    ready=r['q'];pending=ready.copy();args=dict(batch=0)
                    st=dict(active=False,sample=d[1]-origin,ready=ready.copy(),callbackStates=['due']*len(ready),pending=pending.copy())
            elif n.startswith('TimerCallback'):
                g=d[0];args=dict(g=g,batch=0);assert pending and pending[0]==g,(n,pending,g)
                if n=='TimerCallbackUpgrade':
                    if not d[1]:pending=pending[1:]
                    st=dict(callback='ref' if d[1] else 'done',callbackRef=bool(d[1]),pending=pending.copy())
                elif n=='TimerCallbackLock':st=dict(callback='check',timerLock='callback',pending=pending.copy())
                elif n=='TimerCallbackCheck':st=dict(callback='finish' if d[1] else 'wake',pending=pending.copy())
                elif n=='TimerCallbackWake':st=dict(callback='unpark' if d[2] else 'finish',accepted=bool(d[2]),flagWritten=True,pending=pending.copy())
                elif n=='TimerCallbackUnpark':st=dict(callback='finish',pending=pending.copy())
                elif n=='TimerCallbackFinish':
                    pending=pending[1:];st=dict(callback='done',callbackRef=False,timerLock='free',pending=pending.copy())
            elif n=='ClockAdvance':
                args=dict(t=d[0]-origin);st=dict(now=d[0]-origin)
            elif n=='UserStore':
                total_stores+=1;args=dict(k=key(d[0]),v=d[1]);st=dict(key=key(d[0]),word=d[1],stores=total_stores)
            elif ident in local_call:
                c=ident;o=local_call[c];args=dict(c=c);sb=o['sb'];db=o['db']
                if n in ('LockBucketPairsFirst','LockBucketPairsSecond'):
                    b=d[0];st=dict(pc='lockSecond' if n.endswith('First') and sb!=db else 'snapshot',bucket=b,lockOwner=own('call',c))
                elif n=='FutexWakeStart':st=dict(pc='wakeScan',sourceQueue=r['q'])
                elif n=='FutexItemWake':
                    g=d[0];attempt=bool(d[1]);args.update(g=g,attempted=attempt)
                    if attempt:st=dict(pc='unpark' if d[2] else 'wakeCommit',index=o['index'],waiter=g,accepted=bool(d[2]),flagWritten=True)
                    else:o['index']=d[2]+1;st=dict(pc='wakeScan',index=o['index'])
                elif n=='FutexWakeUnpark':args['g']=d[0];st=dict(pc='wakeCommit')
                elif n=='FutexWakeRetain':
                    g=d[0];args['g']=g;o['index']=d[1]
                    st=dict(pc='wakeScan',index=d[1],wakes=d[2],queue=r['q'],owner=own('none') if d[3] else own('bucket',sb))
                elif n=='FutexWakeEnd':st=dict(pc=['finish','moveSame','moveCross'][d[0]],index=1,wakes=d[1]);o['index']=1
                elif n=='FutexUpdateItemKey':
                    g,idx,moves,k,stop=d;args['g']=g;o['moves']=moves
                    st=dict(pc='finish' if stop else 'moveSame',index=idx,moves=moves,entryKey=key(k))
                elif n=='FutexExtractItem':
                    g,idx,moves,hit=d;args['g']=g;o['moves']=moves
                    st=dict(pc='changeKey' if hit else 'moveCross',index=idx,moves=moves,transfer=g if hit else 0,queue=r['q'],owner=own('transfer',c) if hit else own('bucket',sb))
                elif n=='FutexExtractedKey':args['g']=d[0];st=dict(pc='append',entryKey=key(d[1]),owner=own('transfer',c))
                elif n=='FutexAppendExtracted':args['g']=d[0];st=dict(pc='moveCross',transfer=0,queue=r['q'],owner=own('bucket',db))
                elif n=='FutexMoveEnd':st=dict(pc='finish')
                elif n=='FutexRequeueFinish':
                    dest=r['q'] if sb==db else rows[ri+1]['q'];assert sb==db or rows[ri+1]['event']=='QueueView'
                    st=dict(pc='releaseSource' if sb==db else 'releaseDest',wakes=d[0],moves=o['moves'],sourceQueue=r['q'],destQueue=dest)
                elif n in ('FutexReleaseDest','FutexReleaseSource'):st=dict(pc='releaseSource' if n.endswith('Dest') else 'return',bucket=d[0],lockOwner=own('none'))
                elif n=='SysFutexControlReturn':st=dict(pc='done',result=d[0],activeCall=0)
                else:raise ValueError((n,c))
            else:
                g=ident;w=local_wait[g];args=dict(g=g);b=w['bucket']
                if n=='FutexWaitLock':st=dict(pc='load',bucket=b,lockOwner=own('wait',g))
                elif n=='FutexWaitLoad':st=dict(pc='compare',observed=d[1])
                elif n=='FutexWaitFault':st=dict(pc='faultUnlock')
                elif n=='FutexWaitFaultUnlock':st=dict(pc='resolve',bucket=b,lockOwner=own('none'))
                elif n=='HandlePageFault':st=dict(pc='lock')
                elif n=='FutexWaitCompare':st=dict(pc='mismatchUnlock' if d[2] else 'enqueue',observed=d[1],result='EAGAIN' if d[2] else 'none')
                elif n=='FutexWaitMismatchUnlock':st=dict(pc='close',bucket=b,lockOwner=own('none'),owner=own('none'))
                elif n=='FutexBucketAddItem':st=dict(pc='unlock',bucket=b,queue=r['q'],owner=own('bucket',b))
                elif n=='FutexWaitUnlock':st=dict(pc='pauseCheck',bucket=b,lockOwner=own('none'))
                elif n=='PauseTimeoutCheck':st=dict(pc='cleanupLock' if d[0] else ('armRead' if d[1] else 'wait'),pause='ETIME' if d[0] else 'none',timerState='expired' if d[0] else 'none',deadline=0)
                elif n in ('TimerSetClock','PauseTimeoutClock'):
                    w['sample']=d[1]-origin;args['t']=w['sample']
                    st=dict(pc='arm' if n=='TimerSetClock' else 'remain',sample=w['sample'],now=w['sample'])
                elif n=='TimerSetTimeout':st=dict(pc='wait',timerState='armed',deadline=d[1]-origin,localRef=True,sample=w['sample'])
                elif n=='WakerDoWait':st=dict(pc='inspect' if d[1] else 'park',flagWritten=False)
                elif n=='WaiterPark':w['park']=r;st=dict(pc='wait' if d[1] else 'sleep')
                elif n=='WaiterSpuriousReturn':st=dict(pc='wait')
                elif n=='PauseTimeoutTimerLock':st=dict(pc='remainRead',timerLock='waiter')
                elif n=='PauseTimeoutNoTimer':st=dict(pc='cleanupLock',pause='OK')
                elif n=='PauseTimeoutRemain':st=dict(pc='timerUnlock' if d[0] else 'cancel',pause='ETIME' if d[0] else 'OK',sample=w['sample'])
                elif n=='TimerCancel':st=dict(pc='timerUnlock',cancelled=True,timerState='cancelled')
                elif n=='PauseTimeoutTimerUnlock':st=dict(pc='timerDrop',timerLock='free')
                elif n=='PauseTimeoutTimerDrop':st=dict(pc='cleanupLock',localRef=False)
                elif n=='FutexCleanupLock':st=dict(pc='cleanup',bucket=b,lockOwner=own('wait',g))
                elif n=='FutexRemoveByWaker':st=dict(pc='cleanupUnlock',bucket=b,queue=r['q'],cleanup='found' if d[2] else 'miss')
                elif n=='FutexCleanupUnlock':st=dict(pc='decide',bucket=b,lockOwner=own('none'))
                elif n=='FutexWaitDecide':st=dict(pc='close',result=result(d[1]));w['result']=result(d[1])
                elif n=='WaiterDrop':st=dict(pc='return',closed=True,flagWritten=True)
                elif n=='SysFutexWaitReturn':st=dict(pc='done',result=result(d[0]),returns=1)
                else:raise ValueError((n,g))
            e=dict(tag='trace',ts=str(r['start']),event=n,pid=pid,seq=1+sum(v['pid']==pid for v in events),cpu=r['cpu'],start=r['start'],end=r['end'],deps=[],args=args,state=st)
            assert st is not None and 0<=e['cpu']<ncpu,(n,st)
            # A raw batch names the clock event. Normalized sequence numbers omit auxiliary probes.
            if n=='TimerCollectClock':normalized_batch=e['seq'];args['batch']=normalized_batch;heap.append((d[1],e,None))
            elif n.startswith('TimerCollect') or n.startswith('TimerCallback'):args['batch']=normalized_batch
            if n=='TimerCollectEnd':heap[-1]=(heap[-1][0],heap[-1][1],e)
            if n=='TimerSetTimeout':heap.append((d[2],e,e))
            if n in ('FutexWaitLock','FutexCleanupLock','LockBucketPairsFirst','LockBucketPairsSecond'):
                b=st['bucket'];epoch=d[-1];token=(pid,ident,b)
                lock_acquires.append((b,epoch,e,token));lock_releases[token]=None
            if n in ('FutexWaitUnlock','FutexWaitFaultUnlock','FutexWaitMismatchUnlock','FutexCleanupUnlock','FutexReleaseSource','FutexReleaseDest'):
                token=(pid,ident,st['bucket'])
                acq=next(v for v in reversed(lock_acquires) if v[3]==token)
                lock_releases[(token,acq[1])]=e
            if n in ('PauseTimeoutTimerLock','TimerCallbackLock'):
                timer_acquires.append((g,d[-1],e,(pid,g)))
            if n in ('PauseTimeoutTimerUnlock','TimerCallbackFinish'):
                acq=next(v for v in reversed(timer_acquires) if v[3]==(pid,g))
                timer_releases[(g,acq[1])]=e
            e['_raw_seq']=r['raw_seq']
            events.append(e)
    def dep(e,p):
        assert p is not None
        ref=[p['pid'],p['seq']]
        if p['pid']!=e['pid'] and ref not in e['deps']:e['deps'].append(ref)
    for pid,rawseq,kind,data in sync_edges:
        following=next((e for e in events if e['pid']==pid and e['_raw_seq']>rawseq),None)
        if following is None:continue
        if kind=='HarnessJoin':
            predecessors=[e for e in events if e['pid']==f'p{data[0]}' and e['event'] in ('SysFutexWaitReturn','SysFutexControlReturn')]
            assert predecessors;dep(following,predecessors[-1])
        else:
            for g in data:
                if g:dep(following,next(e for e in events if e['event']=='FutexBucketAddItem' and e['args']['g']==g))
    for e in events:del e['_raw_seq']
    previous={}
    for b,epoch,e,token in sorted(lock_acquires,key=lambda v:(v[0],v[1])):
        assert (b,epoch) not in previous,'duplicate lock acquisition epoch'
        if b in previous:dep(e,previous[b])
        previous[b]=lock_releases[(token,epoch)]
    previous={}
    for g,epoch,e,token in sorted(timer_acquires,key=lambda v:(v[0],v[1])):
        if g in previous:dep(e,previous[g])
        previous[g]=timer_releases[(g,epoch)]
    prev=None
    for epoch,e,end in sorted(heap,key=lambda v:v[0]):
        if prev:dep(e,prev)
        prev=end
    # Publication follows the saved deadline sample and precedes its collection.
    publication={e['args']['g']:e for e in events if e['event']=='TimerSetTimeout'}
    for e in events:
        if e['event']=='TimerCollect':dep(e,publication[e['args']['g']])
    for g,w in waits.items():
        assert sum(e['event']=='SysFutexWaitReturn' and e['args'].get('g')==g for e in events)==1
    for c,o in calls.items():
        assert sum(e['event']=='SysFutexControlReturn' and e['args'].get('c')==c for e in events)==1
    assert waits and calls
    assert all(w['pid'] in threads for w in waits.values())
    assert all(c['pid'] in threads for c in calls.values())
    # Do not turn unsynchronized cross-CPU TSC values into a total execution order.
    # Widen to the attempt envelope. Program order and captured lock epochs remain.
    raw_cross=[(a,b) for i,a in enumerate(events) for b in events[i+1:] if a['pid']!=b['pid']]
    raw_overlap=sum(a['start']<=b['end'] and b['start']<=a['end'] for a,b in raw_cross)
    same_cpu_overlap=sum(a['cpu']==b['cpu'] and a['start']<=b['end'] and b['start']<=a['end'] for a,b in raw_cross)
    for e in events:e['start']=0;e['end']=1
    durations=list({(v['duration']['timed'],v['duration']['ticks']):v['duration'] for v in waits.values()}.values())
    manifest=dict(tag='manifest',schema='private-futex-v3',source=PIN,tree=TREE,cpu_count=ncpu,complete_attempt=True,
        wait_ids=sorted(waits),call_ids=sorted(calls),controllers=sorted({v['actor'] for v in calls.values()}),
        keys=list(keys),buckets=sorted({v['bucket'] for v in keys.values()}),bucket_of={k:v['bucket'] for k,v in keys.items()},
        initial_words={k:v['initial'] for k,v in keys.items()},values=[0,1],quotas=sorted({e['args'][q] for e in events if e['event']=='SysFutexControl' for q in ('nw','nm')}),durations=durations,
        wait_pids={str(g):w['pid'] for g,w in waits.items()},call_pids={str(c):o['pid'] for c,o in calls.items()},call_actors={str(c):o['actor'] for c,o in calls.items()},timer_pids=sorted({e['pid'] for e in events if e['pid'] in ('p8','p9')}),
        evidence=dict(case=case,keys=keys,threads=threads,kernel_images=images,raw_to_normalized_generations={str(g):g for g in list(waits)+list(calls)},bucket_count=nbuckets,clock_unit='nanoseconds',clock_origin_ns=origin,timeboxes='conservative overlap; cross-CPU TSC comparability unproved',raw_files=str(rawdir),raw_sha256=digest(log),build_id=next(l.split()[1] for l in lines if l.startswith('SPECULA_ID ')),source_diff_sha256=digest(H/'patches/instrumentation.patch'),trace_module_sha256=digest(H/'src/trace.rs'),buffers=buffers,raw_cross_pairs=len(raw_cross),raw_overlap_pairs=raw_overlap,same_cpu_overlap_pairs=same_cpu_overlap))
    # All protocol arithmetic remains exact and fits TLC's signed integers.
    assert all(0<=t<2**31 for t in [e['args']['t'] for e in events if 't' in e['args']]+[d['ticks'] for d in durations])
    path=OUT/'traces'/f'case-{case:02}.ndjson'
    path.write_text(''.join(json.dumps(e,separators=(',',':'))+'\n' for e in [manifest]+events))
    return dict(case=case,events=len(events),types=dict(collections.Counter(e['event'] for e in events)),raw_overlap=raw_overlap,cross_pairs=len(raw_cross),same_cpu_overlap=same_cpu_overlap,file=str(path))
if __name__=='__main__':
    results=[]
    for log in sorted((H/'logs').glob('guest-*.log')):results.append(normalize(log))
    assert results,'No executed guest logs'
    coverage=collections.Counter()
    for r in results:coverage.update(r['types'])
    quality=any(r['same_cpu_overlap']>0 and r['raw_overlap']>=0.2*r['cross_pairs'] for r in results)
    report=dict(concurrency_quality='PASS' if quality else 'NOT_ESTABLISHED',attempts=results,covered=dict(coverage),uncovered=sorted(set(list(EVENTS.values())[:57])-set(coverage)))
    (H/'coverage.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
