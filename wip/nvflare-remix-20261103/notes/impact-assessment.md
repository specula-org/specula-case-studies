# NVFlare 发现的影响评估（2026-11-07）

输入：`RESULTS.md` §10–§14、`checks/confirm/*.py` 的复现脚本和 docstring、源码 pin `c411a201`（`/home/ubuntu/nvflare-integrated-model-20261103/sources/current`，只读）。行号都按 pin。上游复核用只读 GitHub API，见"上游与版本复核"。

口径：
- 按根因计数。证据等级分开：REPRODUCED（真实代码上复现，再按"无强制"和"靠强制调度、耗时桩或注入故障"分两档）、STATIC（只读代码确认逻辑）、MODEL-ONLY（只有模型反例）。本次只读代码新看到、没有执行的路径单独标出，不计数。
- 可能性：高 = 常见运维事件下确定性触发；中 = 需要一个常见但不必然的事件（一次重试、一次删除、一次 CJ 崩溃），不需要特殊时序；低 = 需要较少见的事件，或毫秒到秒级的时序巧合；很低 = 需要注入级故障，或微秒窗口叠加其他前提。
- 严重度看"触发之后"的后果和波及面：critical = 数据丢失、安全问题或不可恢复且现实可触发；high = server 级功能丧失、job 无限期挂起、静默的错误资源分配；medium = 状态记录错误、潜伏的功能丧失、无法用支持的接口清理；low = 局部、后果可见、可人工核对。本批没有 critical。
- 优先级是建议的提交顺序，综合严重度、可能性、证据强度和修复成本。所有提交都是外部写操作，需要先经用户批准。

## 汇总表

| 发现（证据） | 后果 | 范围 | 可能性 | 严重度 | 修复覆盖 | 上游状态 | 优先级 |
|---|---|---|---|---|---|---|---|
| R2（REPRODUCED，无强制） | CP 重启后 SJ 永远收不到该 site 的 dead-job 通知；FedAvg task 默认无超时，job 卡在 RUNNING，只能手动 abort | 2.8/2.9/main；Process launcher；CP 在 `heart_beat_timeout`（provisioned 600 s）内重启；1 个 client 就够 | 高 | 高 | F-G（按 name 匹配或 re-login 时通知），独立 | 无相关 issue；main 未变 | 1 |
| H08（REPRODUCED，无强制，真实子进程） | 自动重启的 CJ 用上另一个 job 的 GPU，自己的 GPU 闲置，另一个 job 被挤占或 OOM；无任何日志 | 只在 main（#5550 的自动恢复，未发布）；Process launcher + GPU RM/consumer；同一 site ≥2 个并发 GPU job | 中 | 高 | F-H，同时覆盖模型里的 START 交叠首启路径 | 无；违背 #5550 和设计文档"same resource reservation" | 2 |
| R1（REPRODUCED，无强制） | SP 重启后崩溃前 RUNNING 的 job 永远 RUNNING，abort、delete、下载都不行 | 2.8/2.9/main（#4503 回归，2.7 正常）；任何部署；SP 非优雅退出 | 高 | 中 | F-F（启动时调一次 `update_unfinished_jobs`），独立 | 无；回归 | 3 |
| T1-b（REPRODUCED，部署桩 2 s，无强制） | 调度线程退出，server 不再调度任何 job，直到重启 | 所有版本（2.9 失败点不同）；部署期间删除该 job（秒级窗口） | 中 | 高 | F-A，与 T1 和 715 行路径共用 | 无；main 未变 | 4 |
| T1（REPRODUCED，自然竞态） | 同 T1-b | 所有版本；删除排队中的 job 恰在 1 s 扫描读 meta 之间；窗口随排队数增长 | 低 | 高 | F-A | 无；main 未变 | 4（与 T1-b 合并） |
| H11（REPRODUCED，无强制） | SJ 的 task monitor 线程 KeyError 退出；task 不再收尾、超时或做 dead-client 检查；CSE 无限等待 | 2.8/2.9/main；≥2 个同时挂着的 task（CSE 等）+ 一次 GET_TASK 重发 | 中 | 高 | 需根因修复；monitor 加 try/except 只保线程 | 无；main 未变 | 5 |
| C1-B（REPRODUCED，强制 + 注入存储故障） | completion 线程 KeyError 退出，此后所有 job 不收尾、不归档；占满 `max_jobs` 后停止调度；重启后落入 R1 | 所有版本；RUNNING 写入先挂住再失败，期间 SJ 已退出 | 很低 | 高 | F-B 保线程；根因与 C1-A 同一处（F-C） | 无；同族 #5301 NOT_PLANNED | 6 |
| C1-A/A2（REPRODUCED，强制 + 注入存储故障） | 已发布的终态（EXECUTION_EXCEPTION，或 COMPLETED 且已归档）被改写成 FAILED_TO_RUN | 同上；2.9.1rc8 的 except 分支无条件写，更宽 | 很低 | 低 | F-C | #5301 同根因族（NOT_PLANNED, P3） | 6（附在 C1-B） |
| L13（REPRODUCED，注入消息延迟或丢失） | system_panic 的 job（工作流异常、策略违规）被记为 FINISHED:COMPLETED | 所有版本；SJ→SP 那一条 fire-and-forget 状态消息在 SJ 退出后 >2 s 或丢失 | 低 | 中 | F-I（panic 时非零退出码） | 无；#5662 同类但只修 simulator/client 侧 | 7 |
| T2（REPRODUCED，`fail_run` 桩 2 s，无强制） | `client_cleanup` 线程退出，此后死掉的 client 永不移除，SJ 收不到 dead-client 通知 | 所有版本（秒级窗口只在 2.9+）；≥2 个 client 同时失联，其中一个在处理期间重新登录 | 低 | 中 | F-D 保线程（同时覆盖 T3）；根因 1 行 None 检查 | 无；main 未变 | 8 |
| T3（REPRODUCED，强制时序；自然 4/300） | 同 T2 | 所有版本；多 job；另一 job 的 SJ 恰在通知循环中退出 | 很低 | 中 | F-D；根因是快照遍历 | 无；main 未变 | 8（与 T2 合并） |
| N2（REPRODUCED，时序由场景设定） | 已完成并保存的 job 在收尾窗口被判策略违规，记为 EXECUTION_EXCEPTION | 所有版本；`min_clients` = client 数或配了 required_sites；client 死亡恰在工作流返回前约 60 s | 低 | 低 | F-J | 无（#3671 根因不同）；main 未变 | 9（附在 L13） |
| H03（REPRODUCED，强制抢占） | 过期 monitor 停掉正在服务 task B 的 launch_once trainer，B 没有失效通知 | 2.9+；external_process + `launch_once` + 惰性结果 | 很低 | 低 | F-K | 无；main 未变 | 10（暂不单独提） |
| H01（STATIC） | Attach `send()` 报成功，但 CJ 已拒绝该结果；server 本来就把这一轮记失败 | 2.9+；Attach；两次 RESULT_REJECTED 回复都丢 | 很低 | 低 | 状态查询返回 REJECTED | 无；main 未变 | 不提 |
| N1（MODEL-ONLY） | 非严格 START 下，回复超时但实际启动的 site 的失败 OUTCOME 被丢弃，job 可能 COMPLETED | 默认非严格模式；START 回复晚于 20 s | 低 | 低 | 保留该 site 的 pending outcome | 无；main 未变 | 不提 |

## 按根因计数

| 口径 | 个数 | 是哪些 |
|---|---:|---|
| 在真实代码上复现 | 13 | C1-A、C1-B、H08、H11、T1、T1-b、T2、T3、R1、R2、L13、H03、N2 |
| 其中无强制调度、无注入 | 5 | H08、H11、T1、R1、R2 |
| 其中靠强制调度、耗时桩或注入故障 | 8 | C1-A、C1-B、T1-b、T2、T3、L13、H03、N2 |
| 只有静态代码确认 | 1 | H01 |
| 只有模型反例 | 1 | N1 |
| 本次只读代码新看到、未执行（不计数） | 2 | T1 的 715 行路径；R1 的"abort 后立即 shutdown"路径 |

已复现的 13 个按严重度：high 6 个（R2、H08、T1、T1-b、H11、C1-B），medium 4 个（R1、L13、T2、T3），low 3 个（C1-A、N2、H03）。按可能性：高 2 个（R1、R2），中 3 个（H08、T1-b、H11），低 4 个（T1、L13、T2、N2），很低 4 个（C1-A、C1-B、T3、H03）。H01、N1 不计入这两组。

## 上游与版本复核

- 任务给的 main 是 `e17c1edf6`；写这份文档时 main 已到 `5c54edda`（2026-11-07 00:21 UTC，比 pin 多 26 个提交）。逐个文件比对 blob：`job_runner.py`、`job_def_manager.py`、`filesystem_storage.py`、`job_cmds.py`、`client_manager.py`、`server_engine.py`、`server_runner.py`、`server_app_runner.py`、`training_cmds.py`、`job_scheduler.py`、`wf_comm_server.py`、`task_manager.py`、`bcast_manager.py`、`cse_server_ctl.py`、`gpu_resource_consumer.py`、`process_launcher.py`、`client_executor.py`、`scheduler_cmds.py`、`external_process_backend.py`、`cell_backend.py`、`attach_backend.py`、`attach_session.py` 都与 pin 相同。
- `fed_server.py` 有两处改动：#5672 和 #5708，都在 53–644 行的调用方身份校验（`_resolve_client_fqcn_for_auth`、`_listen_command` 入口）。UPDATE_RUN_STATUS 分支只多了"非 SJ 调用方拒绝"，丢弃逻辑不变；`client_cleanup`、`remove_dead_clients`、`notify_dead_client`、`_sync_client_jobs`、outcome 处理都没变。`cross_site_model_eval.py` 的改动（#5706）只是保存路径限制，与 H11 无关。结论：所有已复现的问题在最新 main 上都还在。
- 发布线（2.8 分支、`2.9.1rc8`）：H11、T1、T2（日志行解引用）、T3、R2、L13、N2、C1 的 completion 线程 `del` 在 2.8 和 2.9 上都有；C1-A 在 2.9.1rc8 上更宽；T1-b 在 2.9.1rc8 上以不同的失败点存在（静态阅读）；H03、H01 从 2.9 开始；T2 的秒级窗口从 2.9 开始；R1 从 2.8 开始（回归）；H08 只在 main。
- 检索过的关键词（issue 和 PR）：FAILED_TO_RUN、`_job_complete_process`、completion thread、running_jobs KeyError、CUDA_VISIBLE_DEVICES、GPUResourceConsumer、resend_task、`_client_task_map`、get_jobs_to_schedule、`_check_job_status`、remove_dead_clients、notify_dead_client、client_cleanup、dictionary changed size、update_unfinished_jobs、update_abnormal_finished_jobs、ABANDONED、`_sync_client_jobs`、re-login、UPDATE_RUN_STATUS、execution_error、`_monitor_accepted_result_source`、`_resolve_ambiguous_result`、RESULT_REJECTED、deployment policy violation、dead client grace、strict_start_job_reply_check 等。除下面各节写到的，没有重复或相关的 issue。
- 维护者的态度（#5300 中 pcnudde 的回复、#5301 的关闭理由）：只在复现需要人为时序、且没有证明自然发生或现实故障时，才会定为 P3 不修；也说过"有些问题真实但实践中不会发生，或后果轻到不值得冒修复的风险"。这决定了下面的提交顺序：先提无强制复现、后果重的。

## 各发现

### R2：CP 重启后 SJ 收不到 dead-job 通知

证据：REPRODUCED，无强制（`checks/confirm/r2_repro.py`：真实 `ClientManager.authenticate` 两次登录 + 真实 `FederatedServer._sync_client_jobs`；对照组 CP 不重启、CJ 退出，每次心跳都通知；CP 重启后通知 0 次）。MC 盲跑能找回（deadlock，深度 28）。

1. 后果：CP 崩溃或被杀后由 supervisor 拉起，重新登录拿到新 token，旧 token 被 `client_manager.py:330-339` 静默弹出，不走 `notify_dead_client`。CJ 随 CP 退出（`monitor_parent_process`）。新 CP 的心跳里不再有这个 job，但 `_sync_client_jobs`（`fed_server.py:1013-1084`）只按 job 启动时 PARTICIPANTS 里的 token 匹配，新 token 对不上，SJ 永远收不到 dead-job 报告；这个 client 名字在新 token 下是活的，cleanup 线程也不会判它死。`ModelController` 的 task 默认 `timeout=0`（`model_controller.py:48`），SJ 无限等这个 site 的结果，job 停在 RUNNING。谁看到：数据科学家看到 job 一直 RUNNING、轮次不动；SP 日志只有一行 `Client: site-X already registered. Re-login the client with a new token.`，SJ 日志里没有任何 dead-client 记录。恢复只能管理员 `abort_job`。
2. 范围：2.8、2.9.1rc8、main 代码相同；POC 和生产都受影响（simulator 不走这条路径）。条件：Process launcher（provisioned 默认 `ClientProcessJobLauncher`；Docker/K8s 下 CJ 是否随 CP 退出没有核实）；CP 在 `heart_beat_timeout` 内重启（provisioned 600 s，未配置时 60 s；超过这个时长，cleanup 会先登出旧 token 并通知 SJ）；task 没设超时（默认）。设了 task 超时时，后果变成这一轮超时，按工作流的容错策略继续或失败。持续到人工 abort（只影响这个 job）。
3. 可能性：高。长时间训练里 CP 崩溃后自动重启（systemd、docker restart policy、k8s）是常见运维事件；复现不需要任何时序，后果确定发生。
4. 严重度：高。普通的故障恢复动作让 job 无限期挂起，没有超时兜底，也没有指向原因的日志；dead-client 和 min_clients 策略在这条路径上完全失效。
5. 修复：`fed_server.py::_sync_client_jobs` 按 token 找不到时，再按 client name 在 PARTICIPANTS 里匹配（`require_previous_report` 的记录也改按 name）；或者在 `ClientManager.authenticate` 的 re-login 分支，把被弹出的旧 Client 交给 `FederatedServer.notify_dead_client`。后一种同时缩小 T2 的触发面，但 T2 的 None 检查仍然需要。
6. 上游：没有相关 issue 或 PR；main 未变。`docs/design/client_job_recovery.md` 写了 "CP restart adoption remains outside this feature"，维护者可能把"CP 重启后 job 不能续跑"当成已知范围外。issue 要强调的是 job 永远不失败、也不报告，而不是不能续跑。
7. 建议：第一批，优先级 1。

### H08：自动重启的 CJ 拿到另一个 job 的 GPU

证据：REPRODUCED，无强制，真实子进程（`checks/confirm/h08_repro.py`：真实 `GPUResourceConsumer.consume`、`JobExecutor._launch_job`/`_restart_job`、`_JobRestart`、`ProcessJobLauncher.launch_job`、`ProcessHandle.can_restart`；只替换 GPU 探测、engine、workspace 和 CJ 命令）。MC：去掉 rpcTimeout 后 5/6 个 run 在 5–22 秒找回重启路径。

1. 后果：CP 的 START_JOB 处理把 job 的 GPU 分配写进 CP 进程级的 `os.environ["CUDA_VISIBLE_DEVICES"]`（`scheduler_cmds.py:122-124` → `gpu_resource_consumer.py:33`）；每次 spawn 复制当时的 `os.environ`（`process_launcher.py:130`）。自动恢复（`client_executor.py:722-758` → `_launch_job`）重新 spawn 时不再 consume，于是 job A 的第二代 CJ 用的是最近一次任何 job 的 START 写下的 GPU，也就是 job B 的。结果是 A 和 B 挤在 B 的 GPU 上，A 自己保留的 GPU 空着，也分不给别人；无辜的 B 可能 CUDA OOM 或明显变慢，B 崩溃后又会触发它自己的重启。没有任何错误日志，CP 日志只有 `restarting CJ (attempt 1/3)`。谁看到：站点运维在 `nvidia-smi` 里看到一张卡上两个进程、另一张卡闲置；数据科学家看到 B 的 OOM 或吞吐下降。安全相关性：违反资源隔离，多 study 部署里不同 study 的 job 会共用一张卡；CUDA 上下文隔离仍在，不构成直接的数据泄露。
2. 范围：只在 main。自动恢复由 #5550（2026-10-26）引入，2.8 和 2.9.1rc8 没有 `_restart_job`，所以还没有发布。条件：Process launcher（Docker launcher 按 `ALLOCATED_RESOURCES` 生成 DeviceIDs，不受影响；Slurm 自己设 GPU env）；CP 配了 `GPUResourceManager` + `GPUResourceConsumer`（provisioned `local_client_resources` 模板的默认组件，需要 project.yml 里 `num_gpus > 0`）；同一 site 上 ≥2 个都申请 GPU 的 job 并发（provisioned 模板 `max_jobs` 为 4，`DefaultJobScheduler` 代码默认 1）；A 的 CJ 以可重启的返回码退出（EXECUTION_ERROR、EXCEPTION、INFRASTRUCTURE_ERROR；`max_cj_restart_failures` 默认 3）。不申请 GPU 的 job 不调用 consume，不受影响。持续 A 这一代 CJ 的整个生命周期。
3. 可能性：中。前提（多 GPU 站点、多 job 并发、CJ 崩溃一次）满足后确定发生，不需要时序；CJ 崩溃恢复正是这个特性要处理的场景。2.10 发布后用户才会碰到。
4. 严重度：高。静默的错误资源分配，伤及另一个 job，直接违背 #5550 和设计文档开头 "same ... resource reservation" 的承诺。
5. 修复：`ProcessJobLauncher.launch_job` 在 130 行之后按 `fl_ctx` 里该 job 自己的 `FLContextKey.ALLOCATED_RESOURCES` 设置子进程的 GPU env，不再依赖进程级 `os.environ`（Docker launcher 已经这样做；重启路径的 `fl_ctx` 来自 `start_app`，已经带这个属性，`client_executor.py:294`）。更彻底的做法是让 consumer 返回 env，而不是改全局 env。同一修复也覆盖模型里找到、没有在代码上复现的"两个 START 处理交叠"首启路径（依赖 START 回复超时）。
6. 上游：无相关 issue。#5559（open，同一特性区，launcher ownership）明确写了 "no GPU capacity accounting is involved"，不是同一问题。设计文档的 follow-up 里有一句 "GPU recovery ... remain separate work"，维护者可能据此归为已知；issue 要说明问题是"用到了别的 job 的 GPU"，不是"缺少 GPU 恢复"。main 未变。
7. 建议：第一批，优先级 2，最好赶在 2.10 发布前。

### R1：SP 重启后 RUNNING 的 job 成为僵尸

证据：REPRODUCED，无强制（`checks/confirm/r1_repro.py`：真实 store、新启动的 JobRunner、真实 `JobCommandModule`；对照组 DISPATCHED 能 abort）。MC 盲跑能找回。

1. 后果：SP 非优雅退出后重启，崩溃前写下的 RUNNING 永远不变。`abort_job` 走 `stop_run`，回答 "Job ... is not running. It can not be stopped."（`job_cmds.py:1073-1105`）；`delete_job` 回答 "is running, could not be deleted"（`job_cmds.py:509-523`）；workspace 没有归档，结果下载不了；`list_jobs` 和 Session API 的 `monitor_job` 永远看到 RUNNING。job 本身已经随崩溃丢了，R1 额外造成的是一个用支持的接口删不掉的僵尸记录，以及挂住的监控和自动化脚本；只能手工改 job store 里的 meta。谁看到：管理员和数据科学家（list_jobs），自动化流水线（monitor_job 等到超时）。
2. 范围：所有部署，任何 SP 非优雅退出时处于 RUNNING 的 job（崩溃、OOM kill、主机或容器重启、kill -9）。admin `restart` 和 `shutdown` 在有运行中的 job 时会拒绝（`training_cmds.py:164-170, 264-267`），但 `shutdown` 只检查 `run_aborted`，"abort 之后立刻 shutdown all"也可能落到这里（静态推断，未执行，不计数）。另外 T1、T1-b、C1-B、T2、T3 的恢复手段都是重启 SP，届时还在跑的 job 都会变成 R1 僵尸。永久。
3. 可能性：高。SP 在有 job 运行时重启就必现，没有时序要求。
4. 严重度：中。不会多丢训练数据，但记录永久错误，且没有任何管理命令能清理，会挂住依赖 job 状态的自动化。
5. 修复：SP 启动后、job runner 开始调度之前调用一次 `self.engine.job_runner.update_unfinished_jobs(fl_ctx)`，把残留的 RUNNING/DISPATCHED 标为 ABANDONED（2.7 在 `FederatedServer._turn_to_hot` 里就是这样做的）。1–3 行。
6. 上游：没有 issue。这是回归：#3898（2025-12）把 `_turn_to_hot` 简化为只调 `update_unfinished_jobs`；#4503（2026-05-02，"Remove HA/Overseer"）删掉 `_turn_to_hot` 时没有把这一步移到别处。2.7 分支的 `fed_server.py` 里仍有调用，2.8、2.9.1rc8、main 都没有；`job_runner.py:852-883` 的两个恢复函数在 main 上仍然没有调用者。
7. 建议：第一批，优先级 3。回归加一行修复，最容易被接受。

### T1-b：部署期间删除 job，调度线程退出

证据：REPRODUCED（`checks/confirm/t1b_repro.py`：真实 `JobRunner.run()` 及 except 分支、真实 SimpleJobDefManager 和 FilesystemStorage；部署用耗时 2 秒的桩，期间做一次真实删除；不强制调度；2/2）。MC：BFS 23 步找到。

1. 后果：部署期间 job 仍是 SUBMITTED，`delete_job` 允许删除（`job_cmds.py:518` 只拒绝 DISPATCHED 和 RUNNING）。部署完成后，try 里的 `_check_job_status`（`job_runner.py:727`）对已删除的 job 拿到 None，`.meta` 抛 AttributeError（`job_runner.py:827-829`）；except 分支在 793–796 行再调一次 `_check_job_status`，抛同样的异常，没有处理，`run()` 退出。此后 server 不再调度任何 job，直到重启；已经在跑的 job 由 completion 线程照常收尾；这个 job 在各 client 上的资源预留也不会被取消。谁看到：所有用户，之后提交的 job 永远 SUBMITTED；SP 只有一条未捕获线程异常（`AttributeError: 'NoneType' object has no attribute 'meta'`，NVFlare 没有装 `threading.excepthook`，由 Python 默认 hook 打到 stderr），没有其他报错，`check_status` 看起来正常。
2. 范围：所有部署（simulator 不走 JobRunner）；FilesystemStorage 是唯一自带的后端，其他后端只要 `get_job` 对已删除 job 返回 None 也一样；1 个 job 就够；窗口是整个部署过程（向所有 client 发 deploy，RPC 超时 10 s，custom code 大或 client 多时更长）。2.9.1rc8 上同一窗口也存在，失败点不同：部署后 `set_status(DISPATCHED)` 对已删除的对象抛 StorageException，except 分支里的 `set_status(FAILED_TO_RUN)` 再抛一次（静态阅读，未执行）。持续到 SP 重启。
3. 可能性：中。"刚提交就发现提错了，马上删掉"是普通的用户操作，用户看到的状态仍是 SUBMITTED，窗口是秒级，不需要时序配合。
4. 严重度：高。一次普通的删除让整个 server 静默停止调度，波及所有用户；恢复要重启 SP，而重启又会把正在跑的 job 变成 R1 僵尸。
5. 修复（与 T1 共用 F-A）：`_check_job_status` 遇到 None 时返回 True，即"不在期望状态"，调用方跳过这个 job；`run()` 的循环体每轮包一层 `try/except Exception`（记日志后 continue）；except 分支里的写状态也要容忍 job 已不存在。
6. 上游：无相关 issue；main 未变。
7. 建议：与 T1 合成一个 issue，以 T1-b 为主场景，优先级 4。

### T1：扫描与删除竞态，调度线程退出

证据：REPRODUCED，自然竞态（`checks/confirm/t1_repro.py`：真实 JobRunner、SimpleJobDefManager、FilesystemStorage，不强制）。300 个排队 job 时一次扫描约 26 ms，每次删除约 2.6% 触发，三轮分别在第 4、159、15 次删除时触发；20 个排队 job 时扫描约 2.2 ms，随机删除 240 次 0 次触发。MC 盲跑多次找回。

1. 后果：同 T1-b。1 秒一次的调度扫描（`job_runner.py:704`，在 try 之外）先 `list_objects` 再逐个 `get_meta`（`job_def_manager.py:517-531`）；被删掉的排队 job 让 `get_meta` 抛 StorageException（`filesystem_storage.py:326-327`）。SP stderr 有一条 `StorageException: object ... does not exist`。
2. 范围：所有版本（2.8、2.9 的 `_scan` 相同）。只涉及删除 SUBMITTED job：已结束的 job 带 `scheduled` 标签，不在扫描列表里。窗口与排队 job 数成正比。需要 SP 处于 HotState 且至少 1 个 client 在线。
   - 只读代码看到的第三条路径（未执行，不计数）：`job_runner.py:715` 的部署前检查同样在 try 之外，窗口是 `schedule_job` 里向各 client 做资源检查的 RPC（15 s 超时）。这期间删除正被调度的 job，调度器返回它之后 715 行抛 AttributeError。修复同 F-A。
   - 未验证的推测（不计数）：删除已结束的 job 时，如果 `rmtree` 先删 `scheduled` 标签文件、后删 data/meta，扫描可能把它列进来并在读 meta 时失败。这取决于目录项删除顺序，没有测。
3. 可能性：低。每次删除的命中率大约是"扫描读到该 job 之前的耗时 / 1 s"，常见的几个到几十个排队 job 时在千分之一到万分之几；但扫描一直在跑，删除排队 job 也是日常操作，长期累积不可忽略。
4. 严重度：高（同 T1-b）。
5. 修复：F-A；另外 `_scan` 对单个对象的 StorageException 直接 `continue`。
6. 上游：同 T1-b。
7. 建议：并入 T1-b 的 issue，优先级 4。

### H11：重发路径重复登记 ClientTask，task monitor 退出

证据：REPRODUCED，无强制、无注入（`checks/confirm/h11_repro.py`：真实 `WFCommServer`、`Task`、`ClientTask`、task manager 和 `_monitor_tasks`，engine 是桩；`send` 和 CSE broadcast 两种方式都复现）。MC 盲跑 2 次找回。

1. 后果：`wf_comm_server.py:246-277` 的循环里，重发分支设 `resend_task = True` 后没有 break；后面某个 task 对这个 client 返回 NO_BLOCK 时，下一轮迭代把 `resend_task` 重置为 False，于是发送块（366–375）把旧 ClientTask 又 append 一次。task 退出时，1264 行的 `_client_task_map.pop(client_task.id)` 第二次 pop 抛 KeyError，`_monitor_tasks` 没有异常处理，线程退出。此后没有 task 会被收尾、超时或做 dead-client 检查，job 策略检查（min_clients、required_sites）也停了。CSE（`cse_server_ctl.py:196-197`、`cross_site_model_eval.py:236`、`cross_site_eval.py:128`）在 `while get_num_standing_tasks()` 处一直等，job 停在 RUNNING，只能手动 abort，CSE 结果丢失（训练阶段的模型通常已经保存）。谁看到：数据科学家看到 job 卡在验证阶段；SJ 日志里一条 `_monitor_tasks` 线程的 KeyError traceback。
2. 范围：2.8、2.9.1rc8、main 代码相同；问题在 SJ 内部，POC、生产、simulator 都可能（simulator 里少有回复丢失）。条件：工作流里有 ≥2 个同时挂着的 task，请求的 client 对排在后面的某个 task 是 NO_BLOCK，即不在 targets 里（client 控制的 CSE，targets 互不相交），或者已经交回了那个 task 的结果（`task_manager.py:62-65`）。后一种对应 server 控制的 CrossSiteModelEval/CrossSiteEval：每个模型一个 broadcast，targets 相同，client 做完后面的验证 task 再回头重取前面的 task 就触发；这一变体是静态推导，复现脚本跑的是 targets 不相交的两种方式。再加一次 GET_TASK 重发：assignment 回复丢失或超时、结果提交没被 server 收到，或者 CJ 重启（main 的自动恢复 #5550 正是靠"server 重发未完成的 assignment"让替换的 CJ 接上）。FedAvg 训练阶段只有一个 task，不受影响。
3. 可能性：中。CSE 是常用的收尾步骤（示例和 recipe 都提供），验证 task 带完整模型，回复体积大，回复超时并不罕见；一旦出现重发，后续是确定性的。
4. 严重度：高。job 无限期挂起且没有自动恢复，monitor 负责的超时和 dead-client 兜底同时失效。
5. 修复：根因在 `_do_process_task_request`：用独立变量记住待重发的 ClientTask，循环结束、没有选中新 task 时再用它，并保持 `resend_task = True`；1264 行改成 `pop(client_task.id, None)`。只给 `_monitor_tasks` 包 try/except 能让线程活下来，但那次异常会打断 A 的退出处理（A 已从 `_tasks` 移除，退出回调没跑），等 A 的 `wait_for_task` 仍可能挂住，所以不能代替根因修复。
6. 上游：无相关 issue 或 PR（#4772、#4493 改过 `_client_task_map`，与这里无关）；main 未变。
7. 建议：第一批，优先级 5。

### C1-B：completion 线程 KeyError 退出

证据：REPRODUCED，强制调度 + 在 RUNNING 写入注入 EIO（`checks/confirm/c1_repro.py` 场景 B，连跑 3 次结果相同）。MC 盲跑 4 次找回线程退出；跨 job 后果在给 J2 退出定价后也能盲跑找回。

1. 后果：`JobRunner.run` 先把 job 放进 `running_jobs`，再写 RUNNING（`job_runner.py:767-769`）。写入抛异常时，except 分支删掉 `running_jobs[job_id]`（772–775）；如果 completion 线程此前已经接手这个 job（SJ 已退出）并正在收尾，它随后执行没有保护的 `del self.running_jobs[job_id]`（583 行），抛 KeyError，整个 completion 线程退出。此后 server 上所有 job，包括完全无故障的，都不会再被收尾：不写终态、不归档 workspace、不发 JOB_COMPLETED。调度器的 `scheduled_jobs` 不再减少，占满 `max_jobs` 后不再调度新 job；`abort_job` 只设 `run_aborted`，状态永远不变。重启 SP 后这些 RUNNING 又落进 R1。谁看到：所有用户；SP stderr 一条 `_job_complete_process` 线程的 KeyError traceback。
2. 范围：所有版本（2.8、2.9 有同一行）；任何部署。需要 RUNNING 那次写 job store 先挂住再失败（例如 NFS 或网络存储的瞬时故障），挂住期间 SJ 已经退出、completion 线程已经接手，而且 completion 线程自己的终态写入在 except 分支删除之后成功（存储已恢复）。持续到 SP 重启。
3. 可能性：很低。需要注入级的存储故障，并且与 SJ 早退在时间上重叠；本地盘写满时写入会立即失败，窗口只有毫秒级。
4. 严重度：高。一旦触发，server 级的收尾和调度同时丧失。
5. 修复：583 行改成 `self.running_jobs.pop(job_id, None)`，completion 线程的循环体包 try/except（F-B，1–3 行，只保线程）。根因与 C1-A 是同一处所有权问题（F-C）：except 分支在 `self.lock` 下发现 completion 线程已经接手（`job_id in self._finished_job_states`）时，不删 `running_jobs`，也不写 FAILED_TO_RUN。
6. 上游：无相关 issue；同族 #5301（迟到的 RUNNING 覆盖终态，我们提的）2026-09-15 以 NOT_PLANNED 关闭，维护者定为 P3，理由是复现需要人为时序，也没有证明存在能让终态抢先的存储故障。C1 正是"存储故障 + 时序"，但仍然需要时序配合。main 未变。
7. 建议：优先级 6，可以提但不急。以 C1-B 为主（后果 server 级、修复一行），C1-A 作为同一 issue 的附带；明确写出需要存储故障，并突出修复成本低。

### C1-A / A2：FAILED_TO_RUN 覆盖已发布的终态

证据：REPRODUCED，强制 + 注入（`c1_repro.py` 场景 A、A2，3/3）。MC：hunt4 盲跑找到 2 次。

1. 后果：A：completion 线程已经发布 `FINISHED:EXECUTION_EXCEPTION` 并发了 JOB_COMPLETED，except 分支随后写 FAILED_TO_RUN 并发 JOB_ABORTED。A2：短 job 在挂起期间正常结束，`FINISHED:COMPLETED`（产物已归档）被改成 FAILED_TO_RUN。except 分支还会对已结束的 job 再调一次 `_stop_run`。谁看到：数据科学家在 list_jobs 或 monitor_job 里看到 FAILED_TO_RUN，但结果其实在；订阅 job 事件的组件先后收到 COMPLETED 和 ABORTED。
2. 范围：同 C1-B。2.9.1rc8 的 except 分支无条件写 FAILED_TO_RUN（main 至少排除了 FINISHED_ABORTED），发布线上覆盖面更宽。记录永久错误。
3. 可能性：很低。同 C1-B；A2 还要求 job 在挂起期间跑完。
4. 严重度：低。状态标签错，产物还在，不影响其他 job。
5. 修复：F-C。把 793–796 行的条件从"不是 FINISHED_ABORTED"改成"当前状态不是终态，且 completion 线程没有接手"。更一般的做法是让 `SimpleJobDefManager.set_status` 拒绝从终态改成其他状态，这样连 #5301 一起覆盖。
6. 上游：与 #5301 同根因族（缺终态检查或 CAS），NOT_PLANNED；main 未变。
7. 建议：不单独提，附在 C1-B。

### L13：panic 的 job 被记为 COMPLETED

证据：REPRODUCED，注入消息延迟或丢失（`checks/confirm/l13_repro.py`：真实 `FederatedServer._listen_command`、`ServerEngine.wait_for_complete`、`JobRunner._get_finished_job_status`；只有 SJ 进程句柄和消息投递时机是桩）。对照组消息 50 ms 到达，记为 EXECUTION_EXCEPTION；SJ 退出 2.5 s 后才到或丢失，记为 COMPLETED。MC：定向 BFS 和 D 轨盲跑都找到。

1. 后果：SJ 在 `system_panic`（工作流抛异常 `server_runner.py:157`、部署策略违规等）之后以退出码 0 退出，执行出错只靠 `server_app_runner.py:90` finally 里一条 fire-and-forget 的 UPDATE_RUN_STATUS 传递（`server_engine.py:874-885`）。SP 在进程退出后最多等 2 s（`server_engine.py:204-235`），然后从 run_processes 里弹出这个 job；晚到的消息找不到条目，被丢弃（`fed_server.py:595-605`）；`_classify_finished_job_status(None)` 给出 FINISHED_COMPLETED。谁看到：数据科学家看到失败的 job 显示 COMPLETED，可能直接使用产物；只有翻 SJ 日志才能看到 "Aborting current RUN due to FATAL_SYSTEM_ERROR"。
2. 范围：所有版本（2.8、2.9 相同）；任何部署；1 个 job。需要 SJ→SP 的本地连接在那一刻慢或丢消息：SJ 发完立刻 shutdown，fire-and-forget 没有确认也没有重试；SP 繁忙时的处理延迟也会触发。记录永久错误。
3. 可能性：低。前提是 job 本身已经 panic，再叠加本地消息晚于 2 s 或丢失。自然丢失率没有测。
4. 严重度：中。失败被静默报成成功，下游可能用到错误或不完整的模型。
5. 修复：SJ 在 FATAL_SYSTEM_ERROR 时以非零退出码退出（`server_app_runner.py` 的 finally 或 runner_process 入口），让分类走可靠的返回码；或者把 UPDATE_RUN_STATUS 改成带回复、可重试的请求，SJ 收到确认后再退出。
6. 上游：无直接相关的 issue；#5662（2026-11-05 合并）修的是 simulator 里 client 因 FATAL_SYSTEM_ERROR 停止时报告失败，属于同类问题的 simulator/client 侧，server 侧这条路径没变。main 上 UPDATE_RUN_STATUS 分支只多了 #5708 的调用方身份检查。
7. 建议：第二批，优先级 7；可以和 N2 合成一个"SJ 收尾时的状态判定"issue。

### T2：重新登录与 logout 循环交错，`client_cleanup` 线程退出

证据：REPRODUCED，不强制，用 2 s 的 `fail_run` 桩代表 abort 往返（`checks/confirm/t2_repro.py`，3/3）。MC：带预算的 BFS 11 步找到；盲跑模拟命中不稳（3 次 900 s 里 1 次）。

1. 后果：`remove_dead_clients`（`fed_server.py:309-321`）先列出失联的 token，再逐个 logout。处理一个死 client 时，如果走到 `_resolve_missing_client_outcome` → `fail_run`（那个 site 的 outcome 还 pending 且 SJ 已退出时，向各方发 abort，耗时数秒），另一个已经列进名单的 client 在这期间重新登录，旧 token 被弹出，`remove_client` 返回 None，`notify_dead_client(None)` 在 1114 行解引用 `client.name`，抛 AttributeError。`client_cleanup`（290–304）没有异常处理，线程退出。此后失联的 client 永不移除：admin 看到的 client 列表里一直有它；SJ 收不到 dead-client 通知，job 等一个已死的 site，默认无 task 超时就挂起；调度器按陈旧名单向死 client 部署。谁看到：运维（`check_status` 里死 client 一直在），以及之后受影响的 job 的用户；SP stderr 一条 AttributeError traceback。
2. 范围：所有版本都有这个解引用（2.8 在 `remove_dead_clients` 的日志行，2.9 起在 `notify_dead_client`）；秒级窗口只在 2.9+，因为 2.8 没有 `_resolve_missing_client_outcome`，2.8 上窗口是微秒级。条件：≥2 个 client 在同一个 5 s 清理周期里同时超过 `heart_beat_timeout`（例如同时断网），其中一个在另一个的处理期间重新登录；重新登录只在 CP 重启或 server 会话变化时发生。持续到 SP 重启。
3. 可能性：低。需要关联的多点失联，再加 CP 重启恰好落在秒级的处理窗口内。
4. 严重度：中。server 级的失联检测丧失，但后果是潜伏的，要等之后有 client 死掉才体现为 job 挂起。
5. 修复：`remove_dead_clients` 和 `logout_client` 里 `if client is None: continue`（根因，1 行）；`client_cleanup` 循环包 try/except（F-D，同时保住 T3 和未复现的"遍历活字典"变体）。
6. 上游：无相关 issue；main 上这段未变。
7. 建议：第二批，与 T3 合成一个 issue，优先级 8。

### T3：遍历 `run_processes` 时另一个 job 退出

证据：REPRODUCED，强制时序（`checks/confirm/t3_repro.py`：锁内 poll 停 50 ms 必现）；自然时序下 job B 在通知前后 ±10 ms 内均匀退出，300 次里 4 次触发。MC：盲跑深度 11 找回，D 轨 4 秒命中。

1. 后果：同 T2。根因：`notify_dead_client`（`fed_server.py:1118`）不拿 `engine.lock` 就遍历 `engine.run_processes`，循环体里的 `notify_dead_job` → `send_command_to_child_runner_process` 要拿这把锁（`server_engine.py:887-911`）；另一个 job 的 SJ 退出时，`wait_for_complete` 在锁内 pop 掉一项（`server_engine.py:219-234`），继续迭代时抛 `RuntimeError: dictionary changed size during iteration`。
2. 范围：所有版本（2.8 有同一循环）；多 job 并发；死 client 参与了某个 job，同时另一个 job 恰好结束。持续到 SP 重启。
3. 可能性：很低。死 client 处理本身就少（600 s 超时），再叠加毫秒级窗口（在 ±10 ms 内退出时约 1.3%）。
4. 严重度：中（同 T2）。
5. 修复：先在 `engine.lock` 下拷一份 `list(self.engine.run_processes.items())` 再遍历（不能整个循环持锁，因为循环体要拿同一把锁）；`remove_dead_clients` 也遍历 `list(...)` 快照；外层用 F-D。
6. 上游：无；main 未变。
7. 建议：并入 T2 的 issue。

### N2：收尾窗口里宽限期到期，完成的 job 被判失败

证据：REPRODUCED，时序由场景设定（`checks/confirm/n2_repro.py`：真实 `process_dead_client_report`、`_monitor_tasks`、`_check_dead_clients`、`_job_policy_violated`、`finalize_run`；dead-job 报告的时间往前拨 59.5 s，`stop_controller` 用 1 s 的桩；对照组不 panic）。panic 之后记为 EXECUTION_EXCEPTION 的链路由 `l13_repro.py` 的对照组确认。MC：v8 的 C 轨报出，加时序前提 T4 后只在 `slowFinalize` 逃逸下出现。

1. 后果：`_monitor_tasks` 要到 `finalize_run` 置 `_all_done` 才停（`wf_comm_server.py:1201-1213, 1046`），而 ServerRunner 在 `control_flow` 返回后先 `stop_controller` 再 `finalize_run`（`server_runner.py:171-172`），这段时间里仍在做 60 s 宽限期的 dead-client 判定（1179–1199）和部署策略检查（1369–1404）。一个在工作流返回前约 60 s 死掉的 client 恰好在收尾窗口里到期，task monitor 调 `system_panic("Aborting job due to deployment policy violation")`，已经正常完成并保存的 job 记为 `FINISHED:EXECUTION_EXCEPTION`。谁看到：数据科学家看到失败状态，但结果和模型都在；SJ 日志在 "finalizing" 之后出现策略违规。
2. 范围：所有版本。需要 `min_clients` 等于 client 数（recipe 常见写法；FedJob 默认 1 时只有 required_sites 里的 site 死亡或全部 client 死亡才算违规），或者配了 required_sites；client 死亡报告要落在"返回前 60 s"起、长度等于收尾耗时（秒级）的区间里。记录永久错误。
3. 可能性：低。job 最后一分钟恰好有 client 死亡，且宽限期到期与收尾窗口重叠。
4. 严重度：低。成功的 job 被报失败，产物完整，可以人工核对；影响是误报和可能的重跑。
5. 修复：ServerRunner 在 `stop_controller` 之前告诉 communicator 工作流已经返回，`_monitor_tasks` 此后不再做策略 panic（1–3 行）。L13 的退出码修复不覆盖 N2：panic 照样发生，状态照样是 EXECUTION_EXCEPTION。
6. 上游：无相关 issue；#3671 是通信错误导致的 job 失败，根因不同。main 未变。
7. 建议：附在 L13 的 issue 里，优先级 9；单独提价值不大。

### H03：过期的 source monitor 停掉服务下一个 task 的 trainer

证据：REPRODUCED，强制抢占（`checks/confirm/h03_repro.py`：桩让 `peer_silent_for` 在返回旧值之前切换 source 身份）。MC：Trainer_X 变体深度 66 找到，需要 `monitorStale` 逃逸。

1. 后果：launch_once 的外部 trainer 在服务 task B 时被 task A 的过期 monitor 停掉，而且不发 B 的 source 失效通知；B 的接收方只能等自己的下载超时，之后这一轮或这个 job 失败。谁看到：数据科学家看到 B 这一轮失败或 job 失败；CJ 日志里出现针对 A 的 "heartbeat timed out"，被停的却是 B 的 trainer。
2. 范围：2.9+；Client API `external_process` + `launch_once=True` + 惰性（可下载）结果。需要 monitor 先读到"心跳超时"或"断连超过宽限"，紧接着 A 结算、B 被接受，都落在 `external_process_backend.py:1239-1283` 两次检查之间的微秒窗口里。
3. 可能性：很低。先要有真实的心跳停顿超过超时，再叠加微秒窗口。
4. 严重度：低。后果可见（失败，而不是错误结果），受 B 自身超时约束。
5. 修复：`_monitor_accepted_result_source` 只在 `_fail_accepted_result_source` 确认身份仍是 A 时才调 `_stop_trainer`（让它返回"是否认领成功"，或在 `_result_failure_lock` 内复核后再停）。
6. 上游：无；main 未变。
7. 建议：暂不单独提（优先级 10）。

### H01：Attach 模式把"传输完成"当成"已接受"

证据：STATIC（只读代码，未执行复现）。

1. 后果：CJ 在任务已关闭时回 RESULT_REJECTED，且不记录归属（`cell_backend.py:236-242`）；状态查询于是回 UNKNOWN（281–282）；TP 的 `_resolve_ambiguous_result`（`attach_session.py:441-467`）在 waiter 已 COMPLETED 时推断为已接受，`send()` 返回成功并清掉 trainer 侧数据。server 本来就把这一轮记为该 client 失败，影响只是 trainer 误以为发送成功。
2. 范围：2.9+ Attach 模式；两次 RESULT_REJECTED 回复都丢失；任务已经因超时或 END_RUN 关闭。
3. 可能性：很低。
4. 严重度：低。
5. 修复：CJ 记录被拒绝的 result_id，状态查询返回 REJECTED；或者 TP 在状态为 UNKNOWN 时不从传输完成推断接受。
6. 上游：无；main 未变。
7. 建议：不提（只有静态证据，后果轻）。

### N1：非严格 START 下丢弃迟到 site 的失败 OUTCOME

证据：MODEL-ONLY（hunt5 冒烟阶段的线索，有源码锚点，没有在代码上复现）。

1. 后果：默认的非严格 START 回复检查（`strict_start_job_reply_check=False`，`job_runner.py:362-407`）下，START 回复超时（20 s）的 site 被从 `_pending_client_outcomes` 里去掉；但 SJ 是在收回复之前用全部 job_clients 启动的，那个 site 的 CJ 实际在参与训练。它的失败 OUTCOME 被 SP 以 "Dropped terminal outcome for untracked job/client" 丢弃（`fed_server.py:943-945`），job 可能以 COMPLETED 结束；同样的 CJ 失败发生在被跟踪的 site 上会让 job 失败，两者不一致。
2. 范围：使用默认非严格模式的部署；START 回复丢失或晚于超时。
3. 可能性：低。
4. 严重度：低。FL 本来就容忍部分参与，问题在于状态不一致。
5. 修复：非严格模式下保留这些 site 的 pending outcome，或者让 SP 接受当前 job 任一参与者的 outcome。
6. 上游：无；这个开关来自 2.7 的 #4209；main 未变。
7. 建议：不提（model-only）；以后做了代码级复现再考虑并入状态判定的 issue。

## 修复覆盖关系

| 修复 | 位置 | 覆盖 | 不覆盖 |
|---|---|---|---|
| F-A | `job_runner.py::run` 循环体 try/except；`_check_job_status` 对 None 安全；`job_def_manager.py::_scan` 跳过不存在的对象 | T1、T1-b、715 行路径（线程存活和根因都覆盖） | C1-B（另一个线程） |
| F-B | `_job_complete_process`：583 行 `pop(job_id, None)`，循环体 try/except | C1-B 的线程退出 | C1-A 的状态覆盖 |
| F-C | `run()` except 分支：completion 线程已接手时不删 `running_jobs`、不写 FAILED_TO_RUN；或 `set_status` 拒绝终态→其他 | C1-A、A2、C1-B 的触发源；做到 `set_status` 时连 #5301 一起 | — |
| F-D | `client_cleanup` 循环 try/except | T2、T3、遍历活字典的变体（只保线程） | 根因：T2 的 None 检查，T3 的快照遍历 |
| F-E | `_monitor_tasks` 循环 try/except | H11 的线程退出 | H11 的重复登记和 A 的退出处理；N2 |
| H11 根因 | `_do_process_task_request` 的重发逻辑 + `pop(id, None)` | H11 | — |
| F-F | SP 启动时调 `update_unfinished_jobs` | R1 | — |
| F-G | `_sync_client_jobs` 按 name 匹配，或 re-login 时通知 | R2；re-login 时通知还缩小 T2 的触发面 | T2 的 None 检查仍要做 |
| F-H | `ProcessJobLauncher.launch_job` 按该 job 自己的分配设 GPU env | H08，以及模型里的 START 交叠首启路径 | — |
| F-I | SJ 在 FATAL_SYSTEM_ERROR 时非零退出，或状态消息带确认 | L13 | N2（panic 仍会发生） |
| F-J | 工作流返回后不再做策略 panic | N2 | — |
| F-K | monitor 认领成功才停 trainer | H03 | — |

共性：长期线程的循环体没有异常处理。涉及 job runner 调度线程（T1、T1-b）、completion 线程（C1-B）、task monitor（H11）、`client_cleanup`（T2、T3）。给这四个循环统一加"每轮 try/except + 记日志"，能保住 6 个根因的线程存活，但不修其中任何一个根因，H11 还会留下挂住的 task。所以这条可以作为附加建议写进 issue，不能代替各自的根因修复。

## 提交建议与顺序

第一批（无强制复现或秒级自然窗口、后果重；建议现在提，共 5 个 issue）：
1. R2：CP 重启后 SJ 收不到 dead-job 通知，job 无限挂起。
2. H08：自动恢复的 CJ 用上另一个 job 的 GPU。说明只在 main、违反 #5550 的承诺，赶在 2.10 之前。
3. R1：SP 重启后 RUNNING 的 job 无法清理。写成 #4503 的回归，附 2.7 的对照和一行修复。
4. T1-b + T1：删除 job 让调度线程退出。主场景用 T1-b（部署期间删除，秒级窗口），T1 附自然竞态的实测命中率；715 行路径作为同一修复覆盖的第三个入口，注明只读代码。
5. H11：重发路径重复登记 ClientTask，task monitor 退出，CSE 挂起。

第二批（需要注入或时序巧合；按维护者对 #5301 的态度，合并成少量 issue，强调后果和修复成本）：
6. C1-B（附 C1-A）：completion 线程 KeyError 退出；写明需要存储故障，修复一行。
7. L13（附 N2）：SJ 收尾时的状态判定，失败报成功、成功报失败。
8. T2 + T3：`client_cleanup` 线程会被两种竞态杀死。

第二批也可以合成一个"后台线程与收尾状态加固"的 issue，附上面的共性说明，降低维护者的处理成本。

暂不提：H03（很低，必要时附在别的 issue 里提一句）、H01（只有静态证据）、N1（只有模型反例）。

写 issue 时：每个 issue 标明证据等级（无强制 / 强制 / 注入），给出复现脚本和 main SHA（`5c54edda`），后果写用户能看到的现象，不写模型细节。

## 自然发生率

截至定稿（08:50 后），`notes/repro-natural-A.md` 还不存在；`notes/repro-natural-B.md` 只是骨架，范围是 C1-A、C1-B、T1-b、H03，目前只写了 C1 的窗口分析（§1.1），测量、随机试验和结论都还是占位。§1.1 与本文一致：C1-B 只有 RUNNING 写入失败这一条路径（另一个删除入口 `remove_running_job` 只被没有调用者的 `pause_server_jobs` 调用）；配置错误的 SJ 不发 UPDATE_RUN_STATUS，`wait_for_complete` 一定等满 2 s 才 pop，这限定了 C1 需要的写入挂起时长。B 也明确写了本轮试验不会把 C1、T1-b 升到"无强制"一档。所以上面的可能性评级仍只依据代码里的默认常量和现有复现脚本（T1 的 300/20 排队实测、T3 的 ±10 ms 自然命中率）。自然测量结果出来后，最可能改变评级的是 T1（常见排队规模下的命中率）、T1-b、C1、T3、L13（本地状态消息的自然丢失或延迟）和 N2。
