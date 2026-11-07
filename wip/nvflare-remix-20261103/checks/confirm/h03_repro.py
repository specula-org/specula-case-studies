"""H03 (Phase 1 rank 10, round 8): the accepted-result-source monitor of task A
stops the reused launch_once trainer that already serves task B.
Pinned source c411a201, read-only via sys.path.

ExternalProcessBackend._monitor_accepted_result_source (external_process_backend.
py:1239-1283) checks under trainer._result_failure_lock that the trainer's live
result source is still task A, then, outside the lock, evaluates heartbeat
silence and the cell connection. On a timeout it calls
_fail_accepted_result_source(trainer, A) - which re-checks the identity and
returns False when the source is no longer A (1285-1296) - and then calls
_stop_trainer(trainer) unconditionally (1268, 1278). If A settles and B is
accepted between the two checks, the monitor kills the trainer serving B, and no
source-failure notice is sent for B.

Real code: _TrainerSession, ExternalProcessBackend._monitor_accepted_result_source,
_fail_accepted_result_source, _claim_result_source_failure. Stubs: the process
group (alive), the cell (connected), _stop_trainer / _cleanup_trainer /
_fail_job_for_lost_result_source (recorders), DownloadService.notify_source_failure.
Forced schedule: the monitor thread is preempted right after it reads the peer's
silence (stale, above the timeout); meanwhile A settles and B's result is accepted.
Control: the trainer really is silent while serving A.
"""
import sys, threading, types
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

import nvflare.app_common.executors.client_api.external_process_backend as epb  # noqa: E402
from nvflare.fuel.f3.streaming.download_service import DownloadService  # noqa: E402

notices = []
DownloadService.notify_source_failure = staticmethod(lambda **kw: notices.append(kw["ref_ids"]) or {})


def scenario(preempt):
    notices.clear()
    tr = epb._TrainerSession("tok", "site-1.trainer")
    tr.result_source_live.set()
    tr.result_source_task_id = "A"
    tr.result_source_refs, tr.result_receiver_ids = ("refA",), ("server.job1",)

    def silent_for():
        if preempt:   # preempted here: A settles, B is accepted (cell_backend._handle_result_ready)
            with tr._result_failure_lock:
                tr.result_source_task_id = "B"
                tr.result_source_refs = ("refB",)
        return 20.0   # value read before B's messages refreshed the session
    tr.peer_silent_for = silent_for
    be = epb.ExternalProcessBackend.__new__(epb.ExternalProcessBackend)
    be.logger = MagicMock()
    be._context = types.SimpleNamespace(heartbeat_timeout=10.0)
    be._cell = types.SimpleNamespace(is_cell_connected=lambda fqcn: True)
    be._lifecycle_lock, be._terminal_intent, be._closed, be._run_abort_signal = threading.Lock(), None, False, None
    be._secure_mode = False
    be._process_group_alive = lambda t: True
    stops, failed_jobs = [], []
    be._stop_trainer = lambda t, natural_exit_wait=0.0: stops.append(t.result_source_task_id)
    be._cleanup_trainer = lambda t: None
    be._fail_job_for_lost_result_source = lambda reason: failed_jobs.append(reason)
    be._monitor_accepted_result_source(tr, "A")
    return {"trainer stopped while serving": stops, "source-failure notices": list(notices),
            "client job failed": bool(failed_jobs)}


ctl = scenario(False)
h03 = scenario(True)
print("control (silent while serving A):", ctl)
print("H03 (A settles, B accepted in between):", h03)
ok = ctl["trainer stopped while serving"] == [None] and ctl["source-failure notices"] == [("refA",)] \
    and h03["trainer stopped while serving"] == ["B"] and not h03["source-failure notices"]
print("H03 REPRODUCED: the stale monitor of task A stopped the trainer serving task B, with no failure notice"
      if ok else "not reproduced")
