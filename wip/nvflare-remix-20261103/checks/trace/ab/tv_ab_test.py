"""v11 blocks A+B group-level trace harness (WfSJ_C policies + Model_C).

Runs the real ScatterAndGather / CyclicController control flow with the real
WFCommServer task table (process_task_request / process_submission /
check_tasks, as upstream tests/unit_test/app_common/workflow/scatter_and_gather_test.py
does), the real InTimeAccumulateWeightedAggregator and FullModelShareableGenerator.
The persistor is a recording stand-in (save succeeds). Port-level events go to
$TV_AB_OUT/<scenario>.json:
  env  launch | task r | call c r rc | complete | retire
  obs  open | schedule r | acc r c out | ret c r accepted | agg r kind |
       aggregate r | art r kind | saved r returned
"""
import json
import os
from unittest.mock import Mock

import numpy as np

from nvflare.apis.client import Client
from nvflare.apis.dxo import DXO, DataKind, MetaKey
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import ReservedKey, ReturnCode
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.impl.wf_comm_server import WFCommServer
from nvflare.apis.server_engine_spec import ServerEngineSpec
from nvflare.apis.signal import Signal
from nvflare.app_common.abstract.learnable_persistor import LearnablePersistor
from nvflare.app_common.abstract.model import make_model_learnable
from nvflare.app_common.aggregators.intime_accumulate_model_aggregator import InTimeAccumulateWeightedAggregator
from nvflare.app_common.app_constant import AppConstants
from nvflare.app_common.shareablegenerators.full_model_shareable_generator import FullModelShareableGenerator
from nvflare.app_common.workflows.cyclic_ctl import CyclicController
from nvflare.app_common.workflows.scatter_and_gather import ScatterAndGather

OUT = os.environ.get("TV_AB_OUT", "/tmp/tv_ab")


class Tracer:
    def __init__(self):
        self.ev = []

    def __call__(self, ev_name, **kw):
        self.ev.append(dict(ev=ev_name, **kw))

    def dump(self, scn):
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, f"{scn}.json"), "w") as f:
            json.dump(self.ev, f, indent=1)


def site_no(name):
    return int(name.split("-")[1])


def make_env(n_clients):
    clients = [Client(f"site-{i}", f"token-{i}") for i in range(1, n_clients + 1)]
    engine = Mock(spec=ServerEngineSpec)
    engine.get_clients.return_value = clients
    fl_ctx = FLContextManager(engine, "server", "job", {}, {}).new_context()
    engine.new_context.side_effect = lambda: fl_ctx
    return clients, engine, fl_ctx


def recording_persistor(tr, rounds, state):
    persistor = Mock(spec=LearnablePersistor)
    persistor.load.return_value = make_model_learnable({"w": np.zeros(2)}, {})

    def save(learnable, fl_ctx):
        r = state["round"]
        tr("art", r=r, kind=state.get("kind", "clean"))
        tr("saved", r=r, returned="normal" if r == rounds or state.get("stop") else "none")

    persistor.save.side_effect = save
    return persistor


def result_for(task_data, client, value, rc=ReturnCode.OK, contribution_round=0):
    if rc == ReturnCode.OK:
        result = DXO(DataKind.WEIGHT_DIFF, value, meta={MetaKey.NUM_STEPS_CURRENT_ROUND: 1}).to_shareable()
    else:
        from nvflare.apis.shareable import make_reply

        result = make_reply(rc)
    result.set_peer_props({ReservedKey.IDENTITY_NAME: client.name})
    result.set_cookie_jar(dict(task_data.get_cookie_jar()))
    result.add_cookie(AppConstants.CONTRIBUTION_ROUND, contribution_round)
    return result


def run_sag(scn, rounds=2, values=None, stale_rounds=()):
    """SAG with one site; values[r] is round r's contribution; in stale_rounds the
    contribution carries the wrong contribution round, so can_accept rejects it."""
    tr = Tracer()
    clients, engine, fl_ctx = make_env(1)
    state = {"round": 0}
    aggregator = InTimeAccumulateWeightedAggregator()
    aggregator.handle_event(EventType.START_RUN, fl_ctx)
    real_accept, real_aggregate = aggregator.accept, aggregator.aggregate

    def accept(shareable, fl_ctx):
        ok = real_accept(shareable, fl_ctx)
        state["last_acc"] = ok
        tr("acc", r=state["round"], c=1, out="accepted" if ok else "rejected")
        if ok:
            state["any"] = True
        return ok

    def aggregate(fl_ctx):
        res = real_aggregate(fl_ctx)
        kind = "clean" if state.get("any") else "empty"
        state["kind"] = "clean" if kind == "clean" else "stale"
        tr("agg", r=state["round"], kind=kind)
        tr("aggregate", r=state["round"])
        return res

    aggregator.accept, aggregator.aggregate = accept, aggregate
    components = {"aggregator": aggregator, "persistor": recording_persistor(tr, rounds, state),
                  "shareable_generator": FullModelShareableGenerator()}
    engine.get_component.side_effect = components.get
    controller = ScatterAndGather(min_clients=1, num_rounds=rounds, persistor_id="persistor",
                                  snapshot_every_n_rounds=0, memory_gc_rounds=0, wait_time_after_min_received=0)
    comm = WFCommServer()
    comm._engine = engine
    controller.set_communicator(comm)
    controller.initialize(fl_ctx)
    panic = Mock()
    controller.system_panic = panic

    def broadcast(task, fl_ctx, min_responses, wait_time_after_min_received, **kwargs):
        state["round"] += 1
        state["any"] = False
        r = state["round"]
        tr("schedule", r=r)
        comm.broadcast(task, fl_ctx, min_responses=min_responses, wait_time_after_min_received=0)
        tr("task", r=r)
        cb = task.result_received_cb

        def traced_cb(client_task, fl_ctx):
            cb(client_task=client_task, fl_ctx=fl_ctx)
            tr("ret", c=1, r=r, accepted=bool(state.get("last_acc")))

        task.result_received_cb = traced_cb
        for client in clients:
            task_name, task_id, task_data = comm.process_task_request(client, fl_ctx)
            value = (values or {}).get(r, {"w": np.array([1.0, 2.0])})
            tr("call", c=site_no(client.name), r=r, rc="OK")
            cr = r if r in stale_rounds else r - 1
            comm.process_submission(client, task_name, task_id, result_for(task_data, client, value, contribution_round=cr), fl_ctx)
            tr("complete")
        comm.check_tasks()
        tr("retire")

    controller.broadcast_and_wait = broadcast
    tr("launch")
    tr("open")
    controller.control_flow(Signal(), fl_ctx)
    panic.assert_not_called()
    tr.dump(scn)
    return tr.ev


def run_cyclic(scn, rounds=2):
    """Cyclic relay over two sites (the relay needs at least two active sites)."""
    tr = Tracer()
    clients, engine, fl_ctx = make_env(2)
    state = {"round": 0}
    components = {"persistor": recording_persistor(tr, rounds, state),
                  "shareable_generator": FullModelShareableGenerator()}
    engine.get_component.side_effect = components.get
    controller = CyclicController(num_rounds=rounds, task_assignment_timeout=0, persist_every_n_rounds=1,
                                  snapshot_every_n_rounds=0, memory_gc_rounds=0, task_check_period=0.01)
    comm = WFCommServer()
    comm._engine = engine
    controller.set_communicator(comm)
    controller._engine = engine
    controller.get_client_disconnect_time = lambda name: None
    controller.start_controller(fl_ctx)
    controller._participating_clients = clients
    panic = Mock()
    controller.system_panic = panic

    def relay(task, fl_ctx, targets, task_assignment_timeout, dynamic_targets, abort_signal, **kwargs):
        state["round"] += 1
        r = state["round"]
        tr("schedule", r=r)
        comm.relay(task, fl_ctx, targets=targets, task_assignment_timeout=task_assignment_timeout,
                   dynamic_targets=dynamic_targets)
        tr("task", r=r)
        cb = task.result_received_cb

        def traced_cb(client_task, fl_ctx):
            cb(client_task=client_task, fl_ctx=fl_ctx)
            tr("ret", c=site_no(client_task.client.name), r=r, accepted=True)

        task.result_received_cb = traced_cb
        for client in targets:
            task_name, task_id, task_data = comm.process_task_request(client, fl_ctx)
            assert task_name, f"relay did not assign the task to {client.name}"
            tr("call", c=site_no(client.name), r=r, rc="OK")
            comm.process_submission(client, task_name, task_id,
                                    result_for(task_data, client, {"w": np.array([1.0, 2.0])}, contribution_round=r - 1), fl_ctx)
            tr("complete")
            comm.check_tasks()
        tr("retire")

    controller.relay_and_wait = relay
    tr("launch")
    tr("open")
    controller.control_flow(Signal(), fl_ctx)
    panic.assert_not_called()
    tr.dump(scn)
    return tr.ev


def test_sag_two_rounds():
    ev = run_sag("sag_ok", rounds=2)
    assert [e["ev"] for e in ev].count("saved") == 2


def test_sag_rejected_then_ok():
    # round 1's contribution names the wrong round: the aggregator rejects it, the
    # round aggregates nothing (the model is not updated) and SAG still saves
    ev = run_sag("sag_reject", rounds=2, stale_rounds=(1,))
    accs = [e["out"] for e in ev if e["ev"] == "acc"]
    assert accs == ["rejected", "accepted"]
    assert [e["kind"] for e in ev if e["ev"] == "art"] == ["stale", "clean"]


def test_cyclic_two_rounds():
    ev = run_cyclic("cyc_ok", rounds=2)
    assert [e["ev"] for e in ev].count("saved") == 2
