# 5286: Improve concise training output and summarize run results

{'state': 'OPEN', 'createdAt': '2026-09-12T14:13:44Z', 'updatedAt': '2026-09-12T22:22:17Z', 'headRefOid': '29fe1c3a27f6b35de765060158a3bf563aeb69b4', 'baseRefOid': '53ba7ee567468ea7971dad4faccef13c6cb35dc2', 'closedAt': None, 'mergedAt': None}

## Body
## What changes

The default concise console mixes useful training metrics with executor bookkeeping and raw client output, and Recipe result retrieval provides little help locating or interpreting the saved results. This PR makes **the existing `concise` mode** focus on round progress, reported metrics, and warnings/errors, and adds an **end-of-run summary** built from existing artifacts. No new log mode or example-specific reporting helper is required.

Concise is already the simulator default. Run the existing example normally; no environment variable or extra option is required:

```bash
python job.py
```

Recipe now consumes `--log_config` as a shared system argument alongside the existing export arguments. `python job.py --log_config full` (or `--log_config=full`) works without adding a logging option to each script. It overrides the SimEnv constructor value and inherited `FL_LOG_LEVEL`; with no option, existing defaults are unchanged. The short `-l` remains specific to `nvflare simulator`. Script-local help continues to list the script’s own arguments. This reuses the existing process logging environment for process-based POC services; it does not reconfigure Docker containers or already-running production services, or turn remote monitoring into a full-log stream.

- `console` and `log_fl.txt` use the focused presentation in concise mode. Full diagnostic records remain in `log.txt` and `log.json`; `msg_only`, `full`, and `verbose` retain their existing choices. Detailed client prints are available in diagnostic files.
- Shared server setup installs the existing `MetricsArtifactWriter` when no writer is configured, including ordinary FedJob exports and JSON jobs. Explicit writers keep their settings and are not duplicated. The `metrics_artifact_writer` component ID also reserves this role for independently implemented or no-op FLComponent replacements; a subclass of MetricsArtifactWriter is not required. The unified, PyTorch, and TensorFlow BaseFedJob annotations and API docstrings all accept `Optional[FLComponent]`, matching runtime validation. Existing metrics events produce `=== ROUND N / M ===` sections, aligned client rows as contributions arrive, an aggregated row, and the observed aggregation duration. The completed sections stay visible. The evaluation controller reports bounded client/model metrics as each result is saved, including jobs without Recipe or ValidationJsonGenerator. Recipe additionally presents a client-by-model comparison in its final summary. Live training headings repeat when later clients or the aggregator report different metric names. An accepted update with no displayable metrics still identifies its client; the aggregation count describes accepted updates, not displayed metric rows. Tables are bounded to two columns of metrics/models and ten rows, with artifact references for omitted results, shortened names, or structured values. Formatting failures cannot propagate into workflow control; original artifacts are unchanged.
- `Run.get_result()` prints a `RUN SUMMARY` section with up to ten recorded training rounds, separate evaluation tables, model/metrics/log directories, and elapsed time through result retrieval. Current completed status and legacy `FINISHED_OK` become `✓ Completed`; `FINISHED:CAN_NOT_SCHEDULE` becomes `✗ Not scheduled` without requesting training error logs; other supported terminal non-success statuses receive failure details and `✗ Failed`. Classification shares the existing session terminal-status rules. It supports standard simulator and downloaded POC/production layouts, reads JSON with a size limit, and never loads model weights. Missing or malformed artifacts cannot fail result retrieval. Cached calls do not print the report again; cleanup that removes a workspace is explicitly reported.
- POC and production share the same existing session monitor. Concise monitoring previews the server's latest structured logs using the existing log API. Parsing is limited to the last 64 KiB / 200 lines; retained deduplication state is at most 200 SHA-256 hashes, independent of job duration. Full/verbose monitoring also prints resource/deployment metadata on status changes; concise keeps that dictionary out of the console. No extra thread, log transport, or cursor API is introduced.
- Original FedAvg diagnostic messages and `center_message()` are unchanged from upstream. External-trainer tests explicitly select `full` logging because they assert transport/executor/persistence diagnostics. Empty `SimEnv` client lists are normalized to count-based configuration and tested through real job export to the simulator process boundary. Expected in-process `END_RUN` shutdown is INFO; unexpected stop reasons remain warnings. Resolved client counts are used in the simulation preparation message.


The existing `concise` configuration now selects ordinary metric-writer and evaluation-controller loggers using the existing `ConciseFilter` entry and `LoggerNameFilter`. It changes the existing console format to message-only and retains the timestamped file formatter for `log_fl.txt`. There is no `ProgressFormatter`, `ProgressFilter`, added formatter/filter entry, or `.progress` child-logger channel. Inherited reporting calls use the defining module’s ordinary logger, so GlobalModelEval, HECrossSiteModelEval, and user subclasses remain visible without adding logger names to the allowlist. Other subclass diagnostics keep their original logger. Remote replay uses that same configured filter and console formatter. The existing exclusion option suppresses class-level diagnostic INFO in concise output while retaining module-level reporting and all warnings/errors. Those diagnostics remain in log.txt/log.json and full/verbose output.

Shared argument parsing and import-time state live in private `recipe/_args.py`; `spec.py` delegates to the implementation and preserves its existing `DEFAULT_EXPORT_DIR` constant. The parser and its tests were moved, retaining the existing export/logging flag behavior. Run presentation lives in the private summary implementation.

Metric summaries and table cells share one scalar formatter. The small table renderer remains because the existing admin `Table` has a different bordered layout and does not provide incremental numeric columns. Summary text uses the existing wrapping helper; ordinary console records use the existing formatter. A single internal bounded-tail helper serves result summaries, error summaries, and server log retrieval. The existing console formatter and Recipe presentation share encoding-aware text conversion: UTF-8 retains decorations, ASCII/CP1252 receive compatible fallbacks, and reporting I/O errors cannot replace a result.

## Actual output

Captured from the unmodified three-round Hello PyTorch example on this checkout, using its default synthetic data and CPU training. The before capture uses upstream's default concise output; the after capture also uses concise, including the new end summary. **203 lines before → 77 lines after (including blank lines).** Local paths in the after capture are shortened below; no output lines are removed. `FL_LOG_LEVEL` was unset, verifying default concise behavior. The workspace override shown in the capture only isolates this validation run.

The values are reported as recorded: this example's accuracy values are percentages, but the shared renderer does not infer a unit or synthesize a training loss. `accuracy` is measured before local training; `accuracy_after_local_training` is measured afterward. Neither is presented as evaluation of the saved final model. The separate global-model evaluation reports 75 and 77; the best-model evaluation reports 70 at both sites.

<details>
<summary>After: approved round sections and final summary (complete captured output)</summary>

```text
/private/tmp/nvflare-pr1c/examples/hello-world/hello-pt/job.py:81: RuntimeWarning: NVFLARE_SIMULATOR_WORKSPACE_ROOT overrides SimEnv workspace_root from '/tmp/nvflare/simulation' to '/workspace'; unset it to use the constructor value
  env = SimEnv(num_clients=args.n_clients)

NVIDIA FLARE · hello-pt
Simulation · 2 clients

============================= ROUND 1 / 3 ==============================

  Training

  Client              accuracy  accuracy_after_local_training
  site-1                     1                             20
  site-2                     1                             20
  ──────────────────────────────────────────────────────────────────
  Aggregated                 1                             20

  ✓ Aggregated 2 client updates                                 10.1s

============================= ROUND 2 / 3 ==============================

  Training

  Client              accuracy  accuracy_after_local_training
  site-1                    30                             40
  site-2                    30                             70
  ──────────────────────────────────────────────────────────────────
  Aggregated                30                             55

  ✓ Aggregated 2 client updates                                 3.0s

============================= ROUND 3 / 3 ==============================

  Training

  Client              accuracy  accuracy_after_local_training
  site-1                    70                             80
  site-2                    70                             50
  ──────────────────────────────────────────────────────────────────
  Aggregated                70                             65

  ✓ Aggregated 2 client updates                                 2.0s

  Evaluating saved models on 2 clients…
Evaluated "SRV_FL_global_model.pt" on "site-1": accuracy=75
Evaluated "SRV_FL_global_model.pt" on "site-2": accuracy=77
Evaluated "SRV_best_FL_global_model.pt" on "site-1": accuracy=70
Evaluated "SRV_best_FL_global_model.pt" on "site-2": accuracy=70

============================= RUN SUMMARY ==============================

  NVIDIA FLARE · hello-pt
  Simulation · 2 clients

  ✓ Completed                                                   30.8s

  Training · aggregated client metrics

  Round               accuracy  accuracy_after_local_training
  1                          1                             20
  2                         30                             55
  3                         70                             65

  Model evaluation · accuracy

  Client        SRV_FL_global_model.pt  SRV_best_FL_global_model.pt
  site-1                            75                           70
  site-2                            77                           70

  Models    server/simulate_job/app_server/
  Metrics   server/simulate_job/metrics/
  Evaluation server/simulate_job/cross_site_val/cross_val_results.json
  Logs      server/log.txt · site-1/log.txt · site-2/log.txt
  Results   /workspace/hello-pt

Simulation completed successfully.
Result can be found in : /workspace/hello-pt
```
</details>

<details>
<summary>Before: default concise output (complete captured output)</summary>

```text
/private/tmp/nvflare-pr1c/examples/hello-world/hello-pt/job.py:79: RuntimeWarning: NVFLARE_SIMULATOR_WORKSPACE_ROOT overrides SimEnv workspace_root from '/tmp/nvflare/simulation' to '/private/tmp/nvflare-pr1c-before'; unset it to use the constructor value
  env = SimEnv(num_clients=args.n_clients)
2026-09-12 05:02:06,151 - INFO - model selection weights control: {}
2026-09-12 05:02:06,683 - INFO - Initializing BaseModelController workflow.
2026-09-12 05:02:06,683 - INFO - Beginning model controller run.
2026-09-12 05:02:06,683 - INFO - 
================================================================================
                                 Start FedAvg.                                  
================================================================================

2026-09-12 05:02:06,683 - INFO - loading initial model from persistor
2026-09-12 05:02:06,683 - INFO - Both source_ckpt_file_full_name and ckpt_preload_path are not provided. Using the default model weights initialized on the persistor side.
2026-09-12 05:02:06,687 - INFO - 
--------------------------------------------------------------------------------
                                Round 0 started.                                
--------------------------------------------------------------------------------

2026-09-12 05:02:06,688 - INFO - Sampled clients: ['site-1', 'site-2']
2026-09-12 05:02:06,688 - INFO - Sending task train to ['site-1', 'site-2']
2026-09-12 05:02:09,165 - INFO - ClientTaskWorker started to run
2026-09-12 05:02:09,165 - INFO - ClientTaskWorker started to run
2026-09-12 05:02:10,040 - INFO - start task run() with full path: /private/tmp/nvflare-pr1c-before/hello-pt/site-2/simulate_job/app_site-2/custom/client.py
2026-09-12 05:02:10,040 - INFO - start task run() with full path: /private/tmp/nvflare-pr1c-before/hello-pt/site-1/simulate_job/app_site-1/custom/client.py
2026-09-12 05:02:10,041 - INFO - Initialize ClientRunner for client: site-2
2026-09-12 05:02:10,041 - INFO - Initialize ClientRunner for client: site-1
2026-09-12 05:02:10,046 - INFO - set transaction info: tx_id='T614fa263-a4d2-470c-9c2d-b07a5e0050cb', ref_id='e7eb0f49-6b5a-4bf5-99cf-3129bbe2e80b' self.num_receivers=1
2026-09-12 05:02:10,046 - INFO - set transaction info: tx_id='T016d14fc-a1f8-4811-bdd8-de793d866b77', ref_id='77001582-3dc0-499e-ba50-2ee272f42ce5' self.num_receivers=1
2026-09-12 05:02:10,056 - INFO - execute for task (train)
2026-09-12 05:02:10,057 - INFO - sending task data to in-process trainer
2026-09-12 05:02:10,057 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:10,057 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:10,057 - INFO - execute for task (train)
2026-09-12 05:02:10,057 - INFO - sending task data to in-process trainer
2026-09-12 05:02:10,637 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:10,637 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:15,546 - INFO - site = site-2, current_round=0
2026-09-12 05:02:15,546 - INFO - site = site-1, current_round=0
2026-09-12 05:02:15,577 - INFO - Accuracy of the network on 100 test images: 1.00%
2026-09-12 05:02:15,577 - INFO - Accuracy of the network on 100 test images: 1.00%
2026-09-12 05:02:15,693 - INFO - site=site-1, epoch=1/1, loss=2.3030
2026-09-12 05:02:15,693 - INFO - site=site-2, epoch=1/1, loss=2.3022
2026-09-12 05:02:15,694 - INFO - Finished Training for site-2
2026-09-12 05:02:15,694 - INFO - Finished Training for site-1
2026-09-12 05:02:15,705 - INFO - Accuracy of the network on 100 test images: 20.00%
2026-09-12 05:02:15,705 - INFO - Accuracy of the network on 100 test images: 20.00%
2026-09-12 05:02:15,725 - INFO - site: site-2, sending model to server.
2026-09-12 05:02:15,725 - INFO - site: site-1, sending model to server.
2026-09-12 05:02:16,192 - INFO - set transaction info: tx_id='Tab4227d7-2777-40e7-8f43-f6cdc6ee65c0', ref_id='b8e6f3e1-7642-49d2-a1eb-7367f5af5aa3' self.num_receivers=1
2026-09-12 05:02:16,193 - INFO - set transaction info: tx_id='T2caa15ca-72a1-4faf-b731-cb3f3bb20d9c', ref_id='7096fb9e-d9e0-4c12-8f43-692085873bcd' self.num_receivers=1
2026-09-12 05:02:16,200 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:16,201 - INFO - Aggregated 1/2 results
2026-09-12 05:02:16,201 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:16,202 - INFO - Aggregated 2/2 results
2026-09-12 05:02:16,203 - INFO - Finished one task run for client: site-1 interval: 2 task_processed: True
2026-09-12 05:02:16,204 - INFO - Finished one task run for client: site-2 interval: 2 task_processed: True
2026-09-12 05:02:16,783 - INFO - Start persist model on server.
2026-09-12 05:02:16,789 - INFO - End persist model on server.
2026-09-12 05:02:16,789 - INFO - 
--------------------------------------------------------------------------------
                                Round 1 started.                                
--------------------------------------------------------------------------------

2026-09-12 05:02:16,789 - INFO - Sampled clients: ['site-1', 'site-2']
2026-09-12 05:02:16,790 - INFO - Sending task train to ['site-1', 'site-2']
2026-09-12 05:02:18,213 - INFO - set transaction info: tx_id='Tc01a0a2b-9928-4d31-80fa-204507e2d8a1', ref_id='722e9c83-28f3-4966-9190-7c2e931da469' self.num_receivers=1
2026-09-12 05:02:18,213 - INFO - set transaction info: tx_id='T3f4abb05-82a3-48bd-a7d6-1ab9f96f7e4e', ref_id='cabdb9fa-543c-4b6f-b32d-0d59abec8e2f' self.num_receivers=1
2026-09-12 05:02:18,222 - INFO - execute for task (train)
2026-09-12 05:02:18,222 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:18,222 - INFO - sending task data to in-process trainer
2026-09-12 05:02:18,222 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:18,223 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:18,223 - INFO - execute for task (train)
2026-09-12 05:02:18,223 - INFO - sending task data to in-process trainer
2026-09-12 05:02:18,223 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:18,243 - INFO - site = site-2, current_round=1
2026-09-12 05:02:18,243 - INFO - site = site-1, current_round=1
2026-09-12 05:02:18,258 - INFO - Accuracy of the network on 100 test images: 30.00%
2026-09-12 05:02:18,258 - INFO - Accuracy of the network on 100 test images: 30.00%
2026-09-12 05:02:18,309 - INFO - site=site-2, epoch=1/1, loss=2.2540
2026-09-12 05:02:18,309 - INFO - site=site-1, epoch=1/1, loss=2.2588
2026-09-12 05:02:18,310 - INFO - Finished Training for site-2
2026-09-12 05:02:18,310 - INFO - Finished Training for site-1
2026-09-12 05:02:18,321 - INFO - Accuracy of the network on 100 test images: 70.00%
2026-09-12 05:02:18,322 - INFO - Accuracy of the network on 100 test images: 40.00%
2026-09-12 05:02:18,329 - INFO - site: site-2, sending model to server.
2026-09-12 05:02:18,331 - INFO - site: site-1, sending model to server.
2026-09-12 05:02:18,734 - INFO - set transaction info: tx_id='T001ec071-6fe7-4e94-ac0d-bd9272e81a53', ref_id='0c8b4289-7904-49a2-8ad3-5052547a830a' self.num_receivers=1
2026-09-12 05:02:18,734 - INFO - set transaction info: tx_id='Tbc56aee2-c329-4239-b9da-cff88afc4cb5', ref_id='d9b7c464-627c-46ab-8804-b600989fedbb' self.num_receivers=1
2026-09-12 05:02:18,743 - INFO - validation metric 30.0 from client site-2
2026-09-12 05:02:18,744 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:18,744 - INFO - Aggregated 1/2 results
2026-09-12 05:02:18,746 - INFO - Finished one task run for client: site-2 interval: 2 task_processed: True
2026-09-12 05:02:18,746 - INFO - validation metric 30.0 from client site-1
2026-09-12 05:02:18,746 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:18,747 - INFO - Aggregated 2/2 results
2026-09-12 05:02:18,748 - INFO - Finished one task run for client: site-1 interval: 2 task_processed: True
2026-09-12 05:02:19,312 - INFO - new best validation metric at round 1: 30.0
2026-09-12 05:02:19,323 - INFO - Start persist model on server.
2026-09-12 05:02:19,325 - INFO - End persist model on server.
2026-09-12 05:02:19,325 - INFO - 
--------------------------------------------------------------------------------
                                Round 2 started.                                
--------------------------------------------------------------------------------

2026-09-12 05:02:19,325 - INFO - Sampled clients: ['site-1', 'site-2']
2026-09-12 05:02:19,325 - INFO - Sending task train to ['site-1', 'site-2']
2026-09-12 05:02:20,751 - INFO - set transaction info: tx_id='T4bef3c71-300d-4603-b7fa-36c9cff5a066', ref_id='2092659f-f2c7-46f6-b607-794688db27b1' self.num_receivers=1
2026-09-12 05:02:20,756 - INFO - set transaction info: tx_id='T91b484f7-78d1-4b2a-8718-953e720e10c4', ref_id='1bca7659-62ec-4f4f-a8fc-507d52e6bdaf' self.num_receivers=1
2026-09-12 05:02:20,759 - INFO - execute for task (train)
2026-09-12 05:02:20,759 - INFO - sending task data to in-process trainer
2026-09-12 05:02:20,760 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:20,760 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:20,763 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:20,763 - INFO - execute for task (train)
2026-09-12 05:02:20,763 - INFO - sending task data to in-process trainer
2026-09-12 05:02:20,764 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:20,844 - INFO - site = site-1, current_round=2
2026-09-12 05:02:20,844 - INFO - site = site-2, current_round=2
2026-09-12 05:02:20,860 - INFO - Accuracy of the network on 100 test images: 70.00%
2026-09-12 05:02:20,860 - INFO - Accuracy of the network on 100 test images: 70.00%
2026-09-12 05:02:20,910 - INFO - site=site-1, epoch=1/1, loss=1.5092
2026-09-12 05:02:20,910 - INFO - site=site-2, epoch=1/1, loss=1.6199
2026-09-12 05:02:20,910 - INFO - Finished Training for site-2
2026-09-12 05:02:20,910 - INFO - Finished Training for site-1
2026-09-12 05:02:20,922 - INFO - Accuracy of the network on 100 test images: 50.00%
2026-09-12 05:02:20,922 - INFO - Accuracy of the network on 100 test images: 80.00%
2026-09-12 05:02:20,929 - INFO - site: site-1, sending model to server.
2026-09-12 05:02:20,929 - INFO - site: site-2, sending model to server.
2026-09-12 05:02:21,266 - INFO - set transaction info: tx_id='Tb2745301-f0ea-495f-ba46-19b3ec807af2', ref_id='ab2aea5f-761c-4ecd-8636-f4d8e26f8c2a' self.num_receivers=1
2026-09-12 05:02:21,272 - INFO - set transaction info: tx_id='T9ec9e909-192f-4f69-a306-efa815ce57b8', ref_id='979c57d7-4937-4ab1-abcd-2cf923682de8' self.num_receivers=1
2026-09-12 05:02:21,272 - INFO - validation metric 70.0 from client site-2
2026-09-12 05:02:21,272 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:21,273 - INFO - Aggregated 1/2 results
2026-09-12 05:02:21,274 - INFO - Finished one task run for client: site-2 interval: 2 task_processed: True
2026-09-12 05:02:21,278 - INFO - validation metric 70.0 from client site-1
2026-09-12 05:02:21,278 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:21,278 - INFO - Aggregated 2/2 results
2026-09-12 05:02:21,279 - INFO - Finished one task run for client: site-1 interval: 2 task_processed: True
2026-09-12 05:02:21,845 - INFO - new best validation metric at round 2: 70.0
2026-09-12 05:02:21,858 - INFO - Start persist model on server.
2026-09-12 05:02:21,861 - INFO - End persist model on server.
2026-09-12 05:02:21,861 - INFO - 
================================================================================
                                Finished FedAvg.                                
================================================================================

2026-09-12 05:02:21,863 - INFO - Formatter not found. Stats will not be printed.
2026-09-12 05:02:21,863 - INFO - Beginning model validation with clients: ['site-1', 'site-2'].
2026-09-12 05:02:21,863 - INFO - Locating server models.
2026-09-12 05:02:21,887 - INFO - Server models loaded: ['SRV_FL_global_model.pt', 'SRV_best_FL_global_model.pt'].
2026-09-12 05:02:21,887 - INFO - Sending SRV_FL_global_model.pt model to all participating clients for validation.
2026-09-12 05:02:21,887 - INFO - Sending SRV_best_FL_global_model.pt model to all participating clients for validation.
2026-09-12 05:02:23,299 - INFO - set transaction info: tx_id='T0a944018-279c-4cb1-9ee7-0fb6c7eb3ae7', ref_id='54ca013f-f8bc-4303-bf8d-3d888f638cb6' self.num_receivers=1
2026-09-12 05:02:23,301 - INFO - set transaction info: tx_id='T1e2b8055-a123-474d-97c4-d889ac0b78a5', ref_id='6d8cd24f-6817-45ba-8169-994299824316' self.num_receivers=1
2026-09-12 05:02:23,308 - INFO - execute for task (validate)
2026-09-12 05:02:23,309 - INFO - sending task data to in-process trainer
2026-09-12 05:02:23,309 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:23,309 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:23,310 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:23,310 - INFO - execute for task (validate)
2026-09-12 05:02:23,310 - INFO - sending task data to in-process trainer
2026-09-12 05:02:23,311 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:23,448 - INFO - site = site-1, current_round=None
2026-09-12 05:02:23,448 - INFO - site = site-2, current_round=None
2026-09-12 05:02:23,467 - INFO - Accuracy of the network on 100 test images: 77.00%
2026-09-12 05:02:23,467 - INFO - Accuracy of the network on 100 test images: 75.00%
2026-09-12 05:02:23,467 - INFO - site = site-2, running cross-site evaluation
2026-09-12 05:02:23,467 - INFO - site = site-1, running cross-site evaluation
2026-09-12 05:02:23,820 - INFO - Saved validation result from client 'site-2' on model 'SRV_FL_global_model.pt' in /private/tmp/nvflare-pr1c-before/hello-pt/server/simulate_job/cross_site_val/result_shareables/site-2_SRV_FL_global_model.pt
2026-09-12 05:02:23,822 - INFO - Finished one task run for client: site-2 interval: 2 task_processed: True
2026-09-12 05:02:23,824 - INFO - Saved validation result from client 'site-1' on model 'SRV_FL_global_model.pt' in /private/tmp/nvflare-pr1c-before/hello-pt/server/simulate_job/cross_site_val/result_shareables/site-1_SRV_FL_global_model.pt
2026-09-12 05:02:23,826 - INFO - Finished one task run for client: site-1 interval: 2 task_processed: True
2026-09-12 05:02:25,845 - INFO - set transaction info: tx_id='T9e1e7fc0-40b1-40ea-861a-8073060ad92a', ref_id='0319ed1d-f631-40e5-bcd1-7a1a95726e87' self.num_receivers=1
2026-09-12 05:02:25,847 - INFO - set transaction info: tx_id='T29124442-fbbe-460f-986c-3acf4d95789a', ref_id='be96822c-b93c-4df7-ac57-b9eba796f43f' self.num_receivers=1
2026-09-12 05:02:25,854 - INFO - execute for task (validate)
2026-09-12 05:02:25,854 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:25,854 - INFO - sending task data to in-process trainer
2026-09-12 05:02:25,854 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:25,855 - INFO - object has been downloaded to all 1 receivers - clear cache
2026-09-12 05:02:25,855 - INFO - execute for task (validate)
2026-09-12 05:02:25,855 - INFO - sending task data to in-process trainer
2026-09-12 05:02:25,855 - INFO - waiting for result from in-process trainer
2026-09-12 05:02:25,988 - INFO - site = site-1, current_round=None
2026-09-12 05:02:25,989 - INFO - site = site-2, current_round=None
2026-09-12 05:02:26,004 - INFO - Accuracy of the network on 100 test images: 70.00%
2026-09-12 05:02:26,004 - INFO - Accuracy of the network on 100 test images: 70.00%
2026-09-12 05:02:26,004 - INFO - site = site-1, running cross-site evaluation
2026-09-12 05:02:26,004 - INFO - site = site-2, running cross-site evaluation
2026-09-12 05:02:26,365 - INFO - Saved validation result from client 'site-2' on model 'SRV_best_FL_global_model.pt' in /private/tmp/nvflare-pr1c-before/hello-pt/server/simulate_job/cross_site_val/result_shareables/site-2_SRV_best_FL_global_model.pt
2026-09-12 05:02:26,366 - INFO - Saved validation result from client 'site-1' on model 'SRV_best_FL_global_model.pt' in /private/tmp/nvflare-pr1c-before/hello-pt/server/simulate_job/cross_site_val/result_shareables/site-1_SRV_best_FL_global_model.pt
2026-09-12 05:02:26,367 - INFO - Finished one task run for client: site-2 interval: 2 task_processed: True
2026-09-12 05:02:26,368 - INFO - Finished one task run for client: site-1 interval: 2 task_processed: True
2026-09-12 05:02:28,374 - WARNING - ask to stop job: reason: END_RUN received
2026-09-12 05:02:28,376 - WARNING - ask to stop job: reason: END_RUN received
2026-09-12 05:02:28,525 - WARNING - request to stop the job for reason END_RUN received
2026-09-12 05:02:28,526 - INFO - End the Simulator run.
2026-09-12 05:02:28,526 - WARNING - request to stop the job for reason END_RUN received
2026-09-12 05:02:28,527 - INFO - Clean up ClientRunner for : site-1 
2026-09-12 05:02:28,527 - INFO - End the Simulator run.

Simulation completed successfully.
Result can be found in : /private/tmp/nvflare-pr1c-before/hello-pt
```
</details>

## Boundaries

- Reporting does not decide success or alter training, export, submission, or cleanup behavior. Aggregation finished does not mean model persistence or job completion. Elapsed time excludes environment cleanup.
- Metric names, units, and timing remain application-defined. Saved artifacts provide full precision and detail. The end summary covers standard artifact layouts; custom artifact names/layouts remain accessible in the returned workspace.
- Live remote output is a bounded preview, not complete log delivery: high-volume jobs can outpace the tail, and rotation can drop earlier records. The existing API still transfers a bounded snapshot (up to 5 MiB), so network calls can delay synchronous monitoring. This change bounds JSON parsing and retained state, not the existing transport's request latency. Detailed logs remain authoritative.
- The server must run the updated reporting components. Client-local warnings require existing client-log collection/streaming to appear in server-side monitoring. Jobs without metric-producing components do not acquire invented metrics.

## Failure output

Failed Recipe runs now summarize available exceptions, affected sites, application code locations, and log paths. If a site’s JSON tail has no usable error or lacks traceback details, the summary also checks its text error log. This preserves the exception type and application location when ordinary logger.exception("Training failed") stores only the message in JSON. The summary restricts frame and exception lookup to the final traceback section, excluding logging prefixes and earlier chained exceptions even when the final section has no call frames. Section boundaries follow Python’s exception-chain separators; a literal traceback marker in a message does not start a new section. It reads the exception header after the final frame, or after the traceback marker when there is no frame, before truncating the display. This recognizes bare AssertionError and preserves ValueError: bad input when its message continues on a new line, rather than treating the continuation as a new exception. Both reads count toward the same 20-file limit, with at most 1 MiB read per file. Repeated client errors are grouped; a downstream task-abort record is omitted only when the named client's application traceback is available. Nonzero simulator exits include the summary in their exception. POC/production summarize before cleanup, preserving status and result behavior if diagnostics cannot be retrieved.

**Remote client details require prior log streaming.** Current provisioning templates configure `SiteLogStreamer` for `error_log.txt`. Recipe uses the existing `get_job_logs()` API to retrieve those server-side error streams; it neither enables streaming nor contacts clients directly. Deployments without streaming, sites with `allow_log_streaming=False`, or interrupted transfers may lack client diagnostics. The report explicitly notes when client logs are absent. The server's existing selector now recognizes `error_log.txt` and its `ERRORLOG` storage type.

Client-log collection first enumerates stored `ERRORLOG_*` components, then requests at most 20 named sites individually with a server-enforced 1 MiB UTF-8 log-byte tail limit per request. The limit applies before transfer for live files, archived workspace logs, and stored log components; protocol encoding adds overhead. Older servers that reject the limit are never retried without it. No `target="all"` log download is used for failure collection. Component-derived names matching the case-insensitive `all` or `server` selectors are skipped, preventing accidental aggregate requests. The existing `SessionSpec.get_job_logs()` interface now includes the same keyword-only `max_bytes` contract as its implementation; no new public method is introduced. Local summary parsing is also limited to 20 files and the last 1 MiB per file. Downloaded client excerpts are retained beside results in a unique `failure-logs-*` directory. Full tracebacks remain in the original site logs. This is a summary of available evidence, not a guaranteed global root-cause diagnosis; custom formats and rotated logs can omit the original failure. No communication outage was injected.

Success and failure now share the same `RUN SUMMARY` heading, job/environment context, outcome/elapsed-time alignment, and field spacing. The final summary repeats the job name and known local client count; production participation is not inferred. Failures show `✗ Failed`, the recorded status, error details, and log/results locations; the duplicate workspace footer is removed. Available partial metrics remain visible.

Actual output from a real Hello NumPy simulation with an intentional training-code error (final summary; workspace path shortened):

```text
============================= RUN SUMMARY ==============================

  NVIDIA FLARE · hello-numpy
  Simulation · 2 clients

  ✗ Failed                                                      11.9s

  Status    FINISHED:EXECUTION_EXCEPTION

  Failure details

  Error     NameError: name 'undefined_training_variable' is not defined
  Where     site-1, site-2 / TaskScriptRunner
  Code      client.py:31 (train)
  Logs      site-1/error_log.txt · site-2/error_log.txt

  Full tracebacks and additional messages are in the logs.
  Results   /workspace/hello-numpy
```

The real missing-CIFAR POC case reports `FileNotFoundError`, the existing `python prepare_data.py --data_root ...` instruction, both clients, and `prepare_data.py:117 (validate_cifar10)`. Both cases retain downloaded diagnostics and stop POC services. Three isolated Hello NumPy simulation failures were also run: a training `NameError`, a missing-data `FileNotFoundError`, and a corrupt server checkpoint. They preserve the original failure and include the available error details at the end of the raised exception. Tracebacks and abort messages preceding the summary are still visible.

## Relative CIFAR cache paths

The beginner Hello PyTorch example and advanced simulation/POC recipes now resolve relative `--data_root` paths against the submission working directory before embedding client arguments, expanding `~` first. Quoted `--data_root "~/cifar"` therefore resolves to the local user’s home for simulation/POC and remains unchanged for production clients to expand. This restores `prepare_data.py --data_root ./data` followed by `job.py --dataset cifar10 --data_root ./data` without adding pre-start validation or downloading data. Exports for local environments record that same absolute path; production recipes preserve the supplied client-side path. Client errors for unresolved relative paths explain the working-directory rule. The example fix is a separate commit from the framework/reporting changes.

## Validation

- Concise diagnostic-filter review: 93 targeted tests passed. A real CrossSiteModelEval result produced the unwanted diagnostic before the change; the regression now checks local filtering and remote JSON replay for base/global/HE/user controllers while retaining warnings. The unmodified three-round Hello PyTorch run completed with final model evaluation 75/77; diagnostic INFO was absent from the console and retained in server/log.txt. The refreshed complete capture appears above. Full project style check passed.

- Review #467: the initial 24 boundary cases all failed on the prior commit and pass with the fix. Coverage combines single-word/typed logging prefixes, frame-less SyntaxError/bare/multiline exceptions, earlier chained frames, and JSON/text logs. The expanded matrix also covers implicit exception chains and literal traceback markers within multiline messages. The final failure-summary, Run, and session-monitor suites passed 129 tests (3 existing skips). Full project style check passed.

- Review #466: 125 targeted tests passed, including local concise filtering and JSON-based remote replay for GlobalModelEval, HECrossSiteModelEval, and a user subclass; inherited custom-writer metrics; and actual multiline, bare, and chained exception tracebacks. Full project style check passed.

- Latest cleanup and failure-reporting checks: 774 recipe/reporting unit tests passed, 18 skipped (two POC socket tests rerun outside the sandbox); 104 focused encoding/failure/logging tests passed, 3 skipped after the final console conversion change. Real formatter tests cover missing JSON tracebacks and nested message-less assertions.
- All 51 simulator-integration and example-export cases passed after removing the extra logging layer and extracting shared arguments. A real ASCII Hello NumPy run completed with no encoding errors; fresh Hello PyTorch success and intentional Hello NumPy failure captures appear above. Full project style check passed.

Earlier validation:

- Output and annotation review: 199 targeted tests passed (3 skipped), and the full style check passed. Verified unified/PyTorch replacement construction and resolved type hints; verified the TensorFlow wrapper annotation from source without a TensorFlow runtime. A fresh unmodified three-round Hello PyTorch run succeeded, and the intentional NumPy training failure returned nonzero with the expected exception summary; both actual captures are refreshed below. Malformed `--log_config` was verified to print argparse usage/error and exit 2 without a traceback.

- Custom-writer compatibility: 40 targeted tests passed; full project style check passed. Real BaseFedJob/FedJob export and ServerJsonConfigurator loading cover an independent no-op replacement, a configured writer with a custom output directory, a writer under another ID, and automatic setup when no writer exists. The replacement case reproduced the extra-writer bug before the fix.

- Latest review checks: 272 targeted tests passed (3 skipped), including bounded JSON-to-text fallback, formatter-generated text errors, unscheduled outcomes, missing/filtered client metrics, and constructor logging at the simulator boundary. All four real simulator output cases passed: three Recipe modes and a two-client, two-round plain FedJob export with no configured writer, loaded through the simulator CLI as JSON. Full project style check passed.

- Home-path regression: all 60 tests in the three Hello PyTorch example suites passed. Real exports cover absolute, relative, and literal `~/...` paths across simulation, POC, and production. Client validation checks both missing and present home-relative caches from a different working directory. Full project style check passed.

- Latest context/alias/interface checks: 228 targeted tests passed (3 skipped); 55 example tests passed, including real exported-config checks for relative/absolute paths in simulation, POC, and production, and exports without local data. All five real simulation/POC output integrations passed. Fresh successful Hello PyTorch and failed Hello NumPy captures appear above. Full project style check passed.

- Latest review fixes: 248 targeted tests pass (3 skipped), both real POC failures pass with bounded requests, and project style checks pass. Coverage includes legacy success/failure status behavior, 20-site request limits, server-side byte limits for live/archive/component storage with multibyte text, invalid-limit rejection, no unbounded fallback on older servers, and text contexts containing `train[0]`.

- Shared summary layout: 67 targeted tests passed (3 skipped), full project style check passed, and a real failed NumPy simulation produced the final summary above while preserving its nonzero exit.

- Text-log review fix: 20 failure-summary/session tests pass. Coverage uses FLARE’s actual text formatter to verify matching JSON/text peer attribution and to retain unrelated peer errors.

- Failure summary validation: 173 targeted unit tests passed (3 skipped); both real POC failure cases passed, asserting original client exceptions in the final summary, code locations, retained results, and service cleanup. Full project style check passed.

- Simplification validation: 95 targeted unit tests passed (3 skipped), all three real NumPy output integrations passed, and the full project style check passed.
- Latest targeted checks: 195 unit tests passed, 3 skipped; all three real NumPy output integrations passed, now exercising shared `--log_config` and inherited-setting overrides.
- Unmodified Hello PyTorch accepted `python job.py --num_rounds 1 --log_config full` and completed with full diagnostic output; the default three-round run also completed and supplies the updated capture above.
- Earlier display validation: 213 unit tests passed, 3 skipped: Recipe run/session/environment behavior, logging, metric artifacts, cross-site evaluation, and client shutdown.
- Behavioral regression tests verify bounded replay across repeated 1,000-record snapshots; large evaluation payloads remain intact on disk while console output stays bounded; all three standard result layouts; failed status with available metrics; malformed artifacts; last-ten-round limits; cached result calls; aligned multi-row tables through log formatting; missing values; and safe formatting of application-defined values.
- Real unmodified Hello PyTorch simulation: three rounds, full end summary, final model evaluation 75/77 (captured above).
- All six real simulation/POC cases passed (181 seconds): default concise, explicitly selected concise/message-only output, Hello PyTorch simulation-to-POC continuity, and unsuccessful job cleanup.
- Earlier validation after restoring the original FedAvg diagnostic messages: 6 affected external-trainer end-to-end tests passed, 1 skipped (TensorFlow), and both concise/message-only real NumPy output tests passed.
- Project style check: `./runtest.sh -s --skip-install` passed.
- Documentation HTML build passed (117 existing warnings).

## Diff size against upstream/main

| Files | Added | Removed | Net |
|---|---:|---:|---:|
| Production Python | +938 | −146 | +792 |
| Test Python | +1698 | −207 | +1491 |
| Documentation | +201 | −9 | +192 |
| **Total** | **+2837** | **−362** | **+2475** |

## Production Python breakdown

Counts include blank lines, comments, and docstrings, and compare the full PR with its upstream base. Production includes example scripts. Moving the existing argument parser from `spec.py` to `_args.py` contributes additions and removals in both files; it is not all new logic. The table reports those moves without hiding them.

| File | Purpose | Added | Removed | Net |
|---|---|---:|---:|---:|
| `nvflare/recipe/_failure_summary.py` | Bounded client-log collection, text/JSON parsing, peer attribution, and failure formatting | +205 | −0 | +205 |
| `nvflare/recipe/_run_summary.py` | Read saved artifacts; present run context and encoding-safe summaries | +165 | −0 | +165 |
| `nvflare/fuel/utils/log_utils.py` | Configure existing concise components; bounded metrics/tails and console encoding fallback | +134 | −3 | +131 |
| `nvflare/recipe/_args.py` | Move existing shared argument parsing/state out of the public specification | +124 | −0 | +124 |
| `nvflare/recipe/session_mgr.py` | Bounded progress/log retrieval; retain metadata in full/verbose monitoring | +90 | −23 | +67 |
| `nvflare/app_common/widgets/metrics_artifact_writer.py` | Render round headings, client/aggregation rows, and elapsed time from existing events | +62 | −0 | +62 |
| `nvflare/recipe/run.py` | Display outcomes, artifacts, and failure details before cleanup; cache reporting | +45 | −0 | +45 |
| `nvflare/fuel/flare_api/flare_api.py` | Shared terminal-outcome classification and bounded log-request option | +19 | −1 | +18 |
| `nvflare/recipe/sim_env.py` | Resolved client configuration and contextual failure summaries | +14 | −4 | +10 |
| `nvflare/app_common/workflows/cross_site_model_eval.py` | Bounded evaluation progress with artifact fallback | +13 | −1 | +12 |
| `examples/hello-world/hello-pt/prepare_data.py` | Explain the working-directory rule for relative cache-path errors | +9 | −1 | +8 |
| `nvflare/private/fed/server/job_cmds.py` | Select stored error logs and enforce requested byte limits before transfer | +16 | −8 | +8 |
| `nvflare/private/fed/server/server_json_config.py` | Supply the existing progress writer when a job has none | +8 | −0 | +8 |
| `nvflare/fuel/flare_api/api_spec.py` | Match the existing log-retrieval interface to its byte-limit implementation | +5 | −0 | +5 |
| `examples/advanced/hello-pt-environments/job.py` | Resolve simulation/POC cache paths while preserving production paths | +4 | −1 | +3 |
| `nvflare/client/in_process/api.py` | Distinguish normal end-of-run shutdown from unexpected stop warnings | +5 | −2 | +3 |
| `examples/hello-world/hello-pt/job.py` | Resolve simulation cache paths without pre-start validation | +3 | −1 | +2 |
| `nvflare/app_opt/pt/job_config/base_fed_job.py` | Align writer annotation and API documentation with supported FLComponent replacements | +3 | −2 | +1 |
| `nvflare/app_opt/tf/job_config/base_fed_job.py` | Align writer annotation and API documentation with supported FLComponent replacements | +3 | −2 | +1 |
| `nvflare/job_config/base_fed_job.py` | Align writer annotation and API documentation with supported FLComponent replacements | +3 | −2 | +1 |
| `nvflare/recipe/__init__.py` | Consume shared arguments before importing Recipe implementations | +1 | −0 | +1 |
| `nvflare/recipe/spec.py` | Delegate parsing and run presentation to private implementation modules | +7 | −95 | -88 |
| **Total production Python** | | **+938** | **−146** | **+792** |





## timeline-comments 5646426203 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5646426203; ; 
<!-- greptile_summary -->

<h2><a href="https://app.greptile.com/api/retrigger?id=63428681"><picture><source media="(prefers-color-scheme: dark)" srcset="https://greptile-static-assets.s3.amazonaws.com/badges/RetriggerDark.svg?v=1"><source media="(prefers-color-scheme: light)" srcset="https://greptile-static-assets.s3.amazonaws.com/badges/Retrigger.svg?v=1"><img alt="Retrigger" src="https://greptile-static-assets.s3.amazonaws.com/badges/Retrigger.svg?v=1" align="right"></picture></a>Confidence Score: 5/5</h2>

The PR appears safe to merge; no new actionable defects or outstanding previous findings remain.

<h3>Summary</h3>

- Presents live round, aggregation, and evaluation metrics while retaining detailed diagnostics in existing log files.
- Adds bounded success and failure summaries across simulator, POC, and production result layouts.
- Adds shared Recipe logging arguments, bounded remote log retrieval, and default metric-writer setup.
- Normalizes local CIFAR cache paths and clarifies environment-specific path behavior.
- The changes since the previous review correctly exclude reporting-component diagnostic INFO records without hiding their presentation output or warnings.

<sub>Reviews (26) · Last reviewed commit: ["Exclude reporting-class diagnostics from..."](https://github.com/nvidia/nvflare/commit/29fe1c3a27f6b35de765060158a3bf563aeb69b4)</sub>


## timeline-comments 5646609523 by codecov-commenter; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5646609523; ; 
## [Codecov](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?dropdown=coverage&src=pr&el=h1&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) Report
:x: Patch coverage is `95.60068%` with `26 lines` in your changes missing coverage. Please review.
:white_check_mark: Project coverage is 67.43%. Comparing base ([`53ba7ee`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/53ba7ee567468ea7971dad4faccef13c6cb35dc2?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)) to head ([`29fe1c3`](https://app.codecov.io/gh/NVIDIA/NVFlare/commit/29fe1c3a27f6b35de765060158a3bf563aeb69b4?dropdown=coverage&el=desc&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA)).

| [Files with missing lines](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?dropdown=coverage&src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | Patch % | Lines |
|---|---|---|
| [nvflare/recipe/\_run\_summary.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&filepath=nvflare%2Frecipe%2F_run_summary.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9yZWNpcGUvX3J1bl9zdW1tYXJ5LnB5) | 93.00% | [7 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [nvflare/recipe/\_failure\_summary.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&filepath=nvflare%2Frecipe%2F_failure_summary.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9yZWNpcGUvX2ZhaWx1cmVfc3VtbWFyeS5weQ==) | 95.38% | [6 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [nvflare/recipe/session\_mgr.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&filepath=nvflare%2Frecipe%2Fsession_mgr.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9yZWNpcGUvc2Vzc2lvbl9tZ3IucHk=) | 92.30% | [6 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [nvflare/fuel/utils/log\_utils.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&filepath=nvflare%2Ffuel%2Futils%2Flog_utils.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9mdWVsL3V0aWxzL2xvZ191dGlscy5weQ==) | 97.59% | [2 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [nvflare/recipe/run.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&filepath=nvflare%2Frecipe%2Frun.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9yZWNpcGUvcnVuLnB5) | 93.54% | [2 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [...lare/app\_common/widgets/metrics\_artifact\_writer.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&filepath=nvflare%2Fapp_common%2Fwidgets%2Fmetrics_artifact_writer.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9hcHBfY29tbW9uL3dpZGdldHMvbWV0cmljc19hcnRpZmFjdF93cml0ZXIucHk=) | 98.14% | [1 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [...lare/app\_common/workflows/cross\_site\_model\_eval.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&filepath=nvflare%2Fapp_common%2Fworkflows%2Fcross_site_model_eval.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9hcHBfY29tbW9uL3dvcmtmbG93cy9jcm9zc19zaXRlX21vZGVsX2V2YWwucHk=) | 88.88% | [1 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |
| [nvflare/recipe/sim\_env.py](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&filepath=nvflare%2Frecipe%2Fsim_env.py&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#diff-bnZmbGFyZS9yZWNpcGUvc2ltX2Vudi5weQ==) | 88.88% | [1 Missing :warning: ](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?src=pr&el=tree&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) |

<details><summary>Additional details and impacted files</summary>



```diff
@@            Coverage Diff             @@
##             main    #5286      +/-   ##
==========================================
+ Coverage   67.26%   67.43%   +0.17%     
==========================================
  Files        1021     1024       +3     
  Lines      106125   106637     +512     
==========================================
+ Hits        71380    71908     +528     
+ Misses      34745    34729      -16     
```

| [Flag](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286/flags?src=pr&el=flags&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | Coverage Δ | |
|---|---|---|
| [unit-tests](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286/flags?src=pr&el=flag&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA) | `67.43% <95.60%> (+0.17%)` | :arrow_up: |

Flags with carried forward coverage won't be shown. [Click here](https://docs.codecov.io/docs/carryforward-flags?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA#carryforward-flags-in-the-pull-request-comment) to find out more.
</details>

[:umbrella: View full report in Codecov by Harness](https://app.codecov.io/gh/NVIDIA/NVFlare/pull/5286?dropdown=coverage&src=pr&el=continue&utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).   
:loudspeaker: Have feedback on the report? [Share it here](https://about.codecov.io/codecov-pr-comment-feedback/?utm_medium=referral&utm_source=github&utm_content=comment&utm_campaign=pr+comments&utm_term=NVIDIA).
<details><summary> :rocket: New features to boost your workflow: </summary>

- :snowflake: [Test Analytics](https://docs.codecov.com/docs/test-analytics): Detect flaky tests, report on failures, and find test suite problems.
- :package: [JS Bundle Analysis](https://docs.codecov.com/docs/javascript-bundle-analysis): Save yourself from yourself by tracking and limiting bundle sizes in JS merges.
</details>


## timeline-comments 5646971064 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5646971064; ; 
/build


## timeline-comments 5647071375 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5647071375; ; 
/build


## timeline-comments 5647319827 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5647319827; ; 
/build


## timeline-comments 5647498261 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5647498261; ; 
/build


## timeline-comments 5647698180 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5647698180; ; 
/build


## timeline-comments 5647793965 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5647793965; ; 
/build


## timeline-comments 5647861439 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5647861439; ; 
/build


## timeline-comments 5647890739 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5647890739; ; 
/build


## timeline-comments 5647973744 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5647973744; ; 
/build


## timeline-comments 5648092534 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648092534; ; 
/build


## timeline-comments 5648125913 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648125913; ; 
/build


## timeline-comments 5648247848 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648247848; ; 
Addressed in 05c6a7352.

The two earlier regressions are fixed:
- Shared server setup supplies the existing MetricsArtifactWriter when a job has none. A real two-client, two-round plain FedJob export, loaded by the simulator CLI as JSON, now shows each round and aggregation. Explicit writers are preserved; Recipe integration tests assert that round headings appear only once.
- Failure summaries try error_log.txt when the bounded log.json tail has no usable error. Both reads consume the shared 20-file allowance. Tests cover empty, malformed, INFO-only, and oversized JSON, JSON preference when usable, and the total read limit.

Disposition of the eight additional findings:

| Finding | Resolution |
|---|---|
| 1. Terminal status classification | FINISHED:CAN_NOT_SCHEDULE now displays “Not scheduled” and does not request training error logs. ABANDONED remains an unsuccessful execution: JobRunner.update_unfinished_jobs applies it to previously running jobs, so it does not establish that training never ran. |
| 2. Filtered metrics disappear | Accepted updates whose metrics are all filtered now retain a client line saying “no displayable metrics.” The count continues to describe accepted updates. |
| 3. Private Run context setup | Retained intentionally. Recipe supplies metadata it owns internally; direct Run(env, job_id) construction has an environment-only fallback. No demonstrated broken caller, and adding constructor metadata parameters would expand the public API solely for presentation. |
| 4. Constructor log configuration | The cited SimEnv path does not use SessionManager. Its constructor value reaches FedJob.simulator_run. The existing simulator-boundary test now explicitly covers concise and full constructor values. PocEnv and ProdEnv do not expose that constructor parameter. |
| 5. Parser not tied to formatter tests | Already covered: test_groups_client_errors_and_omits_only_the_linked_abort generates text with the actual BaseFormatter, including bracket-bearing workflow names, and checks extracted exceptions and peer attribution. |
| 6. Repeated tail reads | One private bounded-tail helper now serves all three readers. Raw byte tails remain appropriate for transport; summaries explicitly request complete-record tails. Tests verify byte bounds and both contracts. |
| 7. Formatter allocation | Retained intentionally: BaseFormatter stores mutable per-record state, while console and file handlers can share ProgressFormatter under different handler locks. Constructing it locally avoids cross-handler state races without adding locks or thread-local caches. No measured performance regression was supplied. |
| 8. Test filename | Renamed to _failure_summary_test.py. |

Validation: 272 targeted tests passed, 3 skipped; all four real simulator output cases passed; full project style check passed. This follow-up adds 13 net production Python lines. The PR description retains the actual output examples and includes refreshed overall and per-file LOC tables.



## timeline-comments 5648248654 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648248654; ; 
/build


## timeline-comments 5648282476 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648282476; ; 
/build


## timeline-comments 5648307564 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648307564; ; 
Fixed in d1ab06336. Server setup now checks the explicit metrics_artifact_writer component ID as well as existing MetricsArtifactWriter instances before adding a default. Independent and no-op FLComponent replacements therefore retain control of collection and output paths.

A behavioral test uses real BaseFedJob/FedJob export and ServerJsonConfigurator loading, without mocking component construction. The replacement case failed before the fix and passes afterward. Companion cases verify that configured writers retain their custom output directory, writers under other IDs are not duplicated, and a missing writer still gets the default.

All 40 targeted tests and the full project style check passed. The production fix adds two net lines; the PR description and LOC tables are updated.



## timeline-comments 5648308215 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648308215; ; 
/build


## timeline-comments 5648523322 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648523322; ; 
Pushed two focused follow-ups:

- a4ceba0d6: metrics_artifact_writer is Optional[FLComponent] in the unified, PyTorch, and TensorFlow BaseFedJob signatures. Their API docstrings describe independent replacements; runtime validation is unchanged.
- 8e7ad291e: full/verbose Recipe monitoring retains resource_spec/deploy_map metadata on status changes, table labels always have a separator before values, and round/outcome duration padding excludes newline characters and uses the same column.

Disposition of the runtime/output review:

| Finding | Resolution |
|---|---|
| 1. Metadata visibility | Restored in full/verbose monitoring; concise retains the intended compact output. Tests verify metadata is emitted only on status changes. |
| 2. Automatic writer scope/replacements | Shared reporting across simulation, POC, and production is intentional. The standard metrics_artifact_writer ID reserves the role for independent replacements; existing MetricsArtifactWriter instances under other IDs are also respected. An arbitrary component under an unrelated ID does not declare that role, and setup cannot infer semantic equivalence. The documented ID provides that explicit contract. |
| 3. Missing logging-argument value | Verified in a real subprocess: argparse prints “argument --log_config: expected one argument” and exits 2, without a traceback. This is a normal CLI usage error, not an unhandled exception traceback. Silently ignoring this shared option could start a job with unintended settings. |
| 4. Missing table separator | Fixed and covered with a full-width label/value regression case. |
| 5. Newline-aware padding | Simplified: prepend newlines after padding the actual line; round and run durations now explicitly start at the same column. |
| 6. Repeated tail polling | Retained as the bounded existing-API tradeoff: at most one normal poll per five seconds, 64 KiB/200 parsed lines, and 200 digests. An offset/resume protocol is not provided by the current endpoint; adding one would broaden this reporting PR. |
| 7. Sequential error-log requests | Retained intentionally. target="all" would reintroduce the previously fixed unbounded fan-out/transfer problem. Each named-site request has a server-enforced byte cap and the collection stops after 20 sites. |
| 8. Terminal-state helpers | Both CLI and session terminal helpers already exist on the PR base, 53ba7ee56. Recipe outcome classification reuses the session helper. New standard FINISHED:* statuses are recognized by the prefix logic without maintaining another list. Broader legacy-helper consolidation is pre-existing scope. |

Validation: 199 targeted tests passed, 3 skipped; full project style check passed. Unified/PyTorch type hints and independent replacement construction were verified; the TensorFlow annotation was verified from source without a TensorFlow runtime. Fresh real Hello PyTorch success and intentional Hello NumPy failure captures are included in the PR description. Overall and per-file LOC tables are refreshed.



## timeline-comments 5648524095 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648524095; ; 
/build


## timeline-comments 5648735605 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648735605; ; 
Addressed in fde38e95f:

- Console encoding: the existing console formatter and Recipe output now use an encoding-aware fallback. A real Hello NumPy run with PYTHONIOENCODING=ascii completed through result retrieval without encoding/logging errors. Tests also exercise ASCII/CP1252 success and failure summaries, Unicode job names, and closed output streams.
- Missing traceback: when JSON supplies an error message without traceback details, the summary checks the corresponding text error log within the same 20-file/1-MiB-per-file limits. Tests use the actual JSON/text formatters with logger.exception("Training failed") and verify the application location.
- Message-less exceptions: the parser recognizes bare exception types such as AssertionError and extracts the final exception before truncation. Coverage uses an actual nested assertion traceback exceeding the display limit.

The logging simplification is substantive: removed ProgressFormatter, ProgressFilter, and .progress child-loggers; ordinary component loggers now use the existing concise filter and console formatter configuration. This also makes ordinary evaluation-controller INFO messages visible. The PR includes a new complete real output capture (89 lines), preserving the original before example.

Shared argument parsing/state moved from public spec.py into private _args.py, preserving flag behavior and DEFAULT_EXPORT_DIR.

Validation: 774 recipe/reporting unit tests passed, 18 skipped (two socket tests rerun outside the sandbox); final focused runs passed 104 encoding/failure/logging tests and 76 parser/spec tests. All 51 simulator-integration and example-export cases passed. Real UTF-8 success, ASCII success, and intentional training-failure runs completed as expected. Full project style check passed. PR description and both LOC tables updated.



## timeline-comments 5648736492 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648736492; ; 
/build


## timeline-comments 5648792855 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648792855; ; 
Fixed both findings in 6b66d9f52.

1. Inherited evaluation and metrics reporting now uses the defining module's ordinary logger. The existing concise configuration already admits those modules, so GlobalModelEval, HECrossSiteModelEval, and user subclasses retain inherited reporting locally and in remote replay. Other subclass diagnostics retain their own logger. No extra mode, formatter, record marker, or child-logger channel was added.
2. Exception extraction now selects the header after the final traceback frame instead of the last identifier-looking line. Actual multiline ValueError messages, including a continuation that itself looks like a typed exception, preserve the original type/message. Bare assertions and chained exceptions remain covered.

125 targeted tests passed, including real subclass result saving, existing concise filtering, actual JSON formatting and remote replay, custom-writer reporting, and real exception tracebacks. The full project style check passed. These changes add 10 net production Python lines. The PR description and both LOC tables have been updated; the captured output examples are preserved.



## timeline-comments 5648793774 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648793774; ; 
/build


## timeline-comments 5648895237 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648895237; ; 
Fixed in 88b54ab93: addressed the frame-less traceback finding and checked the adjacent parser boundaries together.

Frame and exception searches now begin inside the final traceback section, so a prefix such as Failure cannot become the exception header and a previous chained exception cannot supply its frame. Only Python's explicit/implicit exception-chain separators advance to another section; literal traceback-marker text within an exception message does not.

The initial 24 regression combinations all failed on the previous commit and pass with this fix. The final coverage also includes implicit chains and marker-bearing multiline messages, alongside the existing framed, bare, multiline, JSON/text fallback, and bounded-read cases. Final targeted validation: 129 passed, 3 existing skips. Full project style check passed.

The production change is 10 net lines in _failure_summary.py. Updated the PR description and both LOC tables; existing output examples are preserved.



## timeline-comments 5648896067 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5648896067; ; 
/build


## timeline-comments 5649007368 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#issuecomment-5649007368; ; 
/build


## reviews 5186662272 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5186662272; COMMENTED; 



## reviews 5186703305 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5186703305; COMMENTED; 



## reviews 5186720716 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5186720716; COMMENTED; 



## reviews 5186742944 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5186742944; COMMENTED; 



## reviews 5186745452 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5186745452; COMMENTED; 



## reviews 5186966167 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5186966167; COMMENTED; 



## reviews 5187020346 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187020346; COMMENTED; 



## reviews 5187020400 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187020400; COMMENTED; 



## reviews 5187025172 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187025172; COMMENTED; 



## reviews 5187071569 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187071569; COMMENTED; 



## reviews 5187072572 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187072572; COMMENTED; 



## reviews 5187072677 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187072677; COMMENTED; 



## reviews 5187273106 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187273106; COMMENTED; 



## reviews 5187348475 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187348475; COMMENTED; 



## reviews 5187498418 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187498418; COMMENTED; 



## reviews 5187520585 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5187520585; COMMENTED; 



## reviews 5188119511 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5188119511; COMMENTED; 



## reviews 5188263964 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#pullrequestreview-5188263964; COMMENTED; 



## inline-comments 3996450087 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996450087; ; nvflare/recipe/sim_env.py
<a href="#"><img alt="P2" src="https://greptile-static-assets.s3.amazonaws.com/badges/p2.svg?v=9" align="top"></a> **Client Count Is Incorrect**

When `SimEnv` is configured with a positive `num_clients` and `clients=[]`, this line reports `0 clients` even though `self.num_clients` contains the resolved positive count. This gives users an incorrect description of the simulation being prepared; use the resolved `self.num_clients` value instead.

```suggestion
            num_clients = self.num_clients
```

**Knowledge Base Used:** [Recipes, examples, edge, and collaboration](https://app.greptile.com/nvidia-public-github/-/custom-context/knowledge-base/nvidia/nvflare/-/docs/recipes-examples-edge-collaboration.md)

Note: If this suggestion doesn't match your team's coding style, reply to this and let me know. I'll remember it for next time!


## inline-comments 3996497223 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996497223; ; nvflare/recipe/sim_env.py
Fixed in 0644e0e42: the preparation message now uses self.num_clients, which the constructor has already resolved. Regression coverage includes positive num_clients with clients=[], count-only configuration, explicit names, and matching count/names. All 22 SimEnv unit tests and the project style check pass.


## inline-comments 3996505858 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996505858; ; nvflare/app_common/workflows/fedavg.py
<a href="#"><img alt="P2" src="https://greptile-static-assets.s3.amazonaws.com/badges/p2.svg?v=9" align="top"></a> **FedAvg Banners Add Clutter**

Wrapping the new FedAvg progress messages in `center_message()` changes concise single-line updates into 80-column banners with leading and trailing blank lines. This reintroduces the console clutter these reporting changes are intended to reduce. The integration test only checks for the message substring, so it does not detect this formatting regression. Keep the start, round, and finish messages as direct `self.info()` strings.

```suggestion
            self.info(f"Starting FedAvg training: {self.num_rounds} rounds.")
```

Note: If this suggestion doesn't match your team's coding style, reply to this and let me know. I'll remember it for next time!


## inline-comments 3996514821 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996514821; ; nvflare/app_common/workflows/fedavg.py
Keeping center_message() intentionally to preserve the centered, visually separated progress messages requested during maintainer review. The target base (upstream/main at 53ba7ee56) already uses these banners for FedAvg start, rounds, and completion; retaining them is not a formatting regression relative to main. The noise reduction in this PR comes from filtering routine executor/transfer messages and replacing monitor metadata dumps/dots, while preserving meaningful workflow output. A matched three-round NumPy run on main and the PR reduced raw console output from 182 to 134 lines, with all six per-client metric messages, aggregation progress, and matching round metrics retained. The PR description includes both complete captured outputs and explicitly documents the banner decision. The integration assertions protect client metrics and aggregation progress; they intentionally do not require single-line banner formatting.


## inline-comments 3996515977 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996515977; ; nvflare/app_common/workflows/fedavg.py
That context resolves the concern. You’re right that retaining `center_message()` is an intentional preservation of the existing FedAvg banner convention, not a formatting regression relative to the target base. The measured reduction comes from filtering routine executor/transfer output and simplifying monitor reporting, while the meaningful workflow output remains covered. I’m withdrawing this finding; no code change is needed.


## inline-comments 3996684089 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996684089; ; nvflare/recipe/session_mgr.py
<a href="#"><img alt="P2" src="https://greptile-static-assets.s3.amazonaws.com/badges/p2.svg?v=9" align="top"></a> **Progress Monitoring Grows Unbounded**

In progress mode, each refresh downloads and reparses the server's available `log.json` snapshot—up to 5 MiB—while retaining every distinct matching line in a persistent set. For long-running or high-volume jobs, this repeatedly blocks the synchronous status-monitoring loop and steadily increases memory use in the submitting process. Use an incremental cursor or a bounded tail and deduplication strategy instead.


## inline-comments 3996684093 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996684093; ; nvflare/app_common/workflows/cross_site_model_eval.py
<a href="#"><img alt="P2" src="https://greptile-static-assets.s3.amazonaws.com/badges/p2.svg?v=9" align="top"></a> **Validation Payloads Flood Logs**

Each cross-site validation result now serializes the complete application-defined `dxo.data` payload into progress logging. These payloads are not size-bounded, and non-JSON objects are stringified without truncation, so arrays, detailed per-sample values, or other large structures can flood the console and log files even though the full result is already saved as an artifact. Keep progress output to a bounded summary and direct users to the saved result for full details.

**Knowledge Base Used:** [Workflow execution](https://app.greptile.com/nvidia-public-github/-/custom-context/knowledge-base/nvidia/nvflare/-/docs/workflow-execution.md)

Note: If this suggestion doesn't match your team's coding style, reply to this and let me know. I'll remember it for next time!


## inline-comments 3996741131 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996741131; ; nvflare/recipe/session_mgr.py
Fixed in c3f9e88c9 using a bounded tail and deduplication strategy. The monitor selects the last 200 lines, parses at most 64 KiB, and retains at most 200 SHA-256 hashes from the current tail instead of every displayed line over the life of the job. The behavioral test runs repeated 1,000-record snapshots and checks the output bound, bounded hash state, and overlapping-snapshot suppression. The existing API still transfers snapshots capped at 5 MiB; this does not introduce an incremental transport or guarantee network latency. The PR description documents that limitation and that live output is a preview, with saved logs providing the complete history. The existing concise mode now uses this presentation; the additional progress mode has been removed.


## inline-comments 3996741188 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996741188; ; nvflare/app_common/workflows/cross_site_model_eval.py
Fixed in c3f9e88c9. Evaluation progress now uses the same bounded scalar-metric formatter as training and the end summary: at most six entries, shortened names/strings, and a saved-result reference for structured values or additional metrics. It no longer serializes or stringifies arbitrary application objects for display. A behavioral test saves an actual DXO containing 100,000 sample values, a 100,000-character string, and 100 additional metrics; it verifies the saved payload is intact while the progress message remains under 1,000 characters. All 207 unit tests and 5 real simulation/POC integration cases pass, as does the project style check.


## inline-comments 3996745890 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996745890; ; nvflare/fuel/utils/log_utils.py
<a href="#"><img alt="P1" src="https://greptile-static-assets.s3.amazonaws.com/badges/p1.svg?v=9" align="top"></a> **Concise Mode Loses Output**

The focused view replaces the existing `concise` configuration instead of remaining opt-in. Existing users—and simulations that default to `concise`—previously received application INFO records through `ConciseFilter`. Rewiring both readable-output handlers to `ProgressFilter` now suppresses every INFO record not emitted from a `.progress` logger, so user training output silently disappears from an established mode. The related monitoring path also retrieves server progress logs when `FL_LOG_LEVEL` is unset. Please preserve the existing `concise` behavior and expose the focused view through a separate opt-in mode.

Note: If this suggestion doesn't match your team's coding style, reply to this and let me know. I'll remember it for next time!


## inline-comments 3996788939 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996788939; ; nvflare/fuel/utils/log_utils.py
Keeping the revised concise behavior intentionally, following explicit maintainer direction to improve the existing concise mode rather than introduce another configuration mode. The console and log_fl.txt are the focused human-readable view; detailed application INFO records are retained in log.txt/log.json, and msg_only or full remains available for console diagnostics. The PR description and logging documentation now explicitly describe this presentation change, including the default remote monitoring preview. The separate-mode suggestion would contradict that requested UX, so it is not being applied. Tests that inspect transport/executor diagnostics now explicitly select full instead of relying on the concise default. The final end-of-run summary supplements intermediate progress with actual saved training/evaluation results and artifact locations.


## inline-comments 3996789959 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996789959; ; nvflare/recipe/sim_env.py
Follow-up fixed in b599f18a8: the presentation test exposed an existing deployment mismatch for clients=[]. SimEnv now normalizes an empty list to None, so num_clients=2 is propagated as count-based configuration. A new behavioral test leaves FedJob.simulator_run, client resolution, and export real and intercepts only subprocess.Popen; it confirms the actual simulator command contains -n 2, -c site-1,site-2, and -t 2. This covers the previously mocked-away failure path.


## inline-comments 3996790037 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996790037; ; nvflare/app_common/workflows/fedavg.py
Final implementation in b599f18a8 restores FedAvg diagnostic messages exactly to upstream, including center_message(). The workflow file is now absent from the PR diff. This preserves existing Finished FedAvg. and zero-based Round N started. assertions; the focused concise view independently renders one-based round progress through the existing metrics writer. External-trainer tests explicitly select full logging because they verify diagnostics. Six affected real end-to-end tests passed, with the TensorFlow case skipped; concise and message-only real NumPy tests also passed.


## inline-comments 3996914475 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996914475; ; nvflare/app_common/widgets/metrics_artifact_writer.py
<a href="#"><img alt="P2" src="https://greptile-static-assets.s3.amazonaws.com/badges/p2.svg?v=9" align="top"></a> **Later Metrics Are Hidden**

The live round table chooses its columns from the first accepted client update and reuses them for later clients and the aggregated row. Because accepted updates can report different metric keys, valid scalar metrics introduced by later clients appear only as missing-value dashes and are omitted from concise progress. Derive the columns from all metrics available during the round or otherwise display newly encountered keys.


## inline-comments 3996988253 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3996988253; ; nvflare/app_common/widgets/metrics_artifact_writer.py
Fixed in d96eb1eee. The live table now selects columns from each displayed result and repeats the headings when the metric names change, including for the aggregated row. This preserves aligned output for ordinary rounds while displaying later clients’ differing metrics instead of all-missing rows. A regression test covers accuracy on site-1, loss on site-2, and weighted_loss from aggregation. The existing two-column display limit and artifact reference still apply.


## inline-comments 3997142620 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3997142620; ; nvflare/recipe/_failure_summary.py
<a href="#"><img alt="P2" src="https://greptile-static-assets.s3.amazonaws.com/badges/p2.svg?v=9" align="top"></a> **Plain-Text Context Is Lost**

The `error_log.txt` parser puts the full formatted suffix into `message` without extracting `fl_ctx`. As a result, `_first_error()` cannot recover `peer` or `peer_rc`, so the later suppression of cascading `TASK_ABORTED` records does not work for downloaded client error streams or layouts that only contain `error_log.txt`. Those records can then occupy the three-entry summary and crowd out more useful diagnostics. Parse the context prefix into `fl_ctx` before yielding the record, as the JSON path already does.


## inline-comments 3997153756 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3997153756; ; nvflare/recipe/_failure_summary.py
Fixed in 2d491710e. The text-log reader now separates the leading FL context from the message and retains it as fl_ctx, allowing the same peer/peer_rc handling as JSON logs. Regression coverage generates text with the actual BaseFormatter and verifies both grouping/removal of a linked TASK_ABORTED record and preservation of an unrelated peer error, including server-only downloaded workspace layouts. All 20 failure-summary/session tests and the full project style check pass.


## inline-comments 3997621135 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3997621135; ; nvflare/fuel/utils/log_utils.py
<a href="#"><img alt="P2" src="https://greptile-static-assets.s3.amazonaws.com/badges/p2.svg?v=9" align="top"></a> **Concise Includes Diagnostic Logs**

The concise filter now accepts every INFO record from both reporting component loggers, not just their presentation messages. Existing controller diagnostics such as “Formatter not found,” client-wait messages, model-location messages, and cleanup messages will therefore appear alongside the intended progress output, making concise mode less focused. Please distinguish presentation records from these components’ diagnostic INFO records.

Note: If this suggestion doesn't match your team's coding style, reply to this and let me know. I'll remember it for next time!


## inline-comments 3997621140 by greptile-apps[bot]; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3997621140; ; nvflare/recipe/_failure_summary.py
<a href="#"><img alt="P2" src="https://greptile-static-assets.s3.amazonaws.com/badges/p2.svg?v=9" align="top"></a> **Multiline Exceptions Are Mislabeled**

This regex also matches any standalone identifier in a traceback, and `_first_error()` uses the last match. For a valid multiline exception such as `ValueError: first line\nadditional`, the summary reports `additional` instead of the actual exception, making the failure summary misleading even though the complete traceback remains in the logs.


## inline-comments 3997801064 by chesterxgchen; https://github.com/NVIDIA/NVFlare/pull/5286#discussion_r3997801064; ; nvflare/fuel/utils/log_utils.py
Fixed in 29fe1c3a2. Concise now uses the existing LoggerNameFilter exclusion option to suppress class-level diagnostic INFO while retaining the defining module's reporting records. Warnings/errors still pass through regardless of class, and inherited reporting remains visible for GlobalModelEval, HECrossSiteModelEval, and user subclasses. Detailed log.txt/log.json and full/verbose retain the diagnostic INFO.

This is four lines of configuration using the existing filter, with no additional logging mode or formatter.

Validation: the new base-controller regression failed before the change; all 93 targeted tests now pass, including actual saved-result logs through local filtering and JSON-based remote replay. Full project style check passed. A real, unmodified three-round Hello PyTorch run retained all round/evaluation results and the final summary; formatter/model-location/result-path diagnostics were absent from the console and present in server/log.txt. The PR description preserves the before capture and now includes the complete 77-line after capture plus refreshed LOC tables.



## Files
docs/user_guide/admin_guide/configurations/logging_configuration.rst
docs/user_guide/data_scientist_guide/recipe_api.rst
examples/advanced/hello-pt-environments/README.md
examples/advanced/hello-pt-environments/job.py
examples/hello-world/hello-pt/README.md
examples/hello-world/hello-pt/job.py
examples/hello-world/hello-pt/prepare_data.py
nvflare/app_common/widgets/metrics_artifact_writer.py
nvflare/app_common/workflows/cross_site_model_eval.py
nvflare/app_opt/pt/job_config/base_fed_job.py
nvflare/app_opt/tf/job_config/base_fed_job.py
nvflare/client/in_process/api.py
nvflare/fuel/flare_api/api_spec.py
nvflare/fuel/flare_api/flare_api.py
nvflare/fuel/utils/log_utils.py
nvflare/job_config/base_fed_job.py
nvflare/private/fed/server/job_cmds.py
nvflare/private/fed/server/server_json_config.py
nvflare/recipe/__init__.py
nvflare/recipe/_args.py
nvflare/recipe/_failure_summary.py
nvflare/recipe/_run_summary.py
nvflare/recipe/run.py
nvflare/recipe/session_mgr.py
nvflare/recipe/sim_env.py
nvflare/recipe/spec.py
tests/integration_test/fast/hello_pt_environment_continuity_test.py
tests/integration_test/fast/recipe_run_output_test.py
tests/integration_test/slow/external_process_e2e_test.py
tests/unit_test/app_common/widgets/metrics_artifact_writer_test.py
tests/unit_test/app_common/workflow/cross_site_model_eval_test.py
tests/unit_test/client/in_process/api_test.py
tests/unit_test/examples/hello_pt_client_test.py
tests/unit_test/examples/hello_pt_environments_job_test.py
tests/unit_test/examples/hello_pt_job_test.py
tests/unit_test/fuel/flare_api/session_new_methods_test.py
tests/unit_test/fuel/log_utils_dynamic_config_test.py
tests/unit_test/private/fed/server/job_cmds_test.py
tests/unit_test/private/fed/server/server_json_config_test.py
tests/unit_test/recipe/_args_test.py
tests/unit_test/recipe/_failure_summary_test.py
tests/unit_test/recipe/run_test.py
tests/unit_test/recipe/session_mgr_test.py
tests/unit_test/recipe/sim_env_test.py
tests/unit_test/recipe/spec_test.py