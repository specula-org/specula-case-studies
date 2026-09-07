"""Synthetic trace-engine fixtures; not implementation execution evidence."""
from pathlib import Path
from copy import deepcopy as cp
import json
root=Path(__file__).resolve().parent
nil='nil'; noentry={'client':-1,'request':-1,'op':{'kind':'Get','value':nil}}
def msg(kind,src,dst,view=0,**kw):
 d=dict(kind=kind,src=src,dst=dst,view=view,opnum=0,commit=0,entry=cp(noentry),log=[],start=0,lastNormal=0,nonce=0,hasState=False,result=nil);d.update(kw);return d
def state():
 return dict(status='Normal',view=0,lastNormal=0,log=[],commit=0,acks=[],table=[],heard=True,waiting=0,attempts=0,stable=0,svc=[],dvcSent=False,dvc=[],catching=False,nonce=0,responses=[],messages=[],replies=[],app=nil,executed=[])
p=dict(replicas=[dict(id=i,durable=0,owner='ready',incarnation=0,state=state()) for i in range(3)],clients=[dict(id=c,view=0,next=0,pending=False,entry=cp(noentry)) for c in [100,101]],network=[],frames=[],nextFrame=0,phase='faults',healthySet=[0,1,2],invocations=[],responses=[],happensBefore=[],committedHistory=[])
config=dict(revision='3ac0104a567092139534c9022205d02281a2da41',servers=[0,1,2],clients=[100,101],values=['A','AA','B'],primary_timeout=3,failure_budget=1,integration_mode=False,full_value='AA',prefix_value='A')
events=[]
def emit(name,**kw):events.append(dict(tag='vsr',event=name,**kw,post=cp(p)))
def r(i):return p['replicas'][i]['state']
def owner(i,v):p['replicas'][i]['owner']=v
def persist(i):
 p['replicas'][i]['durable']=r(i)['view'];owner(i,'publish' if r(i)['messages'] or r(i)['replies'] else 'ready');emit('PersistView',node=i)
def publish(i):
 q=r(i)['messages'] if r(i)['messages'] else r(i)['replies'];m=q.pop(0)
 if m not in p['network']:p['network'].append(cp(m))
 owner(i,'publish' if r(i)['messages'] or r(i)['replies'] else 'ready');emit('PublishOutput',node=i)
def flush(i):
 persist(i)
 while r(i)['messages'] or r(i)['replies']:publish(i)
def execute(i,e):
 out=nil if e['op']['kind']=='Put' else r(i)['app']
 if e['op']['kind']=='Put':r(i)['app']=e['op']['value']
 r(i)['commit']+=1
 h=dict(pos=r(i)['commit'],entry=cp(e),result=out,view=r(i)['view'])
 r(i)['executed'].append(h)
 if h not in p['committedHistory']:p['committedHistory'].append(cp(h))
 r(i)['table'][0].update(hasReply=True,result=out)
 return out
emit('Init',config=config)
e=dict(client=100,request=0,op=dict(kind='Put',value='AA'))
p['clients'][0].update(pending=True,next=1,entry=cp(e));p['invocations'].append(cp(e));request=msg('Request',100,0,entry=cp(e));p['network'].append(request)
emit('ClientOnRequest',client=100,op=e['op'])
p['network'].remove(request);r(0)['log'].append(cp(e));r(0)['table']=[dict(client=100,request=0,hasReply=False,result=nil)];r(0)['acks']=[dict(opnum=1,**{'from':[0]})];r(0)['messages']=[msg('Prepare',0,j,opnum=1,entry=cp(e)) for j in [1,2]];owner(0,'persist');emit('OnRequest',node=0,message=request,keep=False);flush(0)
prepare=next(m for m in p['network'] if m['dst']==1);p['network'].remove(prepare);r(1)['log'].append(cp(e));r(1)['table']=[dict(client=100,request=0,hasReply=False,result=nil)];r(1)['messages']=[msg('PrepareOk',1,0,opnum=1)];owner(1,'persist');emit('OnPrepareAppend',node=1,message=prepare,keep=False);flush(1)
ack=next(m for m in p['network'] if m['kind']=='PrepareOk');p['network'].remove(ack);execute(0,e);r(0)['acks']=[];replyentry=cp(noentry);replyentry.update(client=100,request=0);r(0)['replies']=[msg('Reply',0,100,entry=replyentry)];owner(0,'persist');emit('OnPrepareOk',node=0,message=ack,keep=False);flush(0)
reply=next(m for m in p['network'] if m['kind']=='Reply');p['network'].remove(reply);p['clients'][0]['pending']=False;p['responses'].append(dict(client=100,request=0,result=nil));emit('ClientOnReply',message=reply,keep=False)
def write(name,data):
 (root/name).write_text(''.join(json.dumps(x,separators=(',',':'))+'\n' for x in data))
write('trace-synthetic-good.ndjson',events)
bad=cp(events);bad[3]['post']['replicas'][0]['state']['log'][0]['op']['value']='B';write('trace-synthetic-bad-state.ndjson',bad)
bad=cp(events);bad[-1]['message']['result']='B';write('trace-synthetic-bad-reply.ndjson',bad)
bad=cp(events);del bad[3];write('trace-synthetic-missing-persist.ndjson',bad)
print('Wrote synthetic positive fixture:',len(events),'events, plus 3 negative variants')
