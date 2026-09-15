# 3830: [BUG][2.5] Aborting jobs that use flower

State: CLOSED

**Description**
When aborting a NVFlare job that uses Flower for the training logic, the abort does not interrupt the training loop (it only prevents executing the next round or evaluation).

**To Reproduce**
Steps to reproduce the behavior:
1. Clone the [hello-fower example](https://github.com/NVIDIA/NVFlare/tree/2.5/examples/hello-world) (branch 2.5).
2. Start POC mode.
3. Inspect what python processes are running before submitting the job.
4. Submit the `flower_pt` job.
5. Optional: Inspect what python processes are running during submitting the job.
6. Abort the job using `abort_job`.
7. Inspect what python processes are running after submitting the job. See that the CPU/GPU load does not drop after aborting the job but the training continues in the background.

**Expected behavior**
Training loop should be stopped by abort signal.

**Environment:**
 - OS: macOS 13.4.1, RedHat Enterprise Linux 9.6 (Plow)
 - Python Version: 3.11
 - NVFlare Version: 2.5.2 ([this commit])
 - Flower Version: 1.11.0rc0
 - Tested on CPU

Is there some kind of interrupt signal that i can listen to in `client.py` and pass to my `train()` function to stop it when the job is aborted?



## Comment 3544394553 https://github.com/NVIDIA/NVFlare/issues/3830#issuecomment-3544394553

Hi @SlamanigG

I observed the same behavior using NVFLARE 2.5 with Flower 1.11.0.

The newer NVFLARE versions (2.6 and 2.7) are designed to work with Flower 1.23.0.

For NVFLARE 2.5, we needed to add the following lines:

```
diff --git a/nvflare/app_common/tie/executor.py b/nvflare/app_common/tie/executor.py
index f40bca989..d86ebc4f9 100644
--- a/nvflare/app_common/tie/executor.py
+++ b/nvflare/app_common/tie/executor.py
@@ -138,6 +138,9 @@ class TieExecutor(Executor):
             self._notify_client_done(Constant.EXIT_CODE_FATAL_ERROR, fl_ctx)
         elif event_type == EventType.END_RUN:
             self.abort_signal.trigger(True)
+            if self.connector:
+                self.logger.info(f"stopping connector {type(self.connector)}")
+                self.connector.stop(fl_ctx)
 
     def execute(self, task_name: str, shareable: Shareable, fl_ctx: FLContext, abort_signal: Signal) -> Shareable:
         if task_name == self.configure_task_name:
```

This fix is already included in NVFLARE 2.6 and later.

We recommend trying the newer versions if possible. Otherwise, you can manually apply this change to 2.5.

## Comment 3563405701 https://github.com/NVIDIA/NVFlare/issues/3830#issuecomment-3563405701

Hi @SlamanigG, the flower team worked on some updates that might help with this issue https://github.com/adap/flower/pull/6151

Would you mind checking if this issue persists with the latest version of nvflare and the flwr-nightly build?

## Comment 4282410099 https://github.com/NVIDIA/NVFlare/issues/3830#issuecomment-4282410099

@SlamanigG did you have a chance to confirm this issue still exists in later flwr versions?

## Comment 4286277610 https://github.com/NVIDIA/NVFlare/issues/3830#issuecomment-4286277610

@holgerroth Yes, I  am pretty sure this still existts. Cannot confirm 100% though, as I have since used a workarund.

## Comment 4337584196 https://github.com/NVIDIA/NVFlare/issues/3830#issuecomment-4337584196

Update: I checked this against latest `upstream/main` and the latest released Flower version I found (`flwr==1.29.0`), and I can no longer reproduce the original "training keeps running indefinitely after abort" behavior.

Current code state:

- `upstream/main` at `7bec4a617f2364421c0195cac18cfb9e384df185` includes the `END_RUN` connector-stop path in `nvflare/app_common/tie/executor.py`, so abort triggers the NVFlare abort signal and then calls `connector.stop(fl_ctx)`. This is the path that was missing in the 2.5.2 code used in the original report.
- The Flower integration now stops both sides of the Flower runtime: the server applet issues `flwr stop <run_id> nvflare` and shuts down SuperLink, and the client connector stops the SuperNode/client applet side.
- Flower `1.29.0` includes the newer shutdown behavior from flwrlabs/flower#6151.

Confirmation test:

- Environment: NVFlare from `upstream/main` commit `7bec4a617f2364421c0195cac18cfb9e384df185`, installed as `2.7.1+288.g7bec4a617`; `flwr==1.29.0`; local POC mode with 1 client.
- Test app: a Flower `NumPyClient` whose `fit()` writes a heartbeat once per second for 120 seconds, and writes a `fit_finished_*` marker only if it completes naturally.
- Procedure: submit the app through `FlowerRecipe`, wait until `fit()` starts, call NVFlare `run.abort()`, then observe the heartbeat, the ClientApp PID, and the fit-completion marker.
- Result: PASS. The `fit()` did not complete naturally, no `fit_finished_*` marker was written, the Flower ClientApp process exited, and a post-test process check found no leftover Flower/NVFlare subprocesses.

One nuance: shutdown was not instantaneous in this local POC run. The heartbeat advanced briefly after `abort()` returned, and the ClientApp exited about 13 seconds after `abort()` returned. So the current behavior is "abort terminates Flower training after a short shutdown interval," not "abort interrupts the user `fit()` loop synchronously at the exact moment the command returns."

Based on this test, the original concern appears fixed for current `upstream/main` + `flwr==1.29.0`. For NVFlare 2.5.x, the original behavior likely still applies unless the connector-stop patch mentioned above is applied manually.
