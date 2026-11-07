# C1-A / C1-B / T1-b / H03：自然时序下的可能性（2026-11-07）

源码：`/home/ubuntu/nvflare-integrated-model-20261103/sources/current`（pin `c411a201`，只读，经 `sys.path` 导入）。涉及的 `job_runner.py`、`job_def_manager.py`、`filesystem_storage.py`、`job_cmds.py`、`server_engine.py`、`external_process_backend.py`、`cell_backend.py` 与 upstream main `e17c1edf6` 相同（main 只在 `fed_server.py` 有 #5672 的改动）。

运行方式：`PYTHONDONTWRITEBYTECODE=1 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/nvflare-venv/bin/python -B <script> ...`，工作目录 `.tmp/`，逐次试验的原始记录在 `.tmp/c1n_*.jsonl`、`.tmp/t1bn_*.jsonl`，批次日志在 `.tmp/{c1n,t1bn,h03n}_batch.log`。本机 96 核，测量期间负载约 40（其他任务的 TLC 在跑），延迟数字都是这台机器上的。

新脚本（都在 `checks/confirm/`，没有改动已有的 `*_repro.py`）：`c1_natural.py`、`t1b_natural.py`、`h03_natural.py`。

证据级别沿用 RESULTS.md 的口径。本轮的随机试验都不对线程做事件对齐，但 C1 仍要注入存储故障，T1-b 的部署仍是耗时桩，所以它们**仍属于"REPRODUCED（强制时序 / 桩 / 注入故障）"这一档**，下文细分写成"注入故障，调度不强制"之类。没有任何一项升级到"REPRODUCED（无强制）"。

---

## 1. C1-A / C1-B

### 1.1 窗口（代码）

- `JobRunner.run` 先把 job 放进 `running_jobs`（`job_runner.py:768`），再写 RUNNING（769）。写入抛异常时，except 分支先删 `running_jobs[job_id]`（773-775，有判断），再 `_stop_run`（778；SJ 已不在 `run_processes` 时什么都不做）、`cancel_client_resources`（785，一次 client RPC），最后在 `_start_lock` 内 `_check_job_status` 并写 FAILED_TO_RUN（792-796）。这里只排除 FINISHED_ABORTED，没有终态检查，也没有 try。
- completion 线程（492-592）每 1 s 扫一次（592），只处理"在 `running_jobs` 里、不在 `engine.run_processes` 里"的 job（495-497）。收尾顺序：`_get_finished_job_status`（SJ 异常退出时先向 client 发 abort，`abort_client_run` 的超时是 2.0 s，460）→ `_save_workspace` 归档（547，失败时有 60 s 重试宽限，62）→ 575 写终态（失败则 `continue`，576-581）→ 582-583 无保护的 `del self.running_jobs[job_id]`。
- 记 φ 为 768 之后 completion 线程第一次扫描的相位，F 为它从拾取 job 到 575 写完终态的耗时，D 为 RUNNING 写入从发出到抛异常的耗时：
  - φ > D：什么都不发生，except 分支先删掉了 job，completion 线程看不到它。
  - φ < D < φ + F，且 575 写入成功：C1-B，completion 线程在 583 抛 KeyError 退出。
  - φ + F < D + T_cancel：C1-A，575 的终态先落盘，796 的 FAILED_TO_RUN 后到、覆盖它。两者可以同时发生。
- 前提：在 [768, 768 + D] 内 SJ 已从 `run_processes` 移除。SJ 进程退出后，`ServerEngine.wait_for_complete` 还要最多等 2 s 的 UPDATE_RUN_STATUS（`server_engine.py:210`）才 pop。配置错误的 SJ 在 `conf.configure()`（`runner_process.py:91`）就失败，早于建 job cell（104），以 CONFIG_ERROR 退出（`mpm.py:171-173`），不会发 UPDATE_RUN_STATUS，所以一定会等满这 2 s。
- 只有这一条路径能触发 C1-B。另一个删除 `running_jobs` 的入口 `remove_running_job`（953-958）只被 `ServerEngine.pause_server_jobs`（`server_engine.py:1118`）调用，而后者在整个代码树里没有调用者。

### 1.2 真实代码路径的测量（`c1_natural.py measure`，以及试验中的打点）

```
FilesystemStorage.update_meta (RUNNING write, real fsync): median=3.596 ms p99=11.132 ms max=25.285 ms
FilesystemStorage.update_meta failing on a read-only job dir (real EACCES): median=0.181 ms p99=0.459 ms max=3.250 ms | failed to write content: PermissionError: [Errno 13] Permission denied
workspace archive of a 1 MB run dir (real zip + replace): 1.9 ms
workspace archive of a 100 MB run dir (real zip + replace): 340.7 ms
```

- SJ 最快多久退出：`python -B -c "import nvflare.private.fed.app.server.runner_process"` 五次分别为 1.03、0.82、0.81、0.86、0.81 s。配置错误要在这之后才暴露，再加 `wait_for_complete` 的 2 s，所以从 spawn 到移出 `run_processes` 至少约 3 s。
- 相位 φ：对照组 20 次的拾取时刻（相对 769）为 min 0.026 / median 0.527 / max 0.990 s；sdk 组 96 次为 0.015 / 0.551 / 0.997 s。φ 在 [0, 1 s) 上均匀分布。
- F 的组成：abort 往返（client 正常回复时几十到几百 ms，client 不回复时等满 2.0 s）+ 归档（上面实测）+ 一次 get_meta 和一次带 fsync 的 update_meta（约 4 ms）。

### 1.3 自然调度的随机试验（`c1_natural.py run <scenario> <n> <par>`）

真实代码：`JobRunner.run` 及其 completion 线程、`_get_finished_job_status`、`abort_client_run`、`_save_workspace`、`SimpleJobDefManager`、`FilesystemStorage`（真实文件，带 fsync 和 zip 归档）；`ServerEngine.wait_for_complete` 回收一个真实子进程，该子进程睡 1.0–1.5 s 后以 103（CONFIG_ERROR）退出，代表 fail-fast SJ。桩：engine 的管道、调度器、`_deploy_job`（0.1–1.5 s 随机）、client RPC 的耗时（`start_client_job`、abort、cancel）。RUNNING 写入上的故障是注入的：等 D 后抛 `StorageException`。两个线程之间没有任何 event 或对齐；每次试验的 deploy/start 耗时都是随机的，所以 φ 也是随机的。`start_client_job` 慢（4.5–6.5 s，代表 START_JOB 回复晚于 SJ 退出加 2 s）时，SJ 在 768 前已被回收；"_alive" 组用快速回复（0.1–0.5 s），SJ 在 768 时还活着。

| 场景 | D（RUNNING 写入失败耗时） | 768 时 SJ | n | C1-A | C1-B | 调度线程退出 | 无事 |
|---|---|---|---:|---:|---:|---:|---:|
| control | 无故障 | 已回收 | 20 | 0 | 0 | 0 | 20（EXECUTION_EXCEPTION） |
| fastfail | 0（本地盘的瞬时错误） | 已回收 | 100 | 0 | 0 | 0 | 100 |
| fixed:0.05 | 0.05 s | 已回收 | 30 | 0 | 0 | 0 | 30 |
| fixed:0.2 | 0.2 s | 已回收 | 30 | 2 | 3 | 0 | 26 |
| fixed:0.5 | 0.5 s | 已回收 | 30 | 16 | 3 | 0 | 14 |
| fixed:0.8 | 0.8 s | 已回收 | 30 | 23 | 5 | 0 | 4 |
| fixed:1.2 | 1.2 s | 已回收 | 30 | 30 | 1 | 0 | 0 |
| fixed:2.0 | 2.0 s | 已回收 | 30 | 30 | 0 | 0 | 0 |
| sdk | 3 次尝试 + full-jitter 退避，本组 0.49–2.89 s，中位 1.81 s | 已回收 | 100 | 95 | 2 | 0 | 4 |
| slow | 5–15 s | 已回收 | 30 | 30 | 0 | 0 | 0 |
| sdk_alive | 同 sdk | 活着 | 60 | 0 | 0 | 0 | 60 |
| slow_alive | 5–15 s | 活着 | 30 | 30 | 0 | 0 | 0 |
| silentabort:1.2 | 1.2 s，completion 线程的 abort 等满 2 s | 已回收 | 20 | 0 | 20 | 0 | 0 |

（C1-A 与 C1-B 可同时出现，所以一行的数加起来可能超过 n。）

原始输出（摘录）：

```
scenario=control trials=20 C1-A=0 C1-B=0 scheduler_dead=0 benign=20 final_status={'FINISHED:EXECUTION_EXCEPTION': 20}
scenario=fastfail trials=100 C1-A=0 C1-B=0 scheduler_dead=0 benign=100 final_status={'FINISHED:FAILED_TO_RUN': 100}
scenario=sdk trials=100 C1-A=95 C1-B=2 scheduler_dead=0 benign=4 final_status={'FINISHED:FAILED_TO_RUN': 99, 'FINISHED:EXECUTION_EXCEPTION': 1}
scenario=slow trials=30 C1-A=30 C1-B=0 scheduler_dead=0 benign=0 final_status={'FINISHED:FAILED_TO_RUN': 30}
scenario=sdk_alive trials=60 C1-A=0 C1-B=0 scheduler_dead=0 benign=60 final_status={'FINISHED:FAILED_TO_RUN': 60}
scenario=slow_alive trials=30 C1-A=30 C1-B=0 scheduler_dead=0 benign=0 final_status={'FINISHED:FAILED_TO_RUN': 30}
scenario=fixed:0.8 trials=30 C1-A=23 C1-B=5 scheduler_dead=0 benign=4 final_status={'FINISHED:FAILED_TO_RUN': 27, 'FINISHED:EXECUTION_EXCEPTION': 3}
  example: {"d": 0.8, "sj_reaped_rel768": -1.9494, "pickup_rel768": 0.6571, "history": [["job_runner", "DISPATCHED", -5.2644], ["job_runner", "RUNNING-write-failed", 0.8001], ["job_runner", "FINISHED:FAILED_TO_RUN", 0.8881], ["completion", "FINISHED:EXECUTION_EXCEPTION", 0.9414]], "crashes": [["Thread-1 (_job_complete_process)", "KeyError", "'9fbe0296-916b-4e95-b6f6-b632251a2535'"]], "final": "FINISHED:EXECUTION_EXCEPTION"}
scenario=silentabort:1.2 trials=20 C1-A=0 C1-B=20 scheduler_dead=0 late_RUNNING_over_terminal(#5301)=0 benign=0 final_status={'FINISHED:EXECUTION_EXCEPTION': 20}
```

sdk 组里 C1-A + C1-B 同时出现的一次（时间相对 769，秒）：`RUNNING-write-failed 0.513` → completion 写 `FINISHED:EXECUTION_EXCEPTION 0.620` → run 线程写 `FINISHED:FAILED_TO_RUN 0.709`，completion 线程 `KeyError` 退出。

读法：
- 窗口函数和推导一致：SJ 已回收时，任何一种 C1 的比例约为 min(1, D / 1 s)（D = 0.05/0.2/0.5/0.8/1.2/2.0 s 时分别为 0/30、4/30、16/30、26/30、30/30、30/30）。
- C1-B 的份额约为 F / 1 s。client 正常回复 abort 时 F 约 0.2 s，C1-B 占 2–17%；client 不回复、abort 等满 2 s 时，D = 1.2 s 下 20/20 都是 C1-B（且终态在 FAILED_TO_RUN 之后写入，所以 C1-A 不出现）。归档 GB 级 workspace 同样会拉长 F（100 MB 实测 0.34 s），这一点没有单独跑。
- C1-B 的后果是 completion 线程退出、之后所有 job 都不收尾，`c1_repro.py` 场景 B 已在真实代码上展示，这里没有重复。
- SJ 在 768 时还活着的话，D 必须超过 SJ 剩余寿命 + 2 s：sdk_alive（D ≤ 2.9 s）0/60，slow_alive（D ≥ 5 s）30/30。

### 1.4 哪些存储后端、哪些错误让它现实

代码树里只有一个 `StorageSpec` 实现：`FilesystemStorage`（`nvflare/app_common/storages/`）。provision 模板默认用它，job store 位于 `/tmp/nvflare/jobs-storage`（`nvflare/lighter/templates/master_template.yml:237-245`）。没有 S3 或其他对象存储的实现，"S3 类"只能是用户自写的 `StorageSpec`，或者把 FilesystemStorage 放在网络文件系统或 FUSE 挂载上。

- 本地盘上的 FilesystemStorage（默认）：写入的错误来自 `_write`（`filesystem_storage.py:33-76`，tmp 文件 + fsync + `os.replace`），现实中的错误是 ENOSPC/EDQUOT（store 会不断累积归档后的 workspace，代码里没有清理）、EROFS（ext4 `errors=remount-ro`，这台机器的 /home 就是这样挂的）、EIO、EMFILE。它们都在系统调用里立刻返回，实测 0.18 ms，窗口因子 D / 1 s 约 2×10⁻⁴；fastfail 组 0/100。这些错误通常是持续性的，持续性错误的后果不是 C1，而是调度线程退出（见 1.6）。
- 网络文件系统上的 FilesystemStorage：NFS 默认 hard 挂载，服务端不可用时只会卡住、不报错，这就是 #5301 的"迟到的 RUNNING"而不是 C1（见 1.7）。soft 挂载要在重传用尽后才返回 EIO（nfs(5) 的 TCP 默认 timeo=600 即 60 s、retrans=2，分钟级；本机没有 man 页，这是文档默认值，没有实测）。整个服务端不可用时，completion 线程自己的归档和 575 写入也会卡住或失败（失败则 `continue`），所以 C1-A 基本不会出现；C1-B 需要服务端恰好在"RUNNING 请求已超时、completion 线程的请求还没超时"之间恢复，概率不高。
- 对象存储式的自写 `StorageSpec`（经 SDK 访问，带重试）：这类错误是逐请求独立的（限流 503、偶发 5xx、单条连接被重置），一个请求耗尽重试时，并发或稍后的请求照常成功。耗尽重试需要秒级（sdk 组按"3 次尝试 + 指数 full-jitter 退避"取值，0.5–2.9 s；本机没有 botocore，这个分布是按公开文档的默认重试策略构造的，没有实测）；读超时类错误还要更久（slow 组）。**这是让 C1 几乎必然发生的错误类型**：sdk 组 96/100 出现 C1，slow 组 30/30。

### 1.5 SJ 何时会在窗口内消失

- 进程 launcher：CP 的 START_JOB 处理在 `_launch_job`（`client_executor.py:360`）里同步启动 CJ 进程后就回复，`start_client_job` 一般 0.1–0.5 s 返回；而 fail-fast SJ 最早约 3 s 后才被回收。所以 768 时 SJ 还活着，只有 D ≥ 约 3 s 的失败才会触发（slow_alive）。
- K8s launcher：CP 回复 START_JOB 之前要等 CJ pod 进入 Running（`k8s_launcher.py:1234` 的 `enter_states([JobState.RUNNING])`，`pending_timeout` 默认 120 s，167），server 端最多等 20 s（`server_engine.py:1107`）。pod 调度加拉镜像往往要好几秒到 20 s，所以 fail-fast SJ 在 768 之前就被回收是常态，这时 D ≥ 1 s 就足够（sdk/slow 组的条件）。
- 很短的 job（几秒内正常结束）与 fail-fast SJ 等价：`c1_repro.py` 的 A2 已展示 `FINISHED:COMPLETED`（产物已归档）被 FAILED_TO_RUN 覆盖。

### 1.6 附带发现：持续性写失败让调度线程退出（与 T1-b 同一个无保护的 except 分支）

store 在 job 启动途中变成不可写时，RUNNING（或 DISPATCHED）写入失败 → except 分支 796 的 FAILED_TO_RUN 写入同样失败 → 异常离开 `run()`，调度线程退出，之后不再调度任何 job，失败的 job 停在 DISPATCHED 或 SUBMITTED。这里不注入任何代码异常：harness 把 job 目录 chmod 成只读，`FilesystemStorage._write` 真实地得到 EACCES（相当于 EROFS），故障开始的时刻由 harness 放在启动阶段（persistent）或部署阶段（persistent_early）。

```
scenario=persistent trials=10 C1-A=0 C1-B=0 scheduler_dead=10 benign=0 final_status={'DISPATCHED': 10}
  example: {"d": "readonly", ..., "history": [["job_runner", "DISPATCHED", -4.6547], ["job_runner", "RUNNING-write-failed:StorageException", 0.0004], ["job_runner", "FINISHED:FAILED_TO_RUN-write-failed:StorageException", 0.1392]], "crashes": [["job_runner", "StorageException", "failed to write content: PermissionError: [Errno 13] Permission denied: '/home/u"]], "final": "DISPATCHED"}
scenario=persistent_early trials=10 C1-A=0 C1-B=0 scheduler_dead=10 benign=0 final_status={'SUBMITTED': 10}
```

证据级别：REPRODUCED（真实 OS 故障、故障时刻由 harness 设定；调度不强制；engine 为桩）。在本地盘的默认部署下，这比 C1 现实得多：满盘或只读重挂载只要发生在任何一次 job 启动的 DISPATCHED/RUNNING 写入时，调度线程就会退出。上游没有相关 issue。

### 1.7 与 #5301 的关系（同一窗口，"迟到但成功"的写入）

同一个 harness 的 `stall:<D>` 场景：RUNNING 写入延迟 D 后成功，不注入失败。

```
scenario=stall:0.5 trials=20 C1-A=0 C1-B=0 scheduler_dead=0 late_RUNNING_over_terminal(#5301)=4 benign=16 final_status={'FINISHED:EXECUTION_EXCEPTION': 16, 'RUNNING': 4}
scenario=stall:1.5 trials=20 C1-A=0 C1-B=0 scheduler_dead=0 late_RUNNING_over_terminal(#5301)=20 benign=0 final_status={'RUNNING': 20}
```

也就是说，只要 SJ 已回收，RUNNING 写入卡住超过 φ + F，终态就会被 RUNNING 覆盖（φ < 1 s、F 约 0.2 s，所以卡住 1.5 s 时 20/20），job 永久停在 RUNNING。这里不需要时序协助，但写入延迟本身是注入的。

### 1.8 结论

- 自然发生率：
  - 默认部署（本地盘 FilesystemStorage + 进程 launcher）下基本为 0。SJ 在 768 时还活着；本地盘的写失败是亚毫秒级，窗口因子约 2×10⁻⁴；本地盘的典型故障又是持续性的，它导致的是 1.6 的调度线程退出，而不是 C1。
  - 以下两条同时成立时，C1 在自然调度下几乎必然发生（sdk 96/100，slow 30/30，slow_alive 30/30），其中 C1-B 的份额约为 F / 1 s：
    - 存储请求逐个独立地失败，且失败耗时 ≥ 1 s，典型来源是带重试的对象存储 SDK、网络存储客户端超时；
    - SJ 在失败之前已被回收，典型来源是 fail-fast SJ 或极短 job，且 START_JOB 回复慢于 SJ 退出 + 2 s（K8s launcher 下常见），或者失败耗时超过 SJ 剩余寿命 + 2 s。
  - 所以每次 job 启动的发生率约为 P(fail-fast SJ 或极短 job) × P(这一次 RUNNING 请求以 ≥ 1 s 的耗时失败)，窗口因子近似为 1。前两项都没有生产数据。
- 证据级别：C1-A、C1-B 都是 REPRODUCED（注入存储故障，调度不强制，engine/RPC 为桩），比 `c1_repro.py` 的"强制调度 + 注入故障"少了事件对齐，但仍在"强制 / 桩 / 注入"这一档。

---

## 2. T1-b

### 2.1 窗口（代码）

调度扫描列出 job（`job_runner.py:704`）到写 DISPATCHED（734）之间，job 一直是 SUBMITTED，admin `delete_job` 会接受（`job_cmds.py:518` 只拒绝 DISPATCHED/RUNNING；FLARE API `Session.delete_job`，`flare_api.py:587`，走的也是这个命令）。删除之后 `get_job` 返回 None（`job_def_manager.py:379-385`），`_check_job_status` 对 None 取 `.meta`，抛 AttributeError（827-829）：
- 删除发生在 `schedule_job` 的 client 资源检查期间（RPC 超时 15 s，`server_engine.py:1024`）：在 715 抛出，这里在 try 之外；
- 删除发生在 `_deploy_job`（723）期间：在 727 抛出（这是 #5305 加上的部署后复查），except 分支 792-795 再次调用、再次抛出，异常离开 `run()`。

窗口长度 W = 资源检查往返 + 部署耗时。部署 = server 端解包与签名校验 + secure 模式下每个 site 一张 job 证书（264，以及 SJ 一张，289）+ 发给 client 的 DEPLOY 往返，最多等 `admin_timeout`（默认 10 s，`nvflare/private/fed/app/utils.py:92`）。空闲 server 上，job 在提交后 0–1 s 被扫描列出，窗口随即打开。

### 2.2 测量（`t1b_natural.py measure`）

```
JobCertIssuer.issue_many, 2 sites: 46, 46, 30 ms
JobCertIssuer.issue_many, 8 sites: 60, 97, 90 ms
JobCertIssuer.issue_many, 20 sites: 122, 143, 170 ms
get_jobs_to_schedule scan with 20 queued jobs: 2.8 ms
get_jobs_to_schedule scan with 300 queued jobs: 32.7 ms
```

server 端可测的部分都在百毫秒以内，窗口由两次 client 往返主导。

### 2.3 自然时序的随机试验（`t1b_natural.py run <deploy> <delete> <n> <par>`）

真实代码：`JobRunner.run`、`DefaultJobScheduler`（真实的资源检查流程）、`SimpleJobDefManager`、`FilesystemStorage`、`JobCommandModule.delete_job`（真实的状态前置检查和删除）。桩：engine、`check_client_resources`（0.02–0.3 s）、`_deploy_job`（按模型 sleep）、`start_client_job`、SJ。提交时刻相对 1 s 扫描的相位是随机的，admin 的删除时刻独立于 runner 的进度随机抽取，没有对齐。部署模型：fast = 0.3–2.0 s（client 正常回复的小 job）；slowclient = 10 s（某个已登记的 client 不回复 DEPLOY，等满 `admin_timeout`）。删除时刻模型：uniform14 = 提交后 0–14 s 均匀；human = 对数正态，中位 8 s；script = 0–2 s。

```
deploy=fast delete=uniform14 trials=60 scheduler_dead=4 {'during deploy (727/795)': 3, 'during resource check (line 715, outside try)': 1} delete_refused(job already DISPATCHED/RUNNING)=52 deleted_before_pickup=4
  killing delete times after submit: min=0.48s max=1.69s
  measured window listing->DISPATCHED (jobs not deleted in it): n=52 min=0.53s median=1.52s max=2.19s; pickup after submit median=0.49s
deploy=slowclient delete=uniform14 trials=40 scheduler_dead=27 {'during deploy (727/795)': 26, 'during resource check (line 715, outside try)': 1} delete_refused(job already DISPATCHED/RUNNING)=10 deleted_before_pickup=3
  killing delete times after submit: min=0.72s max=10.36s
  measured window listing->DISPATCHED (jobs not deleted in it): n=10 min=10.03s median=10.20s max=10.30s; pickup after submit median=0.35s
deploy=fast delete=human trials=40 scheduler_dead=0 {} delete_refused(job already DISPATCHED/RUNNING)=40 deleted_before_pickup=0
deploy=slowclient delete=human trials=30 scheduler_dead=20 {'during deploy (727/795)': 20} delete_refused(job already DISPATCHED/RUNNING)=10 deleted_before_pickup=0
  killing delete times after submit: min=2.81s max=9.71s
deploy=fast delete=script trials=30 scheduler_dead=11 {'during deploy (727/795)': 11} delete_refused(job already DISPATCHED/RUNNING)=7 deleted_before_pickup=12
  killing delete times after submit: min=0.36s max=1.46s
```

逐条核对 fast/uniform14 的 60 次：凡是落在"列出 → DISPATCHED"之间的删除，调度线程全部退出；早于列出的删除安全；晚于 DISPATCHED 的删除被拒绝。窗口内触发是确定性的，没有微秒级竞争。

### 2.4 结论

- 自然发生率 = P(删除落在 [列出, DISPATCHED] 内)，没有任何时序巧合的成分：
  - client 都正常回复时窗口约 0.5–2.2 s，从提交后约 0.5 s 开始。人工在控制台里删（中位 8 s）基本碰不到（0/40）；脚本或工具"提交后发现不对立刻删"（0–2 s）有 11/30。
  - 有一个已登记但不回复的 client 时，部署要等满 10 s 的 `admin_timeout`（资源检查阶段不回复则最多 15 s），窗口随之变成约 10 s，人工删除也有 20/30 落进去。窗口关闭之后 job 已是 DISPATCHED/RUNNING，删除会被拒绝。
  - 队列繁忙时，job 排队期间每次扫描只有毫秒级的 T1 窗口；轮到它部署时才打开 T1-b 窗口，删除一个久排的 job 命中的概率约为 W / 排队时长。
  - 先 `abort_job` 再 `delete_job` 也一样（静态推理，没有单独跑）：部署期间 job 还不在 `_starting_jobs` 里，abort 会把它写成 FINISHED_ABORTED，删除随即被允许；只要删除早于 727，结果相同。
- 证据级别：REPRODUCED（桩：部署与 RPC 耗时；删除时刻随机，调度不强制），与 `t1b_repro.py` 同档，补上了窗口实测和不同删除模式下的命中率。

---

## 3. H03

### 3.1 窗口（代码）

`ExternalProcessBackend._monitor_accepted_result_source`（`external_process_backend.py:1239-1283`）先在锁内确认 source 仍是 A（1243-1250），再在锁外读心跳静默（1259）或连接状态（1270）。判定超时后调用 `_fail_accepted_result_source(trainer, A)`，在 `_result_failure_lock` 内复查（1288-1293）；如果 A 已经结算，复查返回 False，但 monitor 仍然无条件 `_stop_trainer`（1268 / 1278），没有失效通知，也不判 job 失败。读与复查之间只有纯 Python 代码：比较、f-string、一次函数调用，没有 I/O。

前提：external_process 模式加 `launch_once`（默认 True，`backend_spec.py:73`）；A 的 lazy 结果还在被拉取（source live）；trainer 的会话静默超过 `heartbeat_timeout`（默认 30 s，心跳间隔 5 s，`backend_spec.py:78-79`）。trainer 有独立的心跳线程（`nvflare/client/cell/api.py:1056`），所以健康的 trainer 不会静默 30 s；要静默这么久，trainer 必须卡住至少 25 s，然后恰好在 monitor 读完、复查之前恢复，并把 SETTLED(A)（以及 B 的 RESULT_READY）送达。仅 A 结算就足以触发这次停机，B 被接受只决定被误杀的是不是正在服务 B 的 trainer。

### 3.2 测量（`h03_natural.py measure 80000`，真实 `_monitor_accepted_result_source`；W = 复查拿到锁的时刻 − 静默读返回的时刻）

```
idle: n=80000 W median=0.7 us p99=1.1 us p99.9=5.2 us max=21 us; W>=1ms in 0/80000; mean=0.8 us
4 busy threads: n=20000 W median=0.7 us p99=1.3 us p99.9=11.8 us max=25622 us; W>=1ms in 5/20000; mean=6.1 us
P(burst lands in W | burst uniform over one 0.5 s poll) ~= mean W / 0.5 s: idle 1.5e-06, busy 1.2e-05
```

CPython 3.12 有 GIL，接收线程只能在 monitor 线程于这约 1 µs 内被强制切走时插进来；有忙线程争 GIL 时，偶尔（5/20000）会被切走数毫秒，均值因此升到 6 µs。

### 3.3 自然时序的随机试验（`h03_natural.py run 300 4 40 <busy>`）

真实代码：monitor 线程（真实循环，0.5 s 轮询，`_RESULT_POLL_INTERVAL`，75）、`CellBackendBase._handle_result_source_settled`（A）和 `_handle_result_ready`（B）。后者包含真实的会话校验和 touch、`_task_lock`、`_on_result_source_settled`，以及 `_on_result_accepted`，它会启动 B 的真实 monitor。桩：进程组探测（存活）、cell 连接（已连接）、`_stop_trainer` / `_cleanup_trainer` / `_fail_job_for_lost_result_source`（只记录）、`DownloadService.notify_source_failure`（只记录）。`heartbeat_timeout` 设为 1 s 以缩短试验；竞争只取决于 burst 相对轮询的相位，与超时取值无关。条件设定：trainer 已静默超过超时，SETTLED(A)+RESULT_READY(B) 在"越过超时之后的那个轮询周期"内均匀随机到达，没有与 monitor 对齐。正向对照 `selftest`：把 burst 放进静默读之后（强制），分类器报 `H03_stop_after_settle`（停在服务 B 时，没有通知，job 不失败）。

```
forced positive control: {"kind": "H03_stop_after_settle", "stops": [[1000609.9, "B"]], "notices": [], "job_failed": false, "replies": ["client_api.result_source_settled", "client_api.result_accepted"]}
natural trials: 35548 (4 procs x 40 concurrent pairs x 300.0s, 2 busy threads/proc) outcomes={'loud_fail_A': 17748, 'normal': 17800}
H03 rate per conditioned episode: 0/35548 (95% upper bound 8.4e-05)
natural trials: 36036 (4 procs x 40 concurrent pairs x 300.0s, 0 busy threads/proc) outcomes={'loud_fail_A': 18181, 'normal': 17855}
H03 rate per conditioned episode: 0/36036 (95% upper bound 8.3e-05)
```

burst 在轮询之前到达时一切正常（约一半），在轮询之后到达时 A 被高调判失败（另一半）。H03 需要 burst 落进 W，两轮共 71,584 次一次也没有，与 W 推出的 10⁻⁶–10⁻⁵ 一致。

### 3.4 结论

- 自然发生率：每个"trainer 静默超过 heartbeat_timeout、并在下一个轮询周期内结算 A"的事件里，H03 的概率约为 1.5×10⁻⁶（空闲）到 1.2×10⁻⁵（CJ 有忙线程）。这种事件本身就很少见，而且在 99.999% 的情况下，它的后果是 A 被高调判失败，而不是 H03。free-threaded Python 下窗口同样是约 1 µs 的墙钟时间，数量级不变。没有找到让"超时判定"和"结算到达"相关联的自然机制（以下是静态推理）：CJ 整体冻结时下载也会停住（trainer 经 CJ 的内部 listener 连接，`external_process_backend.py:236-267`、`445`），恢复后先到的是排队的心跳，而不是 SETTLED。
- 需要的时序前提：monitor 线程在 1259 / 1270 与 1288 之间被抢占，期间 SETTLED(A) 被处理。在模型里这对应带价逃逸 `monitorStale`。
- 证据级别不变：REPRODUCED（强制调度，`h03_repro.py`）；自然时序下 0/71,584，不升级。

---

## 4. 上游 issue（只读检索，`gh api search/issues`，2026-11-07）

- #5301 "Delayed RUNNING status write can overwrite a completed job status"：2026-09-15 以 NOT_PLANNED 关闭。维护者（pcnudde）确认可达，定为 P3，原话是 "We have not demonstrated natural occurrence or a storage fault that allows terminal publication to overtake the initial status write... We can reassess if production evidence or a realistic fault reproduction establishes a stronger need."
  - 它与 C1-A 缺的是同一个终态检查（`set_status` 和 796 都不拒绝"终态 → 非终态"）。
  - 本轮能补的是"不需要时序协助"这一半：SJ 已回收时，RUNNING 写入卡住 1.5 s（1.7，20/20 停在 RUNNING），或以 ≥ 1 s 的耗时失败（1.3，sdk 96/100、slow 30/30），终态都会被覆盖，调度不强制。
  - 补不了的是"生产中确有这样的存储故障"：故障仍是注入的，代码树里也没有会这样失败的后端。
- #5300 "Pre-run abort can be overwritten after client deployment starts"：2026-10-05 以 COMPLETED 关闭，修复是 #5305（`4eab92c1b`）。#5305 加了部署后的复查（`job_runner.py:726-733`），并把 except 分支改为 `_check_job_status(..., FINISHED_ABORTED)`（792-796）。T1-b 正是在这两处对已删除的 job 取 `.meta`，两处都没有处理 `get_job` 返回 None 的情况。
- #5069（PR，2026-08-10 合并）"Bound permanent workspace archival retries"：引入了 completion 线程归档失败的 60 s 宽限（545-573），也就是 F 里归档那一段的来源。与 C1 不是同一问题。
- #5067（PR，2026-08-07 合并）"Fix TASK_READY heartbeat expiry during materialization"：说明健康 trainer 的心跳误判超时在实际中出现过，但修的是 TASK_READY 等待期间；accepted-result-source monitor（H03）不在其范围内。
- 没有相关 issue 的：C1-B 的 KeyError（"running_jobs" 9 条结果，无相关）、T1-b（"delete_job SUBMITTED" 0 条，"delete job while deploying" 无相关）、1.6 的持续性写失败、H03（"_stop_trainer" 3 条都是无关 PR：#4994、#5107、#4906；"ExternalProcessBackend" 13 条无相关）。注意：`gh search issues` 只搜 issue，对 "FAILED_TO_RUN" 返回空；改用 `gh api search/issues`（含 PR）才有结果。

---

## 5. 汇总

| bug | 现实触发条件 | 自然时序下的可能性（怎么测的） | 证据级别 | 脚本 |
|---|---|---|---|---|
| C1-A | fail-fast SJ（或极短 job）在 RUNNING 写入失败前已被回收，且 RUNNING 写入以 ≥ 1 s 的耗时失败（对象存储 SDK 重试耗尽、网络存储超时），其他请求照常成功 | 条件成立时几乎必然：sdk 95/100、slow 30/30、slow_alive 30/30；窗口 ≈ min(1, D/1 s)。默认本地盘部署下约为 0：fastfail 0/100，失败耗时实测 0.18 ms | REPRODUCED（注入存储故障，调度不强制） | `c1_natural.py` |
| C1-B | 同 C1-A，且失败落在 completion 线程收尾期间（φ < D < φ + F） | 占 C1 窗口的约 F / 1 s：client 正常回复 abort 时 2–17%，client 不回复（abort 等 2 s）时 20/20 | REPRODUCED（注入存储故障，调度不强制） | `c1_natural.py` |
| T1-b | 已列出、尚未 DISPATCHED 的 job 被 admin/API 删除 | 窗口内命中是确定性的；窗口实测 0.5–2.2 s（client 正常）/ 约 10 s（一个 client 不回复 DEPLOY）。脚本式快速删除 11/30，人工删除 0/40（快部署）或 20/30（慢 client） | REPRODUCED（部署耗时为桩，删除时刻随机） | `t1b_natural.py` |
| H03 | external_process + launch_once，trainer 静默超过 30 s 后恰在 monitor 读与复查之间结算 A | 每个此类事件约 1.5×10⁻⁶–1.2×10⁻⁵（W 实测 0.7 µs 中位，忙时均值 6 µs）；自然试验 0/71,584 | REPRODUCED（强制调度，`h03_repro.py`）；自然时序未复现 | `h03_natural.py` |
| 附带：持续性写失败 → 调度线程退出 | store 在 job 启动途中变为不可写（满盘、只读重挂载） | 每次此类故障都会触发，20/20 | REPRODUCED（真实 OS 故障，故障时刻由 harness 设定） | `c1_natural.py`（persistent / persistent_early） |
| 附带：#5301 迟到的 RUNNING | SJ 已回收，RUNNING 写入卡住 ≥ φ + F | stall 1.5 s 20/20，0.5 s 4/20 | REPRODUCED（注入写入延迟，调度不强制） | `c1_natural.py`（stall） |
