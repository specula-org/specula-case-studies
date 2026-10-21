#!/usr/bin/env python3
"""Translate native receipts; never compute a backend result or a copied byte."""
import argparse, copy, hashlib, importlib.util, json, re, shutil
from pathlib import Path
H=Path(__file__).resolve().parents[1]; O=H.parent
UNIT=2048; P=2; MAX=12
TAGS={0:'zero',83:'seed',165:'sentinel',255:'uninit',65:'t0',66:'t1',67:'t2'}
ACTIONS=set(re.findall(r'e.event = "([^"]+)"',(O/'spec/Trace.tla').read_text()))
def norm(n):
    if type(n) is not int or n%UNIT: raise ValueError(f'nonrepresentable byte count: {n}')
    return n//UNIT
def tags(data,n):
    if any(x not in TAGS for x in data[:n]): raise ValueError('nonuniform or unobserved byte cell')
    return [TAGS[x] for x in data[:n]]
def idle():
    return dict(pc='Dispatch',kind='read',O=0,N=0,target=0,fault=0,S=0,K=0,copyO=0,candidate=0,D=0,
                status='Pending',errorSite='none',result=-1,ioKind='Read',ioOff=0,ioLen=0,ioDone=0,ioEnd=0,
                page=0,afterIo='BackendReturn',resizeOld=0,resizeNew=0,resizePurpose='resize',afterResize='BackendReturn',
                segmentEnd=0,collectNext=0,collectEnd=0,overwrite=False,out=['sentinel']*MAX)
def adapt(events,backend):
    q=idle(); accepted=[]; held=dict(cache=False,writer=False,up=False,reader=False,offset=False)
    def error_pc():
        return ('Ext2RollbackBlocks' if q['resizePurpose']=='rollback' else 'Ext2RollbackStart') if backend=='ext2' and q['kind']=='pwrite64' else 'BackendReturn'
    out=[]
    for r in events:
        a=r['event']; v=r['v']; state=dict(local=None,accepted=None,held=None,inode={},pages=[],disk=[],blocks=[],position=[]); args=[]
        if a not in ACTIONS: raise ValueError(f'unknown native event: {a}')
        if a=='SyscallEnter':
            q=idle(); accepted=[]; k=['read','pread64','pwrite64','ftruncate'][v[0]]
            args=[k,norm(v[1]),norm(v[2]),norm(v[3]),norm(v[4]) if v[0]!=3 else 0]
            q.update(kind=k,O=args[1],N=args[2],target=args[3],fault=args[4])
            if k=='read': held['offset']=True; state['position']=[norm(v[1])]
        elif a=='RamfsReadAtObserve': q.update(S=norm(v[0]),copyO=norm(v[1]),K=norm(v[2]),pc='RamReadCache')
        elif a=='RamfsReadAtAcquireCache': held['cache']=True; q.update(ioKind='Read',ioOff=norm(v[0]),ioLen=norm(v[1]),pc='VmoBegin')
        elif a in ('Ext2ReadAt','ExfatReadAt'):
            q.update(S=norm(v[0]),copyO=norm(v[1]),K=norm(v[2]),ioKind='Read',ioOff=norm(v[1]),ioLen=norm(v[3]))
            held['reader' if backend=='ext2' else 'up']=True
            q['pc']='BackendReturn' if backend=='ext2' and q['K']==0 else 'VmoBegin'
        elif a in ('Ext2ReadAtEmpty','Ext2WriteAtEmpty'): q['pc']='BackendReturn'
        elif a=='RamfsWriteAtAcquireCache': held['cache']=True; q['pc']='RamWriteMetadata'
        elif a in ('RamfsWriteAtPublish','Ext2WriteAtPrepare','ExfatWriteAtPrepare'):
            if backend=='ramfs':
                size,candidate=norm(v[1]),norm(v[2]); end=norm(v[3]); state['inode']={'L':norm(v[0])}; after='WriteCopyStart'
            else:
                held['writer']=True; size,candidate=norm(v[0]),norm(v[1]); end=norm(v[2]) if backend=='exfat' else candidate
                after='Ext2Allocate' if backend=='ext2' else 'ExfatReleasePreparation'
            q.update(S=size,candidate=candidate,resizeOld=size,resizeNew=end,resizePurpose='write',afterResize=after)
            growing=(candidate>size) if backend!='exfat' else end>size
            q['pc']='ResizeBegin' if growing else after
            if backend=='exfat' and growing and end>norm(v[3]): q['pc']='ExfatAllocate'
        elif a=='ExfatResizeAllocation':
            state['inode']={'L':norm(v[0]),'A':norm(v[1]),'clusters':v[2]}
            q['pc']='ResizeBegin' if q['kind']=='pwrite64' else 'BackendReturn'
        elif a=='ExfatWriteAtReleasePreparation': held['writer']=False; q['pc']='ExfatAcquireCopy'
        elif a=='ExfatWriteAtAcquireCopy': held['up']=True; q['pc']='WriteCopyStart'
        elif a=='RamfsResizeAcquireCache': held['cache']=True; q['pc']='RamResizeMetadata'
        elif a in ('RamfsResize','Ext2Resize','ExfatResize'):
            size,target=norm(v[0]),norm(v[1]); q.update(S=size,resizeOld=size,resizeNew=target,resizePurpose='resize')
            if backend=='ramfs':
                state['inode']={'L':norm(v[2])}; q['afterResize']='RamResizePublish' if target<size else 'BackendReturn'
            elif backend=='ext2': held['writer']=True; q['afterResize']='Ext2ResizePublish'
            else: held['up']=True; q['afterResize']='ExfatAllocate'
            q['pc']='ExfatResizeUpgrade' if backend=='exfat' else 'BackendReturn' if size==target else 'ResizeBegin'
        elif a=='ExfatResizeUpgrade': held.update(up=False,writer=True); q['pc']='ResizeBegin' if q['target']<q['S'] else 'ExfatAllocate'
        elif a in ('RamfsResizePublish','Ext2ResizePublish','Ext2WriteAtPublish','ExfatWriteAtPublish'):
            state['inode']={'L':norm(v[0])}; q['pc']='BackendReturn'
            if a=='ExfatWriteAtPublish': held.update(up=False,writer=True)
            if a=='Ext2ResizePublish': state['blocks']=[[j for j in range(12) if v[1]&(1<<j)]]
        elif a=='PageCacheResizeBegin':
            new,old,lo,hi=map(norm,v[:4])
            if (new,old)!=(q['resizeNew'],q['resizeOld']): raise ValueError('native resize arguments differ from retained caller')
            q.update(ioKind='Zero',ioOff=lo,ioLen=hi-lo,ioDone=0,afterIo='ResizeCapacity',pc='FillZeros' if hi>lo else 'ResizeCapacity')
        elif a=='PageCacheFillZeros':
            if (norm(v[0]),norm(v[1])) != (q['ioOff'],q['ioOff']+q['ioLen']): raise ValueError('native zero-copy range differs from selected interval')
            q['pc']='VmoBegin'
        elif a=='PageCacheResizeCapacity':
            state['inode']={'C':norm(v[1])}
            if v[2]: state['pages']=[{'index':j,'state':'Absent','data':['uninit']*P} for j in range(v[1]//4096,v[0]//4096)]
            q['pc']='Ext2CacheBound' if backend=='ext2' else q['afterResize']
        elif a=='Ext2ResizePageCacheBound': state['inode']={'npages':v[0]}; q['pc']=q['afterResize']
        elif a=='WriteAtCopyStart':
            q.update(ioKind='Write',ioOff=norm(v[0]),ioLen=norm(v[1]),pc='VmoBegin',
                     afterIo={'ramfs':'BackendReturn','ext2':'Ext2WritePublish','exfat':'ExfatWritePublish'}[backend])
        elif a=='VmoIoBegin':
            off,length,effective=map(norm,v[:3])
            if (off,length)!=(q['ioOff'],q['ioLen']): raise ValueError('native VMO call differs from caller receipt')
            q.update(ioDone=0,ioEnd=off+effective,pc=q['afterIo'] if effective==0 else 'CollectBegin')
        elif a=='VmoCollectBegin':
            q.update(segmentEnd=min(v[1]*P,q['ioEnd']),collectNext=v[0],collectEnd=v[1],overwrite=bool(v[2]),pc='CommitPage')
        elif a in ('VmoCommitPage','VmoBackendRead'):
            index,st=v[:2]; state['pages']=[{'index':index,'state':['Uninit','Clean','Dirty','Evicted'][st],'data':tags(r['data'],P)}]
            if a=='VmoCommitPage': q.update(page=index,pc='BackendRead' if st==0 and not q['overwrite'] and backend!='ramfs' else 'CollectedPage')
            else: q['pc']='CollectedPage'
        elif a=='VmoCollectedPage':
            nxt=v[0]+1; more=nxt<q['collectEnd']; q.update(collectNext=nxt,page=nxt if more else (q['ioOff']+q['ioDone'])//P,pc='CommitPage' if more else 'CopyPage')
        elif a=='VmoCopyPage':
            index,offset,before,after,delta,failed,st,rd=v
            if after-before!=delta: raise ValueError('invalid independent cursor delta')
            count=norm(delta); at=q['ioOff']+q['ioDone']; done=q['ioDone']+count
            if rd:
                q['out'][q['D']:q['D']+count]=tags(r['data'],count)
            else:
                state['pages']=[{'index':index,'state':['Uninit','Clean','Dirty','Evicted'][st],'data':tags(r['data'],P)}]
                if q['ioKind']=='Write' and st!=0: accepted=sorted(set(accepted)|set(range(at,at+count)))
            if q['ioKind']!='Zero': q['D']+=count
            q['ioDone']=done
            if failed: q.update(status='EFAULT',errorSite='user_destination' if rd else 'user_source',pc=error_pc())
            elif q['ioOff']+done==q['ioEnd']: q['pc']=q['afterIo']
            elif q['ioOff']+done==q['segmentEnd']: q['pc']='CollectBegin'
            else: q.update(pc='CopyPage',page=(q['ioOff']+done)//P)
        elif a=='ExfatBackendReadBlocked': q['pc']='BackendReadBlocked'
        elif a=='VmoRangeError':
            if q['resizePurpose']!='rollback': q.update(status='EINVAL',errorSite='fill_range' if v[0]==0 else 'backend_bound')
            q['pc']=error_pc()
        elif a=='Ext2AllocateRangeBlocks':
            if v[1].bit_count()*4096 != v[2]: raise ValueError('allocated blocks lack completed zero-write receipts')
            state['blocks']=[[j for j in range(12) if v[0]&(1<<j)]]
            state['disk']=[{'index':j,'data':['zero']*P} for j in range(12) if v[1]&(1<<j)]
            q['pc']='WriteCopyStart'
        elif a=='Ext2RollbackWrite':
            q.update(resizePurpose='rollback',resizeOld=norm(v[1]),resizeNew=norm(v[0]),afterResize='Ext2RollbackBlocks',pc='ResizeBegin' if v[1]>v[0] else 'BackendReturn')
        elif a=='Ext2RollbackBlocks': state['blocks']=[[j for j in range(12) if v[0]&(1<<j)]]; q['pc']='BackendReturn'
        elif a=='BackendReturn':
            errno=v[1]
            q['result']=-1 if errno else norm(v[0]); q['status']={0:'Ok',14:'EFAULT',22:'EINVAL'}[errno]
            q['pc']='Ext2ReadAtime' if backend=='ext2' and q['kind'] in ('read','pread64') and not errno and q['K']>0 else 'Return'
            held.update(cache=False,writer=False,up=False,reader=False)
        elif a=='Ext2ReadAtUpdateAtime': q['pc']='Return'
        elif a=='InodeHandleReturn':
            actual=-1 if v[1] else norm(v[0])
            if actual!=q['result']: raise ValueError('syscall result changed after backend return')
            if q['kind']=='read': state['position']=[norm(v[2])]; held['offset']=False
            q['pc']='Done'
        else: raise ValueError('missing receipt adapter: '+a)
        state.update(local=copy.deepcopy(q),accepted=accepted[:],held=held.copy())
        out.append(dict(tag='trace',event=a,tid='t'+str(r['tid']),start=r['start'],end=r['end'],args=args,state=state))
    return out

def collect(log):
    prior=H/'coverage.json'
    if prior.exists():
        before=json.loads(prior.read_text())
        if before.get('source_log')!=log.name:
            archive=H/'history'/log.stem; archive.mkdir(parents=True,exist_ok=True)
            for scenario in before['scenarios']:
                name=scenario['scenario']
                for old in (O/'traces'/(name+'.ndjson'),O/'traces/raw'/name):
                    if old.exists(): shutil.move(str(old),str(archive/old.name))
            for name in ('coverage.json','validation.json','validation-proposed.json'):
                if (H/name).exists():
                    shutil.copyfile(H/name,archive/name)
                    if name.startswith('validation'): (H/name).unlink()
    scenarios=[]; current=None; side=[]
    for line in log.read_text(errors='replace').splitlines():
        for marker in ('SPECULA_BEGIN ','SPECULA_RAW ','SPECULA_END ','SPECULA_CASE '):
            pos=line.find(marker)
            if pos<0: continue
            value=json.loads(line[pos+len(marker):])
            if marker=='SPECULA_BEGIN ': current=dict(config=value,raw=[]); scenarios.append(current)
            elif marker=='SPECULA_RAW ': 
                if current is None: raise ValueError('receipt outside scenario')
                current['raw'].append(value)
            elif marker=='SPECULA_END ': current['end']=value; current=None
            else: side.append(value)
    (H/'non-tla/raw').mkdir(parents=True,exist_ok=True)
    (H/'non-tla/raw'/('observations-'+log.stem+'.json')).write_text(json.dumps(side,indent=2)+'\n')
    spec=importlib.util.spec_from_file_location('trace_preprocessor',O/'spec/preprocess_trace.py'); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    coverage=set(); overlaps=0; pairs=0; reports=[]
    for run in scenarios:
        c=run['config']; name=c.pop('name'); c.update(format='asterinas-buffered-v1',revision='604948581512d83734377974d4c34adb4530f2d7',p=P,g=P,max_byte=MAX,initial_size=2,warm_pages=[0],initial_position=0,threads=['t0','t1'])
        rawdir=O/'traces/raw'/name; rawdir.mkdir(parents=True,exist_ok=True)
        (rawdir/'native-receipts.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in run['raw']))
        if 'end' not in run: raise ValueError('scenario did not complete: '+name)
        per={tid:adapt([r for r in run['raw'] if r['tid']==int(tid[1:])],c['backend']) for tid in c['threads']}
        paths=[]
        for tid,events in per.items():
            path=rawdir/(tid+'.ndjson'); paths.append(path); path.write_text(''.join(json.dumps(e,separators=(',',':'))+'\n' for e in events)); coverage.update(e['event'] for e in events)
        (rawdir/'bootstrap.json').write_text(json.dumps(c)+'\n')
        result=module.assemble(c,paths)
        (O/'traces'/(name+'.ndjson')).write_text(json.dumps(result,separators=(',',':'))+'\n')
        pairlist=[(a,b) for a in per['t0'] for b in per['t1']]
        ov=sum(a['start']<=b['end'] and b['start']<=a['end'] for a,b in pairlist); overlaps+=ov; pairs+=len(pairlist)
        reports.append({'scenario':name,'events':sum(map(len,per.values())),'overlapping_pairs':ov,'cross_thread_pairs':len(pairlist)})
        print(name, reports[-1])
    report={'source_log':log.name,'scenarios':reports,'covered':sorted(coverage),'missing':sorted(ACTIONS-coverage),'overlapping_pairs':overlaps,'cross_thread_pairs':pairs,'overlap_fraction':overlaps/pairs if pairs else 0}
    (H/'coverage.json').write_text(json.dumps(report,indent=2)+'\n')
    if not scenarios: raise ValueError('no executed trace scenarios')
    return side
if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('log',type=Path); args=parser.parse_args(); collect(args.log)
