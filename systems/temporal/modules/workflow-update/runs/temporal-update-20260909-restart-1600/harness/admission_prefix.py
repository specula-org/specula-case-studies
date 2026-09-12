#!/usr/bin/env python3
"""Map ONLY a measured admission prefix. Never extrapolate the remaining trace.

This adapter does not run base.tla or choose model successors. Every mutable
field below comes from a leased snapshot or the independent bootstrap readback;
the empty observer collections are checked at the bounded bootstrap. It stops
before Matching because the full observer/state mapping is still incomplete.
"""
import copy
import datetime
import hashlib
import json
from pathlib import Path
import sys

source, target = map(Path, sys.argv[1:3])
rows = [json.loads(line) for line in source.read_text().splitlines()]
events = [(n, r) for n, r in enumerate(rows, 1) if "event" in r]
def find(name, after=0):
    return next((n, r) for n, r in events if n > after and r["event"]["name"] == name)
baseline_line, baseline = find("probe.LeasedBaseline")
readback_line, readback = find("probe.Bootstrap")
b = baseline["event"]["state"]["mutable"]
extra = baseline["event"]["state"]["extra"]
stored = readback["event"]["state"]["stored"]
assert b["next"] == stored["State"]["next_event_id"] == 5
assert b["rv"] == stored["DBRecordVersion"]
assert b["task"] is None and b["timerPointer"] == "0x0"
assert b["sticky"] and not b["closed"] and not b["info"]
assert not b["registry"]["updates"] and extra["clearedPrefix"] == 4
cfg = rows[0]["config"]
updates, version = cfg["updates"], extra["eventVersion"]
assert version >= 0
namespace, workflow, run = cfg["namespaceID"], cfg["workflowID"], cfg["runID"]
pending = {"kind": "pending", "value": "none"}
no_task = dict(kind="none", scheduled=0, started=0, startedTime=0, attempt=0,
               version=version, stamp=0, transient=False, route="normal")
no_info = dict(stage="none", acceptedID=0, eventID=0, batchID=0, result=pending)
no_call = dict(uid="none", op="update", waitStage="COMPLETED", status="idle",
               oid=0, expired=False, reply=dict(stage="NONE", result=pending), active=False)
no_effect = dict(oid=0, kind="none", prev="none", result=pending)
info = {u: copy.deepcopy(no_info) for u in updates}
db = dict(next=b["next"], rv=1, range=1, closed=b["closed"], sticky=b["sticky"],
          task=no_task, transfer=False, info=info, events=[])
ctx = {k: copy.deepcopy(v) for k, v in db.items() if k != "events"}
ctx.update(loaded=b["loaded"], host="h1", generation=1, reg={u:0 for u in updates})
write = dict(state="none", returned=True, error="none", range=0, rv=0, next=0,
             info=info, closed=False, sticky=False, task=no_task, transfer=False, events=[])
s = dict(db=db,ctx=ctx,objects=[],timers=[],timerPointer=0,matching=[],workers=[],dispatch=[],
         cache={"h1":[]},physicalHistory=[],write=write,pc="idle",returnPC="idle",batch=[],effects=[],
         cancels=[],active=no_effect,second="none",clearTodo=[],clearReturn="idle",handler="none",
         caller="none",selected=0,inlineWorker=0,commands=[],closeCommand=False,rejectTodo=[],
         successor=False,skip=False,acquiring=False,clock=0,limitRaised=False,
         calls={"client-1":no_call},observed=[],applied=[],timeoutApplications=[],everRequested=[])
s = copy.deepcopy(s)
result = [{"tag":"temporal-update.meta","schema":1,"sourceRevision":cfg["sourceRevision"],
           "constants":dict(updates=updates,values=["value-1","value-2"],clients=["client-1"],hosts=["h1"],
                            initialHost="h1",namespaceID=namespace,workflowID=workflow,runID=run,
                            eventVersion=version,hostCacheEnabled=extra["hostCacheEnabled"]),
           "initialState":copy.deepcopy(s)}]
origin = []
def emit(name, params, raw_line, raw):
    result.append(dict(tag="temporal-update", event=name, ordinal=len(result), params=params, post=copy.deepcopy(s)))
    origin.append(dict(ordinal=len(result)-1,rawLine=raw_line,rawOrdinal=raw["ordinal"],ts=raw["ts"]))
def copy_mutable(m):
    assert m["mutableIdentity"] == b["mutableIdentity"]
    assert m["registry"]["identity"] == b["registry"]["identity"]
    for field in ["loaded","next","closed","sticky"]:
        s["ctx"][field]=m[field]
    s["ctx"]["rv"]=m["rv"]-b["rv"]+1
    s["ctx"]["range"]=m["range"]-b["range"]+1
    assert not m["info"]
request_line, request = find("UpdateWorkflowExecution",readback_line)
req=request["event"]["state"]
uid=req["request"]["meta"]["update_id"]
assert req["wait_policy"]["lifecycle_stage"] == 3
assert req["workflow_execution"]["run_id"] == run
s["calls"]["client-1"].update(uid=uid,status="request",active=True)
s["everRequested"].append(uid)
emit("UpdateWorkflowExecution",dict(c="client-1",u=uid,stage="COMPLETED"),request_line,request)
admit_line, admit = find("UpdaterApplyRequestNew",request_line)
m=admit["event"]["state"]["mutable"]
copy_mutable(m)
objects=m["registry"]["updates"]
assert set(objects)=={uid}
obj=objects[uid]
assert obj["state"]=="Admitted" and not obj["acceptedReady"] and not obj["outcomeReady"]
assert not obj["callbacks"] and obj["acceptedID"]==0
s["objects"].append(dict(uid=uid,generation=1,state=obj["state"],accepted="pending",outcome=pending,
                         acceptedID=obj["acceptedID"],callbacks=bool(obj["callbacks"])))
s["ctx"]["reg"][uid]=1
s["calls"]["client-1"].update(oid=1,status="binding")
s.update(pc="admitSchedule",caller="client-1")
emit("UpdaterApplyRequestNew",dict(c="client-1"),admit_line,admit)
schedule_line,schedule=find("AddWorkflowTaskScheduledEvent",admit_line)
m=schedule["event"]["state"]["mutable"]
copy_mutable(m)
t=m["task"]
assert t["Type"]==3 and t["StartedEventID"]==0 and m["timer"]["InMemory"]
assert m["timerPointer"]!="0x0" and m["timer"]["TimeoutType"]==2
assert m["timer"]["EventID"]==t["ScheduledEventID"]
assert m["timerState"]!=3
assert datetime.datetime.fromisoformat(schedule["ts"].replace("Z","+00:00")) < datetime.datetime.fromisoformat(m["timer"]["VisibilityTimestamp"].replace("Z","+00:00"))
task=dict(kind="Speculative",scheduled=t["ScheduledEventID"],started=t["StartedEventID"],startedTime=0,
          attempt=t["Attempt"],version=t["Version"],stamp=t["Stamp"],transient=False,
          route={1:"normal",2:"sticky"}[t["TaskQueue"]["kind"]])
s["ctx"]["task"]=task
s["timers"].append(dict(task=task,timeout="STS",speculative=m["timer"]["InMemory"],
                        eligible=False,submitted=False,cancelled=False,consumed=False))
s["timerPointer"]=1
s["dispatch"].append(task)
s["calls"]["client-1"]["status"]="wait"
s.update(pc="idle",caller="none")
emit("AddWorkflowTaskScheduledEvent",{},schedule_line,schedule)
target.parent.mkdir(parents=True,exist_ok=True)
target.write_text("".join(json.dumps(r,separators=(",",":"))+"\n" for r in result))
target.with_suffix(".provenance.json").write_text(json.dumps(dict(
    status="ADMISSION_PREFIX_ONLY",source=str(source),sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
    baselineRawLine=baseline_line,readbackRawLine=readback_line,recordVersionOffset=b["rv"]-1,
    rangeOffset=b["range"]-1,transitions=origin,remainingRawLines=len(rows)-schedule_line,
    stopReason="Full Matching, backend, cache, callback and waiter mapping is incomplete; no omitted suffix was validated."
),indent=2)+"\n")
print(f"{source.name}: mapped {len(result)-1} admission transitions; full trace INCOMPLETE")
