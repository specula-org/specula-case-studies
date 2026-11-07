# 结果（2026-11-04 凌晨，供审阅）

工作目录：`~/nvflare-remix-20261103`。Codex 的工作区和 Specula 仓库都没有改动；所有输入都是只读拷贝，放在 `inputs/`。设计文档见 `DESIGN.md`，过程日志见 `notes/COORDINATOR-LOG.md`。

## 1. 做成了什么

**粗细自由组合框架**（`DESIGN.md` §1–§4）。

- **按"进程 × 组件"切成 9 个动作组。** 切分依据是 Phase 1 的隐患：易出 bug 的机制放在同一组内部，组与组之间沿交互简单、不易出 bug 的边界切开。9 个组是：JobSP、JobCP、RunCJ、TaskCJ、Trainer、PaySrc、PayRcv、CommSJ、WfSJ；另外有一个 Net 组（可靠或丢包两个变体）。
- **每组只通过两类端口和外界交互：**
  - 自己独占的一个端口变量；
  - append-only 的消息日志，每种消息只由一个组发送，接收方的消费状态是私有的。

  同一进程里的组之间可以读彼此的端口。跨进程只能走消息，例外是父进程观察子进程退出这类 OS 事实。
- **组合方式：** 一个 TLA+ 根模块 `Mix.tla`（由 `scripts/gen_mix.py` 生成）覆盖所有组合，配置里的 `Grain` 为每个组选一个变体。没被选中的变体，其私有变量保持常量，不增加状态。
- **按 site 选粒度：** 每个 site 的组可以单独选变体，例如 site 1 的 trainer 用细变体、site 2 的用粗变体。
- **组合空间：** 2 个 site 时共 2^3 × 2^12 × 2 = 65,536 种组合。`sweep.py --strategy cover:2|3 --per-site` 用 t-way covering array 覆盖：两两覆盖只要 9 个组合，3-way 覆盖要 19 个。
- **解耦约束是机械强制的，不靠自觉：**
  - 生成器做静态检查：一个变体只能写自己的变量、只能发自己拥有的消息类型、不能引用别的变体的私有变量、import 必须在白名单内、除 Net 组外不能读写丢包标志。
  - 生成的每一步都带 `Assert(NetOK(g))`：已有消息不可改写，新消息必须是本组拥有的类型。
- **粗细之间的契约**（交互保持，Remix 的核心条件）：
  - 细变体在端口上的行为必须包含在粗变体之内；
  - 粗变体只能合并端口上不可见的步骤；
  - 检查方式：`gen_ref.py` 生成 RefStep（refinement）、RefEnv（抽象函数不随别的组的步骤变化）和非空性负控，并把结果写成带实例签名的 receipt。
- **可靠性论证：** `DESIGN.md` §2 写了归纳证明的草稿，并列出成立所需的条件 C1–C9。按设计审查（`notes/design-review.md`）的意见改过一轮；审查找出了 2 个 Critical 漏洞，都已修复。
- **Trace validation 不依赖粒度**（§6）：同一条真实 POC trace（共 120 步，其中 75 个事件改变端口状态）可以在任意组合上按端口回放。接受只能往粗的方向推广，所以正例要在全细组合上跑；拒绝只能往细的方向推广，所以负例在全粗组合上跑。

**规模**

- 9 个组都有粗变体，其中 6 个组的细变体已正式注册（JobSP、JobCP、RunCJ、Trainer、PaySrc、PayRcv）。TaskCJ、CommSJ、WfSJ 三个细变体的状态见 §5。
- 细变体共 393 个动作、5,473 行；粗变体共 120 个动作、1,343 行。加上端口层，spec 一共 7,191 行。
- 细变体逐动作来自 9 月的三个种子 spec，保留了源码锚点，种子里内部伪造的环境都换成了相邻组的真实端口。Trainer 组是新写的，种子里没有，直接依据 `client/in_process/api.py`。

## 2. 找到了什么

证据等级分开写，模型反例和代码复现不混在一起计数。

| 编号 | 内容 | 涉及的组 | 证据 |
|---|---|---|---|
| S02 / H02（Phase 1 v2 MC-2/TP-C） | in-process `send()` 收尾的 `clear_cache` 会清掉 executor 已经投递的下一轮输入，导致 trainer 永远等待（之后靠 result_wait_timeout 中止，或者 executor 一直挂着） | Trainer × TaskCJ | 组件级模型反例，10 步（`checks/trainer/`）。在 pin 版本的真实代码上用强制调度复现（`checks/confirm/s02_repro.py`）。现实触发概率低：需要 trainer 线程在 `publish_result` 返回后的那个窗口里一直被挂起，直到下一轮任务投递 |
| H30（Phase 1 H29 的推论，新推导） | 收尾时有 straggler：任务超时导致本轮失败、run 结束；straggler 的结果迟到，SJ 开始 pull。END_RUN 让 CJ 退出循环并关掉 DownloadService，源端回复 INVALID_REQUEST；这不是 DownloadCancelled，于是 SJ decode 失败走 `os._exit(1)`，SJ 在 run 已经结束后死掉 | 全部 9 个组 | **从粗到细逐级复现，反例一直存在**：全粗组合 3.3 秒（`checks/campaign/cmp_F10c_s1`）→ 6 个细组 5.3 秒（`checks/findings/H30_six_fine_groups.ce.txt`）→ 全部 9 个组都用细变体时 8 秒、128 步（`checks/findings/H30_all_fine.ce.txt`）。另一条路径：下载在 SJ 自己的 DS shutdown 之后才注册，这一点已在真实代码上确认（`checks/confirm/h30_shutdown_latch.py`，pin 版 DownloadService）：shutdown 只取消当时正在进行的下载，之后才注册的下载没有任何 latch，失败只会是普通错误。"已完成的 workflow 变成失败的 job"这一端到端结果（需要 2 个 site 加 minClients）跑了 300 秒模拟，还没跑到，也没做真实运行；**真实 POC 12 次运行均未复现**：命中窗口的 2 次被 SJ 先关 DS 的时序挡住（MASKED），详见 §7 和 `poc-h30/REPORT.md`。现实中需要异常的时序才会触发 |
| MC-2（payload 种子的已知问题） | 取消和已经被接受的 EOF 并发时，进度状态和最终结果不一致 | PaySrc × PayRcv | 改成基于消息的链路后，两边都用细变体，模型里仍能复现（已知行为，`notes/pay-impl.md`） |
| CANT_SCHEDULE 覆盖已确认的 ABORTED | 管理员 `abort_job` 已经回复"Aborted the job before running it"，调度器之后依据旧快照把 job 写成 FINISHED_CANT_SCHEDULE。写入时没有加锁，也没有 compare-and-set | JobSP | 模型反例（`checks/job/ce_cantschedule_over_aborted.*`）。源码锚点：job_runner.py:703、job_scheduler.py:334-383、filesystem_storage.py:251-275。严重度低，未在真实系统复现 |

另外，组合反例分诊（zoom-in）也帮着修掉了一些模型自身的错误，比如 payload 那边的"先检查 abort"和 DS shutdown 的原子性。这类属于模型错误，不算发现。

## 3. Refinement receipts（细 ⊑ 粗）

| 组 | 细/粗动作数 | 结果 |
|---|---|---|
| Trainer | 8 / 4 | 组件 harness 内穷举通过（164 个状态），负控按预期失败；完整组合里在 budget 内截停，无违例 |
| PaySrc | 93 / 10 | harness（chaotic 端口环境）内穷举通过：无故障 170 万、S10 181 万状态；完整组合里约 200 万状态时截停，无违例 |
| PayRcv | 23 / 12 | harness 内穷举通过：无故障、S10、H29、S10+netLoss（295 万）、S12、S19 |
| JobSP | 88 / 28 | 完整组合里在 budget 内截停，无违例：Net R 时 904 万状态，Net L 时 378 万；负控按预期失败 |
| JobCP | 45 / 18 | 截停，无违例：Net R 165 万，Net L 204 万（MaxLaunch 2） |
| RunCJ | 14 / 11 | 截停，无违例：Net R 340 万，Net L 462 万（MaxLaunch 2） |
| TaskCJ / CommSJ / WfSJ | 21/8、52/13、49/16 | 截停，无违例：各约 170 万状态；按场景实例另跑了模拟。因为都没有穷举完，所以保持 `"wip"` |

"穷举通过"的只有 harness 里的那几组（payload、Trainer）。完整组合里的检查都在 budget 内截停，按 `DESIGN.md` C1 的标准，这些结论还不能推广到全细组合。

## 4. 局限（会影响你接下来怎么用）

1. **完整组合里的 receipt 太贵。** 全粗、单 site、不开故障时就已经超过 900 万个状态。原因是各 agent 把粗变体写得越来越细，粗变体不够"粗"了。我已经让它们把只有本组自己读的端口字段挪进私有变量，并合并步骤。

   更根本的解法是把 receipt 放到组件 harness 里做：显式写出环境假设，再在组合里检查这些假设成立（assume-guarantee）。payload 和 Trainer 已经这样做了；"环境假设成立"这一步还没有自动化。在那之前，campaign 结果里大多是 "transfer: missing"，表示组合里的结论还不能算推广到全细组合。
2. **只有 1 轮。** payload 每次 launch 只有一个事务，所以 2 轮在完整组合里会卡在 envelope 那一步，S02 只能在组件 harness 里跑。
3. **trace validation 的工具已经能跑，但全粗组合的回放卡在第 7 个事件（Launch）。** 原因是 job 粗变体加了 deploy 阶段，回放映射还没跟上。全细组合上的正例还没跑。
4. **两个场景还只做到模型层面：** H30 端到端和 CANT_SCHEDULE。S02 和 H30 的关键环节有真实代码的单元级复现。
5. 中途有约 3 小时停摆：所有 agent 在 20:30 撞到 5 小时用量上限，23:20 恢复。

## 5. 收尾状态

- **组合是活的：** 全粗、单 site 的组合里，job 能正常结束（模拟 3 秒到达）。job agent 在全粗组合上跑了 745 万状态的模拟，没有违例。完整组合穷举不了，要靠模拟或组件 harness。
- **组合 sweep：** 用 pairwise covering array 生成了 10 个组合，覆盖每两个 (group[, site], variant) 选择的组合。设置是 per-site 粒度、2 个 site，故障开 cjCrash 和 taskTimeout，其中 5 个组合的 Net 是丢包变体。每个组合模拟 150 秒，8 个核心端口不变式都没有违例。这些不变式是 ClaimNeedsMaterialized、MaterializedIsRegistered、AggregateIsAccepted、AcceptedWasClaimed、NoFreeWhileChildAlive、AtMostOneFree、NoReleaseBeforeMaterialize、SuccessorInputPreserved。结果在 `checks/sweeps/final_cover2.md`。这只是有界模拟，不是穷举。
- **未解决：**
  - 在部分组合里，TLC 求值 `NoSJDeathAfterWorkflowDone`（经由 `SJFatal`/`Flag`）时报 cast 错误。换成直接写的不变式（`NoPayFatalAfterDone`）就正常。原因还没查。
  - `SJExitCode` 没有考虑 controller panic 和 `pJobSP.sjKilled`（fed 和 job agent 都提了）。
  - payload 端口目前每次 launch 只有一个事务，挡住了 S11、S12，也挡住了 2 轮。
  - 其他端口改动请求见 `notes/port-requests.md`。
- **资源：** 早先一次超时运行留下的孤儿 JVM（pid 2440673）跑了两个多小时，我想停掉它被权限拒绝了，现在已经自己结束。`/` 写满时 JVM 的 perf data 会写进 `/tmp` 导致 SIGBUS，已在 `tlc.sh` 里加 `-XX:-UsePerfData` 规避。

## 6. 下一步建议

- 把"harness receipt + 环境假设检查"做成框架标准流程，用它取代完整组合里的 receipt。
- payload 改成每轮一个事务，这样就能支持 Rounds ≥ 2，让 S02 能在完整组合里跑。
- H30 用真实 POC 复现：FedAvg min_clients=1、2 个 site、一个慢客户端；可以基于 Codex 的 POC harness 改。
- 补上 Attach / external trainer、SAG、Swarm 这几个组。Phase 1 排名前十的场景大多在这些组件里。

## 7. 第二轮（01:00 起，按"下一步"推进）

- **assume-guarantee receipt 已作为标准流程**（`DESIGN.md` §2.1）。流程分三步：
  1. 为每个组写环境假设 `Env_<G>.tla`，包含两种形式：生成形式 `EnvNext` 供 harness 探索，检查形式 `EnvAllowed` 供组合里检查。
  2. `scripts/gen_harness.py` 生成只含"该组细变体 + 环境"的 harness，在里面穷举检查 refinement、RefEnv，以及生成形式确实落在假设之内。
  3. 在组合里检查 `AG_<G>`（`spec/AG.tla`），确认邻居组的实际行为没有超出环境假设。
- **Trainer 是第一个样板：**
  - harness receipt 穷举通过：1 site 1 launch 467 个状态；1 site 2 launch 6.5 万个状态，2 秒。负控按预期失败，S02 仍在 12 步内被找到。
  - 头两次在组合里检查假设，都找出了假设写窄了的地方，各补了一次：一是 executor 发出的 ABORT/STOP 信号可以互相覆盖；二是粗 TaskCJ 在 ABORT 之后仍可能投递输入。
  - 补完后，在全粗、TaskCJ 细化、全细三种组合里各模拟 120–150 秒，假设都成立。
  - 顺带发现的端口改进：`trainerSignal` 应该改成一个只增不减的已触发主题集合，已记在 `notes/port-requests.md`。
- **H30 真实 POC（`poc-h30/REPORT.md`）：NOT REPRODUCED，12 次真实运行**（6 进程，模型 4 MiB–1 GiB，`min_responses=1` 制造 straggler）。
  - 有 2 次正好命中窗口：END_RUN 时 SJ 正在 pull 512 MiB 的结果。但 SJ 自己的 DownloadService 在 END_RUN 之后约 1 ms 就关闭了，进行中的下载拿到 typed `DownloadCancelled`，走 SERVICE_UNAVAILABLE 分支，不是致命分支。job 状态 COMPLETED。
  - CJ 那边要先过一个不可中断的 5 秒 `task_check_interval` sleep，才会关自己的 DS（client_runner.py:175,679,814-821），实测比 SJ 晚 7.6–7.9 秒。
  - 另一条路径（晚于 SJ shutdown 才注册的下载）被 TASK_CHECK 挡住了：envelope 在 0.1 秒内就到，而从收轮到 DS shutdown 至少要 1.9 秒。
  - 结论：保护来自时序余量，代码里没有保证，所以判 MASKED/NOT REPRODUCED，不判 REFUTED。
  - **这是模型的一个教训：** 模型没有时间，允许"CJ 一收到 END_RUN 就关 DS、SJ 的 DS shutdown 无限滞后"。真实系统里这需要异常的时序，比如 SJ readiness 被持有、或 CJ 没有在 submit 中。后续应该把这类时序前提显式建成故障开关，例如 `slowSJTeardown`、`fastCJTeardown`。这样反例会自动带上它所依赖的时序前提，便于判断现实中有多大可能。
- **把时序前提写进模型（T1）：** `PortsJob.CJTeardownTimingOK`。默认要求 CJ 的 DS shutdown 晚于 SJ 自己的；打开 `slowSJTeardown` 故障才去掉这个约束。用全细组合、每种设置模拟 3 次、每次 120 秒做对比：
  - 不加 T1：3 次里 1 次走到 H30 坏状态；
  - 打开 `slowSJTeardown`：3 次里 2 次走到；
  - 加上 T1：3 次里只有 1 次走到。追这一次的路径，暴露出一个**跨组集成不一致**：PaySrc 在 `pRunCJ.state = "stopping"` 时就关 DS，而真实调用点是 RunCJ 的 run-finally（`dsDown`），所以 PaySrc 绕过了 T1。已转给负责 payload 的 agent 修，修完重跑这组对比。
  - 这正是 assume-guarantee 应该系统性抓住的一类问题：两个组对同一事件的建模位置不一致。
- **TLC 的一个怪行为：** 在部分组合里，TLC 恰好在坏状态上求值不变式时抛 cast 异常，于是这次运行记成 error 而不是 violation。我核对过这些 error 的最终状态，都正是 H30 坏状态（`fatal ∧ done`）。`run_mc.py` 现在把这种情况记为 `violation_evalerror` 并保留 trace。
- **多轮支持（S02 进入完整组合）**还在由 agent 做，结果出来后补进这里。

## 8. 第三轮（11-04 03:00–05:40）：通用性质、模型修正、自由组合加固

- **自由组合的现状：** 默认的 `spec/Mix.tla` 现在包含全部 20 个变体（9 个组各有 C/F，Net 有 R/L），全局组合有 2^9 × 2 = 1024 种。可按 site 拆的组还能在不同 site 选不同粒度。只有 bounded 精化证据的变体（TaskCJ/F、CommSJ/F、WfSJ/F，registry 标 `"wip"`）也默认可选，`gen_mix.py` 每次都会列出来；`MIX_EXCLUDE_WIP=all` 可以排除。
  - 演示：6 个任意组合，2 site（全粗、全细、两种交替、两种 per-site 混合，Net R/L 都有），开 cjCrash+taskTimeout+abort 和 6 个定时器，simulation 深度 100，每个 150 秒。全部能组合运行，各 938–4,582 条 trace，无违例（`checks/sweeps/demofree.jsonl`）。
- **assume-guarantee 扩到第二个组 RunCJ**（`spec/Env_RunCJ.tla`，`AG_RunCJ`，`DESIGN.md` §2.1）：
  - harness 第一次跑，2 秒就反驳了 RefStep：我给粗 RunCJ 加的握手 guard 比细变体严。已修正。组合层的精化检查跑了 290 万状态，没走到这个交错。
  - 修正后 harness 全部穷尽通过：1 site 2 launch 10,911 状态；加 cjCrash/netLoss/slowSJTeardown 86,973；2 site 867,245。负控按预期失败。
  - 在 5 个组合里模拟检查 `AG_RunCJ` 和 `AG_Trainer`：每个 2 site、2 launch、12 个故障/定时器，240 秒，没有违例（bounded 证据）。
- **其他精化复查**（修模型后重跑，都是截停、无违例）：JobSP 530 万状态，JobCP 290 万，WfSJ 220 万，RunCJ 290 万。payload 两边在 harness 里穷尽通过（最多 237 万），负控都失败。
- **GPT review 的 4 条：**
  1. per-site PayRcv 关掉全局 shutdown：已修，`gen_mix` 计算 SiteSplittable，PayRcv 不可拆。
  2. DS shutdown 没有调用-返回握手：已修，端口加 `tx.shut` / `rx.sjDown`，RunCJ 发 STOPPED/退出和 SJ 退出都等 shutdown 返回。
  3. 任意组合的精化保证：部分完成，assume-guarantee 已覆盖 Trainer、RunCJ，其余组未做。
  4. trace 检查缺 identity/状态匹配：未做。
- **通用性质（不带 Phase 1 假设）的 sweep 找出的全是模型问题，已修：** kill 没落到 SJ 上；poll 预算导致假 hang；restart 到上限时 hang；定时器被当成可选故障；粗 JobSP 启动失败分支在 job 跑完后还能触发；SJ panic 被当成正常退出（真实代码判 `FINISHED_EXECUTION_EXCEPTION`）；粗 JobCP 心跳发得太晚。修完后全粗 1-site BFS 搜了 790 万状态，没有违例（截停）。
- **abort-race 候选降级为 model-only、时序不现实**（`checks/findings/ABORT_classified_completed.md`）：反例要求 `mark_run_aborted` 比 10 秒 graceful wait 还晚；定向 sim/BFS 去掉 900 秒 outcome 超时后都没再找到。新增时序假设 T2（`slowAdminStop` 可解除），并把 `abortCmdError` 从 `abort` 拆出来。
- **截至此时，没有独立发现且在真实代码上确认的 bug。** S02、H30 子结论的证据都来自 Phase 1 的假设（见 §2）。
- 在跑：bfs4（单 site，每次细化一个组 + 全粗，77 个 run）、sim100c（2 site per-site 两两覆盖，深度 100，60 个 run）。它们用的是 RunCJ 修正前的快照，粗 RunCJ 会漏掉"在迟到注册和它被关闭之间退出"这一种交错。

## 8. 第三轮（11-04）：通用性质 sweep、模型修正、rarity 预算

**sweep 结果（只统计修正模型之后的）**
- bfs4：77 个 BFS run，11 个组合（全粗 + 每次细化一个组）× 7 种故障场景，1 site，每个 600 s。全部跑满预算停止，没有违例。
- sim100c：60 个 simulation run，2 site，per-site 两两覆盖，深度 100，共约 34 万条 trace。全部跑满预算停止，没有违例。
- 这些都是有界检查，不是证明。

**独立候选**
- abort race（管理员 abort 的 job 被判 COMPLETED）由通用性质 `GFinishedNoAbnormalExit` 报出，Phase 1 里没有。
- 对照源码后降为 model-only、时序上不现实：`abort_app_on_server` 返回后立即执行 `mark_run_aborted`，而 SJ 至少要过 10 s graceful wait 才会被移出 `run_processes`（`checks/findings/ABORT_classified_completed.md`）。
- 为此加了时序假设 T2，并把 ABORT 命令出错拆成单独的 fault `abortCmdError`。

**修正的模型问题（都是模型错误，不算发现）**
- 粗 JobSP 在 job 跑完后仍可触发"启动失败"。
- SJ panic 被当成正常退出；真实代码是 `FATAL_SYSTEM_ERROR` → `execution_error` → `FINISHED_EXECUTION_EXCEPTION`。
- 粗 JobCP 的心跳发得太晚。
- 粗 PayRcv 的 fatal 判断太宽，改了两处：只由自身 DS shutdown 导致的失败是 typed cancel，不 fatal；SJ 的 shutdown 对接收端是原子的。
- DS shutdown 调用-返回握手：GPT 第 2 条，加上外部 review 指出的"返回过早"。CJ 的 `shutdown()` 要等 inline 同步清理（`transaction_done(DELETED)` + `_sync_termination_marker`）跑完才返回。
- 每项修改后都重跑了精化检查：payload 的无故障检查穷尽通过；JobSP、JobCP、RunCJ、WfSJ 跑满预算停止，没有违例；负向检查都按预期失败。

**rarity 预算（DESIGN.md §7）**
- 每种故障按 −log 概率定价，路径总价不超过 K。条件式的故障许可（粗动作、时序假设的逃逸）按"去掉付费故障后这一步是否仍然允许"自动计价。
- 新增时序假设 T3：迟到的 envelope 在 SJ 关闭 DS 之后才开始 decode，对应 `slowEnvelope`。依据是 H30 POC 实测。
- **校准**（细化 PaySrc/PayRcv/RunCJ/WfSJ，只开 H30 相关故障）：
  - K=2 时 10 分钟内找不到；
  - K=3 时 34 秒找到 H30，代价 3：提前结束本轮 +1，CJ 先于 SJ 关 DS（违反 T1）+2；
  - 不设上限时也是代价 3，用时 92 秒。
  - 这和真实 POC 的结论一致：H30 需要异常时序。
- **盲跑**（36 个故障全开）：
  - 全粗组合在 K=1 时很快报出反例，查明都是粗模型过近似，已修；
  - 细组合在 K=1–5、每档 15 分钟内都没有违例；
  - 预算让 simulation 更集中：同一条反例，K=1 一分钟就找到，不设上限时 10 分钟都没找到。

**目前的结论**：model checking 尚未独立发现新的、在真实代码上确认的 bug。它的作用主要有三方面：
- 暴露模型与真实代码的不一致；
- 把已知假设变成跨组的具体路径；
- 给出可比较的"现实代价"。

## 9. 第四轮（11-04 16:20–22:24）：三方会诊、v4 模型、4 小时 hunt4

**会诊结论**（A 完整性 / B 效率 / C 召回，`.tmp/discuss/*.md`）：主要是搜索效率问题，其次才是模型缺口。
- 旧 sweep 的随机 trace 几乎都在 job 启动前就结束：sim100c 式配置下只有 0.4% 的 trace 启动了 SJ。
- 用已知答案的问题做召回测试：模型能表达的 10 项里，盲跑找回 3 项，放宽配置后找回 7 项。
- 45 条 hazard 里有 24 条模型里没有。

**一个影响以往结果的工具问题**：旧 TLC 2.20（`lib/tla2tools-2.20-old.jar`，和 `~/Specula/lib` 里的是同一个构建）在 simulation 找到违例后，worker 会在重建 trace 时崩溃，run 随后挂起，违例丢失。
- 历史日志里有 16 个 run 是这样，其中 7 个是 blind2，当时都被记成了 budget_stopped。
- 已换成 2026.09 nightly；`run_mc` 现在把这种情况记为 `worker_exception`。

**v4 修改**（DESIGN.md §8）：
- 建模能力：profile 开关（`wfTolerant`、`lossBudget3`）；`trainerError`；故障降频；已知发现过滤（不变式层面的 K 形式，再加上 deadlock 检查里的 `KnownStuck`）。
- 新增性质和工具：`GDoneSavedCompleted`；`PropsMR`（多轮版端口不变式）；`hunt.py`。
- 模型错误修正（6 处）：
  1. JobCP 两个变体都不等 server 回复就从 outcome 上报返回，导致完成的 job 被心跳判失败，新增 `outcomeSeen` 端口；
  2. WfSJ 每轮端口字段的重置时机；
  3. 粗 CommSJ 对同一提交回复两次；
  4. 丢包后用同一 key 重发同样的消息；
  5. TaskCJ 重试到上限被误判成 hang；
  6. `trainerStall` 没有任何动作读取。
- 性质修正：`GTerminalNoLiveSJ` 排除 FAILED_TO_RUN 的异步清理窗口；两条 seed 回执性质的语义写偏了（RECEIVED 表示 server 收到，不表示 workflow 接受），不再用于 hunt。
- 每次修改后都重跑了精化检查：Trainer harness 穷尽通过；Trainer、CommSJ（两次）、JobSP、JobCP、WfSJ 的混合级检查跑满预算、没有违例；负向检查都按预期失败。

**hunt4**：102 个 run（另有 8 个补跑），18:10–22:24，共约 40 run·小时。

| 跑法 | run 数 | 跑满预算 | 违例 | 规模 |
|---|---:|---:|---:|---|
| S 降频深 simulation（T=20/200，深度 800–1500） | 66 | 64 | 2 | 64,932 条 trace，1.28 亿状态 |
| P per-site 混合，降频 | 6 | 6 | 0 | 2,629 条 trace |
| B rarity BFS K=1（L2 或 A2） | 10 | 10 | 0 | 2,885 万 distinct |
| R rarity BFS K=2 | 5 | 5 | 0 | 2,246 万 distinct |
| C 不降频对照 | 3 | 3 | 0 | 5,194 条 trace |
| A AG 性质（4 个 AG_*） | 3 | 3 | 0 | 2,007 条 trace |
| X 重跑被 TLC 2.20 吞掉的 run | 10 | 10 | 0 | 3,460 条 trace |

- 实例：2 site / 2 launch / 2 轮 30 个，2 site / 2 轮 25 个，1 site / 2 launch / 2 轮 21 个，其余是较小的实例。
- 故障按 tail、restart、net、job、task 分类开，另有一组全开。
- 都是有界检查，跑满预算停止不算证明。
- campaign 中途修过两处模型错误；在那之前完成的 run 用的是修正前的模型。

**发现（按口径分开）**

| 发现 | 新于上游 | 新于 Phase 1 | MC 盲跑独立找到 | 证据 |
|---|---|---|---|---|
| C1：启动失败路径的 FAILED_TO_RUN 覆盖了 completion 线程已经发布的终态（`job_runner.py:760-800` 只排除 ABORTED，`495-506` completion 线程会处理仍在 `running_jobs` 里的 job） | 是（和 #5301 同属不做 CAS 写状态这一类） | 是 | 是（2 次） | model-only，有源码锚点；要求 RUNNING 写入出现 storeError 且 SJ 已退出，现实中可能性低 |
| H19 类问题出现在重启路径：重启提交抛异常，但后端可能已经接受，于是 CJ 还活着时资源就被释放（`client_executor.py:771-776` 的注释也承认这一点） | 否（上游 #5559，未修） | 是（Phase 1 只列了初次 launch 的情况） | 是 | model-only，算 MC 重新发现的已知类问题 |
| H21、#5301 | 否 | 否 | 是（冒烟测试和 campaign 头几分钟） | 已知 |
| 判为设计行为：H33（outcome 缺失或 grace 到期后 job 失败）、STOPPED 之后的崩溃按 ok 处理、FAILED_TO_RUN 之后 SJ 异步退出、迟到结果也拿到 RECEIVED | — | — | — | 不计入发现 |

- 汇总：新于上游 1 个（model-only）；新于 Phase 1 2 个（都是 model-only）；MC 重新发现的已知问题 3 个；新发现且在真实代码上确认的 0 个；模型错误 6 处，性质错误 3 类。
- C1 反例：`checks/findings/C1_failed_to_run_over_terminal.log`。

**结论**：
- 效率问题解决之后，trace 已经能走到 job 收尾和多轮：B 实测，降频 1/20 到 1/200 时，57–97% 的 trace 启动了 SJ 并进入第一轮；全细组合不开故障时 304 步走到 FINISHED，而 hunt 的深度是 800–1500。trace 的平均长度不能当证据，因为 deadlock 模式下终态之后会一直 stutter 到深度上限。
- 在这个前提下，4 小时里能报出来的问题主要是两类：模型自身的错误，以及已知类问题的新路径。真正新的候选只有 C1，而且触发它需要很不现实的组合。
- 剩下没找到的部分，主要落在模型缺口上（A 的前 10 项：SJ→CJ 方向的 payload、每次重试新建 tx、Attach 模式、SAG、多 job 等），而不再是搜索效率。

## 10. 第五轮（11-05）：C1 代码级确认、补模型缺口

**C1 在真实代码上复现**（`checks/confirm/c1_repro.py`；pin `c411a201`；2026-11-04 的 upstream main `3083649b` 里 `job_runner.py` 与 pin 完全相同）：
- 用的是真实的 `JobRunner.run()` 和它的 completion 线程；engine、job store、scheduler、workspace 是假的，部署步骤直接跳过。只在 RUNNING 那次写入注入存储异常，调度用 event 强制。连跑 3 次结果相同。
- A：RUNNING 写入卡住后抛 EIO；在这期间 completion 线程发布了 `FINISHED:EXECUTION_EXCEPTION` 并触发 `_job_completed`；随后 except 分支写入 `FINISHED:FAILED_TO_RUN`，又触发 `_job_aborted`。这就是模型反例的路径。
- A2：同上，但 job 很短，在卡住期间正常结束：`FINISHED:COMPLETED`（产物已归档）被改写成 `FAILED_TO_RUN`。
- B（核对源码时发现的同源后果）：RUNNING 写入在 completion 线程归档 workspace 时抛异常，except 分支先删掉了 `running_jobs[job_id]`；completion 线程随后执行 `del self.running_jobs[job_id]`（`job_runner.py:583`，没有保护），抛 KeyError，整个线程退出。之后一个完全没有故障的 job2 一直停在 RUNNING，永远不会收尾。
- 对照组（不注入故障）：job1 正常记为 `FINISHED:EXECUTION_EXCEPTION`，job2 记为 `FINISHED:COMPLETED`。
- 上游：没有相关 issue。同族的 #5301（我们提的，迟到的 RUNNING 覆盖终态）在 2026-09-15 以 NOT_PLANNED 关闭：维护者确认可达，定为 P3，理由是复现需要人为控制时序，也没有证明存在能让终态抢先的存储故障。C1 需要的正是存储故障，但仍然需要时序配合。
- 证据级别：REPRODUCED（强制调度，注入存储故障）。B 的影响（completion 线程退出，后续所有 job 都不收尾）是单 job 模型表达不了的，这也是 A 缺口 10（多 job）的一个具体理由。

**H08 在真实代码上复现**（`checks/confirm/h08_repro.py`；Phase 1 排名第 1 的候选，之前没有确认过；上游没有相关 issue）：
- 用的是真实的 `GPUResourceConsumer.consume`、`JobExecutor._launch_job` / `_restart_job`、`_JobRestart`、`ProcessJobLauncher.launch_job` 和 `ProcessHandle.can_restart`，并且真的启动子进程；只把 GPU 探测、engine、workspace 和 CJ 的启动命令换掉（子进程只记录它看到的 `CUDA_VISIBLE_DEVICES`）。没有强制调度。
- 过程：job A 拿到 GPU 0 并启动 CJ；随后同一个 CP 上的 job B 拿到 GPU 1；A 的 CJ 以 EXECUTION_ERROR 退出后被重启（`max_cj_restart_failures` 默认是 3）。结果：A 的第二代 CJ 拿到的是 `CUDA_VISIBLE_DEVICES=1`，也就是 B 的 GPU。
- 原因：START 处理会把分配写进进程级的 `os.environ`（`gpu_resource_consumer.py:34`）；每次 spawn 都会复制当时的 `os.environ`（`process_launcher.py:130`）；而重启路径（`client_executor.py:722-758`、`375-415`）不会重新 consume。
- 前提：GPU 资源管理器、server 的 `max_jobs` ≥ 2、in-process trainer（重启门槛默认就能通过）。

**H11 在真实代码上复现**（`checks/confirm/h11_repro.py`；Phase 1 第 8 名，之前标为 candidate-test；上游没有相关 issue；2026-11-04 的 main 上 `wf_comm_server.py` 与 pin 相同）：
- 用的是真实的 `WFCommServer`、`Task`、`ClientTask`、task manager 和 `_monitor_tasks` 线程，只有 engine 是假的。不需要强制调度，也不需要注入故障：只要有两个目标互不相交、同时挂着的 task，再加上一次 GET_TASK 重试（回复丢失或 CJ 重启都会导致重试）。`send` 方式和 `cse_server_ctl.py:186-193` 的 broadcast 方式都能复现。
- 过程：task A 发给 site-1，task B 发给 site-2；site-1 拿到 A，回复丢失，于是重新请求，拿到的是 A 的重发。结果：A 的 `client_tasks` 里同一个 ClientTask 出现了两次；A 收尾时 monitor 线程 `wf_task` 抛 KeyError 退出；之后 site-2 交回 B 的结果，B 也一直不会完成，standing task 数始终是 1。
- 原因：在 `wf_comm_server.py:246-277` 的循环里，重发分支没有 break，下一个 task 的 NO_BLOCK 会把 `resend_task` 重置，于是发送块（366-375）把旧的 ClientTask 又追加了一次；task 退出时，第 1259 行的 `_client_task_map.pop(id)` 没有默认值，第二次 pop 抛出 KeyError，而 `_monitor_tasks` 没有异常处理。
- 后果：client 控制的 CSE（`cse_server_ctl.py:196`）会在 `while get_num_standing_tasks() > 0` 处一直等下去；task 超时、dead client 检查也都停了，job 只能手动 abort。

**补模型缺口（v5，DESIGN.md §9）**：A 列了 10 项。下面按处理结果分开列：
- 已补（四个 profile 开关和两类线程退出）：
  - `nonStrictStart`：NVFlare 默认的非严格 START 回复检查。它会把 START 回复超时的 site 从 active sites 里去掉，端口上用 `startDropped` 记录这些 site。
  - `otherJob`：同一个 CP 上的第二个 job，会改写 CP 全局的 GPU env（H08）。
  - `errResilient`：FedAvg 的 `ignore_result_error=True`。
  - `cseTasks`：目标互不相交、同时挂着的多个 task（H11）。
  - 线程退出：completion 线程退出（C1-B）和 task monitor 退出（H11）都按真实代码建模为线程退出，不再是"卡住"。对应端口标志和两条通用性质 `GCompletionThreadAlive`、`GTaskMonitorAlive`。
- 未补，原因写在 DESIGN.md §9：
  - SJ→CJ payload：CJ 下载失败只会重新 GET_TASK。
  - 每次 try 新建 tx：server 按回执去重，H31 在 Phase 1 里只是契约基线，而改动要重写 PaySrc_F 的键。
  - 显式 ref 复用：只出现在特定 API 用法里。
  - SAG：H04 还在代码里，但它是 SJ 内部的问题，helper 也在文档里写明不回滚，直接在代码上验证更省事。
  - Attach、client sampling、SP/CP 进程重启、完整的多 job：这一轮没有做。
- 模型错误，冒烟阶段发现，已修，2 处：
  - JobCP_F 的重启分支覆盖了 START 处理线程的 pc，导致 START 回复永远发不出去；
  - JobSP_C 的 Terminate 允许"不杀进程"的分支作用于一个还活着的 SJ。
- 我自己写错、被精化检查抓到的 1 处：第一版非严格 START 的粗变体把"评估回复"和"过滤 pending"合成了一步。真实代码在这两步之间有窗口，期间到达的 OUTCOME 仍按 pending 处理；粗变体已改为两步。
- 精化检查：改动后每个组都重跑了，全部跑满预算、没有违例（JobSP 三个配置分别 9.7M、5.2M 状态，JobCP 5.1M，CommSJ cseTasks 2.6M）；负向检查都按预期失败。

**hunt5**（11-05 04:50–07:16，57 个 run，21.3 run·小时）：

| 跑法 | run 数 | 跑满预算 | 违例 | 规模 |
|---|---:|---:|---:|---|
| S 新 profile 族，降频深 simulation，已知发现过滤 | 36 | 33 | 3 | 32,917 条 trace，7,987 万状态 |
| D 盲跑重新发现（不过滤 C1-B、H11、H08） | 10 | 4 | 6 | 5,217 条 trace，1,743 万状态 |
| O v4 的五个故障族跑在 v5 模型上 | 5 | 5 | 0 | 3,930 条 trace，956 万状态 |
| B rarity BFS（K=1） | 6 | 6 | 0 | 2,113 万 distinct |

另补跑了 18 个 H08 重新发现 run（`hunt5h08*`），见下面 H08 一条。

- D：C1-B 被盲跑独立找到 4 次，H11 被找到 2 次。两条 trace 的机制都和真实代码上的复现一致，不需要定向约束。
- H08：第一批 6 个 run 都没碰到。原因是"其他 job 写 env"在模型里只能发生一次，随机模拟往往在我们的 START 之前就用掉了。改成"env 不是 B 的就可以再写"之后，6 个 run 都在 3–15 秒内找到 H08，但走的都是 START 处理期间被插入的那条路径，而它依赖"server 等 START 回复超时"这个计价的时序逃逸。去掉 rpcTimeout 后，5/6 个 run 在 5–22 秒内找到了重启路径，正是真实代码上复现的那条。
- S 的 3 个违例：2 个是 C1 的反方向（start 失败路径先写 FAILED_TO_RUN，completion 线程再覆盖），属于已复现的 C1-B；1 个是之前已判为时序上不合理的 `ABORT_classified_completed`，靠 `slowAdminStop` 时序逃逸才能到达。K 过滤已扩展到 C1 的反方向。
- 冒烟阶段的 lead N1：在非严格 START 下，START 回复超时的 site 的失败 OUTCOME 会被 server 丢弃（`fed_server.py:943-945`），job 可能以 COMPLETED 结束。属于 H32 类（Phase 1 契约基线）；model-only，有源码锚点；已用 K11 过滤。

## 11. 第六轮（11-05）：后台线程异常退出排查、模型优化、8 小时 model checking

**线程排查**：逐个检查了 SP、SJ、CP、CJ 上的长期线程，看循环体里是否有没被异常处理覆盖的调用：job runner 调度循环、completion 线程、task monitor、SJ waiter、abort cleanup、client cleanup、CP child waiter、CP 和 CJ 的心跳、download service 的 tx monitor。其中 task 收尾回调、`get_return_code`、tx monitor 的用户回调、CP 上报路径都有保护。新发现 3 条，都在真实代码上复现了，上游没有相关 issue，main 上的相关文件和 pin 相同：

| 线索 | 现象 | 复现方式 | 后果 |
|---|---|---|---|
| T1 | 1 秒一次的调度扫描先列出 job 再逐个读 meta（`job_def_manager.py:517-531`），没有异常处理；被删掉的排队 job 会让 `get_meta` 抛 StorageException，而调用发生在 `JobRunner.run` 的 try 之外（`job_runner.py:703`） | `t1_repro.py`：真实的 JobRunner、SimpleJobDefManager、FilesystemStorage，不做强制调度。300 个排队 job 时一次扫描约 26 ms，每次删除约 2.6% 的概率触发，3 轮分别在第 4、159、15 次删除时触发；20 个 job 时扫描约 2.2 ms，随机删除 240 次一次也没触发 | 调度线程退出，之后 server 再也不调度任何 job，直到重启 |
| T1-b | 部署期间 job 仍是 SUBMITTED，`delete_job` 允许删除（`job_cmds.py:518`）；部署完成后，try 里的 `_check_job_status` 抛 AttributeError，except 分支第 794-797 行的 `_check_job_status` 又抛同样的异常，没有处理 | `t1b_repro.py`：真实的 `run()` 及其 except 分支；部署用 stub（耗时 2 秒），期间做一次真实的删除。2/2 次确定性复现 | 同上，而且窗口是整个部署过程（秒级） |
| T2 | 网络中断后几个 client 同时超时又重连。`remove_dead_clients` 先列出死 client，再逐个 logout；处理一个死 client 时，`fail_run` 会向各方发 abort（数秒），这时另一个 client 重新登录，旧 token 被弹出，`remove_client` 返回 None，`notify_dead_client(None)` 抛 AttributeError（`fed_server.py:309-321, 1114`），`client_cleanup` 没有异常处理 | `t2_repro.py`：真实的 `ClientManager.authenticate` 和 FederatedServer 的 cleanup、logout、notify 路径；job runner 是 stub，`fail_run` 耗时 2 秒，代表 abort 往返。3/3 次复现 | 之后死掉的 client 永远不会被移除 |

另外注意到：`remove_dead_clients` 遍历的是 ClientManager 内部的 dict，没有加锁；`notify_dead_client` 也直接遍历 `run_processes`。并发注册或 job 退出时，两处都可能抛 "dictionary changed size during iteration"。这两处没有单独复现。

**进程重启排查**（也都在真实代码上确认了，上游没有相关 issue）：

| 线索 | 现象 | 复现方式 | 后果 |
|---|---|---|---|
| R1 | SP 重启时的恢复函数 `update_abnormal_finished_jobs`、`update_unfinished_jobs`（`job_runner.py:852-883`）在整个代码树里都没有调用者，GitHub 上的 main 也一样 | `r1_repro.py`：存储里留着崩溃前写下的 RUNNING；新启动的 JobRunner 照常运行；管理命令走真实的 `JobCommandModule` | 被打断的 job 永远停在 RUNNING：`abort_job` 回答 "is not running"，`delete_job` 回答 "is running, could not be deleted"，结果也下载不了。对照组的 DISPATCHED 还能 abort |
| R2 | CP 重启后重新登录会拿到新 token，旧 token 被静默移除（`client_manager.py:330-339`）；`_sync_client_jobs`（`fed_server.py:1013-1084`）只按 job 启动时的参与者 token 匹配，所以对不上，SJ 永远收不到 dead-job 通知 | `r2_repro.py`：真实的 `ClientManager.authenticate` 和 `_sync_client_jobs`。对照组（CP 不重启、CJ 退出）每次心跳都会通知；CP 重启后通知 0 次 | SJ 一直在等这个 client 的结果，而 FedAvg 的 task 默认没有超时，job 卡住，只能用管理命令手动处理 |

**trace validation**（DESIGN §6，这一轮把工具修好了）：
- 修了两处：一是静默步上限从 10 提到 120，细变体两个可观测事件之间最多有 100 步左右的内部步；二是允许一步对应 3 个观测事件，因为 `ServerRunnerEndRun` 在同一步里置 done 并广播两条 END_RUN，真实代码也是一次 aux broadcast。
- 结果：真实 POC trace（120 步，其中 68 个端口事件）在全细组合上被接受。BFS 会因为静默步的交错爆炸而跑不完，所以接受是用随机模拟找到的一条完整匹配。全粗组合和两种交替组合也都接受。
- 负例：把 `SendStart` 挪到 `ServerLaunch` 之前，全粗组合在 BFS 下穷尽拒绝。

**hunt6**（11-05 17:20 至 11-06 00:29，墙钟 7 小时 9 分，155 个 run，75.1 run·小时；没有 worker 异常，结束后没有残留进程）：

| 跑法 | run 数 | 跑满预算 | 违例 | 规模 |
|---|---:|---:|---:|---|
| S 11 个故障族，降频深 simulation，已知发现全部过滤 | 120 | 120 | 0 | 135,154 条 trace，3.20 亿状态 |
| L 3-site 实例（simulation） | 12 | 12 | 0 | 9,499 条 trace，4,008 万状态 |
| D 盲跑重新发现 T1、R1、R2 | 8 | 0 | 8 | 156 条 trace |
| B rarity BFS（K=1、K=2） | 15 | 15 | 0 | 9,389 万 distinct |

- D 的 8 个 run 都找到了要找的问题：T1 4 次、R1 2 次、R2 2 次（R2 表现为 deadlock）。我核对了 R2 的两条 trace，机制一致：CP 重启，CJ 随之退出，SJ 那一轮的 task 一直挂着，没有任何 dead-client 通知，job 停在 RUNNING。
- 把已知发现过滤掉之后，S、L、B 三类共 147 个 run 没有报出任何新违例。这两轮的新 bug 都是先做代码排查（线程异常退出、进程重启），再补进模型的。
- **更正（§12）：** 当时我据此判断"盲跑已接近饱和"，这个结论不成立。事后测量表明，hunt6 的搜索基本没有到达 job 的运行和收尾阶段：T=20 的模拟大多在 RUNNING 之前就因故障结束，BFS 也没到 job 结束的深度。所以 0 个新违例只说明启动阶段没有问题。

## 12. 第七轮（11-06）：状态空间诊断、v7 搜索改造、hunt7

**诊断**（`.build/x7/`；导出 hunt6 原配置的模拟 trace，每组 64 条，逐条看 job 何时进 RUNNING、何时进终态；另跑无故障 BFS 求最短路径）：

| 问题 | 测量 | 原因 |
|---|---|---|
| 节流 T=20 下 job 活不到 RUNNING | 细 JobSP 的族（allP、proc、restart、job）只有 0–15/64 条 trace 到 RUNNING；T=200 时是 43–53/64 | 节流按步抽签（每步 1/T），而 abort、delete、CHECK 超时、丢包几乎每一步都可用；稀有度权重是按"发生一次"定价的，所以长时间可用的故障被大量过度采样 |
| BFS 到不了 job 结束 | 无故障最短路径：到 RUNNING 14/20/39/53 步（全粗 1 site/2 site、全细 1 site/2 site）；到终态全粗 1 site 69 步，其余超过 58–129 步还没到。hunt6 B 轨停在 30–60 层 | 启动阶段很小（全粗 1 site 前 47 层只有 4,095 个状态）；宽度爆炸在 RUNNING 之后，每层约 ×1.4 |
| RUNNING 之后的宽度爆炸 | 新状态主要来自收尾阶段各组件的关闭顺序、任务轮询、SJ 工作流启动的一串内部步骤 | TLC 没有偏序规约，独立的内部步骤每种顺序都是新状态；网络是只增不减的消息历史，路径不同的状态永远不会合并 |
| 细 JobSP 的调度器空转 | 58–93% 的模拟步数在 job 终态之后，其中 99% 是 BeginPass/ReturnPass/EndPass；按墙钟只占 5–30% | job 结束后调度扫描还能无限转圈 |

- TLC 模拟日志里的 `trace length mean` 不可信：tail 族实际 trace 中位 134 步，日志报 1435。
- **定价漏洞（这一轮发现，"不现实的时序"的一个实例）：** client 端的 get-task 超时、task-check 超时、等回执超时，以及有损网络下多出的一次轮询，本该按 netLoss/submitTimeout 计价，实际都是免费的。
  - 原因是 TLC 会预先计算共享模块里零参数的常量定义（`FedLossy`、`FedMaxPoll`、`FedMaxTry`），在 `INSTANCE ... WITH Faults <- NormalFaults` 的定价实例里仍沿用那个值，替换不生效。我用三个模块的最小例子确认了这一点（`.build/x7/toy`）。
  - 后果：client 可以在回复到达前立刻超时、重新轮询，几次就用完轮询上限，trace 停在 AtBound。受影响的是含 netLoss/submitTimeout 的族（tail、net、cse、err、allP）的所有带节流或预算的 run，包括 hunt5、hunt6。
  - 没有造成假反例；之前报告的 bug 和 N1 都不依赖这几步。
  - 修法：三者改成以故障集为参数的算子（`FedLossyIn(Faults)` 等）。模型本身的行为不变，只影响定价。
- 已知的三处时序前提 T1–T3 仍然有效：默认禁止，由 `slowSJTeardown`/`slowAdminStop`/`slowEnvelope` 放开并按最高权重计价。模型里没有时间这一根因还在。

**v7 改动**（DESIGN §11；模型行为不变，只改搜索）：
- **按阶段放行故障：** `spec/JobPhase.tla` 用端口定义 7 档进度。每条模拟 trace 开始时随机抽一档，到达之前拒绝计价步和只为驱动故障机制的免费步（如 30 秒时钟 tick），之后按 1/T 放行；每条 trace 的稀有度预算为 4。
- **检查点 BFS：** `scripts/ckpt.py` 用同一组合、同一故障集、预算 0 模拟到某一档，取那个状态作为 BFS 初始状态。hunt7 为 11 个族各采了阶段 2–5 的检查点，每个 2 份。
- **去掉调度器空转：** 没有 SUBMITTED job 时不开始扫描。
- **TLC 线程栈加到 64 MB：** 去掉空转后，什么都不可用的状态上 TLC 要沿 532 个动作的 `\/` 链递归到底，默认栈会溢出。

**验证：**
- 按阶段放行（T=20，每组 48 条 trace）：到 RUNNING 的比例从 0–15/64 升到 27–33/48；终态之后的步数降到 2–15%。第一个故障的位置随抽到的阶段变化，例如 proc 全细 2 site 各档的中位数为 16、33、95、364、501、875 步。
- 检查点 BFS：proc 族从阶段 3 出发，K=1，5 分钟 44 万状态无违例；R1 在 3 秒（深度 8）、R2 在 5 秒（深度 21）重新找到，机制与原来一致。
- JobSP 细到粗精化复查跑满预算（586 万状态）无违例；全细组合上真实 POC trace 仍被接受（40 秒）。
- hunt7 冒烟 31 个 run：28 个无违例，3 个盲跑重新发现（T1 ×2、R1）全部命中，没有 worker 异常。
- 代价：按阶段放行后每一步更贵（tail 族每 worker 每秒 2.8 步，hunt6 的配置是 16.6 步），因为 trace 现在大部分时间处在多个组件同时活跃的阶段；全细 2 site 一个 job 要约 900 步才到 end-run。

**hunt7**（11-06 05:49 至 10:25 UTC，墙钟 4 小时 36 分，130 个 run，35.9 run·小时；没有 worker 异常，结束后没有残留进程）：

| 跑法 | run 数 | 违例 | 规模 |
|---|---:|---:|---|
| S 按阶段放行的深度模拟，11 个故障族，已知发现全部过滤 | 60 | 0 | 3,679 条 trace（每条走完整个 job），3,102 万状态（TLC 计数） |
| L 3-site 实例 | 6 | 0 | 231 条 trace |
| D 盲跑重新发现 | 8 | 8 | T1 ×4、R1 ×2、R2 ×2，新的搜索方式没有丢掉旧发现 |
| C 检查点 BFS（阶段 2–5，K=1；6 个族加 K=2） | 56 | 0 | 7,029 万 distinct；从检查点往后 14–63 层；4 个穷尽 |

- 穷尽的 4 个（在"从该阶段出发、最多 1 个故障"的范围内无违例）：tail 族 end-run（20.7 万状态）、job 族第 2 轮（1.2 万）、err 族 end-run（22.8 万）、del 族第 2 轮（93.0 万）。
- 局限：2 site 全细的族（cse、allP）从检查点只往后走了 14–18 层；故障要很久以后才显现的后果（比如收尾时的 hang）只有 S 轨覆盖。
- 结论：这次搜索真正到达了运行和收尾阶段，在当前模型能表达的范围里仍然没有新违例。和 hunt6 不同，这个"没有"现在有覆盖数据支撑，但仍是有界证据。
- 我的一个操作失误：等待 hunt7 结束的循环用了 `pgrep -f`，匹配到了自己，所以 hunt7 在 10:25 结束后我过了约 4 小时才发现。结果本身不受影响。

**同时做的代码排查**（只读源码，没有改 spec）：
- **T3（REPRODUCED，强制时序；`checks/confirm/t3_repro.py`）：** `notify_dead_client`（`fed_server.py:1118`）遍历 `engine.run_processes` 时没有拿 `engine.lock`，而循环体里的 `send_command_to_child_runner_process` 要拿这把锁。另一个 job 的 SJ 退出时，`wait_for_complete`（`server_engine.py:219-234`）会在锁内 pop 掉一项；循环继续时抛 `RuntimeError: dictionary changed size during iteration`，`client_cleanup` 线程退出，之后死掉的 client 不再被移除。对照组正常；强制时序（锁内停 50 ms）必现；自然时序下 job B 在通知前后 ±10 ms 内退出，300 次里 4 次触发。§11 当时已注意到但没有复现。后果和 T2 相同，根因不同。
- 其余 6 处遍历共享字典的地方（cellnet、job runner、task monitor 等）读写都在同一把锁下。
- SJ 心跳早于登记导致误杀：排除，各 launcher 创建完进程或 pod 就返回。
- **时序清单**（`notes/timing-inventory.md`，16 项，时序 spec 的底稿）：3 项带价逃逸的默认时序前提（T1–T3），8 项计价故障，2 项免费步，2 项模型里没有表达。
- **L13（只有代码阅读）：** SJ 退出时 server 最多等 2 秒的 UPDATE_RUN_STATUS（`server_engine.py:204-235`），晚到或丢失时 `execution_error` 被丢弃（`fed_server.py:595-605`），SJ 以 0 退出的话 job 记为 COMPLETED；这两段还分别用 `FederatedServer.lock` 和 `engine.lock`。没有复现，模型里还没有表达。

**按根因汇总**（截至第七轮）：

| 口径 | 个数 | 是哪些 |
|---|---:|---|
| 在真实代码上复现 | 10 | C1-A、C1-B、H08、H11、T1、T1-b、T2、T3、R1、R2 |
| 其中不需要强制调度 | 5 | H08、H11、T1、R1，R2（server 端逻辑层面） |
| 其中靠强制时序或耗时的桩代码 | 5 | C1-A、C1-B、T1-b、T2、T3 |
| 新于上游 | 9（或 10） | 都没有提交；C1-A 和我们的 #5301（NOT_PLANNED）缺的是同一个终态检查，按同一根因族算就是 9 |
| 新于 Phase 1 | 8 | C1-A、C1-B、T1、T1-b、T2、T3、R1、R2 |
| Phase 1 候选、第一次确认 | 2 | H08、H11 |
| 只有模型反例 | 1 | N1 |
| 只有代码阅读线索 | 1 | L13 |

**L13 补进模型并在代码上复现**（第七轮后续）：
- 代码级（`checks/confirm/l13_repro.py`；真实的 `FederatedServer._listen_command`、`ServerEngine.wait_for_complete`、`JobRunner._get_finished_job_status`；只有 SJ 进程句柄和消息投递时机是桩）：system_panic 之后 SJ 以 0 退出，执行出错只靠一条 fire-and-forget 的 UPDATE_RUN_STATUS 传递。对照组（消息 50 ms 到）记为 `FINISHED:EXECUTION_EXCEPTION`；消息在 SJ 退出 2.5 秒后才到、或丢失时，记为 `FINISHED:COMPLETED`。证据级别：REPRODUCED（注入消息延迟或丢失）。触发需要 SJ 到父进程的内部连接在那一刻出问题。
- 模型：新故障 `statusLost`（权重 2，和其他时序逃逸同级），只作用于"panic 后以 0 退出"的情况；细、粗 JobSP 各加一个观察 SJ 退出的分支。新通用性质 `GFinishedNoPanic`（记为 COMPLETED 的 job 没有发生过 panic）。原来的 `GFinishedNoAbnormalExit` 只排除 `"crashed"`，抓不到这种情况；模型里"panic 一定被记录"的写法是 bfs3 时当作模型错误修掉的，现在看那是真实代码会出现的结果。
- 检查：带 `statusLost` 的定向 BFS 找到违例（细 JobSP 50 层、粗 32 层，路径都是 CommSJ 策略 panic → SJ 退出 → 状态消息没到 → COMPLETED）；不带它的对照跑满 380 万状态无违例；JobSP 细到粗精化复查跑满 614 万状态无违例。
- 按根因汇总更新为：在真实代码上复现 11 个（加 L13，属于"靠注入故障"一类）；新于上游 10（或 11）；新于 Phase 1 有 9 个。

## 13. 第八轮（11-06）：补模型缺口——client 注册表与清理线程（Reg 组）

- **新组 Reg**（DESIGN §12；`spec/Reg_C.tla`、`Reg_F.tla`、`PortsReg.tla`）：SP 上的 ClientManager 和 cleanup 线程。SJ 得知 client 死亡的两条真实路径都在模型里了：cleanup 线程登出失效 token 后通知；心跳同步发现 job 不在 client 上时通知。T2、T3、R2 从此是模型自己的行为，不再在模型之外。
- **精化：** Reg 细到粗跑满 769 万状态无违例；负控按预期失败（9 层）。CommSJ 细到粗复查 123 万状态无违例；真实 POC trace 在全细组合上仍被接受（75 秒）。
- **盲跑能找回：** T2（2 site，深度 12）；T3（排除 T2 后，深度 11）；R2（CP 重启，SJ 永远收不到通知，deadlock 深度 28）。对照组（只有 CJ 崩溃，心跳同步会通知 SJ）跑满 258 万状态没有卡住。hunt8 冒烟里 S 轨的盲跑模拟也自己找到了 T3。
- **建模时抓到的一个时序假象：** 第一版允许"CP 重启让旧 token 失效"并且允许重新登录插在名单列出和第一次移除之间，于是 1 个 site 就能触发 T2。现实中 CP 几秒内就重新登录（远早于 60–600 秒的心跳超时），名单列出后第一个 token 是微秒内就处理的。改成原子步骤后，1 site 跑满 239 万状态不再出现，T2 需要两个失效 token，和真实复现条件一致。
- 新计划 `plans/hunt8.py`（加 reg、status 两个族；T2、T3、L13 的盲跑回归放在 D 轨）。C 轨的检查点要重新采集（变量集合变了）。

**第 3 项起步：Attach / external trainer 的代码核实**
- **H03（Phase 1 排名第 10，第一次确认；REPRODUCED，强制调度；`checks/confirm/h03_repro.py`）：** `ExternalProcessBackend._monitor_accepted_result_source`（`external_process_backend.py:1239-1283`）先在锁内确认 source 仍是任务 A，再在锁外判断心跳超时或连接断开；判定后调用 `_fail_accepted_result_source(trainer, A)`（这里会重新核对身份，source 已换成 B 时返回 False），然后**无条件**调用 `_stop_trainer`。两步之间如果 A 完成结算、B 被接受，monitor 会停掉正在服务 B 的 trainer，而且不发 B 的 source 失效通知。对照组（服务 A 时真的失联）：发出 refA 的失效通知、job 判失败、trainer 停止。H03 场景：trainer 在服务 B 时被停，没有任何通知，B 的接收方只能等自己的超时。自然时序下窗口是微秒级。
- **H01（Phase 1 排名第 4）：静态逻辑成立，未执行复现。** CJ 在解码确认之后、任务已关闭时回 RESULT_REJECTED 且不记录归属（`cell_backend.py:236-242`）；状态查询于是回 UNKNOWN（`cell_backend.py:281-282`）；TP 的 `_resolve_ambiguous_result`（`attach_session.py:441-467`）在 UNKNOWN 且 waiter 已 COMPLETED 时推断为已接受，`send()` 返回成功。需要两次 RESULT_REJECTED 回复都丢失；任务此时已关闭，server 本来就把这一轮记为失败，影响限于 trainer 误以为发送成功，所以优先级低。
- **上游核对**（GitHub API，只读；main = `e17c1edf6`，2026-11-05）：`external_process_backend.py`、`cell_backend.py`、`server_engine.py`、`job_runner.py` 与 pin 完全相同。`fed_server.py` 有一处改动（#5672，`_listen_command` 入口加调用方身份校验），L13 的丢弃逻辑、T2/T3 的 cleanup 路径、R2 的 `_sync_client_jobs` 都没变。所有已复现的 bug 在最新 main 上仍然存在。

**按根因汇总（截至第八轮）：**

| 口径 | 个数 | 是哪些 |
|---|---:|---|
| 在真实代码上复现 | 12 | C1-A、C1-B、H08、H11、T1、T1-b、T2、T3、R1、R2、L13、H03 |
| 其中不需要强制调度或注入 | 5 | H08、H11、T1、R1，R2（server 端逻辑层面） |
| 其中靠强制调度、耗时的桩或注入故障 | 7 | C1-A、C1-B、T1-b、T2、T3、L13（注入消息延迟或丢失）、H03（强制调度） |
| 新于上游 | 11（或 12） | 都没有提交，最新 main 上仍存在；C1-A 与 #5301 同根因族时为 11 |
| 新于 Phase 1 | 9 | C1-A、C1-B、T1、T1-b、T2、T3、R1、R2、L13 |
| Phase 1 候选、第一次确认 | 3 | H08、H11、H03 |
| 只有模型反例 | 1 | N1 |
| 只有静态代码确认 | 1 | H01 |

## 14. 第八轮续：external trainer 建模（第 3 项）与第二个 job（2b）

**第 3 项：Trainer_X**（DESIGN §13）
- 新增 Trainer 组的第三个变体，表达外部 trainer 进程（launch_once）和 CJ 端的结果接受、accepted-source monitor。H03 的微秒窗口作为带价时序逃逸 `monitorStale`（权重 3）。
- 精化 X→C 跑满 305 万状态无违例，负控按预期失败（26 层）。
- **MC 自己找到 H03**（深度 66）：发布 A → monitor 读到"失联"后被抢占 → 恢复、A 结算 → B 发布 → monitor 停掉 trainer，B 没有失效通知；与 `h03_repro.py` 一致。对照（不开 `monitorStale`）跑满 102 万状态无违例。

**2b：第二个只存在于 SP 内部的 job（profile `multiJob`）**
- 备份：`.work/v8-pre-2b-20261106-1700`（改动前）。
- 精化：JobSP 细到粗（开 multiJob）跑满 458 万状态无违例；不开 multiJob 的回归 210 万状态无违例。真实 POC trace 在全细组合上仍被接受（86 秒）。无故障的 multiJob 对照跑满 139 万状态，没有 deadlock。
- **T1 的真实场景进入模型：** 删掉另一个排队中的 job（J2），调度线程退出，我们的 job 再也不会被调度（5 步，我们的 job 没被删）。
- **C1-B 的跨 job 后果进入模型：** completion 线程在我们的 job 上因 KeyError 退出时，J2 还在运行，此后永远收不了尾（`c1_repro.py` 场景 B 里的 job2）。盲跑模拟能找到线程退出本身，但 J2 恰好还没结束的组合概率太低，600 秒内没碰到；加一个"我们的 job 结束前 J2 不退出"的定向约束后在 2,896 条 trace 内找到（81 步）。

- 冒烟（`plans/hunt8.py`，加 multi 族，allP 开 multiJob；S/L/D 共 25 个 run）：22 个无违例，3 个是 D 轨的预期找回（T1 ×2、R1），没有 worker 异常。
- **模型覆盖：** 12 个已复现的根因现在都有对应的模型行为。其中 11 个已确认 MC 能找回：C1-A、C1-B、H08、H11、T1、T2、T3、R1、R2、L13、H03。T1-b 有对应动作（`JobRunnerFailureStatusDeleted`），但没有单独确认盲跑能找回。

**2b 收尾**（按目标核查暴露的问题并修掉）：
- **trace validation 的读法：** 我们的 TV 把 `TraceNotAccepted == tpos <= Len(TR)` 设为不变式，它被违反表示游标越过了 trace 末尾，也就是接受。`gen_trace.py` 按这个打印 TRACE ACCEPTED。最终模型上：全细（模拟，103 秒）接受；全粗（模拟，11 秒）接受；把 `SendStart` 挪到 `ServerLaunch` 之前的负例在全粗上 BFS 穷尽拒绝（9 个状态）。全粗用 BFS 跑满 900 秒没走完，是没有结论，不是拒绝。
- **C1-B 跨 job 后果原来只能靠定向约束到达：** 原因是 J2 的退出是免费步，随机模拟几乎总让 J2 先结束。现实中另一个训练 job 要跑几分钟到几小时，远长于本 job 启动失败的几秒，所以把 J2 的退出计价（`rarity.json`：`JobSP_F.J2Exit`、`JobSP_C.OtherExit` 权重 1）。之后不加约束的盲跑在 T=20 和 T=50 下都找到了（1,494 / 2,934 条 trace 内）：completion 线程已死、J2 仍在运行。
- 这个后果在 deadlock 检查下看不到：其他组件还能走步，属于活锁。所以加了通用性质 `GOtherJobFinalizable`，含义是 completion 线程死后，未结束的 J2 再也到不了终态。hunt8 的 D 轨加了对应回归 `h8D_c1bmulti`。
- **C 轨冒烟：** 为 hunt8 重新采集检查点（14 个族 × 4 个阶段，56/56）；完整冒烟 40 个 run（S 14、C 14、D 6、L 6）：36 个无违例，1 个穷尽，3 个是 D 轨的预期找回（T1 ×2、R1）；没有 worker 异常。D 轨的 T2、L13、C1B-multi 在 150 秒的冒烟时长内没命中，它们的定向 BFS 和模拟此前都已找到。
- **正式时长的盲跑找回（补证）：**
  - D 轨 900 秒：T3（4 秒）、T2（569 秒）、L13（673 秒）；重跑一轮也都找回。
  - C1-B 的跨 job 后果（`GOtherJobFinalizable`）：开阶段门控时 900 秒找不到，因为它的故障发生在启动阶段，只有抽到阶段 0 或 1 的 trace 才可能触发。改为不开阶段门控、1800 秒、12 个 worker 后，753 秒内找回（1,318 条 trace）。hunt8 的这一项已按此设置。
  - T1-b：用里程碑区分它和 T1 的扫描路径，判据是调度线程在部署开始以后才死。BFS 在 23 步内找到：部署前检查 → 删除 → 部署异常 → 失败分支 → `JobRunnerFailureStatusDeleted`。用 `ACTION_CONSTRAINT` 剪掉扫描路径的第一次尝试没有生效：TLC 在检查不变式时没有先套用这个约束，反例仍是 T1。
- **模型覆盖更新：** 12 个已复现的根因现在都已确认 MC 能在模型里找回（T1-b 补上）。

**hunt8 完整一轮**（11-06 19:30 至 11-07 01:02 UTC，墙钟 5 小时 31 分，162 个 run，43.9 run·小时；没有 worker 异常）：

| 跑法 | run 数 | 违例 | 规模 |
|---|---:|---:|---|
| S 按阶段放行的深度模拟，14 个族（新增 reg、status、multi） | 76 | 0 | 4,148 条 trace，3,538 万状态（TLC 计数） |
| L 3-site 实例 | 6 | 0 | 177 条 trace |
| D 盲跑重新发现 | 12 | 10 | T1 ×4、R1 ×2、R2 ×2、T3、C1-B 跨 job；T2、L13 这一轮没命中（900 秒，此前两次正式时长重跑都命中） |
| C 检查点 BFS（阶段 2–5，K=1/2） | 68 | 2 | 7,153 万 distinct；6 个穷尽 |

- **C 轨的 2 个违例（`h8C_del_p5_k2`、`h8C_job_p5_k2`，`GDoneSavedCompletedK`）是 v8 引入的时序假象，已修。**
  - 路径：工作流已正常返回并保存 → 管理员 abort → CJ 被杀 → 心跳同步通知 SJ 这个 client 死了 → 粗 CommSJ 策略 panic → job 记为 FAILED。
  - 原因：v8 把粗 CommSJ 的策略 panic 放宽成"有 dead-client 报告就能 panic"；细 CommSJ 的 30 秒时钟在工作流返回后仍然免费，60 秒宽限期可以在收尾期间瞬间过完。真实代码里 `control_flow` 返回后，`stop_controller` + `finalize_run` 几秒内就结束 task monitor（`server_runner.py:153-172`），报告在返回之后才到的话，宽限期不可能在这之前到期。
  - 修法（时序前提 T4，带价逃逸 `slowFinalize`，权重 2）：细 CommSJ 在工作流返回后不再走时钟 tick，除非打开 `slowFinalize`；粗 CommSJ 加私有标志 `deadEarly`（报告已过宽限期），策略 panic 改为只在 `deadEarly` 时发生，返回后只有 `slowFinalize` 才能置位。备份：`.work/v8-pre-T4-20261107-0104`。
  - 复查：CommSJ 细到粗精化跑满 133 万状态无违例，负控失败；全细、全粗 TV 都接受（87 秒、22 秒）；hunt8 的检查点全部重采（56/56）。从新检查点重跑这两个配置，各跑满 120 万状态无违例；额外打开 `slowFinalize` 后 del 族重新出现同一违例（路径正是心跳同步 → `Mature` → 策略 panic），说明它只在这个时序巧合下成立。
  - 对应的真实可能性：client 在工作流返回前最后几十秒内死掉，宽限期恰好在收尾的几秒内到期，已完成的 job 会因策略 panic 记为执行失败。需要时序巧合，作为 `slowFinalize` 逃逸留在模型里；没有复现。
- 打开 `slowFinalize` 并把预算提到 4 时，job 族还报出 `GFinishedNoAbnormalExitK2`：收尾阶段 abort、发给 SJ 的 abort 命令出错（`abortCmdError`）→ 0 秒终止路径 → SJ 被杀 → job 记为 COMPLETED。这是第 4 轮起记录的已知线索 `ABORT_classified_completed`（依赖 T2 的逃逸），预算 4 才够同时用 abort 和 `abortCmdError`，与 2b、T4 无关。

- **T4 修复后的完整冒烟**（S 14、C 14、D 6、L 6，共 40 个 run，C 轨用新检查点）：37 个无违例，3 个是 D 轨的预期找回（T1 ×2、R1）；没有 worker 异常。
- **新增一条模型线索 N2（只有模型反例，未复现）：** client 在工作流返回前最后几十秒内死掉，60 秒宽限期恰好在收尾的几秒内到期，task monitor 判定违反作业策略并 panic，已完成并保存的 job 记为执行失败。依赖时序巧合，在模型里由 `slowFinalize` 逃逸表达。

**收尾复核（最终模型，T4 修复之后）：**
- **L13：** 定向 BFS 找到（细 JobSP 深度 50，全粗深度 32）。两次 900 秒 D 轨盲跑都找到（187 秒、297 秒）。
- **T2：** 定向 BFS 找到（深度 12）。两次 900 秒 D 轨盲跑都没碰到（各约 75 条 trace）。原因是按 v8 修正后的时序，T2 要求两个 token 都失效，并且重新登录落在一次 logout 处理之内，几个带价事件要在同一条长 trace 里依次发生。hunt8 的 T2 回归因此改为带预算的 BFS（`h8D_t2_s2l1a1`，K=3）：3 秒、11 步找到（两个都失效 → 列出名单并登出第一个 → 另一个重新登录 → 处理下一个时线程退出）。
- **N2 在真实代码上复现**（REPRODUCED，强制时序；`checks/confirm/n2_repro.py`）：真实的 `WFCommServer.process_dead_client_report`、`_monitor_tasks`、`_check_dead_clients`、`_job_policy_violated`、`finalize_run`；engine 和 `system_panic` 是桩，`stop_controller` 用 1 秒代替。site-2 的 dead-job 报告在工作流返回前 59.5 秒到达时，宽限期在收尾窗口内到期，task monitor 调用 `system_panic("Aborting job due to deployment policy violation")`；对照组（报告在返回时才到）没有 panic。之后 FATAL_SYSTEM_ERROR 变成 `execution_error`，job 记为 `FINISHED:EXECUTION_EXCEPTION`（这一段是 `l13_repro.py` 对照组已确认的链路）。根因：`control_flow` 返回后 task monitor 要到 `finalize_run` 才停，期间仍在执行部署策略检查。上游检索：没有相关 issue（#3671 是通信错误导致失败，根因不同）。

**按根因汇总（截至第八轮收尾）：**

| 口径 | 个数 | 是哪些 |
|---|---:|---|
| 在真实代码上复现 | 13 | C1-A、C1-B、H08、H11、T1、T1-b、T2、T3、R1、R2、L13、H03、N2 |
| 其中不需要强制调度或注入 | 5 | H08、H11、T1、R1，R2（server 端逻辑层面） |
| 其中靠强制调度、耗时的桩或注入故障 | 8 | C1-A、C1-B、T1-b、T2、T3、L13、H03、N2 |
| 新于上游 | 12（或 13） | 都没有提交；C1-A 与 #5301 同根因族时为 12 |
| 新于 Phase 1 | 10 | C1-A、C1-B、T1、T1-b、T2、T3、R1、R2、L13、N2 |
| Phase 1 候选、第一次确认 | 3 | H08、H11、H03 |
| 只有模型反例 | 1 | N1 |
| 只有静态代码确认 | 1 | H01 |

**修复后的完整一轮 hunt8b**（11-07 02:07 至 07:42 UTC，墙钟 5 小时 35 分，162 个 run，44.7 run·小时；用 T4 修复后的模型和重采的检查点；没有 worker 异常）：

| 跑法 | run 数 | 违例 | 规模 |
|---|---:|---:|---|
| S 按阶段放行的深度模拟，14 个族 | 76 | 0 | 4,353 条 trace，3,732 万状态（TLC 计数） |
| L 3-site 实例 | 6 | 0 | 209 条 trace |
| C 检查点 BFS（阶段 2–5，K=1/2） | 68 | 0 | 9,202 万 distinct；4 个穷尽 |
| D 盲跑重新发现 | 12 | 11 | L13 在这一轮的模拟里没命中（900 秒，263 条 trace） |

- L13 和 T2 的模拟回归命中率不稳：T2 在 3 次 900 秒运行里命中 1 次，L13 在 5 次里命中 3 次。两者都改为带预算的 BFS（T2：K=3；L13：K=4，JobSP 细、其余粗），结果是确定性的。
- 最终模型上的模拟命中率（`h8simreg`，模拟版回归保留在 `h8D_t2sim`/`h8D_l13sim`）：L13 在 4 次 900 秒运行里命中 1 次（794 秒），3600 秒的一次在 470 秒命中；T2 在 4 次 900 秒运行里 0 次，3600 秒的一次在 2,278 秒命中。所以 D 轨用 BFS 版做确定性回归。
- **按最终计划重跑整个 D 轨**（`plans/hunt8_Dfinal.py`，12 个 run）：**12/12 全部找回**。T1 ×4、R1 ×2、R2 ×2（deadlock）、T2（BFS，4 秒）、T3、L13（BFS，499 秒）、C1-B 跨 job（593 秒）。
- 结论：修复后，S、L、C 三个轨道没有任何新违例；D 轨对已知问题的回归全部通过。

**时序模块化（`spec/Timing.tla`，DESIGN §14）：**
- 4 个时序前提（T1–T4）改为 `TimingOK(Faults, "<逃逸>", T?Holds(...))` 的统一写法。共 8 处调用点：RunCJ_C/F、JobSP_C/F、PayRcv_C/F、CommSJ_C/F。
- 3 个逃逸事件和结构性时序假设也在模块里登记。
- `rarity.py` 能从调用里读出逃逸名。
- **等价性：**
  - 重构前后 576 个步骤的定价完全一致。
  - hunt8b 中 4 个穷尽完成的检查点 BFS 原样重跑，状态数逐个相同：err p5 266,874，status p5 393,274，status p4 528,926，tail p5 484,648。
  - 全细、全粗 TV 仍接受真实 POC trace（71 秒、18 秒）。

**自然时序复现与影响评估（11-07）**（`notes/repro-natural-A.md`、`notes/repro-natural-B.md`、`notes/impact-assessment.md`）：
- 没有任何一项升到"无强制"。把触发事件放在窗口附近随机的试验，仍算"以时序巧合为条件"。
- T2、T3、L13、H03 在自然时序下可以忽略：T2 窗口 0.15–3.3 ms，T3 约 0.08 ms，L13 空闲和忙 SP 共 0/300，H03 0/71,584。
- C1 在默认部署下 0/100；只有慢失败的自写存储加 K8s launcher 时才几乎必然（96/100）。
- T1-b 窗口 0.5–2.2 s（慢 client 约 10 s），窗口内删除必中。另有持续写失败（真实 EACCES）的触发，20/20，与 T1-b 同一根因，不另计。
- N2 窗口在标准 workflow 下 0.8 ms；`finalize_run` 里 import torch，使非 torch job 在装了 torch 的 server 上达到 325 ms。模型的 `slowFinalize`（几秒）偏宽。
- **更正 §11/§13 的 T2：** `t2_repro.py` 里 2 s 的 `fail_run` 桩不符合真实代码。这条路径只在 SJ 已退出时才调 `fail_run`，`_stop_run` 什么都不发（实测 0.03 ms）。断网恢复后的重连不弹掉旧 token，现实触发是宕机超过 600 s 的 CP 重启。
- H01 在代码上复现（桩传输 + 注入两次回复丢失，`checks/confirm/h01_repro.py`）。模型里没有它的行为。
- 新线索，不计数：SFM 在 endpoint 挂上前静默丢 DATA 帧（人为 GIL 负载下 4/100，丢弃逻辑是 #5320 有意加的）；`task_check_period` 属性名不一致（STATIC）。
- 上游 main 已到 `5c54edda`，只改了 `fed_server.py` 的调用方认证（#5672、#5708），所有发现仍在。R1 是 #4503 引入的回归；H08 只在 main（#5550，未发布）。

**按根因汇总（截至 11-07）：**

| 口径 | 个数 | 是哪些 |
|---|---:|---|
| 在真实代码上复现 | 14 | C1-A、C1-B、H08、H11、T1、T1-b、T2、T3、R1、R2、L13、H03、N2、H01 |
| 其中不需要强制调度或注入 | 5 | H08、H11、T1、R1、R2 |
| 其中靠强制调度、桩、注入故障或以时序巧合为条件 | 9 | C1-A、C1-B、T1-b、T2、T3、L13、H03、N2、H01 |
| 有模型反例且盲跑能找回 | 13 | 除 H01 以外的全部 |
| 新于上游 | 13（或 14） | 都没有提交；C1-A 与 #5301 同根因族时为 13 |
| 新于 Phase 1 | 10 | C1-A、C1-B、T1、T1-b、T2、T3、R1、R2、L13、N2 |
| Phase 1 候选、第一次确认 | 4 | H08、H11、H03、H01 |
| 只有模型反例 | 1 | N1 |
| 只有静态代码确认 | 0 | — |
