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
