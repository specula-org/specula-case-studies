#!/usr/bin/env python3
from nvflare.apis.job_def import RunStatus

from repro_helpers import JobHarness, print_source_info, require_event


def control_abort_before_scheduler_sees_job():
    harness = JobHarness()
    try:
        harness.abort_before_running()
        runner_thread = harness.start_runner()
        try:
            harness.manager.wait_for_status(harness.job_id, RunStatus.FINISHED_ABORTED, harness.engine.new_context())
            assert harness.current_status() == RunStatus.FINISHED_ABORTED.value
            assert not harness.engine.started_jobs
            print("CONTROL: abort before scheduling stayed FINISHED:ABORTED and did not start the job")
        finally:
            harness.stop_runner(runner_thread)
    finally:
        harness.cleanup()


def reproduce_abort_overwritten_after_deploy_begins():
    harness = JobHarness()
    harness.engine.admin_server.block_deploy_reply = True
    runner_thread = harness.start_runner()
    try:
        require_event(harness.engine.admin_server.deploy_entered, "JobRunner blocked in client deploy")
        harness.abort_before_running()
        status_after_abort = harness.current_status()
        assert status_after_abort == RunStatus.FINISHED_ABORTED.value, status_after_abort

        harness.engine.admin_server.release_deploy_reply.set()
        require_event(harness.engine.started_event, "job start after pre-run abort")
        harness.manager.wait_for_status(harness.job_id, RunStatus.RUNNING, harness.engine.new_context())
        final_status = harness.current_status()
        assert final_status == RunStatus.RUNNING.value, final_status

        print("BUG: admin abort returned after writing FINISHED:ABORTED")
        print(f"BUG: JobRunner then started the same job; final persisted status is {final_status}")
        print(f"BUG: started_jobs={harness.engine.started_jobs}")
        print(f"BUG: status_transitions={harness.manager.transitions}")
    finally:
        harness.stop_runner(runner_thread)
        harness.cleanup()


if __name__ == "__main__":
    print_source_info()
    control_abort_before_scheduler_sees_job()
    reproduce_abort_overwritten_after_deploy_begins()
    print("RESULT: reproduced pre-run abort being overwritten by JobRunner")
