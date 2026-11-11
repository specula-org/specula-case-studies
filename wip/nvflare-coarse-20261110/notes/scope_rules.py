# Scope of the full-system ledger (PROMPT step 4, STANDARD 8 and 13).
# Paths relative to nvflare/ at pin c411a201. First matching rule wins; files listed
# in notes/region-calib.txt are the calibration region and are matched before these.
# A rule is (prefix, decision, label): decision "x:<category>" = excluded under STANDARD 8
# (label = reason), "c<k>" = in scope, chunk k (label = chunk region).

EXCLUDE_REASONS = {
    "tool": "toolchain: provisioning, CLI, packaging, job config and recipe generation run offline and do not take part in runtime component interaction",
    "ui": "dashboard / web UI: not part of the job lifecycle",
    "sec": "security: certificates, signing, encryption, confidential computing need an attacker model; tokens are kept only as identity generations",
    "fw": "ML framework adapters (PyTorch, TF, HF, Lightning, sklearn, MONAI): model/tensor conversion inside one component, no lifecycle state",
    "num": "numeric aggregation, filters, statistics, PSI, homomorphic encryption: the value computed is out of scope; result classes are modeled at the workflow (Model group)",
    "log": "logging, metrics, experiment tracking, statistics reporting: write-only side outputs",
    "sim": "simulator and in-process simulation: a single-process run mode, not a deployment",
}

RULES = [
    # ---- excluded (STANDARD 8)
    ("tool/", "x:tool", ""), ("lighter/cc_provision", "x:sec", ""), ("lighter/", "x:tool", ""),
    ("cli.py", "x:tool", ""), ("cli_exception.py", "x:tool", ""), ("cli_unknown_cmd_exception.py", "x:tool", ""), ("_version.py", "x:tool", ""), ("recipe/", "x:tool", ""), ("job_config/", "x:tool", ""),
    ("app_opt/pt/recipes", "x:tool", ""), ("app_opt/tf/recipes", "x:tool", ""), ("app_opt/xgboost/recipes", "x:tool", ""),
    ("app_common/np/recipes", "x:tool", ""), ("app_opt/sklearn/recipes", "x:tool", ""),
    ("dashboard/", "x:ui", ""),
    ("fuel/sec/", "x:sec", ""), ("security/", "x:sec", ""), ("app_opt/confidential_computing", "x:sec", ""),
    ("fuel/utils/secret_utils.py", "x:sec", ""), ("fuel/utils/job_secret_scanner.py", "x:sec", ""),
    ("private/fed/utils/job_cert_utils.py", "x:sec", ""), ("private/fed/utils/identity_utils.py", "x:sec", ""),
    ("private/fed/utils/app_authz.py", "x:sec", ""), ("fuel/hci/security.py", "x:sec", ""),
    ("fuel/hci/server/authz.py", "x:sec", ""), ("fuel/hci/tools/authz_preview.py", "x:sec", ""),
    ("app_opt/pt", "x:fw", ""), ("app_opt/tf", "x:fw", ""), ("app_opt/hf", "x:fw", ""), ("app_opt/lightning", "x:fw", ""),
    ("app_opt/sklearn", "x:fw", ""), ("app_opt/monai", "x:fw", ""), ("app_opt/kaggle", "x:fw", ""),
    ("client/hf", "x:fw", ""), ("client/lightning", "x:fw", ""), ("app_common/pt", "x:fw", ""),
    ("app_common/aggregators", "x:num", ""), ("app_common/filters", "x:num", ""), ("app_common/shareablegenerators", "x:num", ""),
    ("app_common/homomorphic_encryption", "x:num", ""), ("app_opt/he", "x:num", ""), ("app_common/statistics", "x:num", ""),
    ("app_opt/statistics", "x:num", ""), ("app_common/psi", "x:num", ""), ("app_opt/psi", "x:num", ""),
    ("app_common/workflows/statistics_controller.py", "x:num", ""), ("app_common/executors/statistics", "x:num", ""),
    ("app_common/executors/psi", "x:num", ""), ("app_common/workflows/hierarchical_statistics_controller.py", "x:num", ""),
    ("app_common/np", "x:num", ""), ("app_common/decomposers", "x:num", ""), ("edge/aggregators", "x:num", ""),
    ("edge/filters", "x:num", ""), ("edge/updaters", "x:num", ""), ("edge/shareablegenerators", "x:num", ""),
    ("edge/models", "x:num", ""), ("app_opt/feature_election", "x:num", ""), ("app_opt/p2p/utils", "x:num", ""),
    ("app_common/logging", "x:log", ""), ("metrics/", "x:log", ""), ("app_common/metrics_exchange", "x:log", ""),
    ("app_common/tracking", "x:log", ""), ("app_opt/tracking", "x:log", ""), ("fuel/utils/log_utils.py", "x:log", ""),
    ("app_common/widgets/metrics_artifact_writer.py", "x:log", ""), ("app_common/widgets/job_stats_reporter.py", "x:log", ""),
    ("app_common/widgets/streaming.py", "x:log", ""), ("app_common/widgets/convert_to_fed_event.py", "x:log", ""),
    ("private/fed/app/simulator/", "x:sim", ""), ("private/fed/simulator/", "x:sim", ""),
    ("private/fed/app/deployer/simulator_deployer.py", "x:sim", ""), ("edge/simulation/", "x:sim", ""),
    ("edge/tools/", "x:sim", ""),
    # ---- in scope, chunk order (STANDARD 13)
    # chunk 1: SP/CP process entry and restart, registration, heartbeat, server admin
    ("private/fed/app/server/", "c1", "SP entry, restart, registration, heartbeat, server admin"),
    ("private/fed/app/deployer/", "c1", ""), ("private/fed/app/fl_conf.py", "c1", ""),
    ("private/fed/app/job_process_cleanup.py", "c1", ""), ("private/fed/app/utils.py", "c1", ""),
    ("private/fed/app/client/client_train.py", "c1", ""), ("private/fed/server/", "c1", ""),
    ("private/fed/client/fed_client_base.py", "c1", ""), ("private/fed/client/fed_client.py", "c1", ""),
    ("private/fed/authenticator.py", "c1", ""), ("private/fed/cmi.py", "c1", ""), ("private/fed/tbi.py", "c1", ""),
    ("private/fed/utils/fed_utils.py", "c1", ""), ("private/fed/utils/app_deployer.py", "c1", ""),
    ("private/fed_json_config.py", "c1", ""), ("private/json_configer.py", "c1", ""), ("private/defs.py", "c1", ""),
    ("private/admin_defs.py", "c1", ""),
    # chunk 2: CP-side admin command agent, aux channel, admin protocol (hci), admin API
    ("private/fed/client/", "c2", "CP admin command agent, aux runner, admin protocol and API"),
    ("private/fed/app/client/", "c2", ""), ("private/fed/app/relay/", "c2", ""), ("private/aux_runner.py", "c2", ""),
    ("private/stream_runner.py", "c2", ""), ("private/privacy_manager.py", "c2", ""), ("fuel/hci/", "c2", ""),
    ("fuel/flare_api/", "c2", ""),
    # chunk 3: task worker, client API, remaining executors/launchers/workflows/widgets
    ("private/fed/task_worker/", "c3", "task worker, client API, remaining executors / launchers / workflows / widgets"),
    ("client/", "c3", ""), ("app_common/executors/", "c3", ""), ("app_opt/job_launcher/", "c3", ""),
    ("app_opt/task_launcher/", "c3", ""), ("app_common/job_launcher/", "c3", ""), ("app_common/task_launcher/", "c3", ""),
    ("app_common/workflows/", "c3", ""), ("app_common/widgets/", "c3", ""), ("widgets/", "c3", ""),
    ("app_common/ccwf/", "c3", ""), ("app_common/job_schedulers/", "c3", ""), ("app_common/resource_managers/", "c3", ""),
    ("app_common/resource_consumers/", "c3", ""), ("app_common/storages/", "c3", ""), ("app_common/state_persistors/", "c3", ""),
    ("app_common/model_locator/", "c3", ""), ("app_common/response_processors/", "c3", ""), ("app_common/app_defined/", "c3", ""),
    ("app_common/streamers/", "c3", ""), ("app_common/utils/", "c3", ""), ("app_common/abstract/", "c3", ""),
    ("app_common/", "c3", ""), ("apis/", "c3", ""), ("private/fed/utils/", "c3", ""), ("private/", "c3", ""),
    # chunk 4: external-process integrations
    ("app_opt/xgboost/", "c4", "external-process integrations: XGBoost, Flower, TIE, tensor stream, P2P"),
    ("app_opt/flower/", "c4", ""), ("app_common/tie/", "c4", ""), ("app_opt/tensor_stream/", "c4", ""),
    ("app_opt/p2p/", "c4", ""), ("app_opt/", "c4", ""),
    # chunk 5: edge and collab
    ("edge/", "c5", "edge (hierarchical device FL) and collab"), ("collab/", "c5", ""),
    # chunk 6: remaining runtime utilities
    ("fuel/utils/", "c6", "remaining runtime utilities (config, components, data events)"), ("fuel/data_event/", "c6", ""),
    ("fuel/common/", "c6", ""), ("fuel/message/", "c6", ""), ("fuel_opt/", "c6", ""), ("utils/", "c6", ""),
    ("fuel/__init__", "c6", ""), ("__init__", "c6", ""),
    # chunk 7: the f3 transport (last: also tests whether output drops once the protocol layer is coarsened)
    ("fuel/f3/", "c7", "f3 transport: cellnet, drivers, streaming, SFM, QAT"),
]
