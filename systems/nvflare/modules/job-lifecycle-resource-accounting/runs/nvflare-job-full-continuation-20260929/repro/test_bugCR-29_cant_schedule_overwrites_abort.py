#!/usr/bin/env python3
"""Reproduce CR-29: scheduler CAN_NOT_SCHEDULE overwrites an acknowledged abort.

This is a Level 1 timing-assisted repro.  It drives normal scheduler and admin
command entry points, with a test-only pause after the real refresh_meta() call
and before the scheduler's real set_status(FINISHED_CANT_SCHEDULE) call.
"""

import json
import sys
import tempfile
import threading
from pathlib import Path


SOURCE_ROOT = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-29/worktree"
)
sys.path.insert(0, str(SOURCE_ROOT))

from nvflare.apis.client import Client
from nvflare.apis.fl_constant import SystemComponents
from nvflare.apis.fl_context import FLContext, FLContextManager
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager
from nvflare.apis.job_def import ALL_SITES, DEFAULT_STUDY, JobMetaKey, RunStatus
from nvflare.apis.server_engine_spec import ServerEngineSpec
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage
from nvflare.fuel.hci.proto import MetaKey
from nvflare.fuel.hci.server.constants import ConnProps
from nvflare.private.fed.server.job_cmds import JobCommandModule


JOB_ID = "11111111-1111-4111-8111-111111111111"
SITE = "site-1"


class _Table:
    def __init__(self, headers, name=None):
        self.headers = headers
        self.name = name
        self.rows = []

    def add_row(self, row, meta=None):
        self.rows.append((row, meta))


class MockConnection:
    def __init__(self, engine, props=None):
        self.app_ctx = engine
        self.props = dict(props or {})
        self.errors = []
        self.strings = []
        self.successes = []
        self.tables = []
        self.meta = {}

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def append_error(self, msg, meta=None):
        self.errors.append((msg, meta))
        if meta:
            self.meta.update(meta)

    def append_string(self, msg, meta=None):
        self.strings.append((msg, meta))
        if meta:
            self.meta.update(meta)

    def append_success(self, msg, meta=None):
        self.successes.append((msg, meta))
        if meta:
            self.meta.update(meta)

    def append_table(self, headers, name=None):
        table = _Table(headers, name)
        self.tables.append(table)
        return table

    def append_dict(self, data, meta=None):
        self.strings.append((json.dumps(data), meta))
        if meta:
            self.meta.update(meta)


class DummyJobRunner:
    def stop_run(self, job_id, fl_ctx):
        raise AssertionError("abort_job should not call stop_run for SUBMITTED jobs")


class TimingJobManager(SimpleJobDefManager):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.pause_after_refresh = False
        self.refresh_reached = threading.Event()
        self.continue_after_abort = threading.Event()
        self.status_writes = []

    def refresh_meta(self, job, meta_keys, fl_ctx):
        super().refresh_meta(job, meta_keys, fl_ctx)
        if self.pause_after_refresh and job.job_id == JOB_ID:
            self.refresh_reached.set()
            if not self.continue_after_abort.wait(timeout=10.0):
                raise TimeoutError("test timed out waiting for admin abort")

    def set_status(self, jid, status, fl_ctx):
        self.status_writes.append((jid, status.value if hasattr(status, "value") else str(status)))
        return super().set_status(jid, status, fl_ctx)


class OneClientEngine(ServerEngineSpec):
    def __init__(self, job_manager, storage):
        self.job_def_manager = job_manager
        self.job_runner = DummyJobRunner()
        self.components = {
            job_manager.job_store_id: storage,
            SystemComponents.JOB_MANAGER: job_manager,
        }
        self.fl_ctx_mgr = FLContextManager(
            engine=self,
            identity_name="server",
            job_id="server",
            public_stickers={},
            private_stickers={},
        )

    def fire_event(self, event_type: str, fl_ctx: FLContext):
        return None

    def get_clients(self):
        return [Client(name=SITE, token="token-site-1")]

    def validate_targets(self, client_names):
        return None

    def get_client_name_from_token(self, token):
        return SITE if token == "token-site-1" else None

    def sync_clients_from_main_process(self):
        return None

    def update_job_run_status(self):
        return None

    def new_context(self):
        return self.fl_ctx_mgr.new_context()

    def get_workspace(self):
        return None

    def add_component(self, component_id: str, component):
        self.components[component_id] = component

    def get_component(self, component_id: str):
        return self.components.get(component_id)

    def register_aux_message_handler(self, topic: str, message_handle_func):
        return None

    def send_aux_request(self, targets, topic, request, timeout, fl_ctx, optional=False, secure=False):
        return {}

    def multicast_aux_requests(self, topic, target_requests, timeout, fl_ctx, optional=False, secure=False):
        return {}

    def get_widget(self, widget_id: str):
        return None

    def persist_components(self, fl_ctx: FLContext, completed: bool):
        return None

    def restore_components(self, snapshot, fl_ctx: FLContext):
        return None

    def start_client_job(self, job, client_sites, fl_ctx: FLContext):
        return None

    def check_client_resources(self, job, resource_reqs, fl_ctx):
        return {site_name: (True, f"token-{site_name}") for site_name in resource_reqs}

    def cancel_client_resources(self, resource_check_results, resource_reqs, fl_ctx):
        return None


def _stored_meta(engine, job_id):
    with engine.new_context() as fl_ctx:
        return engine.job_def_manager.get_job(job_id, fl_ctx).meta


def _schedule_once(engine, scheduler):
    with engine.new_context() as fl_ctx:
        candidates = engine.job_def_manager.get_jobs_to_schedule(fl_ctx)
        return scheduler.schedule_job(engine.job_def_manager, candidates, fl_ctx)


def main():
    with tempfile.TemporaryDirectory(prefix="cr29-job-store-") as tmp:
        storage = FilesystemStorage()
        job_manager = TimingJobManager(uri_root=str(Path(tmp) / "jobs"))
        engine = OneClientEngine(job_manager, storage)
        scheduler = DefaultJobScheduler(max_jobs=2, max_schedule_count=1, min_schedule_interval=0)

        with engine.new_context() as fl_ctx:
            job_manager.create(
                {
                    JobMetaKey.JOB_ID.value: JOB_ID,
                    JobMetaKey.JOB_NAME.value: "cr29-cant-schedule-overwrites-abort",
                    JobMetaKey.DEPLOY_MAP.value: {"app": [ALL_SITES]},
                    JobMetaKey.RESOURCE_SPEC.value: {},
                    JobMetaKey.MIN_CLIENTS.value: 2,
                    JobMetaKey.MANDATORY_CLIENTS.value: [],
                    JobMetaKey.STUDY.value: DEFAULT_STUDY,
                },
                b"dummy-job-content",
                fl_ctx,
            )

        print(f"submitted status={_stored_meta(engine, JOB_ID)[JobMetaKey.STATUS.value]}")

        _schedule_once(engine, scheduler)
        after_first = _stored_meta(engine, JOB_ID)
        print(
            "after first scheduler pass "
            f"status={after_first[JobMetaKey.STATUS.value]} "
            f"schedule_count={after_first[JobMetaKey.SCHEDULE_COUNT.value]}"
        )
        assert after_first[JobMetaKey.STATUS.value] == RunStatus.SUBMITTED.value
        assert after_first[JobMetaKey.SCHEDULE_COUNT.value] == 1

        job_manager.pause_after_refresh = True
        scheduler_error = []

        def run_second_pass():
            try:
                _schedule_once(engine, scheduler)
            except BaseException as e:
                scheduler_error.append(repr(e))

        t = threading.Thread(target=run_second_pass, name="scheduler-second-pass")
        t.start()
        if not job_manager.refresh_reached.wait(timeout=10.0):
            raise TimeoutError("scheduler did not reach refresh_meta pause")

        paused_status = _stored_meta(engine, JOB_ID)[JobMetaKey.STATUS.value]
        print(f"scheduler paused after refresh_meta; stored status before abort={paused_status}")

        abort_conn = MockConnection(engine, props={JobCommandModule.JOB_ID: JOB_ID})
        JobCommandModule().abort_job(abort_conn, ["abort_job", JOB_ID])
        print(f"abort command strings={abort_conn.strings}")
        print(f"abort command successes={abort_conn.successes}")
        if abort_conn.errors:
            raise AssertionError(f"abort_job returned errors: {abort_conn.errors}")

        after_abort = _stored_meta(engine, JOB_ID)[JobMetaKey.STATUS.value]
        print(f"status immediately after acknowledged abort={after_abort}")
        assert after_abort == RunStatus.FINISHED_ABORTED.value

        job_manager.continue_after_abort.set()
        t.join(timeout=10.0)
        if t.is_alive():
            raise TimeoutError("scheduler thread did not finish")
        if scheduler_error:
            raise AssertionError(f"scheduler error: {scheduler_error}")

        final_meta = _stored_meta(engine, JOB_ID)
        final_status = final_meta[JobMetaKey.STATUS.value]
        print(f"status after scheduler resumes={final_status}")
        print(f"set_status history={job_manager.status_writes}")

        list_conn = MockConnection(engine, props={ConnProps.ACTIVE_STUDY: DEFAULT_STUDY})
        JobCommandModule().list_jobs(list_conn, ["list_jobs", "-d", JOB_ID])
        if list_conn.errors:
            raise AssertionError(f"list_jobs returned errors: {list_conn.errors}")
        jobs_from_meta = list_conn.meta.get(MetaKey.JOBS, [])
        listed_status = jobs_from_meta[0][JobMetaKey.STATUS.value] if jobs_from_meta else None
        print(f"list_jobs -d reported status={listed_status}")
        print(f"list_jobs -d raw={list_conn.strings}")

        expected_history = [
            (JOB_ID, RunStatus.FINISHED_ABORTED.value),
            (JOB_ID, RunStatus.FINISHED_CANT_SCHEDULE.value),
        ]
        if job_manager.status_writes[-2:] != expected_history:
            raise AssertionError(f"unexpected status-write suffix: {job_manager.status_writes}")
        if final_status != RunStatus.FINISHED_CANT_SCHEDULE.value:
            raise AssertionError(f"final status was not overwritten: {final_status}")
        if listed_status != RunStatus.FINISHED_CANT_SCHEDULE.value:
            raise AssertionError(f"admin list_jobs did not observe overwritten status: {listed_status}")

        print("BUG_REPRODUCED: FINISHED:CAN_NOT_SCHEDULE overwrote acknowledged FINISHED:ABORTED")


if __name__ == "__main__":
    main()
