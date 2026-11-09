"""H04 (Phase 1 candidate, v11 V3): ScatterAndGather aggregates and saves an
accumulator that a failed accept left half-updated, and the run continues normally.
Pinned source c411a201, read-only via sys.path.

Real code: ScatterAndGather.control_flow and _accept_train_result, WFCommServer
(broadcast, process_task_request, process_submission with the result callback,
check_tasks), InTimeAccumulateWeightedAggregator / DXOAggregator /
WeightedAggregationHelper.add (per-key in-place add; a value without exposed shape
is materialized inside the loop), FullModelShareableGenerator. Stubs: the engine,
a recording persistor. Injected fault: site-2's contribution carries, as its second
key, a lazy value whose materialize() raises (a disk-offload backing that is gone;
the helper documents that such failures are not rolled back).
Control: the same run without the bad value: both sites accepted, no ERROR.
"""
import sys
from unittest.mock import Mock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
import numpy as np  # noqa: E402
from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.controller_spec import TaskCompletionStatus  # noqa: E402
from nvflare.apis.dxo import DXO, DataKind, MetaKey  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import ReservedKey  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.impl.wf_comm_server import WFCommServer  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.signal import Signal  # noqa: E402
from nvflare.app_common.abstract.learnable_persistor import LearnablePersistor  # noqa: E402
from nvflare.app_common.abstract.model import ModelLearnableKey, make_model_learnable  # noqa: E402
from nvflare.app_common.aggregators.intime_accumulate_model_aggregator import InTimeAccumulateWeightedAggregator  # noqa: E402
from nvflare.app_common.app_constant import AppConstants  # noqa: E402
from nvflare.app_common.shareablegenerators.full_model_shareable_generator import FullModelShareableGenerator  # noqa: E402
from nvflare.app_common.workflows.scatter_and_gather import ScatterAndGather  # noqa: E402


class GoneLazyRef:
    """A lazy tensor reference whose backing file was removed."""
    def materialize(self):
        raise OSError("offload backing file is gone")


def run(bad):
    clients = [Client("site-1", "t1"), Client("site-2", "t2")]
    engine = Mock(spec=ServerEngineSpec)
    engine.get_clients.return_value = clients
    fl_ctx = FLContextManager(engine, "server", "job", {}, {}).new_context()
    engine.new_context.side_effect = lambda: fl_ctx
    aggregator = InTimeAccumulateWeightedAggregator()
    aggregator.handle_event(EventType.START_RUN, fl_ctx)
    persistor = Mock(spec=LearnablePersistor)
    persistor.load.return_value = make_model_learnable({"a": np.zeros(2), "b": np.zeros(2)}, {})
    engine.get_component.side_effect = {"aggregator": aggregator, "persistor": persistor,
                                        "shareable_generator": FullModelShareableGenerator()}.get
    ctl = ScatterAndGather(min_clients=2, num_rounds=1, persistor_id="persistor", snapshot_every_n_rounds=0,
                           memory_gc_rounds=0, wait_time_after_min_received=0)
    comm = WFCommServer()
    comm._engine = engine
    ctl.set_communicator(comm)
    ctl.initialize(fl_ctx)
    panic = Mock()
    ctl.system_panic = panic
    seen = {}

    def broadcast(task, fl_ctx, min_responses, wait_time_after_min_received, **kw):
        comm.broadcast(task, fl_ctx, min_responses=min_responses, wait_time_after_min_received=0)
        contrib = {"site-1": {"a": np.array([1.0, 1.0]), "b": np.array([1.0, 1.0])},
                   "site-2": {"a": np.array([100.0, 100.0]), "b": GoneLazyRef() if bad else np.array([3.0, 3.0])}}
        for c in clients:
            name, tid, data = comm.process_task_request(c, fl_ctx)
            res = DXO(DataKind.WEIGHT_DIFF, contrib[c.name], meta={MetaKey.NUM_STEPS_CURRENT_ROUND: 1}).to_shareable()
            res.set_peer_props({ReservedKey.IDENTITY_NAME: c.name})
            res.set_cookie_jar(dict(data.get_cookie_jar()))
            res.add_cookie(AppConstants.CONTRIBUTION_ROUND, 0)
            comm.process_submission(c, name, tid, res, fl_ctx)
        seen["status"] = task.completion_status
        comm.check_tasks()

    ctl.broadcast_and_wait = broadcast
    ctl.control_flow(Signal(), fl_ctx)
    saved = persistor.save.call_args.args[0][ModelLearnableKey.WEIGHTS] if persistor.save.called else None
    return seen.get("status"), panic.called, saved


for label, bad in (("control", False), ("bad lazy value", True)):
    status, panicked, saved = run(bad)
    print(f"{label:15s} task status: {status} | panic: {panicked} | saved a: {None if saved is None else saved['a']}"
          f" | saved b: {None if saved is None else saved['b']}")
status, panicked, saved = run(True)
ok = status == TaskCompletionStatus.ERROR and not panicked and saved is not None and float(saved["a"][0]) > 1.0
print("H04 REPRODUCED (injected fault): the task ended ERROR, SAG still aggregated site-2's half-added "
      "contribution into 'a' and saved the model without a panic" if ok else "not reproduced")
