"""Build a two-site numpy Swarm (CCWF) job and run it in the NVFlare simulator.

Used by run_harness.sh with hooks/ on PYTHONPATH (TV_SWARM_LOG set), so every
simulator process logs the client-side Swarm events.
"""
import sys

from nvflare.apis.dxo import DataKind
from nvflare.app_common.aggregators.intime_accumulate_model_aggregator import InTimeAccumulateWeightedAggregator
from nvflare.app_common.ccwf.ccwf_job import CCWFJob, SwarmClientConfig, SwarmServerConfig
from nvflare.app_common.ccwf.comps.np_file_model_persistor import NPFileModelPersistor
from nvflare.app_common.ccwf.comps.np_trainer import NPTrainer
from nvflare.app_common.ccwf.comps.simple_model_shareable_generator import SimpleModelShareableGenerator


def main(workspace):
    job = CCWFJob(name="swarm_tv", min_clients=2)
    job.add_swarm(
        server_config=SwarmServerConfig(num_rounds=2),
        client_config=SwarmClientConfig(
            executor=NPTrainer(delta=1, sleep_time=0),
            persistor=NPFileModelPersistor(),
            shareable_generator=SimpleModelShareableGenerator(),
            aggregator=InTimeAccumulateWeightedAggregator(expected_data_kind=DataKind.WEIGHT_DIFF),
            wait_time_after_min_resps_received=30.0,
            min_responses_required=2,
        ),
    )
    job.simulator_run(workspace, n_clients=2, threads=2)


if __name__ == "__main__":
    main(sys.argv[1])
