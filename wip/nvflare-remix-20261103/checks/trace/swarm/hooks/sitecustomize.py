"""v11 Swarm trace hooks (loaded in every simulator process through PYTHONPATH).

Active only when TV_SWARM_LOG is set. Appends one JSON line per client-side
Swarm event (site, wall time, thread) to that file. Read by gen_tv_swarm.py.
"""
import json
import os
import threading
import time

_LOG = os.environ.get("TV_SWARM_LOG")


def _emit(ev, **kw):
    rec = dict(ev=ev, t=time.time(), pid=os.getpid(), th=threading.get_ident(), **kw)
    with open(_LOG, "a") as f:
        f.write(json.dumps(rec) + "\n")
        f.flush()


def _install():
    from nvflare.app_common.app_constant import AppConstants
    from nvflare.app_common.ccwf import client_ctl, client_controller_executor, swarm_client_ctl
    from nvflare.app_common.ccwf.common import Constant
    from nvflare.apis.shareable import ReturnCode

    SC = swarm_client_ctl.SwarmClientController
    CC = client_ctl.ClientSideController
    G = swarm_client_ctl.Gatherer

    orig_cfg = SC.process_config

    def process_config(self, fl_ctx):
        r = orig_cfg(self, fl_ctx)
        _emit("cfg", c=self.me)
        return r

    SC.process_config = process_config

    orig_set = CC.set_learn_task

    def set_learn_task(self, task_data, fl_ctx):
        ok = orig_set(self, task_data, fl_ctx)
        if ok:
            _emit("learnq", c=self.me, r=task_data.get_header(AppConstants.CURRENT_ROUND),
                  aggr=task_data.get_header(Constant.AGGREGATOR))
        return ok

    CC.set_learn_task = set_learn_task

    orig_start = SC.start_workflow

    def start_workflow(self, shareable, fl_ctx, abort_signal):
        reply = orig_start(self, shareable, fl_ctx, abort_signal)
        _emit("start", c=self.me, rc=reply.get_return_code(ReturnCode.OK))
        return reply

    SC.start_workflow = start_workflow

    orig_exec = SC.execute_learn_task

    def execute_learn_task(self, data, fl_ctx, abort_signal):
        result = orig_exec(self, data, fl_ctx, abort_signal)
        _emit("trained", c=self.me, r=data.get_header(AppConstants.CURRENT_ROUND),
              rc=result.get_return_code(ReturnCode.OK))
        return result

    SC.execute_learn_task = execute_learn_task

    orig_status = CC.update_status

    def update_status(self, last_round=None, action=None, error=None, all_done=False):
        orig_status(self, last_round=last_round, action=action, error=error, all_done=all_done)
        if action == "finished_learn_task":
            _emit("submitted", c=self.me, r=last_round)
        if error:
            _emit("error", c=self.me, action=action)

    CC.update_status = update_status

    orig_gather = G._do_gather

    def _do_gather(self, client_name, result, fl_ctx):
        me = self.fl_ctx.get_identity_name() if getattr(self, "fl_ctx", None) else None
        _emit("reply", c=me, frm=client_name, r=self.for_round)
        out = orig_gather(self, client_name, result, fl_ctx)
        _emit("accept", c=me, frm=client_name, r=self.for_round)
        return out

    G._do_gather = _do_gather

    orig_end = SC._end_gather

    def _end_gather(self, gatherer):
        _emit("gdone", c=self.me, r=gatherer.for_round)
        return orig_end(self, gatherer)

    SC._end_gather = _end_gather

    orig_endwf = CC._process_end_workflow

    def _process_end_workflow(self, topic, request, fl_ctx):
        _emit("ended", c=self.me)
        return orig_endwf(self, topic, request, fl_ctx)

    CC._process_end_workflow = _process_end_workflow

    CE = client_controller_executor.ClientControllerExecutor
    orig_ce = CE.execute

    def ce_execute(self, task_name, shareable, fl_ctx, abort_signal):
        me = fl_ctx.get_identity_name()
        kind = "config" if task_name.endswith("config") or "config" in task_name else (
            "start" if "start" in task_name else task_name)
        _emit("input", c=me, task=kind)
        return orig_ce(self, task_name, shareable, fl_ctx, abort_signal)

    CE.execute = ce_execute


if _LOG:
    try:
        _install()
    except Exception as e:  # never break the process under test
        _emit("hook_error", err=repr(e))
