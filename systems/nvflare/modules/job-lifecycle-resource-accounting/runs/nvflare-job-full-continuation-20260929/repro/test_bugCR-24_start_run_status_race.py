#!/usr/bin/env python3
"""Reproduce CR-24: FederatedServer.start_run can overwrite a completed engine.

The product code under test is unmodified.  The test uses:

* the real FederatedServer.start_run and FederatedServer.run_engine methods;
* the real ServerRunner.run method;
* a normal user controller whose control_flow returns immediately;
* a deterministic thread scheduler shim for one case only.  The shim makes
  Thread.start() run the target to completion before returning, which is a
  legal scheduling order for "child runs before parent executes next line".

Expected bad behavior: start_run does not return after run_engine has already
set engine_info.status to STOPPED, because start_run then blindly writes
MachineStatus.STARTED and enters its polling loop.  It only returns after the
test sets asked_to_stop, exactly like ServerAppRunner.stop/parent-loss cleanup.
"""

from __future__ import annotations

import os
import json
import sys
import tempfile
import threading
import time
import types
from types import SimpleNamespace


SOURCE = "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-24/worktree"
sys.path.insert(0, SOURCE)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import MachineStatus, ReservedTopic, ServerCommandNames  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.impl.controller import Controller  # noqa: E402
from nvflare.apis.impl.wf_comm_server import WFCommServer  # noqa: E402
from nvflare.fuel.utils.config_service import ConfigService  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
import nvflare.private.fed.server.fed_server as fed_server_mod  # noqa: E402
from nvflare.private.fed.server.server_json_config import WorkFlow  # noqa: E402
from nvflare.private.fed.server.server_runner import ServerRunnerConfig  # noqa: E402
from nvflare.private.fed.server.server_engine_internal_spec import EngineInfo  # noqa: E402


class ImmediateController(Controller):
    def __init__(self):
        super().__init__()
        self.events = []

    def start_controller(self, fl_ctx):
        self.events.append("start_controller")

    def control_flow(self, abort_signal, fl_ctx):
        self.events.append("control_flow_returned")
        return

    def stop_controller(self, fl_ctx):
        self.events.append("stop_controller")


class RecordingCell:
    def __init__(self):
        self.messages = []

    def fire_and_forget(self, targets=None, channel=None, topic=None, message=None, **kwargs):
        self.messages.append((targets, channel, topic, message))


class MinimalEngine:
    """Process/network edge for the real server app runner code."""

    def __init__(self, job_id, clients):
        self.engine_info = EngineInfo()
        self.asked_to_stop = False
        self.run_manager = None
        self.configurator = None
        self.client_manager = SimpleNamespace(clients={c.token: c for c in clients})
        self.events = []
        self.persist_calls = []
        self.aux_requests = []
        self.handlers = {}

    def set_run_manager(self, run_manager):
        self.run_manager = run_manager

    def set_configurator(self, conf):
        self.configurator = conf

    def new_context(self):
        return self.run_manager.new_context()

    def restore_components(self, snapshot, fl_ctx):
        pass

    def register_aux_message_handler(self, topic, message_handle_func):
        self.handlers[topic] = message_handle_func

    def fire_event(self, event_type, fl_ctx):
        self.events.append(event_type)

    def persist_components(self, fl_ctx, completed=False):
        self.persist_calls.append(completed)

    def get_participating_clients(self):
        return self.client_manager.clients

    def get_clients(self):
        return list(self.client_manager.clients.values())

    def send_aux_request(self, targets, topic, request, timeout, fl_ctx, optional, secure):
        assert topic == ReservedTopic.END_RUN
        self.aux_requests.append((targets, topic, timeout, optional, secure))
        return {}

    def shutdown_streamer(self):
        pass


class SyncThread:
    """Scheduler shim: a legal schedule where the child finishes before start() returns."""

    def __init__(self, target=None, args=(), kwargs=None, daemon=None, name=None):
        self._target = target
        self._args = args
        self._kwargs = kwargs or {}

    def start(self):
        self._target(*self._args, **self._kwargs)

    def join(self, timeout=None):
        return


def make_runner_config():
    controller = ImmediateController()
    communicator = WFCommServer()
    controller.set_communicator(communicator)
    workflow = WorkFlow("fast-empty-control-flow", controller)
    return ServerRunnerConfig(
        heartbeat_timeout=60,
        task_request_interval=0.01,
        workflows=[workflow],
        task_data_filters={},
        task_result_filters={},
        handlers=[communicator],
        components={"fast-empty-control-flow": controller},
    )


def make_server(job_id, workspace_root):
    clients = [Client("site-1", "token-site-1")]
    args = SimpleNamespace(workspace=workspace_root, config_folder="config", set=[])
    server = FederatedServer(
        project_name="cr24",
        min_num_clients=1,
        max_num_clients=1,
        args=args,
        check_engine_frequency=0.05,
    )
    server.cell = RecordingCell()
    server.engine = MinimalEngine(job_id=job_id, clients=clients)
    server.runner_config = make_runner_config()
    server.secure_train = False
    server.check_engine_frequency = 0.05
    return server, args


def init_config_service(root):
    ConfigService.reset()
    cfg_dir = os.path.join(root, "config")
    os.makedirs(os.path.join(root, "startup"), exist_ok=True)
    os.makedirs(os.path.join(root, "local"), exist_ok=True)
    os.makedirs(cfg_dir, exist_ok=True)
    ConfigService.initialize(section_files={}, config_path=[cfg_dir], var_dict={})


def run_start_run_case(label, force_child_first):
    root = tempfile.mkdtemp(prefix=f"cr24-{label}-")
    init_config_service(root)
    job_id = f"job-{label}"
    server, args = make_server(job_id, root)
    run_dir = os.path.join(root, job_id)
    os.makedirs(run_dir, exist_ok=True)
    with open(os.path.join(run_dir, "meta.json"), "w", encoding="utf-8") as f:
        json.dump({}, f)
    done = threading.Event()
    result = {"returned": False, "error": None}

    orig_threading = fed_server_mod.threading
    if force_child_first:
        fed_server_mod.threading = types.SimpleNamespace(Thread=SyncThread)

    def invoke_start_run():
        try:
            server.start_run(job_id, os.path.join(root, "app"), SimpleNamespace(), args, snapshot=None)
            result["returned"] = True
        except BaseException as e:  # observation only
            result["error"] = f"{type(e).__name__}: {e}"
        finally:
            done.set()

    caller = threading.Thread(target=invoke_start_run, name=f"caller-{label}", daemon=True)
    caller.start()
    returned_before_stop = done.wait(timeout=1.0)
    status_before_stop = server.engine.engine_info.status
    events_before_stop = list(server.engine.events)
    messages_before_stop = list(server.cell.messages)

    server.engine.asked_to_stop = True
    returned_after_stop = done.wait(timeout=3.0)
    fed_server_mod.threading = orig_threading

    print(f"CASE {label}")
    print(f"  forced_child_first={force_child_first}")
    print(f"  returned_before_asked_to_stop={returned_before_stop}")
    print(f"  engine_status_before_asked_to_stop={status_before_stop}")
    print(f"  returned_after_asked_to_stop={returned_after_stop}")
    print(f"  final_engine_status={server.engine.engine_info.status}")
    print(f"  result={result}")
    print(f"  events_before_stop={events_before_stop}")
    print(
        "  messages_before_stop="
        f"heartbeats:{sum(1 for m in messages_before_stop if m[2] == ServerCommandNames.HEARTBEAT)} "
        f"update_run_status:{sum(1 for m in messages_before_stop if m[2] == ServerCommandNames.UPDATE_RUN_STATUS)}"
    )
    print(
        "  messages_total="
        f"heartbeats:{sum(1 for m in server.cell.messages if m[2] == ServerCommandNames.HEARTBEAT)} "
        f"update_run_status:{sum(1 for m in server.cell.messages if m[2] == ServerCommandNames.UPDATE_RUN_STATUS)}"
    )
    print()

    return returned_before_stop, status_before_stop, returned_after_stop, result


def main():
    assert os.path.realpath(__import__("nvflare").__file__).startswith(SOURCE)

    control = run_start_run_case("control_real_threads", force_child_first=False)
    forced = run_start_run_case("forced_child_finishes_before_parent_started_write", force_child_first=True)

    control_ok = control[2] and control[3]["error"] is None
    bug_triggered = (
        forced[0] is False
        and forced[1] == MachineStatus.STARTED
        and forced[2] is True
        and forced[3]["error"] is None
    )

    print("ASSERTIONS")
    print(f"  control_completed_after_cleanup={control_ok}")
    print(f"  forced_interleaving_stuck_until_asked_to_stop={bug_triggered}")
    print("  expected_correct_behavior=forced case should return once run_engine set STOPPED")

    if not (control_ok and bug_triggered):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
