"""H11 confirmation on the pinned source (c411a201), read-only via sys.path.

WFCommServer._do_process_task_request (wf_comm_server.py:236-280) walks the
standing tasks. For a task already sent to the requesting client without a
result it sets resend_task = True and remembers the ClientTask, but does not
break; the next task's iteration resets resend_task = False and, when the
client is not a target of that task (NO_BLOCK), continues. The loop then ends
with client_task_to_send = the old ClientTask and resend_task = False, so the
publication block (lines 366-375) appends the SAME ClientTask to
task.client_tasks again. When the task exits, the monitor pops every entry of
client_tasks from _client_task_map without a default (line 1259): the second
pop raises KeyError inside _monitor_tasks, which has no handler, and the task
monitor thread dies. No task is retired, timed out or checked for dead
clients afterwards.

Scenario (concurrent tasks with disjoint targets; mode "cse" schedules them
exactly as the client-controlled CSE server controller does,
ccwf/cse_server_ctl.py:186-200, which then waits for get_num_standing_tasks()
to reach 0; mode "send" uses WFCommServer.send):
task A -> site-1, task B -> site-2 (scheduled in that order). site-1 gets A;
the reply is lost, so site-1 asks again (GET_TASK retry) and gets A resent.
site-1 then returns A's result. The real WFCommServer, ClientTask, Task and
SendTaskManager are used; only the engine is a stub. The monitor thread is the
real _monitor_tasks. No forced scheduling is needed: every step is a separate
API call in the order a client retry produces.
"""
import sys, threading, time
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.controller_spec import Task  # noqa: E402
from nvflare.apis.fl_constant import ReservedKey, ReturnCode  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.impl.wf_comm_server import WFCommServer  # noqa: E402
from nvflare.apis.shareable import ReservedHeaderKey, Shareable, make_reply  # noqa: E402

crashes = []
threading.excepthook = lambda a: crashes.append((a.thread.name, a.exc_type.__name__, str(a.exc_value)))

clients = [Client("site-1", "tok-1"), Client("site-2", "tok-2")]
eng = MagicMock()
eng.get_clients.return_value = clients
ctx_mgr = FLContextManager(engine=eng, identity_name="server", job_id="job1")
eng.new_context.side_effect = ctx_mgr.new_context

comm = WFCommServer(task_check_period=0.05)
comm._engine = eng
comm.controller = MagicMock()


def ctx_for(client):
    ctx = ctx_mgr.new_context()
    ctx.set_prop(ReservedKey.PEER_CTX, MagicMock(), private=True, sticky=False)
    return ctx


fl_ctx = ctx_mgr.new_context()
task_a = Task(name="validate_A", data=Shareable(), timeout=0)
task_b = Task(name="validate_B", data=Shareable(), timeout=0)
MODE = sys.argv[1] if len(sys.argv) > 1 else "send"
if MODE == "cse":   # ccwf/cse_server_ctl.py:186-193: one broadcast per evaluator
    comm.broadcast(task=task_a, fl_ctx=fl_ctx, targets=["site-1"], min_responses=1, wait_time_after_min_received=0)
    comm.broadcast(task=task_b, fl_ctx=fl_ctx, targets=["site-2"], min_responses=1, wait_time_after_min_received=0)
else:
    comm.send(task_a, fl_ctx, targets=["site-1"])
    comm.send(task_b, fl_ctx, targets=["site-2"])
print("mode:", MODE)
comm._task_monitor.start()                       # the real monitor loop

name1, id1, data1 = comm.process_task_request(clients[0], ctx_for(clients[0]))
print("site-1 first GET_TASK ->", name1, id1)
# the TASK_ASSIGNMENT reply is lost; the client retries GET_TASK
name2, id2, data2 = comm.process_task_request(clients[0], ctx_for(clients[0]))
print("site-1 retry GET_TASK ->", name2, id2, "(resend of the same client task:", id1 == id2, ")")
ids = [ct.id for ct in task_a.client_tasks]
print("task A client_tasks ids:", ids, "duplicated:", len(ids) != len(set(ids)))

# site-1 returns A's result
result = make_reply(ReturnCode.OK)
attempt = data2.get_header(ReservedHeaderKey.TASK_ATTEMPT_ID)
if attempt is not None:
    result.set_header(ReservedHeaderKey.TASK_ATTEMPT_ID, attempt)
comm.process_submission(clients[0], name2, id2, result, ctx_for(clients[0]))
time.sleep(1.0)
print("monitor thread alive:", comm._task_monitor.is_alive(), "crashes:", crashes)
print("standing tasks:", comm.get_num_standing_tasks(), [t.name for t in comm._tasks])

# site-2 completes B; with a live monitor B would be retired within 0.05 s
n3, i3, d3 = comm.process_task_request(clients[1], ctx_for(clients[1]))
r3 = make_reply(ReturnCode.OK)
if d3 is not None and d3.get_header(ReservedHeaderKey.TASK_ATTEMPT_ID) is not None:
    r3.set_header(ReservedHeaderKey.TASK_ATTEMPT_ID, d3.get_header(ReservedHeaderKey.TASK_ATTEMPT_ID))
comm.process_submission(clients[1], n3, i3, r3, ctx_for(clients[1]))
time.sleep(1.0)
print("after B's result: standing tasks:", comm.get_num_standing_tasks(), [t.name for t in comm._tasks],
      "B completion:", task_b.completion_status)
dup = len(ids) != len(set(ids))
dead = (not comm._task_monitor.is_alive()) and any(c[1] == "KeyError" for c in crashes)
stuck = comm.get_num_standing_tasks() > 0
print("H11 REPRODUCED" if dup and dead and stuck else f"not reproduced (dup={dup} dead={dead} stuck={stuck})")
comm._all_done = True
