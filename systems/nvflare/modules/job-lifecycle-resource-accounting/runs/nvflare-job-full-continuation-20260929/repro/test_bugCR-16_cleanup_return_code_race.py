#!/usr/bin/env python3
"""CR-16 reproduction: abort cleanup can pop before wait_for_complete records rc.

This is a focused confirmation harness. It uses the real NVFlare ServerEngine
methods and the real local ProcessHandle. The only injected state is the normal
post-launch run_processes entry that ServerEngine._start_runner_process creates.
"""

import json
import logging
import os
import sys
import tempfile
import threading
import time
from types import SimpleNamespace


WORKTREE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-16/worktree"
)
sys.path.insert(0, WORKTREE)

import nvflare  # noqa: E402
from nvflare.apis.fl_constant import RunProcessKey  # noqa: E402
from nvflare.apis.job_def import RunStatus  # noqa: E402
from nvflare.apis.job_launcher_spec import JobReturnCode  # noqa: E402
from nvflare.app_common.job_launcher.process_launcher import ProcessHandle  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402
from nvflare.utils.process_utils import spawn_process  # noqa: E402


JOB_ID = "cr16-job"
logging.basicConfig(level=logging.INFO, format="%(levelname)s:%(name)s:%(message)s")


class ObservedRunInfo(dict):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.finished_checked = threading.Event()

    def get(self, key, default=None):
        if key == RunProcessKey.PROCESS_FINISHED:
            self.finished_checked.set()
        return super().get(key, default)


def enum_name(value):
    if hasattr(value, "name"):
        return f"{value.name}({int(value)})"
    return repr(value)


def wait_until(predicate, timeout=5.0, label="condition"):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise TimeoutError(f"timed out waiting for {label}")


def launch_exit_1_handle(delay=0.05):
    code = f"import sys, time; time.sleep({delay!r}); sys.exit(1)"
    adapter = spawn_process([sys.executable, "-c", code], os.environ.copy())
    return ProcessHandle(process_adapter=adapter)


def make_engine(job_handle, run_info):
    engine = ServerEngine.__new__(ServerEngine)
    engine.lock = threading.Lock()
    engine.run_processes = {JOB_ID: run_info}
    engine.exception_run_processes = {}
    engine.engine_info = SimpleNamespace(status=None)
    engine.logger = logging.getLogger("cr16.engine")

    def abort_command_fails(*args, **kwargs):
        # Real abort_app_on_server behavior: an exception on the optional in-band
        # ABORT command makes cleanup use max_wait=0.0 and pop immediately after
        # terminate().
        raise RuntimeError("simulated optional SJ ABORT command failure")

    engine.send_command_to_child_runner_process = abort_command_fails
    run_info[RunProcessKey.JOB_HANDLE] = job_handle
    run_info[RunProcessKey.JOB_ID] = JOB_ID
    run_info[RunProcessKey.PARTICIPANTS] = {}
    return engine


def summarize_case(name, engine, handle):
    exception_info = engine.exception_run_processes.get(JOB_ID)
    status = JobRunner._classify_finished_job_status(exception_info)
    return {
        "case": name,
        "raw_process_return_code": handle.adapter.poll(),
        "mapped_job_return_code": enum_name(handle.poll()),
        "run_processes_contains_job": JOB_ID in engine.run_processes,
        "exception_recorded": exception_info is not None,
        "recorded_process_return_code": (
            None if exception_info is None else enum_name(exception_info.get(RunProcessKey.PROCESS_RETURN_CODE))
        ),
        "completion_thread_classification": status.value,
    }


def cleanup_pops_before_waiter_reads(workspace):
    handle = launch_exit_1_handle()
    run_info = {RunProcessKey.PROCESS_FINISHED: False}
    engine = make_engine(handle, run_info)

    # Let the child really exit with code 1, then make abort cleanup pop first.
    time.sleep(0.2)
    engine.abort_app_on_server(JOB_ID)
    wait_until(lambda: JOB_ID not in engine.run_processes, label="cleanup pop")

    # The waiter now observes no run_processes entry, so it never calls
    # get_return_code(), even though the real local process exited non-zero.
    engine.wait_for_complete(workspace, JOB_ID, handle)
    return summarize_case("cleanup_popped_before_waiter_read", engine, handle)


def waiter_reads_then_cleanup_pops(workspace):
    handle = launch_exit_1_handle()
    run_info = ObservedRunInfo({RunProcessKey.PROCESS_FINISHED: False})
    engine = make_engine(handle, run_info)

    waiter = threading.Thread(target=engine.wait_for_complete, args=(workspace, JOB_ID, handle))
    waiter.start()
    wait_until(run_info.finished_checked.is_set, label="waiter retained run_process_info")

    # Same cleanup path, but now wait_for_complete has the retained dict
    # reference and writes the non-zero return code through it after the pop.
    engine.abort_app_on_server(JOB_ID)
    wait_until(lambda: JOB_ID not in engine.run_processes, label="cleanup pop")
    waiter.join(timeout=5.0)
    if waiter.is_alive():
        raise TimeoutError("wait_for_complete thread did not finish")
    return summarize_case("waiter_read_before_cleanup_pop", engine, handle)


def main():
    assert os.path.realpath(nvflare.__file__).startswith(WORKTREE), nvflare.__file__
    with tempfile.TemporaryDirectory(prefix="cr16-ws-") as workspace:
        cleanup_first = cleanup_pops_before_waiter_reads(workspace)
        waiter_first = waiter_reads_then_cleanup_pops(workspace)

    print("LEVEL 2 state injection: normal post-_start_runner_process run_processes entry")
    print("Real reachable sequence: _start_runner_process records run_processes and starts wait_for_complete;")
    print("then JobRunner._stop_run/ServerEngine.abort_app_on_server starts cleanup after an abort/stop signal.")
    print(json.dumps({"cleanup_first": cleanup_first, "waiter_first": waiter_first}, indent=2, sort_keys=True))

    assert cleanup_first["raw_process_return_code"] == 1
    assert cleanup_first["mapped_job_return_code"] == enum_name(JobReturnCode.EXECUTION_ERROR)
    assert cleanup_first["exception_recorded"] is False
    assert cleanup_first["completion_thread_classification"] == RunStatus.FINISHED_COMPLETED.value

    assert waiter_first["raw_process_return_code"] == 1
    assert waiter_first["mapped_job_return_code"] == enum_name(JobReturnCode.EXECUTION_ERROR)
    assert waiter_first["exception_recorded"] is True
    assert waiter_first["recorded_process_return_code"] == enum_name(JobReturnCode.EXECUTION_ERROR)
    assert waiter_first["completion_thread_classification"] == RunStatus.FINISHED_EXECUTION_EXCEPTION.value

    print("CR16_REPRODUCED: same real non-zero local-process exit is COMPLETED or EXECUTION_EXCEPTION depending on cleanup/read ordering")


if __name__ == "__main__":
    main()
