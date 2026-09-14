#!/usr/bin/env python3
"""CR-1 reproduction probe for WFCommServer broadcast ownership.

This uses the normal server-side controller/communicator task path:
controller.broadcast(...) schedules a broadcast task, and two clients retrieve
it with process_task_request(...).  The original task data is then mutated
between client retrievals to check whether a later client observes a changed
broadcast payload.  Current fixed behavior is that the second client receives
the protected broadcast snapshot and each client has distinct per-client
headers.
"""

import sys
import uuid
from unittest.mock import Mock

from nvflare.apis.client import Client
from nvflare.apis.controller_spec import Task
from nvflare.apis.fl_context import FLContext, FLContextManager
from nvflare.apis.impl.controller import Controller
from nvflare.apis.impl.wf_comm_server import WFCommServer
from nvflare.apis.server_engine_spec import ServerEngineSpec
from nvflare.apis.shareable import ReservedHeaderKey, Shareable
from nvflare.apis.signal import Signal


class DummyController(Controller):
    def __init__(self):
        super().__init__(task_check_period=0.1)

    def control_flow(self, abort_signal: Signal, fl_ctx: FLContext):
        return None

    def start_controller(self, fl_ctx: FLContext):
        return None

    def stop_controller(self, fl_ctx: FLContext):
        return None

    def process_result_of_unknown_task(self, client, task_name, client_task_id, result, fl_ctx):
        raise RuntimeError(f"unknown task {task_name} from {client.name}")


def create_client(name):
    return Client(name=name, token=str(uuid.uuid4()))


def setup_controller(clients):
    engine = Mock(spec=ServerEngineSpec)
    context_manager = FLContextManager(
        engine=engine,
        identity_name="server",
        job_id="job_1",
        public_stickers={},
        private_stickers={},
    )
    engine.new_context.return_value = context_manager.new_context()
    engine.get_clients.return_value = clients

    controller = DummyController()
    fl_ctx = engine.new_context()
    communicator = WFCommServer()
    controller.set_communicator(communicator)
    controller.initialize(fl_ctx)
    controller.communicator.initialize_run(fl_ctx=fl_ctx)
    return controller, fl_ctx


def assert_header_isolation(first_data, second_data, first_task_id, second_task_id):
    first_headers = first_data[ReservedHeaderKey.HEADERS]
    second_headers = second_data[ReservedHeaderKey.HEADERS]
    assert first_headers is not second_headers, "headers were shared between client envelopes"
    assert first_headers[ReservedHeaderKey.TASK_ID] == first_task_id
    assert second_headers[ReservedHeaderKey.TASK_ID] == second_task_id
    assert first_task_id != second_task_id, "broadcast clients should receive distinct task ids"


def main():
    clients = [create_client("site-1"), create_client("site-2")]
    controller, fl_ctx = setup_controller(clients)

    try:
        payload = Shareable()
        payload["model"] = {"round": 0, "weights": [1, 2, 3]}
        task = Task(name="train", data=payload)

        controller.broadcast(task=task, fl_ctx=fl_ctx, targets=clients, min_responses=len(clients))

        first_name, first_task_id, first_data = controller.communicator.process_task_request(clients[0], fl_ctx)
        assert first_name == "train"
        assert first_data["model"]["round"] == 0
        assert first_data["model"]["weights"] == [1, 2, 3]

        task.data["model"]["round"] = 99
        task.data["model"]["weights"].append(99)

        second_name, second_task_id, second_data = controller.communicator.process_task_request(clients[1], fl_ctx)
        assert second_name == "train"
        assert second_data["model"]["round"] == 0
        assert second_data["model"]["weights"] == [1, 2, 3]
        assert_header_isolation(first_data, second_data, first_task_id, second_task_id)

        print("CR-1 probe result: known symptom did NOT reproduce on this source.")
        print(f"first_payload={first_data['model']}")
        print(f"mutated_original={task.data['model']}")
        print(f"second_payload={second_data['model']}")
        print(f"first_task_id={first_task_id}")
        print(f"second_task_id={second_task_id}")
        print("broadcast_snapshot_present=", hasattr(task, "_broadcast_data"))
        return 0
    finally:
        controller.communicator.finalize_run(fl_ctx=fl_ctx)


if __name__ == "__main__":
    sys.exit(main())
