"""Calibration-region candidate (ledger WfSJ.sag.flow, cause record lateAccept):
ScatterAndGather accepts a late result of round r after the round's aggregate was
computed; the default aggregator keeps it, so it is aggregated into round r+1 and the
same client's real round-(r+1) contribution is rejected as a duplicate.
Pinned source c411a201, read-only via sys.path.

Real code: ScatterAndGather.control_flow / process_result_of_unknown_task /
_accept_train_result, WFCommServer (broadcast, process_task_request,
process_submission -> unknown-task path, check_tasks),
InTimeAccumulateWeightedAggregator (no reset() override: Aggregator.reset is a no-op),
DXOAggregator, WeightedAggregationHelper (get_result() empties the accumulator inside
aggregate()), FullModelShareableGenerator.
Stubs: the engine; a persistor whose save() is where the late result arrives (the
window between aggregate() and `_current_round += 1`; in a deployment this is the time
to convert and save the model). Scheduling: the late submission is placed in that window
by the stub (forced interleaving); no fault is injected. min_clients=1 of 2 clients, so
site-2's result is late without any fault (the round ended at the first response).
Control: the same run with site-2's late result arriving after the round counter
advanced (it is discarded as a different round, round 1 aggregates 2 and 3).
"""
import sys
from unittest.mock import Mock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
import numpy as np  # noqa: E402
from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.dxo import DXO, DataKind, MetaKey, from_shareable  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import ReservedKey  # noqa: E402
from nvflare.apis.fl_context import FLContext, FLContextManager  # noqa: E402
from nvflare.apis.impl.wf_comm_server import WFCommServer  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.signal import Signal  # noqa: E402
from nvflare.app_common.abstract.learnable_persistor import LearnablePersistor  # noqa: E402
from nvflare.app_common.abstract.model import make_model_learnable  # noqa: E402
from nvflare.app_common.aggregators.intime_accumulate_model_aggregator import InTimeAccumulateWeightedAggregator  # noqa: E402
from nvflare.app_common.app_constant import AppConstants  # noqa: E402
from nvflare.app_common.shareablegenerators.full_model_shareable_generator import FullModelShareableGenerator  # noqa: E402
from nvflare.app_common.workflows.scatter_and_gather import ScatterAndGather  # noqa: E402


def result_for(name, data, value, rnd):
    res = DXO(DataKind.WEIGHT_DIFF, {"a": np.array([value, value])},
              meta={MetaKey.NUM_STEPS_CURRENT_ROUND: 1}).to_shareable()
    res.set_peer_props({ReservedKey.IDENTITY_NAME: name})
    res.set_cookie_jar(dict(data.get_cookie_jar()))
    res.add_cookie(AppConstants.CONTRIBUTION_ROUND, rnd)
    return res


def run(late_in_window):
    clients = {"site-1": Client("site-1", "t1"), "site-2": Client("site-2", "t2")}
    engine = Mock(spec=ServerEngineSpec)
    engine.get_clients.return_value = list(clients.values())
    fl_ctx = FLContextManager(engine, "server", "job", {}, {}).new_context()
    engine.new_context.side_effect = lambda: fl_ctx
    aggregator = InTimeAccumulateWeightedAggregator()
    aggregator.handle_event(EventType.START_RUN, fl_ctx)
    persistor = Mock(spec=LearnablePersistor)
    persistor.load.return_value = make_model_learnable({"a": np.zeros(2)}, {})
    engine.get_component.side_effect = {"aggregator": aggregator, "persistor": persistor,
                                        "shareable_generator": FullModelShareableGenerator()}.get
    ctl = ScatterAndGather(min_clients=1, num_rounds=2, persistor_id="persistor", snapshot_every_n_rounds=0,
                           memory_gc_rounds=0, wait_time_after_min_received=0)
    comm = WFCommServer()
    comm._engine = engine
    ctl.set_communicator(comm)
    ctl.initialize(fl_ctx)
    ctl.system_panic = Mock()
    rec = {"agg": [], "late": None, "accept_log": []}
    pending = {}

    real_aggregate = aggregator.aggregate

    def aggregate(fl_ctx):
        out = real_aggregate(fl_ctx)
        rec["agg"].append(from_shareable(out).data["a"].copy())
        return out
    aggregator.aggregate = aggregate

    real_accept = ctl._accept_train_result

    def accept(client_name, result, fl_ctx, is_unknown_task=False):
        ok = real_accept(client_name=client_name, result=result, fl_ctx=fl_ctx, is_unknown_task=is_unknown_task)
        rec["accept_log"].append((ctl._current_round, client_name, result.get_cookie(AppConstants.CONTRIBUTION_ROUND),
                                  "late" if is_unknown_task else "in-time", ok))
        return ok
    ctl._accept_train_result = accept

    def submit_late():
        if "site-2" in pending:
            name, tid, data = pending.pop("site-2")
            # a client request carries the client's peer context (identity, job), as the server
            # engine sets it for every request; the retired-assignment fence checks it
            peer = FLContext()
            peer.set_prop(ReservedKey.IDENTITY_NAME, "site-2", private=False, sticky=False)
            peer.set_prop(ReservedKey.RUN_NUM, fl_ctx.get_job_id(), private=False, sticky=False)
            fl_ctx.set_peer_context(peer)
            comm.process_submission(clients["site-2"], name, tid, result_for("site-2", data, 100.0, 0), fl_ctx)
            fl_ctx.set_peer_context(None)

    def save(learnable, fl_ctx):
        # the window between aggregate() and `_current_round += 1`
        if late_in_window:
            submit_late()
    persistor.save.side_effect = save

    def broadcast(task, fl_ctx, min_responses, wait_time_after_min_received, **kw):
        if not late_in_window:
            submit_late()  # control: arrives after the round counter advanced
        rnd = ctl._current_round
        comm.broadcast(task, fl_ctx, min_responses=min_responses, wait_time_after_min_received=0)
        got = {c: comm.process_task_request(clients[c], fl_ctx) for c in clients}
        if rnd == 0:
            name, tid, data = got["site-1"]
            comm.process_submission(clients["site-1"], name, tid, result_for("site-1", data, 1.0, 0), fl_ctx)
            pending["site-2"] = got["site-2"]  # site-2 is still training
        else:
            for c, v in (("site-1", 2.0), ("site-2", 3.0)):
                name, tid, data = got[c]
                comm.process_submission(clients[c], name, tid, result_for(c, data, v, rnd), fl_ctx)
        comm.check_tasks()
    ctl.broadcast_and_wait = broadcast
    ctl.control_flow(Signal(), fl_ctx)
    return rec


for label, inwin in (("control (late result after round advanced)", False), ("late result in the window", True)):
    rec = run(inwin)
    print(label)
    for a in rec["accept_log"]:
        print("   accept: wf round", a[0], "client", a[1], "contribution round", a[2], a[3], "->", "ACCEPTED" if a[4] else "rejected")
    print("   aggregates per round:", [list(map(float, x)) for x in rec["agg"]])

ctl_rec, bug_rec = run(False), run(True)
r1_ok = float(ctl_rec["agg"][1][0]) == 2.5
r1_bad = float(bug_rec["agg"][1][0]) == 51.0 and any(
    a[1] == "site-2" and a[2] == 1 and not a[4] for a in bug_rec["accept_log"])
print("REPRODUCED (forced interleaving, no injected fault): site-2's round-0 result accepted after round 0 was "
      "aggregated, aggregated into round 1, and site-2's round-1 contribution rejected"
      if r1_ok and r1_bad else "not reproduced")
