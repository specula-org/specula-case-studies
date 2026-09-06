"""Synthetic, hand-scripted snapshots. NOT traces from the Rust implementation.

Exercises normal commit/reply, loss/duplication, suffix transfer, crash/recovery,
and an election completed without the new primary's own DVC.
"""
import copy
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
REV = "3ac0104a567092139534c9022205d02281a2da41"


def fresh():
    return dict(status="Normal", view=0, lastNormal=0, commit=0, log=[],
                acks=[], table=[], heard=True, waiting=0, attempts=0,
                stable=0, svc=[], dvcSent=False, dvc=[], catching=False,
                nonce=0, responses=[], app=0, applied=[], out=[])


def msg(kind, src, dst, **kw):
    m = dict(kind=kind, src=src, dst=dst, view=0, opnum=0, commit=0,
             start=0, lastNormal=0, nonce=0, hasState=False, log=[],
             request=dict(client="", number=0, op=0), result=0)
    m.update(copy.deepcopy(kw))
    return m


def entry(key, value):
    return dict(key=key, value=copy.deepcopy(value))


replicas = [dict(id=i, live=True, durableView=0, incarnation=0,
                 usedNonces=[], state=fresh()) for i in range(3)]
clients = [dict(id="c0", state=dict(view=0, next=0, pending=[]))]
network = []
events = []


def r(i):
    return replicas[i]["state"]


def emit(name, outputs=(), consumed=None, **inputs):
    if consumed is not None:
        network.remove(consumed)
        inputs["message"] = consumed
    network.extend(copy.deepcopy(outputs))
    if "node" in inputs and replicas[inputs["node"]]["live"]:
        replicas[inputs["node"]]["durableView"] = r(inputs["node"])["view"]
    e = dict(tag="vsr", event=name, replicas=replicas, clients=clients,
             network=network, outputs=list(outputs), **inputs)
    events.append(copy.deepcopy(e))


def take(kind, src=None, dst=None):
    return copy.deepcopy(next(m for m in network if m["kind"] == kind
        and (src is None or m["src"] == src)
        and (dst is None or m["dst"] == dst)))


def append_request(i, req):
    r(i)["log"].append(copy.deepcopy(req))
    r(i)["table"] = [entry(req["client"], dict(number=req["number"],
                                               hasReply=False, result=0))]


def apply_one(i):
    s = r(i)
    q = s["log"][s["commit"]]
    s["commit"] += 1
    s["app"] += q["op"]
    s["applied"].append(copy.deepcopy(q))
    s["table"] = [entry(q["client"], dict(number=q["number"],
                                           hasReply=True, result=s["app"]))]


emit("Init", schema=1, system="vsr-rs", revision=REV, category="A",
     application="integer-sum", servers=[0, 1, 2], clientIds=["c0"],
     operations=[1, 2], primaryTimeout=2)
q = dict(client="c0", number=0, op=1)
clients[0]["state"].update(next=1, pending=[q])
emit("ClientOnRequest", [msg("Request", "c0", 0, request=q)], client="c0", op=1)
append_request(0, q)
r(0)["acks"] = [entry(1, [0])]
emit("OnRequest", [msg("Prepare", 0, j, request=q, opnum=1) for j in [1, 2]],
     consumed=take("Request"), node=0)
append_request(1, q)
ack = msg("PrepareOk", 1, 0, opnum=1)
emit("OnPrepare", [ack], consumed=take("Prepare", dst=1), node=1)
network.append(copy.deepcopy(ack))
emit("Duplicate", message=ack)
apply_one(0)
r(0)["acks"] = []
reply = msg("Reply", 0, "c0", request=q, result=1)
emit("OnPrepareOk", [reply], consumed=take("PrepareOk", src=1), node=0)
emit("ClientOnIdle", [msg("Request", "c0", j, request=q) for j in range(3)], client="c0")
emit("OnRequest", [reply], consumed=take("Request", dst=0), node=0)
clients[0]["state"]["pending"] = []
emit("ClientOnReply", consumed=take("Reply"), client="c0")
emit("OnPrepareOk", consumed=take("PrepareOk", src=1), node=0)
emit("Lose", consumed=take("Request", dst=1))
emit("OnRequest", consumed=take("Request", dst=2), node=2)
r(0)["stable"] = 1
emit("OnIdle", [msg("Commit", 0, j, commit=1) for j in [1, 2]], node=0)
r(2)["status"] = "StateTransfer"
emit("OnCommit", [msg("GetState", 2, 0)], consumed=take("Commit", dst=2), node=2)
emit("OnGetState", [msg("NewState", 0, 2, log=[q], opnum=1, commit=1)],
     consumed=take("GetState"), node=0)
append_request(2, q)
apply_one(2)
r(2)["status"] = "Normal"
emit("OnNewState", [msg("PrepareOk", 2, 0, opnum=1)], consumed=take("NewState"), node=2)
emit("OnPrepare", [msg("PrepareOk", 2, 0, opnum=1)], consumed=take("Prepare", dst=2), node=2)
apply_one(1)
emit("OnCommit", consumed=take("Commit", dst=1), node=1)
for _ in range(2):
    emit("OnPrepareOk", consumed=take("PrepareOk", src=2), node=0)
replicas[2]["live"] = False
replicas[2]["state"] = fresh()
emit("Crash", node=2)
replicas[2].update(live=True, incarnation=1, usedNonces=[1])
r(2).update(status="Recovering", nonce=1)
emit("Recover", [msg("Recovery", 2, j, nonce=1) for j in [0, 1]], node=2, nonce=1)
emit("OnRecovery", [msg("RecoveryResponse", 0, 2, nonce=1,
     hasState=True, log=[q], commit=1)], consumed=take("Recovery", dst=0), node=0)
emit("OnRecovery", [msg("RecoveryResponse", 1, 2, nonce=1)],
     consumed=take("Recovery", dst=1), node=1)
r(2)["responses"] = [entry(0, dict(view=0, hasState=True, log=[q], commit=1))]
emit("OnRecoveryResponse", consumed=take("RecoveryResponse", src=0), node=2)
append_request(2, q)
apply_one(2)
r(2).update(status="Normal", responses=[])
emit("OnRecoveryResponse", consumed=take("RecoveryResponse", src=1), node=2)
r(1).update(heard=False, stable=1)
emit("OnIdle", node=1)
r(1).update(waiting=1, stable=0)
emit("OnIdle", node=1)
r(1).update(waiting=0, status="ViewChange", view=1)
emit("OnIdle", [msg("StartViewChange", 1, j, view=1) for j in [0, 2]], node=1)
for i in [2, 0]:
    r(i).update(status="ViewChange", view=1, waiting=0, catching=False,
                svc=[1], dvcSent=True, dvc=[])
    out = [msg("StartViewChange", i, j, view=1) for j in range(3) if j != i]
    out += [msg("DoViewChange", i, 1, view=1, lastNormal=0, log=[q], opnum=1, commit=1)]
    emit("OnStartViewChange", out, consumed=take("StartViewChange", src=1, dst=i), node=i)
r(1)["dvc"] = [entry(2, dict(lastNormal=0, log=[q], commit=1))]
emit("OnDoViewChange", consumed=take("DoViewChange", src=2), node=1)
r(1).update(status="Normal", lastNormal=1, heard=True, stable=0,
            waiting=0, svc=[], dvcSent=False, dvc=[], catching=False, acks=[])
emit("OnDoViewChange", [msg("StartView", 1, j, view=1, log=[q], opnum=1, commit=1)
     for j in [0, 2]], consumed=take("DoViewChange", src=0), node=1)
for i in [0, 2]:
    r(i).update(status="Normal", lastNormal=1, heard=True, stable=0, waiting=0,
                svc=[], dvcSent=False, dvc=[], catching=False, acks=[])
    emit("OnStartView", [msg("PrepareOk", i, 1, view=1, opnum=1)],
         consumed=take("StartView", dst=i), node=i)
emit("OnStartViewChange", [msg("StartView", 1, 2, view=1, log=[q], opnum=1, commit=1)],
     consumed=take("StartViewChange", src=2, dst=1), node=1)
emit("OnStartView", consumed=take("StartView", dst=2), node=2)


def write(name, es):
    (HERE / name).write_text("".join(json.dumps(e, separators=(",", ":")) + "\n" for e in es))


write("trace-positive.ndjson", events)
bad = copy.deepcopy(events)
bad[5]["replicas"][0]["state"]["app"] = 999
write("trace-negative-state.ndjson", bad)
bad = copy.deepcopy(events)
bad[2]["outputs"][0]["request"]["op"] = 2
write("trace-negative-output.ndjson", bad)
bad = copy.deepcopy(events)
bad.pop(3)  # Omit the first real backup Prepare handler.
write("trace-negative-missing-event.ndjson", bad)
print(f"Wrote {len(events)}-event positive fixture and three negative fixtures")
