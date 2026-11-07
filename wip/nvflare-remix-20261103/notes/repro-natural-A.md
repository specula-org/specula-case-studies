# T2 / T3 / L13 / N2：自然时序下的可能性；H01 可执行复现（2026-11-07）

源码：`/home/ubuntu/nvflare-integrated-model-20261103/sources/current`（pin `c411a201`，只读，经 `sys.path` 导入）。upstream main `e17c1edf6` 只在 `fed_server.py` 有 #5672 的改动（`_listen_command` 入口的调用方校验），下文用到的其他文件（`client_manager.py`、`server_engine.py`、`job_runner.py`、`wf_comm_server.py`、`server_runner.py`、`conn_manager.py`、`attach_session.py`、`api.py`、`cell_backend.py`、`attach_backend.py`）与 pin 相同；`_listen_command` 的 UPDATE_RUN_STATUS 分支和 T2/T3 的 cleanup 路径在 main 上没变（RESULTS §13）。

运行方式：`PYTHONDONTWRITEBYTECODE=1 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/nvflare-venv/bin/python -B <script> ...`。唯一例外是 N2 的"装了 torch"一组：这个 venv 没有 torch，所以用 `/home/ubuntu/nvflare-runs-20260913/venv-fedavg/bin/python`（Python 3.14，torch 2.14 cpu），仍然把 pin 的源码放在 `sys.path` 最前面（脚本打印了实际加载的 `wf_comm_server.py` 路径，确认是 pin）。临时文件和原始输出在 `.tmp/natA/`、`.tmp/{t2n,t3n,l13n}_*`。本机 96 核，测量期间负载 15–40（其他任务的 TLC 和另一组复现在跑），延迟数字都是这台机器上的。

新脚本（都在 `checks/confirm/`，没有改已有的 `*_repro.py`）：`t2_natural.py`、`t3_natural.py`、`l13_natural.py`、`n2_natural.py`、`h01_repro.py`。

证据级别沿用 RESULTS.md 的口径。本轮的随机试验不在线程之间做事件对齐，但都把一个"巧合"作为条件（让触发事件落在窗口附近 ±X 的均匀分布里，再从命中率反推窗口宽度），所以**T2、T3、N2 仍属于"REPRODUCED（强制时序 / 桩 / 注入故障）"这一档**，下文写成"时序巧合为条件、调度不强制"。L13 在空闲的 SP 上自然条件下没有复现；只在人为制造的 GIL 负载下出现。没有任何一项升级到"REPRODUCED（无强制）"。

---

## 1. T2：重新登录弹掉已列入死亡名单的 token

### 1.1 现实触发条件（代码）

- `remove_dead_clients`（`fed_server.py:309-321`）先列出 `last_connect_time` 早于 `heart_beat_timeout` 的 token，再逐个 `logout_client`。名单里排在后面的 token B 如果在轮到它之前从 `client_manager.clients` 消失，`remove_client` 返回 None（`client_manager.py:193-209`），`notify_dead_client(None)` 在 1114 行取 `client.name` 抛 AttributeError；`client_cleanup`（290-304）没有异常处理，线程退出。
- 能在这段时间里弹掉 B 的只有：同名 client 的新登录（`authenticated_client` 弹掉旧 token，`client_manager.py:332-337`）；管理员 `remove_client` / `disable_client`（`server_engine.py:611-614`，`client_manager.py:117-140`）；B 自己的 quit（`fed_server.py:886-899`）。
- **更正 RESULTS §11 的叙述（"网络中断后几个 client 同时超时又重连"）：** 网络恢复后的重连不会弹 token。CP 只在进程启动时登录（`client_train.py:170`）；断网期间心跳线程一直用旧 token 重试（`communicator.py:686-746`），恢复后 `ClientManager.heartbeat` 刷新旧 token，或在 token 已被移除时用**同一个** token 重新激活（`client_manager.py:376-417`）。secure 模式下心跳超时会走 `_check_server_session`，但只有 server 身份校验旧 token 签名失败时才重新登录（`communicator.py:154-165`），同一个 server 进程不会。所以现实中的触发是：**B 的 CP 宕机超过 `heart_beat_timeout`（SP 默认 600 s，`server_deployer.py:74`）后重启，它的登录恰好落在列名单和轮到 B 之间**；或者管理员在这几毫秒里对 B 执行 remove/disable。此外还需要同一次扫描里另一个过期 token 排在 B 前面（dict 插入顺序）。
- **t2_repro.py 的前提过宽：** 它用耗时 2 s 的 `fail_run` 桩代表"向各方发 abort"。真实代码里 `_resolve_missing_client_outcome` 只在 job 的 SJ 已经不在 `run_processes` 时才调 `fail_run`（`fed_server.py:1095-1103`），此时 `_stop_run` 取不到 run process，什么都不发（`job_runner.py:433-434`）。下面实测这条路径上的真实 `fail_run` 中位数 0.03 ms。所以两个过期 token 之间的间隔是毫秒级，不是秒级。

### 1.2 测量（`t2_natural.py`）

路径上全是真实代码：`ClientManager.authenticate`（两次登录）、`remove_dead_clients` / `logout_client` / `remove_client_data` / `notify_dead_client` / `_resolve_missing_client_outcome`、真实 `JobRunner`（B 前面的死 client 还欠一个已结束 job 的 outcome，走真实 `fail_run`）、`FedAdminServer.client_dead`、`ServerEngine.notify_dead_job` 经过真实的 SP root cell 发到子进程里真实的 SJ cell（TCP）。日志按 INFO 写文件。唯一的替代是用一个线程在指定时刻调用 `remove_dead_clients`（即 `client_cleanup` 循环体），不走 5 s 的循环。B 的重新登录时刻在扫描时刻 ±X 内均匀分布，不做任何对齐；命中率 × 2X 即窗口 W。

```
$ t2_natural.py 600 5 1 1
trials=600 B re-login offset uniform +-5.0 ms; dead clients listed before B=1; running jobs per dead client=1
remove_dead_clients pass: median 0.68 ms; logout_client of one dead client (direct): median 0.94 ms, p90 1.32 ms; real fail_run on the missing-outcome path: median 0.030 ms
client_cleanup crashed (AttributeError on client.name of None) in 9/600; other exceptions: {}
window W = 0.150 ms per scan
  re-login uniform within the 5.2 s cleanup cycle in which B became overdue: P(T2) = 2.9e-05
  re-login uniform over a 10-minute span (CP restarted 10-20 min after it died): P(T2) = 2.5e-07

$ t2_natural.py 600 5 1 3
trials=600 B re-login offset uniform +-5.0 ms; dead clients listed before B=1; running jobs per dead client=3
remove_dead_clients pass: median 1.34 ms; logout_client of one dead client (direct): median 1.70 ms, p90 2.06 ms; real fail_run on the missing-outcome path: median 0.027 ms
client_cleanup crashed (AttributeError on client.name of None) in 21/600; other exceptions: {}
window W = 0.350 ms per scan
  re-login uniform within the 5.2 s cleanup cycle in which B became overdue: P(T2) = 6.7e-05
  re-login uniform over a 10-minute span (CP restarted 10-20 min after it died): P(T2) = 5.8e-07

$ t2_natural.py 400 20 10 1        # 大面积断网：同一次扫描里 B 前面有 10 个过期 token
trials=400 B re-login offset uniform +-20.0 ms; dead clients listed before B=10; running jobs per dead client=1
remove_dead_clients pass: median 5.19 ms; logout_client of one dead client (direct): median 0.61 ms, p90 0.87 ms; real fail_run on the missing-outcome path: median 0.025 ms
client_cleanup crashed (AttributeError on client.name of None) in 33/400; other exceptions: {}
window W = 3.300 ms per scan
  re-login uniform within the 5.2 s cleanup cycle in which B became overdue: P(T2) = 6.3e-04
  re-login uniform over a 10-minute span (CP restarted 10-20 min after it died): P(T2) = 5.5e-06
```

- 窗口 W 比单次 logout 的耗时（约 1 ms）还小。我的解释（推断，没有单独验证）是 GIL：重新登录的线程醒来后要等 cleanup 线程让出 GIL 才能执行，cleanup 线程在 logout 里大部分时间持有 GIL，登录多半拖到 B 已经处理完之后。W 随排在 B 前面的过期 token 数增长（1 个约 0.15–0.35 ms，10 个约 3.3 ms）。

### 1.3 自然概率

- B 的旧 token 只会出现在一次扫描的名单里（过期后的第一次扫描），之后要么被正常移除，要么已被新登录弹掉。所以 B 的登录必须落在那次扫描开始后的 W 之内。
- 如果 B 的重启时刻相对于"过期时刻"在 D 秒范围内均匀分布，P(T2) ≈ W / D。最不利的现实情形是重启恰好发生在 B 过期的那个 5.2 s 清理周期内：P ≈ W / 5.2 s ≈ 3e-5 – 7e-5（1 个 token 在前），大面积断网（10 个在前）约 6e-4。重启时刻分散在 10 分钟里时约 2.5e-7 – 5.5e-6。
- 没有找到能把"弹 token"和扫描时刻对齐的机制：重连不弹 token，重启、管理员操作、quit 都与 cleanup 的 5 s 相位无关。

### 1.4 结论

自然可能性**可以忽略**（每次"宕机超过 600 s 的 CP 重启"约 1e-7 – 1e-5，最不利的情形约 3e-5 – 6e-4）。证据级别不变：REPRODUCED（时序巧合为条件、调度不强制；路径上不再有耗时桩）。t2_repro.py 里 2 s 的 `fail_run` 桩不代表真实代码。

---

## 2. T3：另一个 job 的 SJ 退出改变 `run_processes` 的大小

### 2.1 现实触发条件（代码）

- `notify_dead_client`（`fed_server.py:1105-1122`）在 1118 行不加锁遍历 `engine.run_processes`；dead client 参与的每个 job 都要做一次 `notify_dead_job`（`server_engine.py:887-898`：拿 `engine.lock`、`fire_and_forget`、写一条 warning）。遍历期间如果 `wait_for_complete` pop 掉另一个 job（`server_engine.py:234`）、abort 清理 pop（410），或新 job 启动插入（322-327），下一次 `next()` 抛 RuntimeError，`client_cleanup` 退出。
- 窗口只存在于 cleanup 线程处理一个 dead client 的那一次遍历里，触发事件是这几毫秒内 SP 上任何 SJ 的退出或启动。没有找到相关性：CP 死后没有心跳，SP 在 `heart_beat_timeout` 到期之前不会告诉任何 SJ，所以其他 job 不会因为同一个原因恰好在这时退出。
- 默认 process launcher 的 `poll()` 是 `Popen.poll`（`process_launcher.py:72-76`），K8s/Docker handle 在 `wait()` 返回时已缓存终态（`k8s_launcher.py:477-479, 699-712`；`docker_launcher.py:356-360, 372-387`），所以 `wait_for_complete` 在锁内的时间也很短，t3_repro.py 里"锁内停 50 ms"的强制时序没有现实对应。

### 2.2 测量（`t3_natural.py`）

路径上全是真实代码，包括传输：SP root cell 在本进程，job A（及更多 job）的 SJ 是子进程里真实的 cell，`HANDLE_DEAD_JOB` 走真实 TCP；job B 的 SJ 是真实子进程，真实的 `wait_for_complete` 通过 `Popen` 句柄看到它退出。B 的退出时刻在扫描时刻 ±5 ms 内均匀分布。

```
$ t3_natural.py 1500 5 1 0
trials=1500 B-exit offset uniform +-5.0 ms; dead client in 1 running job(s) besides B; busy SP threads=0
remove_dead_clients pass: median 0.46 ms; notify_dead_client loop (direct): median 0.96 ms, p90 1.38 ms
B exit -> pop latency: median 2.22 ms
pop landed inside the scan in 25/1500; client_cleanup crashed (RuntimeError: dictionary changed size during iteration) in 10/1500
window W = 0.067 ms per dead-client scan
  natural P(T3) per dead-client event at 1 SJ exit/start per minute: 1.1e-06
  natural P(T3) per dead-client event at 1 per 10 minutes: 1.1e-07

$ t3_natural.py 1500 5 3 0
trials=1500 B-exit offset uniform +-5.0 ms; dead client in 3 running job(s) besides B; busy SP threads=0
remove_dead_clients pass: median 0.85 ms; notify_dead_client loop (direct): median 1.64 ms, p90 2.07 ms
B exit -> pop latency: median 2.25 ms
pop landed inside the scan in 47/1500; client_cleanup crashed (RuntimeError: dictionary changed size during iteration) in 31/1500
window W = 0.207 ms per dead-client scan
  natural P(T3) per dead-client event at 1 SJ exit/start per minute: 3.4e-06
  natural P(T3) per dead-client event at 1 per 10 minutes: 3.4e-07
```

另外各跑了 400 次（同参数）：1 个 job 5/400，3 个 job 14/400。合并：1 个 job 15/1900，W ≈ 0.08 ms；3 个 job 45/1900，W ≈ 0.24 ms。

SP 进程有 4 个 CPU 忙线程（人为的 GIL 负载）时：

```
$ t3_natural.py 400 5 1 4
trials=400 B-exit offset uniform +-5.0 ms; dead client in 1 running job(s) besides B; busy SP threads=4
remove_dead_clients pass: median 5.94 ms; notify_dead_client loop (direct): median 61.61 ms, p90 372.14 ms
B exit -> pop latency: median 122.79 ms
pop landed inside the scan in 86/400; client_cleanup crashed (RuntimeError: dictionary changed size during iteration) in 24/400
window W = 0.600 ms per dead-client scan
  natural P(T3) per dead-client event at 1 SJ exit/start per minute: 1.0e-05
  natural P(T3) per dead-client event at 1 per 10 minutes: 1.0e-06
```

这时 B 的 pop 被 GIL 推迟了约 120 ms，±5 ms 的均匀假设不再成立，脚本打印的 W 不能当真；能确定的是遍历本身被拉长到几十到几百毫秒（中位 62 ms），pop 落在扫描内时 24/86 会崩。

### 2.3 自然概率

P(T3) ≈ W × λ，λ 是 SP 上 SJ 退出和启动的总速率。空闲 SP、W ≈ 0.08–0.24 ms（合并值）：λ = 1 次/分钟时每个 dead-client 事件约 1.3e-6 – 4e-6；1 次/10 分钟时约 1.3e-7 – 4e-7。GIL 很忙时把 W 取遍历时长的中位数 60 ms 作上界，λ = 1 次/分钟时约 1e-3。

### 2.4 结论

自然可能性**可以忽略**（空闲 SP 上每个 dead-client 事件 1e-6 量级），只有 SP 进程长期 GIL 饱和、同时 job 启停频繁时才升到 1e-3 量级。证据级别不变：REPRODUCED（时序巧合为条件、调度不强制；路径上无桩，传输真实）。

---

## 3. L13：panic 后 SJ 以 0 退出，状态消息晚到或丢失

### 3.1 现实触发条件（代码）

- FATAL_SYSTEM_ERROR 之后 SJ 以 0 退出，执行出错只靠一条 UPDATE_RUN_STATUS 传递：`start_server_app` 的 finally 里 `update_job_run_status`（`server_app_runner.py:90`，`server_engine.py:874-885`）用 `fire_and_forget` 发一次，之后才是 `runner_process.py:126-146` 的收尾（command agent、F3 streaming、`cell.stop`）。SP 的 `wait_for_complete` 在进程退出后最多再等 2 s（`server_engine.py:209-217`），然后 pop；之后到达的消息在 `_listen_command` 里找不到 job（`fed_server.py:595-605`），被丢弃，job 记为 COMPLETED。
- `fire_and_forget` 在调用线程里同步写 socket（`core_cell.py:1353-1386` → `ConnManager.send_message` → `SfmConnection.send_frame`），返回时帧已在内核缓冲区，SJ 随后立即退出也不会丢。没有重试：endpoint 不在或不是 READY 时直接报错（`conn_manager.py:258-264`），消息就没了。
- SP 侧帧由 100 个线程的 `frame_mgr` 池处理（`conn_manager.py:44, 97, 444-450`）；`FederatedServer.lock` 在别处只短暂持有（`fed_server.py:398, 1228`）。
- 所以 L13 需要三者之一：(a) SP 处理这条消息比 SJ 进程退出晚 2 s 以上；(b) 发送那一刻 SJ→SP 连接不可用（发送报错、不重试）；(c) 下面 3.3 的 SFM 握手竞争把它丢掉。

### 3.2 测量（`l13_natural.py`）

SP 侧（本进程）：真实 root cell 及其 internal listener，按 `_register_cellnet_cbs`（`fed_server.py:469-473`）注册的真实 `_listen_command`，真实 `wait_for_complete`（真实 `Popen` 句柄、`get_return_code`），然后真实 `JobRunner._get_finished_job_status`。SJ 侧（每次试验一个子进程，job id 各不相同）：真实 job cell 连上 internal listener，`settle` 秒后（真实 SJ 的最终状态在连接建立几分钟后才发）带着 sticky 的 FATAL_SYSTEM_ERROR 调真实 `update_job_run_status`，然后 graceful（真实 `shutdown_job_process_runtime` + `cell.stop`）或 abrupt（`os._exit(0)`）退出。不注入任何延迟或丢包；"忙线程"是在 SP 进程里人为加的 CPU 负载（GIL 压力）。

```
$ l13_natural.py 100 graceful 0 1.0
trials=100 SJ exit=graceful busy SP threads=0 settle after connect=1.0s
job status after the SJ exits with 0 following system_panic: {'RunStatus.FINISHED_EXECUTION_EXCEPTION': 100}
send -> SP handler latency: median 3.60 ms, max 8.24 ms
slack before the 2 s wait expires (exit + 2 s - handler): min 2.004 s, median 2.008 s
SJ-side fire_and_forget results: {"{'server':''}": 100}
status message not handled within the 2 s wait: 0/100; of these handled later (late, s after exit): []; never handled within 4 more s: 0
DATA frames dropped by the SP before endpoint attachment: 0
L13 natural: NOT reproduced (every panicked job recorded as EXECUTION_EXCEPTION)

$ l13_natural.py 100 abrupt 0 1.0
trials=100 SJ exit=abrupt busy SP threads=0 settle after connect=1.0s
job status after the SJ exits with 0 following system_panic: {'RunStatus.FINISHED_EXECUTION_EXCEPTION': 100}
send -> SP handler latency: median 3.59 ms, max 6.73 ms
slack before the 2 s wait expires (exit + 2 s - handler): min 2.003 s, median 2.007 s
SJ-side fire_and_forget results: {"{'server':''}": 100}
status message not handled within the 2 s wait: 0/100; of these handled later (late, s after exit): []; never handled within 4 more s: 0
DATA frames dropped by the SP before endpoint attachment: 0
L13 natural: NOT reproduced (every panicked job recorded as EXECUTION_EXCEPTION)

$ l13_natural.py 100 abrupt 4 1.0       # SP 进程里 4 个 CPU 忙线程
trials=100 SJ exit=abrupt busy SP threads=4 settle after connect=1.0s
job status after the SJ exits with 0 following system_panic: {'RunStatus.FINISHED_EXECUTION_EXCEPTION': 100}
send -> SP handler latency: median 172.28 ms, max 1402.41 ms
slack before the 2 s wait expires (exit + 2 s - handler): min 1.177 s, median 1.964 s
SJ-side fire_and_forget results: {"{'server':''}": 100}
status message not handled within the 2 s wait: 0/100; of these handled later (late, s after exit): []; never handled within 4 more s: 0
DATA frames dropped by the SP before endpoint attachment: 0
L13 natural: NOT reproduced (every panicked job recorded as EXECUTION_EXCEPTION)

$ l13_natural.py 100 abrupt 4 0.2       # 同上，但连接建立后 0.2 s 就发
trials=100 SJ exit=abrupt busy SP threads=4 settle after connect=0.2s
job status after the SJ exits with 0 following system_panic: {'RunStatus.FINISHED_EXECUTION_EXCEPTION': 96, 'RunStatus.FINISHED_COMPLETED': 4}
send -> SP handler latency: median 185.39 ms, max 1140.31 ms
slack before the 2 s wait expires (exit + 2 s - handler): min 1.028 s, median 1.979 s
SJ-side fire_and_forget results: {"{'server':''}": 100}
status message not handled within the 2 s wait: 4/100; of these handled later (late, s after exit): []; never handled within 4 more s: 4
DATA frames dropped by the SP before endpoint attachment: 4
L13 natural: REPRODUCED in 4/100 trials (panicked job recorded as COMPLETED)
```

- 空闲 SP 上 200 次全部正确，消息在发送后 3.6 ms（最大 8 ms）被处理，离 2 s 的期限还有 2.0 s 余量。
- 4 个忙线程时延迟中位 172 ms、最大 1.4 s，最小余量仍有 1.18 s，100 次全部正确。也就是说，"晚到超过 2 s"需要 SP 的消息处理整体停顿 2 s 以上，这比我能人为制造的 GIL 负载还重得多。
- 早一版脚本（每次复用同一个 job id、settle 0.2 s，忙线程 4 个）里 1/40、1/80、2/80 出现 COMPLETED，全部是"从未被处理"而不是晚到；其中一轮打开 SFM 的 debug 日志，丢失的那一次正好对应一条 "Ignoring DATA before endpoint attachment"。复用 job id 还引入了 "Connection ... is evicted ... for exceeding limit 1" 的连接替换，那是 harness 的假象，所以最终版改成每次唯一的 job id，丢失仍然出现（上面最后一组 4/100，4 条 drop 日志一一对应）。

### 3.3 新线索（与 L13 相关但不同根因）：SFM 在 endpoint 挂上之前收到的 DATA 帧被静默丢弃

- `ConnManager.process_frame_task` 处理 HELLO 时先回 READY，再 `update_endpoint`（`conn_manager.py:406-409`）；同一连接的帧由线程池并发处理（444-450）。主动方收到 READY 就认为连上了，可以马上发 DATA；被动方如果还没执行到 `update_endpoint`，这个 DATA 帧在 416-419 行以 debug 日志 "Ignoring DATA before endpoint attachment" 丢掉。发送方的 `fire_and_forget` 已经返回成功（上面 100/100 都是 `{'server': ''}`）。
- 这段丢弃逻辑是 upstream 有意加的（#5320，`76c34c36cd`，2026-09-18，注释说明 READY 可能先于 endpoint 挂载到达），main 上仍在。没有查到相关 issue。
- 对 L13 的意义：生产中的 SJ 在启动时就连上，`sync_clients_from_main_process` 的 GET_CLIENTS 请求会重试到拿到回复为止（`server_app_runner.py:81`，`server_engine.py:829-840`），拿到回复说明 endpoint 已挂上，几分钟后的最终状态消息不会碰到这个竞争。只有 SJ→SP 连接在 job 结束前约 1 s 内断开重连过（而 SP 又忙），状态消息才可能被这样丢掉。
- 作为独立线索：任何在新建（或重连）连接上紧接着发出的 `fire_and_forget`，在接收方繁忙时都可能被静默丢弃。影响面没有评估。证据级别：REPRODUCED（harness，人为 GIL 负载 + 连接建立后 0.2 s 即发送）。

### 3.4 自然概率与结论

- 正常部署下（SJ 与 SP 同机，本地连接健康），L13 的自然可能性**可以忽略**：本轮 300 次真实传输试验（含 100 次人为 GIL 负载）没有一次误判，最小余量 1.18 s。
- 变得可能的条件：SP 进程整体停顿超过 2 s（例如长时间的 GC/换页、被 cgroup 限 CPU），或者 SJ→SP 连接恰好在 job 结束时断开或刚重连（K8s/Docker launcher 下 SJ 经网络连回 SP，推测概率高一些，没有测）。模型里的 `statusLost`（权重 2）对应的就是这类情况。
- 证据级别不变：REPRODUCED（注入消息延迟或丢失）。自然时序下未复现。

---

## 4. N2：收尾窗口内 dead-client 宽限期到期，已完成的 workflow 被判违反部署策略

### 4.1 现实触发条件（代码）

- 窗口的起点是 `control_flow` 返回（`server_runner.py:153`）。之后 finally 拿 `wf_lock`（161），调 `stop_controller`（171），再调 `finalize_run`（172）。`finalize_run` 在 `_controller_lock` 内先执行 `_cleanup_inflight_tensor_downloads`，再置 `_all_done`（`wf_comm_server.py:1043-1046`）。
- task monitor（1201-1213）每轮先做 `_check_dead_clients` 和 `_job_policy_violated`，再做 `check_tasks`，而 `check_tasks` 要拿 `_controller_lock`（1215-1217）。所以 `finalize_run` 一拿到锁，monitor 最多再判一次（锁之后的第一个 tick），然后就卡在 `check_tasks` 上，直到 `_all_done` 置位后退出。**窗口 ≈ `stop_controller` 的耗时 + 最多一个 monitor 周期**，与 `finalize_run` 本身多慢无关。
- monitor 周期实际固定为 0.2 s：`WFCommServer` 读的是 `_task_check_period`（116, 1213），`Controller.set_communicator` 写的是另一个属性 `task_check_period`（`controller.py:53`），所以 ScatterAndGather/BaseModelController 的 `task_check_period=0.5` 并不生效（只读代码确认，影响很小，顺带记下）。
- 常用 workflow 的 `stop_controller` 很快：ScatterAndGather 只置 phase（`scatter_and_gather.py:351-352`），BaseModelController 调用户的 `finalize()`（`base_model_controller.py:524-526`，默认空），ccwf `server_ctl` 为空（545-546）。CrossSiteModelEval 要删模型文件（`cross_site_model_eval.py:247-260`），XGBoost 的 tie controller 要停 connector（`tie/controller.py:552-566`），会长一些。
- **新发现的一个自然时长来源：** `_cleanup_inflight_tensor_downloads`（151-162）在 `finalize_run` 里 `from nvflare.app_opt.pt.tensor_downloader import ...`，这会 import torch（`tensor_downloader.py:21`）。非 PyTorch 的 job（numpy、sklearn、XGBoost 等）跑在装了 torch 的 server 环境里（例如基于 PyTorch 镜像的部署）时，SJ 第一次 import torch 就发生在收尾时。实测（`.tmp/natA/probe_import.py`，新进程、页缓存已热）：装 torch 时首次调用 915–1217 ms（3 次），之后 0.013 ms；没装 torch 时每次 1–1.6 ms（失败的 import 每次都重试）。我也确认了 SJ 侧为 numpy job 加载的模块（`runner_process`、`server_runner`、`fed_server`、`server_engine`、SAG/FedAvg/CSE、np persistor、aggregator）都不会提前 import torch。不过由于上面的锁，这 1 s 里 monitor 只有锁后的第一个 tick 能判（GIL 被 import 占着，tick 会晚到）。

### 4.2 测量（`n2_natural.py`）

真实代码：`ServerRunner._execute_run` 整个 workflow 生命周期（`initialize_run` 启动 monitor、`control_flow`、finally 里的 `wf_lock`、`stop_controller`、`finalize_run`，包括真实的 `_cleanup_inflight_tensor_downloads` 和 import），`ServerRunner.handle_dead_job` → `process_dead_client_report`，`_check_dead_clients`、`_job_policy_violated`、`check_tasks`。桩：engine（两个 client，`min_sites=2`，事件记录）、`control_flow` 在 T_ret 返回、`stop_controller`（默认立即返回，同 SAG）。宽限期（配置项 `dead_client_grace_period`，默认 60 s）压缩到 1 s，只影响试验时长：结果只取决于到期时刻相对 T_ret 的位置。每次试验一个新进程（import 是冷的），T_ret 相对 monitor tick 的相位随机。到期时刻在 T_ret ±A 内均匀分布；N2 = 返回之后才 panic。窗口 F = N2 比例 × 2A；若 client 的死亡时刻在返回前最后 60 s 内均匀分布（更早的死亡会在 workflow 运行中就触发 panic，那是预期行为），P(N2) = F / 60 s。

```
$ n2_natural.py 1200 0.25 8 0.0          # 没装 torch（nvflare-venv）
trials=1200 A=+-0.25s stop_delay=0.0s monitor period=0.2s grace(compressed)=1.0s torch imported in 0/1200 workers
outcomes: {'abort-in-workflow': 358, 'N2': 2, 'completed': 840}
finalize_run done after control_flow return: median 1.4 ms, max 5.9 ms
N2 expiry offsets (s after return): min -0.175 max -0.056
measured N2 window F = 0.8 ms  ->  P(N2 | client death uniform in last 60 s) = 1.39e-05

$ n2_natural.py 200 0.5 8 0.0            # 装了 torch、job 本身不用 torch（venv-fedavg）
trials=200 A=+-0.5s stop_delay=0.0s monitor period=0.2s grace(compressed)=1.0s torch imported in 200/200 workers
outcomes: {'abort-in-workflow': 74, 'N2': 65, 'completed': 61}
finalize_run done after control_flow return: median 920.5 ms, max 1124.3 ms
N2 expiry offsets (s after return): min -0.165 max 0.257
measured N2 window F = 325.0 ms  ->  P(N2 | client death uniform in last 60 s) = 5.42e-03

$ n2_natural.py 120 1.5 6 1.0            # stop_controller 耗时 1 s（n2_repro.py 的前提），没装 torch
trials=120 A=+-1.5s stop_delay=1.0s monitor period=0.2s grace(compressed)=1.0s torch imported in 0/120 workers
outcomes: {'abort-in-workflow': 39, 'N2': 38, 'completed': 43}
finalize_run done after control_flow return: median 1001.5 ms, max 1008.2 ms
N2 expiry offsets (s after return): min -0.075 max 0.956
measured N2 window F = 950.0 ms  ->  P(N2 | client death uniform in last 60 s) = 1.58e-02
```

- 装 torch 时 `finalize_run` 要 0.9 s，但窗口只有 0.33 s，正好是"返回前最后一个 tick 到锁后第一个 tick（被 import 的 GIL 占用推迟）"那一段，验证了 4.1 的锁分析。`stop_controller` 在锁外，它耗时多少窗口就加多少（1 s → 0.95 s）。
- 负的 N2 到期偏移（到期略早于返回，但下一个 tick 在返回之后）也算 N2：panic 发生时 workflow 已经正常返回。没装 torch 时这类到期多数被"漏掉"（下一个 tick 之前 monitor 已经退出），job 正常完成。

### 4.3 自然概率

前提：某个 client 的 dead-job 报告在 workflow 返回前最后 60 s 内到达 SJ（CJ 崩溃时经 CP 心跳同步，约一个心跳周期 10 s 内到达；CP 整个失联时要等 SP 的 `heart_beat_timeout` 600 s 后由 cleanup 发出），而 workflow 仍能正常返回（例如这个 client 已交了最后一轮结果）。在此条件下：
- 标准 workflow（SAG、FedAvg、ccwf）、server 环境没装 torch：约 1e-5（实测 1.4e-5）。job 本身用 torch 时 torch 已加载，预计同一量级，但 `nvflare.app_opt.pt` 包本身的首次导入时间没有单独测。
- 非 PyTorch job、server 环境装了 torch：约 5e-3。
- `stop_controller` 耗时 S 秒的 workflow：约 S / 60（S = 1 s 时 1.6e-2）。

模型里的 `slowFinalize`（T4，"收尾的几秒内"）对标准 workflow 偏宽：真实窗口被 `_controller_lock` 截在一个 monitor 周期左右，只有 `stop_controller` 本身慢的 workflow 才有秒级窗口。

### 4.4 结论

自然可能性：标准 workflow 下**很低**（条件概率 1e-5），在"非 torch job + 装了 torch 的 server"或 `stop_controller` 慢的 workflow 下**偶发**（条件概率 0.5%–2%，乘上"最后一分钟内死掉一个 client"本身的概率）。证据级别不变：REPRODUCED（时序巧合为条件、调度不强制；收尾路径真实，engine 和 `control_flow` 是桩）。

---

## 5. H01：Attach trainer 的 send() 在 CJ 两次拒收后仍报成功

### 5.1 机制（代码）

- trainer 侧 `CellClientAPI.send`（`api.py:453-588`）调用 `AttachTrainerSession.publish_result`（`attach_session.py:361-439`）。`_RESULT_SEND_ATTEMPTS = 2`（49）。RESULT_READY 没有回复或回复非 OK 时抛 `_UncertainResultReply`，转去问 RESULT_STATUS；两次都不确定后进入 `_resolve_ambiguous_result`（441-467）：再问一次 RESULT_STATUS，CJ 答 UNKNOWN 时，只要某次 attempt 的 transfer waiter 全部以 COMPLETED 结束，就把这次 attempt 当作已接受（459）。`send()` 随后等这些 transfer（543）、标记 task 完成、正常返回。
- CJ 侧：attach 模式下 CJ 是最终接收方，自己解码 RESULT_READY（`attach_backend.py:203` 不设 pass-through 路由），所以结果的 lazy 数据在 `_handle_result_ready`（`cell_backend.py:195-268`）执行前就已下载完、transfer 由接收方确认为 COMPLETED。如果这时 task 已经关闭（`AttachBackend._run_task` 的 finally 在 abort 或结果超时时清掉 `_current_task`，`attach_backend.py:636-639`），handler 回 RESULT_REJECTED "no current task matching task_id"（`cell_backend.py:236-242`），不记录 result authority，于是 `_handle_result_status` 回 UNKNOWN（281-282）。
- 小结果（没有 lazy transfer）时没有 waiter，`_resolve_ambiguous_result` 返回 None，`send()` 正确地报失败。

### 5.2 复现（`h01_repro.py`）

真实代码：`CellClientAPI.send`、`_wait_for_result_transfers`、`_notify_result_source_settled`；`AttachTrainerSession.publish_result`、`_accepted_result_attempt`、`_accepted_result_attempt_from_status`、`_resolve_ambiguous_result`、`_keep_canonical_attempt`、`mark_result_publishing`、`mark_task_complete`；`AttachBackend` / `CellBackendBase` 的 `_handle_result_ready`、`_handle_result_status`、`_handle_result_source_settled`、`_validate_session_msg`、`_protocol_reply`；真实的 `TransferWaiter` 和 `TransferOutcome`。桩：cell 传输（请求直接交给 CJ 的真实 handler；"丢失"的回复按 `send_request` 收不到回复时的行为返回 cell TIMEOUT）、lazy 结果的 FOBS 编解码（每次 attempt 一个 transaction；CJ 解码时把它的 waiter 置为接收方确认的 COMPLETED）、task 关闭（与 `_run_task` finally 相同的两行）。

```
C1 control: task open, replies delivered:
    ('client_api.result_ready', 'client_api.result_accepted', None, 'delivered')
    ('client_api.result_source_settled', 'client_api.result_source_settled', None, 'delivered')
    CJ result authority: {'task-1': ('73b1e02c296844b993118113e0ce98f5', '819a87a2a17a4302ba77d8987a5662a0')}
    -> send() returned normally (trainer: result delivered)
C2 control: task already closed, RESULT_REJECTED delivered:
    ('client_api.result_ready', 'client_api.result_rejected', "no current task matching task_id 'task-1'", 'delivered')
    CJ result authority: none
    -> send() raised TrainerSessionError: result was rejected by the CJ: no current task matching task_id 'task-1'
C3 control: task already closed, both rejections lost, small result (no lazy transfer):
    ('client_api.result_ready', 'client_api.result_rejected', "no current task matching task_id 'task-1'", 'LOST')
    ('client_api.result_status', 'client_api.result_status', 'UNKNOWN', 'delivered')
    ('client_api.result_ready', 'client_api.result_rejected', "no current task matching task_id 'task-1'", 'LOST')
    ('client_api.result_status', 'client_api.result_status', 'UNKNOWN', 'delivered')
    CJ result authority: none
    -> send() raised TrainerSessionError: result publication failed after status recovery: cell-level failure on RESULT_READY: timeout
H01: task closes after the CJ's download completed; both RESULT_REJECTED replies lost:
    ('client_api.result_ready', 'client_api.result_rejected', "no current task matching task_id 'task-1'", 'LOST')
    ('client_api.result_status', 'client_api.result_status', 'UNKNOWN', 'delivered')
    ('client_api.result_ready', 'client_api.result_rejected', "no current task matching task_id 'task-1'", 'LOST')
    ('client_api.result_status', 'client_api.result_status', 'UNKNOWN', 'delivered')
    ('client_api.result_status', 'client_api.result_status', 'UNKNOWN', 'delivered')
    ('client_api.result_source_settled', 'client_api.error', "no live result source matching task_id 'task-1'", 'delivered')
    ('client_api.result_source_settled', 'client_api.error', "no live result source matching task_id 'task-1'", 'delivered')
    ('client_api.result_source_settled', 'client_api.error', "no live result source matching task_id 'task-1'", 'delivered')
    CJ result authority: none
    -> send() returned normally (trainer: result delivered)
H01 REPRODUCED: send() reported success although the CJ rejected both attempts and holds no result
```

（tuple 依次是：请求 topic、CJ 回复 topic、状态或原因、回复是否送达。）

### 5.3 结论

证据级别从"只有静态代码确认"升为 **REPRODUCED（桩传输 + 注入回复丢失）**。CJ 一侧没有任何结果和 authority，server 那边这一轮本来就按 task 中止/超时处理，影响仍限于 trainer 误以为发送成功（例如据此推进本地状态或清掉模型缓存：`send()` 里 `clear_cache` 会在成功分支释放参数，`api.py:545-557`）。触发只需要两次 RESULT_REJECTED 回复都丢；RESULT_STATUS 回复丢不丢结果一样（异常或非 OK 都按 None 处理，`attach_session.py:512-515`，与 UNKNOWN 走同一分支）。同时 trainer→CJ 方向的下载要成功，所以自然条件下需要 CJ→trainer 方向在这段时间里连续丢两个回复，可能性低；没有做自然时序试验。

---

## 6. 汇总

| 线索 | 现实触发 | 自然可能性（测量或推算） | 证据级别 | 脚本 |
|---|---|---|---|---|
| T2 | 宕机超过 600 s 的 CP 重启（或管理员 remove/disable）恰好落在列名单与轮到它之间；网络恢复后的重连不会触发 | 窗口 0.15–0.35 ms（前面 10 个过期 token 时 3.3 ms）；每次此类重启约 1e-7 – 1e-5，最不利 3e-5 – 6e-4 | REPRODUCED（时序巧合为条件，调度不强制，路径无桩） | `t2_natural.py` |
| T3 | dead-client 扫描的毫秒窗口内恰好有别的 SJ 启停 | 窗口 0.08–0.24 ms；每个 dead-client 事件约 1e-6（1 次启停/分钟）；GIL 饱和时上界 1e-3 | REPRODUCED（同上，传输真实） | `t3_natural.py` |
| L13 | SJ 的唯一一条 UPDATE_RUN_STATUS 在进程退出 2 s 后才被 SP 处理，或丢失（发送时连接断开，或刚重连的连接上被 SFM 丢弃） | 空闲 SP 0/200（处理延迟中位 3.6 ms，余量 ≥ 2.0 s）；人为 GIL 负载 0/100（最大 1.4 s）；正常部署下可以忽略 | REPRODUCED（注入延迟/丢失）；自然时序未复现。连接建立后 0.2 s 即发送 + GIL 负载时 4/100 经 SFM 丢帧复现（新线索，强制条件） | `l13_natural.py` |
| N2 | client 在 workflow 返回前最后一分钟内死掉，宽限期在收尾窗口内到期 | 条件概率：标准 workflow 1.4e-5；非 torch job + 装 torch 的 server 5.4e-3；`stop_controller` 1 s 时 1.6e-2 | REPRODUCED（时序巧合为条件，收尾路径真实） | `n2_natural.py` |
| H01 | task 在 CJ 下载完结果后关闭，两次 RESULT_REJECTED 回复都丢（下载方向正常） | 未做自然试验；需要单方向连续丢两个回复，低 | REPRODUCED（桩传输 + 注入回复丢失），原为 static-only | `h01_repro.py` |
