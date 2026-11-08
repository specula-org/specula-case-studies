# task worker 子系统失败语义排查（第 10 轮，2026-11-08）

源码 pin `c411a201`（只读）。上游 main 在 11-03 之后没有改过 `nvflare/private/fed/task_worker/`、`task_worker_executor.py`、`client_api_task_runner.py`、`app_opt/task_launcher/`（GitHub API 复核）。行号都按 pin。

读过的代码：`task_worker/{supervisor,artifacts,worker,runtime,protocol,cell_session}.py`、`client/{task_worker_executor,client_api_task_runner,client_runner,client_executor}.py`、`app/client/task_worker_process.py`、`app_opt/task_launcher/{k8s_task_service,k8s_launcher}.py`、`app_opt/job_launcher/k8s_launcher.py`（CJ handle、`can_restart`、`_release_job_resources`）、`apis/impl/wf_comm_server.py`（重发、回执）、`server/server_runner.py`（claim/finish 顺序）；设计文档 `task_worker_lifecycle.md`、`client_job_recovery.md`、`task_worker_cellnet_session.md`。测试 harness：`tests/local_task_launcher.py`、`tests/task_execution_test_utils.py`、`tests/integration_test/fast/task_{supervisor,execution}_process_test.py`（在导出的副本 `.tmp/nvflare-src` 里跑通，5/5）。

## 角色与四个事实

CJ 里的 `TaskWorkerExecutor` 每个分派建一个 attempt：物理 attempt ID = `sha256([CJ launch ID, 服务器 attempt ID])`（`task_worker_executor.py:159-166`），CJ 恢复后换新 ID，服务器分派 ID 不变。`TaskSupervisor` 一次只持有一个 attempt，`_launch_identities` 永久防重放。worker 跑一次就退出，结果、完成记录、checkpoint、失败记录都在共享 PVC 上。K8s 下 CJ 只是代理，Pod 的创建、观测、删除由 CP 的 `K8sTaskService._Job` 负责，每个 job 至多一个没停稳的 attempt（`k8s_task_service.py:283`）；CJ 退出后 CP 继续清理，`can_restart` 要等 CJ Pod 确认停止且 `_Job` 线程退出（所有 attempt 停稳）。

四个独立事实：本地完成（`completion.json`）、物理停稳（Pod 删除且 finalizer 去掉后 404）、服务器回执（RECEIVED/TASK_CLOSED）、checkpoint 提交（清单 `os.replace`，`artifacts.py:263-297`）。结果数据只在"停稳 + 校验通过 + 终态回执 + 无读者"之后释放（`supervisor.py:453-489`）。

## 失败语义表

| 操作 | 失败方式 | 处理 | 判断 |
|---|---|---|---|
| `create_attempt` / `write_input` / `write_bootstrap`（`supervisor.py:251-254`） | 写盘失败 | 异常向上；身份已进 `_launch_identities`；没有 handle，`_active` 清空；本轮结果 EXECUTION_EXCEPTION | 同一 CJ 内服务器重发同一分派时只会得到"already owned"，见 W3 |
| `prepare_checkpoint`（launch 前） | 已提交的 checkpoint 损坏 | ValueError，本轮失败 | 之后该 task 名的每一轮都失败，直到人工处理；设计上 fail-stop |
| `launch_task`（CJ→CP，`k8s_task_service.py:341-371`） | 回复丢失或超时 | 包成 TaskLaunchError(handle)；supervisor 取消（CP 建 fence 或删 Pod），本轮失败 | L1：CP 端 launch 按身份幂等，重试本来安全；属设计取舍（可用性），不计 |
| `launch_task`（CP→K8s create） | 传输失败、Pod 可能已建 | 保留 handle，拒绝码才算 rejected；之后按 UID 观测和删除 | 有防护 |
| `poll`（CJ→CP 或 CP→K8s） | API 不可用 | 保留上次 phase，单独记 observation_error，不当作停稳 | 有防护 |
| `wait_for_settlement` / `cancel` | 超时 | `_fence`：`settlement_unconfirmed`，system_panic，保留所有权和证据，不再接新 attempt | 有防护（fail-stop） |
| worker 崩溃、无 `failure.json`、退出码 ≠0 | — | `TaskExecutionInterrupted` → CJ 非零退出 → CP 走 CJ 恢复 | 有防护 |
| worker 写了 `failure.json` | — | RuntimeError，本轮 EXECUTION_RESULT_ERROR，不恢复 | 设计如此 |
| K8s Pod Failed 但容器没有 terminated 状态（如部分驱逐） | `exit_code=None` → `retryable=False` | 当普通失败，不走 CJ 恢复 | L4：没有集群无法确认 kubelet 是否总给出退出码，不计 |
| 完成记录发布（`commit_staged_result`） | 发布与 abort/致命错误竞争 | `completion_guard` 串行化，有未结束的直接操作就拒绝发布（`runtime.py:136-150`） | 有防护 |
| 指标会话 `log`（worker→CJ，最长等 30 s） | CJ 拒绝或断开 | worker 失败，写 `failure.json` | 有防护 |
| 截止时间（`result_wait_deadline` + `_wait`） | worker 与 CJ 不在同一节点 | 用 worker 写的 `time.monotonic()` 减 CJ 的 `time.monotonic()` | **L5：bug，已复现** |
| `commit_checkpoint`（清单替换前） | 写盘失败或 guard 取消 | 不提交，异常向上；之前的 checkpoint 保持 | 有防护 |
| `commit_checkpoint`（清单替换后） | 目录 fsync 失败 | 吞掉并告警，结果照常返回 | 有防护（设计如此） |
| 结果发送（`client_runner.py:654-741`） | 回复丢失 / RETRY | 不重算，重发保存的结果，直到 RECEIVED/TASK_CLOSED | 有防护 |
| `release_payloads` | 写盘失败 | attempt 标 failed 保留证据，告警 | 有防护 |
| CJ 崩溃：提交前 / 提交后发送前 / 发送后拿到回执前 / 拿到回执后 | — | 恢复后的 CJ 先查 checkpoint 清单里记录的分派：已提交就重发保存的结果，否则重算 | 见 W1、W3 |
| CP 崩溃 | — | 不支持接管，需要人工核对 | 设计如此 |

## 线索核实

| 线索 | 结论 | 依据 |
|---|---|---|
| L1 launch 回复丢失就让本轮失败 | 设计取舍，不计 | CP 端同身份同参数的 launch 直接返回已有 attempt（`k8s_task_service.py:278-280`），重试安全；设计文档只承诺"回复丢失不会让执行失去所有者" |
| L2 ABORT_TASK 不核对是哪个 attempt | 排除 | CJ 里 ABORT_TASK 事件只在 `end_run_events_sequence` 里触发（`client_runner.py:1027-1034`）。管理员 abort_task 的 CJ 端处理器调用的 `ClientRunner.abort_task()` 自 #1881（2023-08）起就不存在，但服务器端从不发送 `train.abort_task`，整条路径是死代码，不计 |
| L3 RECEIVED 并释放数据后服务器又重发 | 排除 | `finish_submission` 在 `server_runner.py:611-612` 的 finally 里、回复发出之前执行，设置 `result_received_time`；之后 `_do_process_task_request` 不会再重发（`wf_comm_server.py:244-256`） |
| L4 驱逐的 Pod 没有退出码 | 不计 | 见上表，需集群确认 |
| L5 跨节点单调时钟 | **REPRODUCED** | 见下 |

### L5：CJ 用 worker 节点的单调时钟判超时

worker 在 `_mark_progress`（`client_api_task_runner.py:39-42`）把 `time.monotonic()` 写进 `result_wait_started.json`、`result_staging_started.json`、`script_result_sent.json`。CJ 的 `result_wait_deadline`（62-77 行）用这些值算出绝对截止时间，`TaskSupervisor._wait`（`supervisor.py:348-361`）减去 CJ 自己的 `time.monotonic()`，`remaining <= 0` 就取消 worker 并抛 TimeoutError。`CLOCK_MONOTONIC` 从各节点开机起算，跨节点不可比；K8s 是 task 模式唯一实现的后端，设计文档还推荐 CPU 节点跑 CJ、GPU 节点跑 worker。`finalization_timeout` 默认 30 s，只要出现 `script_result_sent` 标记就生效，不需要任何额外配置。

后果：
- worker 节点比 CJ 节点晚开机超过 `finalization_timeout`（典型：自动扩容新拉起的 GPU 节点）：CJ 在 send 之后、finalize 结束之前任何一次轮询（默认 50 ms）都会判超时，健康的任务被取消、本轮失败；设了 `result_wait_timeout` 时脚本一开始就被取消。
- worker 节点比 CJ 节点早开机：`result_wait_timeout` 和 `finalization_timeout` 永远不触发，挂住的脚本只受可选的 `worker_timeout` 约束（默认 None）。

复现：`bash checks/confirm/l5_monotonic_repro.sh`。真实代码：`TaskWorkerExecutor`、`TaskSupervisor`、worker 进程、Client API 脚本、指标会话。替代：上游测试用 `ProcessTaskLauncher` 代替 K8s 后端；`checks/confirm/timens_exec.py` 用 time namespace 平移 worker 的 `CLOCK_MONOTONIC`，代表"另一个节点"。

| 场景 | 对照（偏移 0） | 偏移后 |
|---|---|---|
| A：默认 30 s，send 后 2 s 收尾 | 2.7 s 成功 | −1000 s：0.7 s TimeoutError |
| B：`finalization_timeout=1s`，send 后 4 s 收尾 | 1.7 s TimeoutError | +1000 s：4.7 s 成功 |

证据等级：REPRODUCED，无强制调度、无耗时桩；环境条件（节点开机时间不同）用 time namespace 模拟，后端换成测试 launcher。上游：无相关 issue/PR（搜 "monotonic" 只有 #5653/#5656 的 conditional_wait，无关）；main 未变。修复方向：worker 只写持续时间，或 CJ 在第一次读到标记时用自己的时钟记下观测时刻。

### L6（11-08 下午补充，只有静态证据，不计数）：停稳慢于 `settlement_timeout` 时，已经完成的结果被丢掉

`TaskSupervisor._wait`（`supervisor.py:362-375`）看到 TERMINAL 后最多等 `settlement_timeout`（默认 10 s，`task_execution_policy.py:102`）。超时就 `_cancel`，取消在 `cleanup_timeout`（默认 60 s）内确认停稳后仍然把 TimeoutError 抛出去，本轮回 EXECUTION_EXCEPTION。worker 这时可能早已发布了有效的 completion。K8s 的停稳要等 CP 轮询（0.5 s）、删除 Pod、kubelet 报告 sandbox 已关（`PodReadyToStartContainers=False`，`k8s_pod.py:19-41`）、去掉 finalizer、再看到 404。集群繁忙时这串步骤能否超过 10 s 只能在真实集群上确认。设计文档写的是"expiry fences further attempts and retains ownership/evidence"，代码在取消成功时并不 fence，只是让本轮失败，属于可用性问题，先记为线索。模型里 `settleTimeout` 只覆盖"取消也确认不了"的 fence 情况。

## 上游查重

#5616（K8s CJ 与 task worker 恢复，OPEN）：跟踪"确认停止后再替换、保留分派、新物理 ID、checkpoint 连续"，验收点与 W1/W2 相同，没有提到时钟。#5500（Process task GPU 与失败清理，OPEN）：Process 后端已推迟，与 K8s 路径无交集。L5 与两者都不重叠。

## 对建模的含义

单点失败基本都有显式 fence，bug 更可能出在多步交错：服务器重发 × CJ 恢复（新 launch ID）× checkpoint 提交点 × 回执驱动的释放 × abort/END_RUN × CP 端准入。建模保留：attempt 身份（launch, 服务器 attempt）、`_launch_identities`、`_completed_attempts`、checkpoint 清单（记录的分派 + 结果）、结果数据是否已释放、CP 端 attempt 表与 `closed/released`、`can_restart` 的两个条件。L5 是时钟域问题，在模型里表示为"截止时间的时钟来源"即可，不需要建实际时间。
