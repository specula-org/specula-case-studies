"""Create a minimal numpy-only NVFlare job folder used by the reproduction tests.

Server: ScatterAndGather + NPModelPersistor; clients: NPTrainer with a configurable sleep per round.
Only built-in, allow-listed components are used (see POC local/resources.json class_allow_list).
"""
import json
import os
import shutil


def make_probe_job(dest: str, name: str = "probe", num_rounds: int = 2, sleep_time: float = 2.0,
                   min_clients: int = 2, resource_spec: dict = None, pad_mb: int = 0) -> str:
    if os.path.exists(dest):
        shutil.rmtree(dest)
    cfg = os.path.join(dest, "app", "config")
    os.makedirs(cfg)
    meta = {
        "name": name,
        "resource_spec": resource_spec or {},
        "deploy_map": {"app": ["@ALL"]},
        "min_clients": min_clients,
        "mandatory_clients": [],
    }
    with open(os.path.join(dest, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)
    server = {
        "format_version": 2,
        "workflows": [
            {
                "id": "scatter_and_gather",
                "path": "nvflare.app_common.workflows.scatter_and_gather.ScatterAndGather",
                "args": {
                    "min_clients": min_clients,
                    "num_rounds": num_rounds,
                    "start_round": 0,
                    "wait_time_after_min_received": 0,
                    "aggregator_id": "aggregator",
                    "persistor_id": "persistor",
                    "shareable_generator_id": "shareable_generator",
                    "train_task_name": "train",
                    "train_timeout": 0,
                },
            }
        ],
        "components": [
            {"id": "persistor", "path": "nvflare.app_common.np.np_model_persistor.NPModelPersistor", "args": {}},
            {
                "id": "shareable_generator",
                "path": "nvflare.app_common.shareablegenerators.full_model_shareable_generator.FullModelShareableGenerator",
                "args": {},
            },
            {
                "id": "aggregator",
                "path": "nvflare.app_common.aggregators.intime_accumulate_model_aggregator.InTimeAccumulateWeightedAggregator",
                "args": {"expected_data_kind": "WEIGHTS"},
            },
        ],
    }
    client = {
        "format_version": 2,
        "executors": [
            {
                "tasks": ["train"],
                "executor": {"path": "nvflare.app_common.np.np_trainer.NPTrainer", "args": {"sleep_time": sleep_time}},
            }
        ],
        "task_data_filters": [],
        "task_result_filters": [],
        "components": [],
    }
    with open(os.path.join(cfg, "config_fed_server.json"), "w") as f:
        json.dump(server, f, indent=2)
    with open(os.path.join(cfg, "config_fed_client.json"), "w") as f:
        json.dump(client, f, indent=2)
    if pad_mb:
        # Optional inert data file (a job carrying a larger payload); only used to lengthen deployment.
        os.makedirs(os.path.join(dest, "app", "custom"), exist_ok=True)
        with open(os.path.join(dest, "app", "custom", "payload.bin"), "wb") as f:
            f.write(os.urandom(pad_mb * 1024 * 1024))
    return dest


if __name__ == "__main__":
    import sys

    print(make_probe_job(sys.argv[1] if len(sys.argv) > 1 else "probe_job"))
