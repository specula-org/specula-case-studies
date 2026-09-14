#!/usr/bin/env python3
"""CR-5 reproduction attempt.

Drive a FedAvg-style broadcast through normal controller/communicator APIs and
check whether task completion on received responses is incorrectly reported as
accepted aggregation.
"""

import json
import os
import sys
import tempfile
import threading
import time

SOURCE_ROOT = os.environ.get(
    "NVFLARE_REPRO_SOURCE",
    "/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-fedavg-20260913/"
    "nvflare-fedavg/.specula-output/confirmation/CR-5/worktree",
)
if SOURCE_ROOT not in sys.path:
    sys.path.insert(0, SOURCE_ROOT)

from nvflare.apis.client import Client
from nvflare.apis.controller_spec import TaskCompletionStatus
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, FLMetaKey, ProcessType, ReturnCode
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.impl.wf_comm_server import WFCommServer
from nvflare.apis.shareable import ReservedHeaderKey
from nvflare.apis.signal import Signal
from nvflare.app_common.abstract.fl_model import FLModel
from nvflare.app_common.aggregators.weighted_aggregation_helper import AggregationStatsKey
from nvflare.app_common.app_constant import AppConstants
from nvflare.app_common.app_event_type import AppEventType
from nvflare.app_common.utils.fl_model_utils import FLModelUtils
from nvflare.app_common.widgets.job_stats_reporter import JobStatsReporter, JobStatusCode
from nvflare.app_common.workflows.fedavg import FedAvg

JOB_ID = "cr5_job"


class FakeWorkspace:
    def __init__(self, root):
        self.root = root

    def get_run_dir(self, job_id):
        path = os.path.join(self.root, job_id)
        os.makedirs(path, exist_ok=True)
        return path


class FakeEngine:
    def __init__(self, clients, reporter, run_root):
        self._clients = clients
        self.reporter = reporter
        self.events = []
        self.workspace = FakeWorkspace(run_root)
        self.ctx_mgr = FLContextManager(engine=self, identity_name="server", job_id=JOB_ID)

    def get_clients(self):
        return self._clients

    def new_context(self):
        return self.ctx_mgr.new_context()

    def get_component(self, _component_id):
        return None

    def get_workspace(self):
        return self.workspace

    def fire_event(self, event_type, fl_ctx):
        peer_ctx = fl_ctx.get_peer_context()
        peer = peer_ctx.get_identity_name() if peer_ctx else None
        self.events.append(
            {
                "event": event_type,
                "peer": peer,
                "round": fl_ctx.get_prop(AppConstants.CURRENT_ROUND),
                "accepted": fl_ctx.get_prop(AppConstants.AGGREGATION_ACCEPTED),
            }
        )
        self.reporter.handle_event(event_type, fl_ctx)


def make_peer_ctx(name):
    return FLContextManager(engine=None, identity_name=name, job_id=JOB_ID).new_context()


def wait_until(predicate, label, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise TimeoutError(label)


def make_result(params, client_name, return_code=ReturnCode.OK):
    result = FLModelUtils.to_shareable(
        FLModel(
            params=params,
            current_round=0,
            meta={
                "client_name": client_name,
                FLMetaKey.NUM_STEPS_CURRENT_ROUND: 1,
            },
        )
    )
    result.set_return_code(return_code)
    return result


def server_assign(engine, controller, client):
    ctx = engine.new_context()
    ctx.set_peer_context(make_peer_ctx(client.name))
    task_name, task_id, task_data = controller.communicator.process_task_request(client, ctx)
    if not task_name:
        raise RuntimeError(f"no task assigned to {client.name}")
    task_data.set_header(ReservedHeaderKey.TASK_ID, task_id)
    task_data.set_header(ReservedHeaderKey.TASK_NAME, task_name)
    ctx.set_prop(FLContextKey.TASK_NAME, task_name, private=True, sticky=False)
    ctx.set_prop(FLContextKey.TASK_ID, task_id, private=True, sticky=False)
    ctx.set_prop(FLContextKey.TASK_DATA, task_data, private=True, sticky=False)
    engine.fire_event(EventType.AFTER_TASK_DATA_FILTER, ctx)
    return task_name, task_id


def server_submit(engine, controller, client, task_name, task_id, result):
    ctx = engine.new_context()
    peer_ctx = make_peer_ctx(client.name)
    ctx.set_peer_context(peer_ctx)
    ctx.set_prop(FLContextKey.TASK_NAME, task_name, private=True, sticky=False)
    ctx.set_prop(FLContextKey.TASK_RESULT, result, private=True, sticky=False)
    ctx.set_prop(FLContextKey.TASK_ID, task_id, private=True, sticky=False)
    result.set_header(ReservedHeaderKey.TASK_NAME, task_name)
    result.set_header(ReservedHeaderKey.TASK_ID, task_id)
    result.set_peer_props(peer_ctx.get_all_public_props())

    engine.fire_event(EventType.BEFORE_PROCESS_SUBMISSION, ctx)
    controller.communicator.process_submission(client, task_name, task_id, result, ctx)


def main():
    print("CR-5 reproduction attempt")
    print("source_head=53ba7ee567468ea7971dad4faccef13c6cb35dc2")
    print("LEVEL 0: normal FedAvg controller API plus normal server assignment/submission boundary")

    with tempfile.TemporaryDirectory(prefix="cr5_jobstats_") as run_root:
        clients = [Client("site-1", "token-1"), Client("site-2", "token-2")]
        reporter = JobStatsReporter()
        engine = FakeEngine(clients, reporter, run_root)

        controller = FedAvg(
            num_clients=2,
            num_rounds=1,
            persistor_id="",
            model={"w": 0.0},
            task_check_period=0.01,
        )
        communicator = WFCommServer(task_check_period=0.01)
        controller.set_communicator(communicator)

        root_ctx = engine.new_context()
        root_ctx.set_prop(FLContextKey.PROCESS_TYPE, ProcessType.SERVER_JOB, private=True, sticky=False)
        controller.initialize(root_ctx)
        controller.abort_signal = Signal()
        communicator._engine = engine

        engine.fire_event(EventType.START_RUN, root_ctx)

        run_thread = threading.Thread(target=controller.run, name="cr5-fedavg-run")
        run_thread.start()

        wait_until(lambda: controller.get_num_standing_tasks() == 1, "FedAvg did not schedule a standing task")

        task_name_1, task_id_1 = server_assign(engine, controller, clients[0])
        task_name_2, task_id_2 = server_assign(engine, controller, clients[1])

        server_submit(engine, controller, clients[0], task_name_1, task_id_1, make_result({}, "site-1"))
        controller.communicator.check_tasks()
        standing_after_empty = controller.get_num_standing_tasks()

        server_submit(engine, controller, clients[1], task_name_2, task_id_2, make_result({"w": 2.0}, "site-2"))
        controller.communicator.check_tasks()

        run_thread.join(timeout=5.0)
        if run_thread.is_alive():
            raise TimeoutError("FedAvg run did not finish after all selected clients responded")

        engine.fire_event(EventType.END_RUN, root_ctx)
        summary = reporter.get_summary(root_ctx)

        task = next(iter(controller.communicator._completed_client_task_map.values()))
        acceptance_events = [
            (event["peer"], event["accepted"])
            for event in engine.events
            if event["event"] == AppEventType.AFTER_CONTRIBUTION_ACCEPT
        ]
        after_aggr_events = [event for event in engine.events if event["event"] == AppEventType.AFTER_AGGREGATION]
        aggr_stats = controller.fl_ctx.get_prop(AppConstants.AGGREGATION_STATS)
        round0 = summary["rounds"][0]

        assert standing_after_empty == 1, "default FedAvg should keep standing until all selected clients respond"
        assert controller.get_num_standing_tasks() == 0, "task should retire after all selected clients respond"
        assert acceptance_events == [("site-1", False), ("site-2", True)], acceptance_events
        assert controller._received_count == 1, controller._received_count
        assert aggr_stats[AggregationStatsKey.ACCEPTED_CONTRIBUTIONS] == 1, aggr_stats
        assert aggr_stats[AggregationStatsKey.CONTRIBUTORS] == ["site-2"], aggr_stats
        assert round0["accepted_clients"] == 1, round0
        assert round0["accepted_client_names"] == ["site-2"], round0
        assert round0["missing_client_count"] == 1, round0
        assert summary["status"] == JobStatusCode.PARTIAL, summary["status"]
        assert after_aggr_events, "FedAvg did not publish AFTER_AGGREGATION"

        print(f"task_completion_status={TaskCompletionStatus.OK.value}")
        print(f"completed_task_record_sample={task.client_name}:{task.task_name}")
        print(f"standing_after_empty_result={standing_after_empty}")
        print(f"standing_after_all_responses={controller.get_num_standing_tasks()}")
        print(f"aggregation_acceptance_events={acceptance_events}")
        print(f"fedavg_accepted_count={controller._received_count}")
        print(
            "aggregation_stats="
            + json.dumps(
                {
                    "accepted_contributions": aggr_stats[AggregationStatsKey.ACCEPTED_CONTRIBUTIONS],
                    "contributors": aggr_stats[AggregationStatsKey.CONTRIBUTORS],
                },
                sort_keys=True,
            )
        )
        print(
            "job_stats_round="
            + json.dumps(
                {
                    "accepted_clients": round0["accepted_clients"],
                    "accepted_client_names": round0["accepted_client_names"],
                    "missing_client_count": round0["missing_client_count"],
                    "status": summary["status"],
                    "reason": summary["status_reason"],
                },
                sort_keys=True,
            )
        )

    print("LEVEL 1: not used; Level 0 reached the claimed receipt-vs-acceptance state without timing help.")
    print("LEVEL 2: not used; no injected pre-condition was needed or justified.")
    print("LEVEL 3: not used; no source modification was needed or justified.")
    print("RESULT: no live wrong outcome; task completion and accepted aggregation remain distinct.")


if __name__ == "__main__":
    main()
