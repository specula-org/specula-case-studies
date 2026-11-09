"""H05 (Phase 1 candidate): the Swarm aggregator's gather closes on "every trainer
replied" while the last reply is still inside aggregator.accept; the round's
aggregate misses that contribution and the late accept lands in the aggregator
after aggregation, so it leaks into the next round's aggregate.
Pinned source c411a201, read-only via sys.path.

Real code: swarm_client_ctl.Gatherer (gather/_do_gather: reply_time is set, then
aggregator.accept runs, both under the gatherer lock; is_done reads reply_time
without it; aggregate), InTimeAccumulateWeightedAggregator. Stubs: the client
controller (update_status, best metric), the engine behind fl_ctx.
Forced scheduling: site-2's accept is held right after its reply_time was set (the
window is the accept's own work: shape checks, per-key adds, and for disk-offloaded
tensors the materialization from disk) until the monitor thread has aggregated.
Control: no hold; both contributions enter the round's aggregate.
"""
import sys, threading, time
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
import numpy as np  # noqa: E402
from nvflare.apis.dxo import DXO, DataKind, MetaKey, from_shareable  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import ReservedKey  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.app_common.aggregators.intime_accumulate_model_aggregator import InTimeAccumulateWeightedAggregator  # noqa: E402
from nvflare.app_common.app_constant import AppConstants  # noqa: E402
from nvflare.app_common.ccwf.swarm_client_ctl import Gatherer  # noqa: E402


def contribution(site, value, rnd):
    s = DXO(DataKind.WEIGHT_DIFF, {"w": np.array([value, value])}, meta={MetaKey.NUM_STEPS_CURRENT_ROUND: 1}).to_shareable()
    s.set_peer_props({ReservedKey.IDENTITY_NAME: site})
    s.set_header(AppConstants.CURRENT_ROUND, rnd)
    s.add_cookie(AppConstants.CONTRIBUTION_ROUND, rnd)
    return s


def run(hold):
    engine = MagicMock()
    fl_ctx = FLContextManager(engine, "site-1", "job", {}, {}).new_context()
    aggr = InTimeAccumulateWeightedAggregator(expected_data_kind=DataKind.WEIGHT_DIFF)
    aggr.handle_event(EventType.START_RUN, fl_ctx)
    executor = MagicMock(best_metric=None, best_round=None, me="site-1")
    in_accept, aggregated = threading.Event(), threading.Event()
    real_accept = aggr.accept

    def accept(shareable, ctx):
        if hold and from_shareable(shareable).data["w"][0] == 100.0:
            in_accept.set()
            aggregated.wait(5)             # preempted between reply_time and the accumulator update
        return real_accept(shareable, ctx)

    aggr.accept = accept

    def gatherer(rnd):
        fl_ctx.set_prop(AppConstants.CURRENT_ROUND, rnd, private=True, sticky=True)
        return Gatherer(task_data=Shareable(), fl_ctx=fl_ctx, for_round=rnd, executor=executor, aggregator=aggr,
                        metric_comparator=MagicMock(), all_clients=["site-1", "site-2"], trainers=["site-1", "site-2"],
                        min_responses_required=2, wait_time_after_min_resps_received=10, timeout=None)

    g0 = gatherer(0)
    g0.gather("site-1", contribution("site-1", 1.0, 0), fl_ctx)
    t = threading.Thread(target=lambda: g0.gather("site-2", contribution("site-2", 100.0, 0), fl_ctx))
    t.start()
    if hold:
        in_accept.wait(5)
    else:
        t.join()
    while not g0.is_done():                # the monitor thread's check (_monitor_gather)
        time.sleep(0.01)
    r0 = from_shareable(g0.aggregate()).data["w"][0]
    aggregated.set()
    t.join()
    # next round: a fresh gatherer on the same aggregator, one new contribution of 5.0
    g1 = gatherer(1)
    g1.gather("site-1", contribution("site-1", 5.0, 1), fl_ctx)
    r1 = from_shareable(aggr.aggregate(fl_ctx)).data["w"][0]
    return r0, r1


ctl = run(hold=False)
h05 = run(hold=True)
print(f"control: round-0 aggregate {ctl[0]:.1f} (expected 50.5) | round-1 aggregate {ctl[1]:.1f} (expected 5.0)")
print(f"held   : round-0 aggregate {h05[0]:.1f}                 | round-1 aggregate {h05[1]:.1f}")
ok = abs(ctl[0] - 50.5) < 1e-6 and abs(h05[0] - 1.0) < 1e-6 and abs(h05[1] - 5.0) > 1e-6
print("H05 REPRODUCED (forced scheduling): the round closed without site-2's contribution and that"
      " contribution leaked into the next round's aggregate" if ok else "not reproduced")
