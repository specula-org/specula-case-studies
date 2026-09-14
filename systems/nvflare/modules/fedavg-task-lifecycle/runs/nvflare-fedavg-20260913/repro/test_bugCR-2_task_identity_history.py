#!/usr/bin/env python3
"""Reproduce CR-2 through ordinary WFCommServer task/result entry points.

This script intentionally uses the real completed-task cache size. It completes
cache_size + 1 tasks so the first completed receipt is evicted, then submits the
old result again through process_submission, the same server-side entry point
used by SubmitUpdateCommand.
"""

import gc
import sys
import weakref
from pathlib import Path


SOURCE_ROOT = Path(__file__).resolve().parents[1] / "confirmation" / "CR-2" / "worktree"
sys.path.insert(0, str(SOURCE_ROOT))

from nvflare.apis.client import Client
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.impl.wf_comm_server import WFCommServer, _COMPLETED_CLIENT_TASK_CACHE_SIZE
from nvflare.apis.signal import Signal
from nvflare.app_common.abstract.fl_model import FLModel
from nvflare.app_common.app_constant import AppConstants
from nvflare.app_common.app_event_type import AppEventType
from nvflare.app_common.utils.fl_model_utils import FLModelUtils
from nvflare.app_common.workflows.fedavg import FedAvg


class Payload:
    pass


class EventEngine:
    def __init__(self, clients):
        self.clients = clients
        self.events = []
        self.context_manager = FLContextManager(engine=self, identity_name="server", job_id="job_1")

    def get_clients(self):
        return self.clients

    def new_context(self):
        return self.context_manager.new_context()

    def get_component(self, component_id):
        return None

    def fire_event(self, event_type, fl_ctx):
        self.events.append(event_type)


def require(condition, message):
    if not condition:
        print(f"NOT REPRODUCED: {message}")
        sys.exit(1)


def main():
    client = Client("site-1", "token")
    engine = EventEngine([client])
    controller = FedAvg(
        num_clients=1,
        num_rounds=_COMPLETED_CLIENT_TASK_CACHE_SIZE + 1,
        persistor_id="",
        task_check_period=999999,
    )
    communicator = WFCommServer(task_check_period=999999)
    controller.set_communicator(communicator)

    root_ctx = engine.new_context()
    controller.initialize(root_ctx)
    communicator.initialize_run(root_ctx)
    controller.abort_signal = Signal()

    callback_count = {"value": 0}

    def aggregate_callback(model):
        callback_count["value"] += 1
        return True

    first_task_id = None
    old_payload = Payload()
    old_payload_ref = weakref.ref(old_payload)
    old_result = FLModelUtils.to_shareable(FLModel(params={"w": old_payload}, current_round=0))

    try:
        for round_num in range(_COMPLETED_CLIENT_TASK_CACHE_SIZE + 1):
            controller.send_model(
                data=FLModel(params={"w": float(round_num)}, current_round=round_num),
                targets=[client.name],
                callback=aggregate_callback,
            )

            fl_ctx = engine.new_context()
            task_name, task_id, _ = communicator.process_task_request(client, fl_ctx)
            require(task_name == AppConstants.TASK_TRAIN, f"expected train task, got {task_name!r}")

            if round_num == 0:
                first_task_id = task_id

            result = FLModelUtils.to_shareable(FLModel(params={"w": float(round_num)}, current_round=round_num))
            communicator.process_submission(
                client=client,
                task_name=task_name,
                task_id=task_id,
                result=result,
                fl_ctx=fl_ctx,
            )
            communicator.check_tasks()

        normal_accept_events = engine.events.count(AppEventType.AFTER_CONTRIBUTION_ACCEPT)

        print(f"level=0")
        print(f"cache_size={_COMPLETED_CLIENT_TASK_CACHE_SIZE}")
        print(f"completed_tasks_driven={_COMPLETED_CLIENT_TASK_CACHE_SIZE + 1}")
        print(f"callback_count_before_late={callback_count['value']}")
        print(f"first_task_id_in_active={first_task_id in communicator._client_task_map}")
        print(f"first_task_id_in_completed={first_task_id in communicator._completed_client_task_map}")

        late_ctx = engine.new_context()
        communicator.process_submission(
            client=client,
            task_name=AppConstants.TASK_TRAIN,
            task_id=first_task_id,
            result=old_result,
            fl_ctx=late_ctx,
        )

        contribution_accept_delta = engine.events.count(AppEventType.AFTER_CONTRIBUTION_ACCEPT) - normal_accept_events
        print(f"callback_count_after_late={callback_count['value']}")
        print(f"after_contribution_accept_delta={contribution_accept_delta}")
        print(f"late_ctx_training_result_is_old_result={late_ctx.get_prop(AppConstants.TRAINING_RESULT) is old_result}")
        print(f"controller_fl_ctx_is_late_ctx={controller.fl_ctx is late_ctx}")
        print(
            "controller_fl_ctx_training_result_is_old_result="
            f"{controller.fl_ctx.get_prop(AppConstants.TRAINING_RESULT) is old_result}"
        )

        require(callback_count["value"] == _COMPLETED_CLIENT_TASK_CACHE_SIZE + 1, "late result invoked callback")
        require(contribution_accept_delta == 0, "late result fired contribution-accept event")
        require(late_ctx.get_prop(AppConstants.TRAINING_RESULT) is old_result, "late ctx did not retain old result")
        require(controller.fl_ctx is late_ctx, "controller did not retain late submission context")
        require(
            controller.fl_ctx.get_prop(AppConstants.TRAINING_RESULT) is old_result,
            "controller context did not retain old result",
        )

        communicator.finalize_run(engine.new_context())
        del late_ctx
        del old_result
        del old_payload
        gc.collect()
        print(f"payload_live_after_finalize_and_gc={old_payload_ref() is not None}")
        require(old_payload_ref() is not None, "old payload was reclaimed after finalize and gc")

        print(
            "BUG REPRODUCED: evicted completed-task duplicate reaches the unknown train-result path; "
            "it skips FedAvg aggregation but remains reachable via controller.fl_ctx TRAINING_RESULT."
        )
    finally:
        communicator._all_done = True


if __name__ == "__main__":
    main()
