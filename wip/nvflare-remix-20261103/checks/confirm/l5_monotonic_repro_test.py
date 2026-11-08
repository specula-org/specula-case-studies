"""L5 (task-worker audit, round 10): CJ enforces Client API task deadlines with the
worker's CLOCK_MONOTONIC. Pinned source c411a201, run from an exported copy.

The worker writes time.monotonic() into progress markers on the shared job filesystem
(client_api_task_runner.py:39-42). CJ turns them into an absolute deadline
(result_wait_deadline, client_api_task_runner.py:62-77) and subtracts its own
time.monotonic() (TaskSupervisor._wait, supervisor.py:348-361). CLOCK_MONOTONIC counts
from each node's boot, so the subtraction is meaningless when the worker Pod runs on a
different node from the CJ Pod. Kubernetes is the only implemented task backend, and
the design recommends a CPU CJ with a GPU worker.

Real code: TaskWorkerExecutor, TaskSupervisor, FileTaskArtifactStore, the worker
process (task_worker_process -> run_worker -> Client API task runner), the cell session
and a real Client API script (the upstream SCRIPT plus post-send work). Stand-ins: the
upstream test-only ProcessTaskLauncher in place of the Kubernetes backend, and a Linux
time namespace (checks/confirm/timens_exec.py, CLOCK_MONOTONIC shifted by <offset>) in
place of "the worker Pod is on a node with a different boot time". Nothing else differs between control and bug runs.

Run: bash checks/confirm/l5_monotonic_repro.sh
"""

import os
import sys
import time
from dataclasses import replace

from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import ReturnCode
from nvflare.apis.signal import Signal
from tests.local_task_launcher import ProcessTaskLauncher
from tests.task_execution_test_utils import SCRIPT, _adapter
from tests.task_execution_test_utils import native_task as _native_task

native_task = _native_task
TIMENS_EXEC = os.environ["L5_TIMENS_EXEC"]


class NodeClockLauncher(ProcessTaskLauncher):
    """Launch the worker as if on a node whose CLOCK_MONOTONIC differs by ``offset`` seconds."""

    def __init__(self, offset):
        super().__init__()
        self.offset = offset

    def launch_task(self, request):
        if self.offset:
            # timens_exec replaces itself with the worker: same PID and process group.
            prefix = (sys.executable, "-B", TIMENS_EXEC, str(self.offset))
            request = replace(request, argv=(*prefix, *request.argv))
        return super().launch_task(request)


def _run(native_task, offset, *, post_send, finalization_timeout=30.0):
    _, custom, context, policy = native_task
    policy = replace(policy, launcher=NodeClockLauncher(offset), finalization_timeout=finalization_timeout)
    script = SCRIPT + f"\nimport time\ntime.sleep({post_send})\n"
    adapter, data = _adapter(custom, context, policy, script=script)
    started = time.monotonic()
    try:
        reply = adapter.execute("train", data, context, Signal())
        outcome = "OK" if reply.get_return_code(ReturnCode.OK) == ReturnCode.OK else reply.get_return_code()
    except Exception as error:
        outcome = f"{type(error).__name__}: {error}"
    elapsed = round(time.monotonic() - started, 1)
    adapter.handle_event(EventType.END_RUN, context)
    print(f"  worker clock offset {offset:+d}s, post-send work {post_send}s, "
          f"finalization_timeout {finalization_timeout}s -> {outcome} after {elapsed}s")
    return outcome


def test_worker_on_later_booted_node_is_cancelled_by_default_finalization_bound(native_task):
    print("\n[A] default finalization_timeout=30s, 2s of post-send work")
    control = _run(native_task, 0, post_send=2)
    assert control == "OK"


def test_worker_on_later_booted_node_bug(native_task):
    # Worker node booted 1000 s after the CJ node (e.g. a freshly scaled GPU node).
    bug = _run(native_task, -1000, post_send=2)
    assert bug.startswith("TimeoutError") and "timed out" in bug
    print("  L5-a REPRODUCED: a healthy 2s finalization was cancelled by the 30s bound")


def test_worker_on_earlier_booted_node_control(native_task):
    print("\n[B] finalization_timeout=1s, 4s of post-send work")
    control = _run(native_task, 0, post_send=4, finalization_timeout=1.0)
    assert control.startswith("TimeoutError")


def test_worker_on_earlier_booted_node_bug(native_task):
    # Worker node booted 1000 s before the CJ node.
    bug = _run(native_task, 1000, post_send=4, finalization_timeout=1.0)
    assert bug == "OK"
    print("  L5-b REPRODUCED: the 1s post-send bound was never enforced")
