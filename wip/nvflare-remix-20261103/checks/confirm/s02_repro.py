"""S02/H02 confirmation: in-process Client API send() tail clears the next
task's input if the executor delivers it between publish_result() and the
clear_cache block (nvflare/client/in_process/api.py:226-239 at c411a201).
Scheduling is forced with events (the window is a real interleaving point:
publish_result returns control to the trainer thread before the clear).
Uses the pinned source tree read-only (sys.path), no network, no job."""
import sys, threading, time, os
SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.path.insert(0, SRC)
sys.dont_write_bytecode = True
from nvflare.client.in_process.api import InProcessClientAPI
from nvflare.app_common.abstract.fl_model import FLModel
from nvflare.app_common.utils.fl_model_utils import FLModelUtils
from nvflare.client.config import ConfigKey
from nvflare.fuel.data_event.data_bus import DataBus
from nvflare.client.in_process.api import TOPIC_GLOBAL_RESULT, TOPIC_LOCAL_RESULT

api = InProcessClientAPI(task_metadata={"job_id": "j", "site_name": "site-1", ConfigKey.TASK_NAME: "train"})
api.init(rank="0", config={ConfigKey.TASK_EXCHANGE: {ConfigKey.TRAIN_TASK_NAME: "train"}} if hasattr(ConfigKey, "TASK_EXCHANGE") else {})
bus = api.data_bus
results = []
got_result = threading.Event()
bus.subscribe([TOPIC_LOCAL_RESULT], lambda t, d, b: (results.append(d), got_result.set()))

# Force the interleaving: pause the trainer thread right after publish_result returns.
paused, resume = threading.Event(), threading.Event()
orig = api._adapter.publish_result
def publish_then_pause(shareable):
    orig(shareable)
    paused.set(); resume.wait(10)
api._adapter.publish_result = publish_then_pause

def model(r):
    return FLModelUtils.to_shareable(FLModel(params={"w": r}, current_round=r))

log = []
def trainer():
    for r in (1, 2):
        m = api.receive(timeout=2.0)
        log.append(("receive", r, None if m is None else m.current_round))
        if m is None:
            return
        api.send(FLModel(params={"w": m.params["w"] + 100}, current_round=m.current_round))
t = threading.Thread(target=trainer, daemon=True); t.start()
bus.publish([TOPIC_GLOBAL_RESULT], model(1))         # executor task 1 (callback sets fl_model)
assert got_result.wait(5); assert paused.wait(5)      # result 1 taken; trainer paused in send()
bus.publish([TOPIC_GLOBAL_RESULT], model(2))         # executor task 2 delivered (callback sets fl_model=2)
log.append(("fl_model after task2 delivery", getattr(api.fl_model, "current_round", None)))
resume.set()                                          # trainer resumes: clear_cache tail runs
t.join(5)
log.append(("fl_model after resume", getattr(api.fl_model, "current_round", None)))
for x in log: print(x)
lost = ("receive", 2, None) in log
print("S02 REPRODUCED: task-2 input lost, receive() timed out" if lost else "not reproduced")
