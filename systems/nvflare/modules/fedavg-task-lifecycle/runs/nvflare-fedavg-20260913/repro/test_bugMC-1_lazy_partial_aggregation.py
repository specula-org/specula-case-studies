from copy import deepcopy

from nvflare.apis.client import Client
from nvflare.apis.controller_spec import ClientTask
from nvflare.apis.fl_context import FLContext
from nvflare.apis.signal import Signal
from nvflare.apis.wf_comm_spec import WFCommSpec
from nvflare.app_common.abstract.fl_model import FLModel
from nvflare.app_common.app_constant import AppConstants
from nvflare.app_common.app_event_type import AppEventType
from nvflare.app_common.utils.fl_model_utils import FLModelUtils
from nvflare.app_common.workflows.fedavg import FedAvg
from nvflare.app_opt.pt.lazy_tensor_dict import LazyTensorDict


class ImmediateResultCommunicator(WFCommSpec):
    """Deliver one normal broadcast result through the task's registered callback."""

    def __init__(self, result):
        self.result = result
        self.delivered_task = None

    def broadcast(self, task, fl_ctx, targets=None, min_responses=0, wait_time_after_min_received=0):
        self.delivered_task = task
        client_task = ClientTask(client=Client("site-1", "token"), task=task)
        if task.before_task_sent_cb:
            task.before_task_sent_cb(client_task, fl_ctx)
        client_task.result = self.result
        task.result_received_cb(client_task, fl_ctx)

    def get_num_standing_tasks(self):
        return 0


def test_rejected_lazy_materialization_failure_does_not_roll_back_partial_param_aggregation(tmp_path):
    fl_ctx = FLContext()
    offload_dir = tmp_path / "tensor_offload"
    offload_dir.mkdir()
    lazy_params = LazyTensorDict(
        {"fails": (str(offload_dir / "missing.safetensors"), "fails")},
        temp_dir=str(offload_dir),
    )
    result = FLModelUtils.to_shareable(
        FLModel(
            params={"survived": 10.0, "fails": lazy_params.make_lazy_ref("fails")},
            current_round=0,
        )
    )
    communicator = ImmediateResultCommunicator(result)

    controller = FedAvg(num_clients=1, num_rounds=1, model=FLModel(params={"initial": 1.0}))
    controller.fl_ctx = fl_ctx
    controller.abort_signal = Signal()
    controller.set_communicator(communicator)
    controller.sample_clients = lambda _: [Client("site-1", "token")]

    accepted_flags = []
    saved_models = []
    aggregation_results = []

    def record_event(event_type):
        if event_type == AppEventType.AFTER_CONTRIBUTION_ACCEPT:
            accepted_flags.append(fl_ctx.get_prop(AppConstants.AGGREGATION_ACCEPTED))

    original_get_aggregated_result = controller._get_aggregated_result

    def record_aggregated_result():
        aggr_result = original_get_aggregated_result()
        aggregation_results.append(deepcopy(aggr_result))
        return aggr_result

    controller.event = record_event
    controller._get_aggregated_result = record_aggregated_result
    controller.save_model = lambda model: saved_models.append(deepcopy(model))

    controller.run()

    aggregation_stats = fl_ctx.get_prop(AppConstants.AGGREGATION_STATS)
    print(f"accepted_flags={accepted_flags}")
    print(f"aggregation_stats={aggregation_stats}")
    print(f"aggregated_result_params={aggregation_results[0].params}")
    print(f"aggregated_result_meta={aggregation_results[0].meta}")
    print(f"saved_model_params={saved_models[0].params}")

    assert accepted_flags == [False]
    assert aggregation_stats["accepted_contributions"] == 0
    assert aggregation_results[0].meta["nr_aggregated"] == 0
    assert aggregation_results[0].params == {"survived": 10.0}
    assert saved_models[0].params == {"survived": 10.0}
