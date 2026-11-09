"""H06 (Phase 1 candidate): with allow_busy_task, a learn task that arrives while the
client is busy makes ClientSideController abort the current task by firing
ABORT_TASK; event dispatch delivers it to the controller itself, which treats it as
"asked to stop" and finalizes the workflow, so the replacement task is accepted but
never runs and the client stops participating. Pinned source c411a201, read-only.

Real code: ClientSideController.set_learn_task / _abort_current_task / handle_event /
finalize / _do_learn (ccwf/client_ctl.py:179-206,227-243,417-487), FLComponent.fire_event,
and the real dispatcher nvflare.private.event.fire_event, which the client run
manager uses with every job component as a handler (client_run_manager.py:203-204),
the controller included. Stubs: the engine (its fire_event calls the real dispatcher
with the controller as the job's component), a learn executor that trains until
aborted. No forced scheduling; the only premise is a learn task arriving while busy
(e.g. the aggregator of round r+1 scattered before this client finished round r).
Control: the replacement arrives after the previous task finished.
"""
import sys, threading, time
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.private.event import fire_event  # noqa: E402
from nvflare.app_common.ccwf.client_ctl import ClientSideController  # noqa: E402


class Ctl(ClientSideController):
    def __init__(self):
        super().__init__(task_name_prefix="wf", allow_busy_task=True, learn_task_abort_timeout=5.0,
                         learn_task_check_interval=0.01)
        self.ran = []

    def start_workflow(self, shareable, fl_ctx, abort_signal):
        return Shareable()

    def do_learn_task(self, name, data, fl_ctx, abort_signal):
        r = data.get_header("round")
        self.ran.append(("start", r))
        while not abort_signal.triggered and not data.get_header("quick"):
            time.sleep(0.01)                     # training
        self.ran.append(("end", r, abort_signal.triggered))


def run(busy):
    ctl = Ctl()
    engine = MagicMock()
    engine.fire_event.side_effect = lambda event_type, fl_ctx: fire_event(event=event_type, handlers=[ctl], ctx=fl_ctx)
    fl_ctx = FLContextManager(engine, "site-1", "job", {}, {}).new_context()
    ctl.workflow_id, ctl.config = "wf", {}
    learner = threading.Thread(target=ctl._do_learn, daemon=True)
    learner.start()

    def task(r, quick=False):
        t = Shareable()
        t.set_header("round", r)
        t.set_header("quick", quick)
        return t

    ctl.set_learn_task(task(1, quick=not busy), fl_ctx)
    time.sleep(0.2)                              # round 1 is training (busy) or already done
    accepted = ctl.set_learn_task(task(2, quick=True), fl_ctx)
    time.sleep(0.5)
    return accepted, ctl.asked_to_stop, ctl.workflow_done, ctl.ran, learner.is_alive()


ctl_res = run(busy=False)
h06 = run(busy=True)
print("control (not busy): accepted:", ctl_res[0], "| asked_to_stop:", ctl_res[1], "| ran:", ctl_res[3])
print("busy replacement : accepted:", h06[0], "| asked_to_stop:", h06[1], "| workflow_done:", h06[2],
      "| ran:", h06[3], "| learn loop alive:", h06[4])
ok = ("start", 2) in ctl_res[3] and h06[0] and h06[1] and ("start", 2) not in h06[3] and not h06[4]
print("H06 REPRODUCED: the controller handled its own ABORT_TASK as a stop; the accepted replacement task"
      " never ran and the learn loop ended" if ok else "not reproduced")
