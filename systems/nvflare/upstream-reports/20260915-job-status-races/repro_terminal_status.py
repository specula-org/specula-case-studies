#!/usr/bin/env python3
from nvflare.apis.job_def import RunStatus
from nvflare.fuel.flare_api.api_spec import MonitorReturnCode

from repro_helpers import GatedRunningJobDefManager, JobHarness, print_source_info, require_event


def control_completion_after_running_is_persisted():
    harness = JobHarness(manager_cls=GatedRunningJobDefManager)
    runner_thread = harness.start_runner()
    try:
        require_event(harness.manager.running_status_written, "normal RUNNING status write")
        harness.mark_server_process_finished()
        require_event(harness.manager.terminal_status_written, "normal terminal status write")
        final_status = harness.current_status()
        assert final_status == RunStatus.FINISHED_COMPLETED.value, final_status
        rc, meta = harness.monitor_once(timeout=1.0, poll_interval=0.1)
        assert rc == MonitorReturnCode.JOB_FINISHED, rc
        assert meta["status"] == RunStatus.FINISHED_COMPLETED.value
        print("CONTROL: normal completion stayed FINISHED:COMPLETED and monitor returned JOB_FINISHED")
    finally:
        harness.stop_runner(runner_thread)
        harness.cleanup()


def reproduce_running_overwrites_terminal_status():
    harness = JobHarness(manager_cls=GatedRunningJobDefManager)
    harness.manager.gate_running_writes = True
    runner_thread = harness.start_runner()
    try:
        require_event(harness.manager.running_write_entered, "JobRunner about to persist RUNNING")
        harness.mark_server_process_finished()
        require_event(harness.manager.terminal_status_written, "completion thread persisted FINISHED:COMPLETED")
        terminal_status = harness.current_status()
        assert terminal_status == RunStatus.FINISHED_COMPLETED.value, terminal_status

        harness.manager.allow_running_write.set()
        require_event(harness.manager.running_status_written, "delayed RUNNING status write")
        final_status = harness.current_status()
        assert final_status == RunStatus.RUNNING.value, final_status

        rc, meta = harness.monitor_once(timeout=0.5, poll_interval=0.1)
        assert rc == MonitorReturnCode.TIMEOUT, rc
        assert meta is None

        print("BUG: completion thread persisted FINISHED:COMPLETED while the RUNNING write was delayed")
        print(f"BUG: delayed RUNNING write then overwrote the terminal status; final status is {final_status}")
        print(f"BUG: monitor_job_and_return_job_meta returned {rc.name} because status was no longer terminal")
        print(f"BUG: status_transitions={harness.manager.transitions}")
    finally:
        harness.stop_runner(runner_thread)
        harness.cleanup()


if __name__ == "__main__":
    print_source_info()
    control_completion_after_running_is_persisted()
    reproduce_running_overwrites_terminal_status()
    print("RESULT: reproduced delayed RUNNING status overwriting a terminal job status")
