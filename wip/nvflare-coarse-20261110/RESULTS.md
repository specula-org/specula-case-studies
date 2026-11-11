# 结果：NVFlare 全系统粗粒度组合建模

## 0. 当前状态

步骤 0–2 已完成，停在这里等确认，确认后再进入步骤 3。

结论先说：
- 21 个根因在校准后的模型里都能到达：12 个由通用扫描找到，其中 2 个是在修正之前找到的；另外 9 个只有定向见证能走到，有 1 个只找到了同族的另一种形态。
- 那 9 个没被扫描找到，相关格子都没跑完（被预算截停），所以不算标准的盲区。其中 3 个在 v1 里确实没有能检查它们的性质，v2 补上了。
- 假警报 15 处（另有 1 次模拟模式下的静止判定虚报），都已带代码锚点修正或说明理由。其中 2 处是我自己引入的：修正 M5 写得过严，时序假设 TA6 没有依据。
- 校准区域新增 1 个候选，未复现。

## 1. 步骤 0：准备

- **磁盘**：工作区所在的 `/home/ubuntu`（`/dev/root`）有 170 GB 可用，高于 30 GB 的门槛，没有写 `notes/cleanup-candidates.md`。PROMPT 里的 176 MB 是容器根分区 `/`（含 `/tmp`）的数字，现在是 166 MB。所有 TLC 临时文件都在工作区 `.tmp/` 下：`scripts/tlc.sh` 设了 `TMPDIR`、`-Djava.io.tmpdir`、`-metadir`、`-XX:-UsePerfData`，每个 JVM 显式设 `-Xmx`。
- **拷贝**（9.4 MB）：remix 的 15 个粗模块（`*_C.tla`）、`Trainer_X`、`Trainer_A`、`Net_L`、端口模块、`Consts`、`Timing`、`JobPhase`、`rarity.json`、注册表；脚本 `gen_mix.py`、`mkmc.py`、`run_mc.py`、`ckpt.py`、`tlc.sh`、`rarity.py`、`ce.py`、`hunt.py`；`lib/tla2tools.jar`（2026.09 nightly，md5 与 remix 相同）和 `CommunityModules-deps.jar`。细变体没拷。
- **生成器改成只用粗变体**：
  - 去掉了按 site 选粒度（`SiteGrain`、`SitesFor`、C9 断言、`site_splittable`）、`wip` 变体处理、mkmc 的 `COARSE_ONLY` 检查；covering array（`sweep.py`）和 receipt（`gen_ref.py`、`gen_harness.py`）没有拷。
  - `Grain` 只剩一个用途：选 Trainer 的部署模式（C 进程内、X 外部进程、A attach）。Net 只用 `Net_L`，不开 `netLoss` 时等同于可靠网络。
  - 保留了全部静态检查：只给自己拥有的变量加撇、只发自己拥有的消息类型、不引用别组私有变量、导入白名单。
  - 新增：注册表里每组可以声明进程存活守卫（`guard`），进程已退出的组不再走步，重启动作除外。

## 2. 步骤 1：标准和账本

- **`STANDARD.md`**（v1）：组件单位（T 长期线程、H handler、O 有状态对象、P 进程）；每个对外操作的四种结果（OK、影响前失败 FB、影响后报失败 FA、做了一半 PA）；失败原因目录（R-absent、R-replaced、R-gone、R-busy、R-concurrent、R-closed、R-state）或计价故障；状态的持久化和 key 的代数、进程级全局状态；步骤规则（生命周期窗口和跨锁的先查后做必须两步）；运维事件和四档计价（1/2/4/6）及档位换算；§7 的通用性质；排除范围；账本格式；防拟合规则。
- **`notes/ledger.csv`**：校准区域 153 行，其中 131 行已建模、22 行排除（每行写了理由）。由 `notes/ledger.d/*.py` 生成，`scripts/ledger.py check` 检查：
  - Next 里的 249 个动作都有 `\* @L` 标注，标注的 id 都在账本里；
  - 账本里 `modeled` 的行都指向存在的动作；
  - spec 注释里没有 bug 编号。
- **校准区域**：remix 粗层锚点引用到的 47 个源文件，共 31,246 行，清单见 `notes/region-calib.txt`。`scripts/scan_units.py` 对这些文件做统一正则粗扫，得到 575 个候选（线程创建 31、按 key 操作 132、无快照遍历 20、全局状态 3、对外操作 389），结果在 `notes/scan-calib.csv`。按函数归并后逐个判断，登记进账本。

## 3. 步骤 2.1：按标准改造粗层

改造后粗层（含端口、Timing、JobPhase、通用性质）从 3,496 行变为 3,949 行。下表是步骤 2.1 的改动；扫描中又做的模型修正见 §6，标准的修订见 §7。

| 改动 | 依据（标准条款 / 代码锚点） | 对应账本行 |
|---|---|---|
| SP 关机后进程退出（`ShutExit`），restart 后起新 SP（`ShutRestart`）；SJ 随 SP 退出。当时还加了时序假设 TA6（停掉的 job 收尾后 SP 才退出），扫描后发现没有代码依据，已撤回（§6 F15） | §1 进程单位 P；`fed_server.py:343-354` | `JobSP.proc.SP` |
| CP 上的 `CUDA_VISIBLE_DEVICES` 建成进程级全局槽 `env`：每次 START 的 consume 都写它，进程 CJ 在 spawn 和 relaunch 时复制它；每个 site 两块 GPU，每代 launch 记录实际用的是哪块（`gpu[l]`）；新增时序逃逸 `startOverlap` | §4 进程级全局状态；`gpu_resource_consumer.py:25-33`、`process_launcher.py:72-160` | `JobCP.res.gpuEnv`、`Timing.startOverlap` |
| 原来"第二个 job 占着唯一资源单元、CHECK 答 no"的分支删掉（两块 GPU 后不成立） | 账本 `JobCP.cmd.check` | 同 |
| cleanup 线程遍历注册表时，有 client 登录（R-concurrent）就退出，新故障 `regIterRace`（微秒窗口，权重 6） | §3 R-concurrent；`fed_server.py:313`、`client_manager.py:431`（`get_clients()` 返回内部 dict，遍历不加锁；`authenticate` 加锁写入） | `Reg.cleanup.iterate` |
| SP 重启时注册表在内存里，全部 client 重新登录换新 token，cleanup 线程是新的 | §4 内存状态随重启丢失 | `Reg.proc.restart` |
| 管理员 abort、SP shutdown 被接受时记下 `stopReq`（"实际发生了什么"的端口证据） | §7 Q2 | `JobSP.admin.abort`、`JobSP.admin.shutdownLoop` |
| Attach 训练进程的 `send()` 成功回复记为 `acked`，CJ 接受的结果记为 `taken` | §7 S6 | `Trainer.att.publish` |
| 线程死亡标志从布尔值改成"出错操作的账本 id"（调度线程、cleanup 线程） | §2 规则 1；分诊时区分根因 | `JobSP.sched.*`、`Reg.cleanup.*` |
| 时序假设改名为 TA1–TA5，避免和 bug 编号混淆；spec 注释里的 bug 编号全部删除 | §10 | `Timing.*` |
| 通用性质模块 `spec/StdProps.tla`（Q1–Q4、S1–S6），删除 remix 的 `GenericProps.tla`（其中有按 bug 写的过滤器） | §7、§10 | — |
| 静止判定 `Q`：`rarity.py` 生成 `QNext`，即把每一步的故障集换成默认计时器（`rarity.json` 的 `default_timers`） | §7 | — |
| 权重按 §6 的四档重定 | §6 | — |

## 4. 步骤 2.2：系统扫描

**格子** = 部署配置 × 失败点 × 生命周期阶段（`scripts/sweep_grid.py`，计划 `plans/calib.py`）：

- **配置**：17 个。`fedavg`（1 site、2 次 launch）、`fedavg2`（2 site）、`nonstrict`、`multijob`（SP 上第二个 job）、`multijobcp`（CP 上第二个 job）、`cse`、`cseserver`、`sag`（带 Model 组）、`cyclic`、`swarm`、`k8s`、`docker`、`external`（外部训练进程）、`attach`、`taskmode`、`sampling`、`fedmodel`（FedAvg 带 Model 组）。
- **失败点**：
  - 每个配置都有 11 个运维事件：cjCrash、sjCrash、cpCrash、spCrash、abort、deleteJob、spShutdown、netLoss、deadClient、taskTimeout、rpcTimeout。
  - 另加该配置特有的故障。`fedavg` 加上全部 37 个通用故障。
  - 一个失败点可以带上它需要的事件（`DEPS`），例如 cpCrash 带 rpcTimeout（对死掉的 CP 发请求会超时）。
- **阶段**：第一遍用 0 提交、2 RUNNING、5 收尾，两轮的配置再加阶段 4；第三遍起补上阶段 1（已 DISPATCHED、还没写 RUNNING）和 3（第一个结果已接受）。
- **每格的跑法**：
  - 先用预算 0 的模拟取该配置该阶段的检查点。只走免费步骤，所以这段前缀对每个格子的 spec 都是零代价的行为。
  - 然后只开这一个失败点和它的依赖，预算为 2×权重 + 依赖权重（第二遍起再 +2），从检查点做 BFS。
  - 第三遍起：BFS 120 秒；没穷尽也没违例的，再从同一检查点模拟 70 秒，用来采深层状态。
  - 只检查 §7 的通用性质：`StdProps` 里的不变式，加上动作性质 S2。
- **反例分诊**（`scripts/classify.py`）：
  - 按违反的性质和端口上的机制特征分组，比如哪个操作让线程退出、哪个状态盖掉了哪个；
  - 路径权重取 `rare` 的实际增量，换算成可能性档位；
  - 同组里取权重最低的反例做代表；
  - Q 类反例用 `scripts/qverify.py` 在 BFS 下复核。
- 已归因的机制在下一遍用过滤器排除，好让后面的反例露出来。

| 遍 | 格子 | 结果 | 改了什么 |
|---|---:|---|---|
| 第一遍 `cal1` | 812 | 反例 283、穷尽 94、截停 404，另有求值错误或取不到检查点 31 | v1，无过滤 |
| 第二遍 `cal2` | 117（中途停掉） | 反例 4 | 模型修正 M2–M8、v2 性质、过滤器；被第三遍取代 |
| 第三遍 `cal3` | 1,345 | 反例 95、穷尽 98、截停 1,152（86%） | 修正 M9，补阶段 1、3，每格加模拟 |
| 第 3b/3c 遍 | 各 97 | 关机相关的格子 | 修正 M10、S5，过滤器改为按原因写（v3） |

合计 2,468 格，约 107 格·小时。

**覆盖的局限**：
- 被截停的格子，BFS 深度大多在 10–50 层，而 1 个 site 的 job 从提交到终态要 60–70 步。所以阶段 0–3 的格子基本走不到终态，"静止时的后果"（Q1–Q4）主要只在阶段 5 的格子和较浅的反例里被检查到。
- 每格的模拟只有 70 秒，TLC 每分钟才报一次进度，所以只知道"有没有违例"，不知道采了多少条 trace。
- "截停且没有违例"不能当成干净。

## 5. 步骤 2.3：对照 remix 的 21 个根因做召回

"扫描"是指只开一个失败点、只查通用性质的格子；"见证"是指定向见证，用按 bug 写的谓词、允许多个故障，只用来判断模型能不能到达，见 `checks/witness/plan.py`、`results.jsonl`。耗时指该格 BFS 或模拟找到反例所用的时间。

| 根因 | 扫描结果（遍、格子、深度、耗时、权重和档位） | 没被扫描找到时 | 见证 | 结论 |
|---|---|---|---|---|
| R1 | 第一遍 `fedavg×spCrash p5`，深度 11，5 s，w1 高 | — | — | 扫描找到 |
| R2 | 第一遍 `multijobcp×cpCrash p2`，深度 2，3 s，w1 高 | — | — | 扫描找到 |
| T1 | 第一遍 `multijobcp×deleteJob p0`，深度 1，3 s，w2 中 | — | — | 扫描找到 |
| T1-b | 第二遍 `fedavg×deleteJob p0`（滤掉 T1 后），深度 5，3 s，w2 中 | — | — | 扫描找到 |
| T2 | 第一遍 `fedavg2×slowFinalize p0`，深度 5，3 s，w6 很低 | 2 site 才有；deadClient 格子起初预算不够（只够两次失联），第二遍起预算 +2 | — | 扫描找到 |
| T3 | 第一遍 `multijob×jobExitRace p0`，深度 3，3 s，w8 很低 | — | — | 扫描找到 |
| H01 | 第一遍 `attach×tpReplyLost p2`，深度 9，4 s，w8 很低 | — | — | 扫描找到 |
| L13 | 第一遍 `fedavg×statusLost p2`，深度 25，87 s，w12 很低（同一次回调异常被收了两次费，实际应为 8） | — | — | 扫描找到 |
| H08 | 第一遍 `multijobcp×cjCrash p0`，深度 10，3 s，w2 中：另一个 job 的 CJ 重启时用了我们的 GPU；同一机制的另一个方向 `multijobcp×startOverlap p0`，深度 11，w4 | — | — | 扫描找到 |
| H04 | 第三遍 `sag×acceptRaise p2`（模拟阶段），深度 74，120 s，w4 低 | — | 也走到了 | 扫描找到 |
| H11 | 第一遍 `cse×*`，深度 0，w0：修正前的过近似，不需要重发 | 修正后（M5'），扫描里被症状级过滤盖住了 | cse，netLoss+submitTimeout，模拟 3.7 s | 修正前扫描找到；修正后只有见证 |
| H05 | 第一遍 `swarm×*`，深度 0，w0：修正前毫秒窗口没有计价 | 修正后（M6），扫描里被症状级过滤盖住了 | swarm，gatherRace，模拟 5.7 s | 修正前扫描找到；修正后只有见证 |
| C1-A | 只找到同族的 #5301 形态：延迟的 RUNNING 写入盖掉终态，第一遍 `fedavg×sjCrash p0`，深度 19，5 s，w2 中 | C1-A 本身（FAILED_TO_RUN 盖掉已发布的终态）要 storeError 和 sjCrash 两个故障；`fedavg×storeError` 阶段 0–3 都截停（深度 20–47） | storeError+sjCrash，模拟 9.8 s | 搜索未完成：要两个故障 |
| C1-B | 未找到 | 同上 | storeError+sjCrash，模拟 2.0 s | 搜索未完成：要两个故障 |
| N2 | 未找到 | deadClient、slowFinalize 的格子在 fedavg 和 fedavg2 下都截停（深度 8–28） | fedavg，deadClient，阶段 3 起 BFS，22 s；模拟 300 s 没走到（策略 panic 要恰好拖到工作流返回之后） | 搜索未完成 |
| S1 | 未找到 | `multijob×slowShutdownAbort` 截停；第三遍还被 TA6 造成的假卡死盖住 | spShutdown+slowShutdownAbort，模拟 1.8 s | 搜索未完成：要两个故障 |
| S4 | 未找到 | `*×spShutdown` 截停；第三遍被 TA6 盖住，3b 被 S5 的误报盖住，3c 修完后仍截停 | spShutdown，模拟 2.0 s | 搜索未完成 |
| V7 | 未找到 | `k8s×cpCrash` 阶段 0–3 截停；阶段 5 虽然穷尽，但检查点已经过了 CP 重启起作用的窗口 | cpCrash+rpcTimeout，模拟 3.9 s | 搜索未完成 |
| H06 | 未找到 | `swarm×busyReplace` 全截停；还要 gatherTimeout（gather 超时关闭后，下一轮才会在这个 client 忙时到达）；**v1 没有能检查它的性质**（job 因进度 panic 失败，在 v1 看来"和实际发生的事相符"） | busyReplace+gatherTimeout，模拟 4.9 s | 搜索未完成；另外是 v1 的性质盲区，v2 的 S7 补上 |
| H07 | 未找到 | `k8s×slowPublish` 全截停；**v1 没有能检查它的性质**：v1 不读 workspace 结果有没有返回 | slowPublish+cjCrash，模拟 18 s | 搜索未完成；v1 的性质盲区，v2 的 S4 产出送达补上 |
| H03 | 未找到 | `external×monitorStale`、`tpSilent` 全截停；**v1 没有能检查它的性质**：v1 不读"结果源被拆掉时有没有通知" | tpSilent+monitorStale，阶段 4 起 BFS，47 s；模拟 600 s、阶段 3 起 BFS 300 s 都没走到 | 搜索未完成；v1 的性质盲区，v2 的 S8 补上 |

汇总（这 21 个根因按"按根因计数"各算一次）：

| 口径 | 个数 | 是哪些 |
|---|---:|---|
| 通用扫描找到 | 12 | R1、R2、T1、T1-b、T2、T3、H01、L13、H08、H04；H11、H05 是在修正之前找到的 |
| 只有定向见证走到（相关格子没跑完） | 9 | C1-A（扫描只找到同族的 #5301 形态）、C1-B、N2、S1、S4、V7、H06、H07、H03 |
| 其中要两个独立故障 | 4 | C1-A、C1-B、S1、H06 |
| 模型走不到 | 0 | — |
| v1 的性质盲区（坏状态可达，但 v1 没有性质检查它） | 3 | H06、H07、H03 → v2 的 S7、S4 产出送达、S8 |

被截停的格子不算"穷尽了也没找到"，所以除了上面 3 个性质盲区，没有根因被记为标准的盲区。

## 6. 假警报（扫描报出、判为模型错误或现实不可达）

每一条都按代码锚点修了模型，或者在分诊里过滤并说明理由（PROMPT §7：修正要带代码锚点或 trace 证据）。

| # | 现象 | 原因类别 | 依据 | 处理 |
|---|---|---|---|---|
| F1 | DISPATCHED 时 pre-run abort 成功，随后 runner 写 RUNNING 盖掉 ABORTED | 粗化漏了互斥 | start claim 期间 `abort_before_start` 返回 STARTING，不改状态（`job_runner.py:724-733,806-815`） | 修正：claim 期间 pre-run abort 不生效 |
| F2 | 工作流完成并保存后才到的 admin abort，被判为"COMPLETED 但有停止请求" | 性质写偏 | 停止请求晚于完成，不让 COMPLETED 变错 | 修正 S4：去掉"无停止请求"一条，只在 Q2 保留 |
| F3 | 第二个 job 占着唯一资源单元，CHECK 答 no，job 直接 CANT_SCHEDULE | 模型前后不一致 | 改成每个 job 各一块 GPU 后，这个分支不再成立 | 删掉该分支 |
| F4 | 检查点取到了终态，格子 1 个状态就"穷尽" | 工具错误 | — | 检查点必须处在指定阶段且未到终态 |
| F5 | SP restart 之后 SUBMITTED 的 job 永远不被调度（第一遍 19 格） | 建模缺口 | 新调度器会重新调度 SUBMITTED 的 job，但 SP→CP 消息 id 没带 SP 代数（违反标准 §4），重新调度建不出来 | 账本记为 gap，分诊中过滤 |
| F6 | 1 个 site 时 cleanup 线程也会死于"被替换的 token" | 粗化过近似 | 一轮清理开始时就固定了死 client 列表（`fed_server.py:309-321`） | 修正 M4：被替换的 token 必须在本轮列表里 |
| F7 | admin stop 比 10 s 的 terminate grace 还慢，被杀的 job 记为 COMPLETED | 时序逃逸，余量很大 | remix 测过余量（10 s 对毫秒） | 过滤；属于 `slowAdminStop` 格子本身的逃逸 |
| F8 | attach 训练进程崩溃、新进程重新 attach 后，CJ 的 `execute()` 永远等 | 建模缺口 | 等待中会话被替换时返回错误（`attach_backend.py:585-640`） | 修正 M8 |
| F9 | taskMode 的 28 个格子报 TLC 求值错误 | spec 求值错误 | 动作里 `x = None \/ x.gen ...` 两边都求值 | 改成 IF（TaskCJ_C、Worker_C） |
| F10 | 关机循环还没结束，SJ 就被杀，启动窗口里漏标 aborted 的 job 记为 COMPLETED | 粗化漏了两处守卫 | completion 线程在 `ask_to_stop` 后不再收尾（`job_runner.py:494`）；时序假设 TA5（循环先于 10 s grace 结束） | 修正 M9 |
| F11 | 关机循环可以无条件跳过已注册的 job | 粗化过近似 | 循环只在遍历时字典大小变化才中途出错（`job_runner.py:944-950`），需要另一个 job 的 SJ 退出且循环够慢 | 修正 M2 |

| F12 | cross-site eval 在所有 client 都失联时空跑到"正常结束"，START 超时后 job 记为 FAILED_TO_RUN，被判为状态含义不符 | 性质写偏 | NVFlare 里 FAILED_TO_RUN 的意思是启动阶段抛了异常（`job_runner.py:770-800`） | S5 改写 |
| F13 | 启动中被关机打断，CJ 刚跑起来就被杀，job 记为 FAILED_TO_RUN，再次被 S5 判违例 | 性质写偏（第二次） | 同上 | S5 删去 FAILED_TO_RUN 一条；盖掉终态的情况由 S2 负责 |
| F14 | 修正 M5 之后 H11 完全走不到 | 我自己的修正引入的模型错误 | M5 要求"本轮还没发过 TASK_CHECK"，可 H11 的崩溃发生在 task 退役时，那时已经发过了；定向见证暴露出来 | 改成 M5'：服务器对同一 client、同一轮发过两次 ASSIGNED（`wf_comm_server.py:340-380`）。修正后见证 3.7 s 走到 |
| F15 | 关机后 SP 一直不退出，job 卡在 RUNNING（第三遍 53 格） | 我加的时序假设没有代码依据 | TA6 假设 SP 退出前会先把停掉的 job 收尾，但 `fl_shutdown` 只等 client 离开（`fed_server.py:343-354`），completion 线程看到 `ask_to_stop` 后就退出循环（`job_runner.py:494`） | 修正 M10：撤回 TA6。撤回后，同一路径的真实后果是"优雅关机也会把被停的 job 留成 RUNNING"，重启后即 R1，见 §8 |
| Q-sim | 模拟模式下，一个还有免费步骤可走的状态被判为静止（cseserver×spShutdown p0） | TLC 模拟模式下的求值异常，原因未查明 | 用 `qverify.py` 在 BFS 下复核：第三遍 54 个 Q 类反例中，53 个确认真静止，只有这 1 个是虚报 | 以后 Q 类反例报告前一律复核 |

另有三处不是假警报，而是档位或覆盖有偏差，也一并修了：
- **H11 不需要重发也能触发**：可能性被高估成"高"。修正 M5'（见 F14）：要求有一次重发。
- **H05 不需要故障**：毫秒窗口没有计价。修正 M6：新增逃逸 `gatherRace`，权重 4。
- **swarm 阶段 4 空跑**：没被选中的 site 每轮都拿 TRY_AGAIN，把轮询上限耗尽。修正 M7：放宽有目标子集的工作流的轮询上限。

按类别统计这 15 条（F1–F15，不含 Q-sim）：
- 粗化或建模缺口 8 条：F1、F3、F5、F6、F8、F10、F11、F14；
- 性质写偏 3 条：F2、F12、F13；
- 时序假设 2 条：F7 是余量很大的逃逸；F15 是假设本身没有依据；
- 工具或求值错误 2 条：F4、F9。

## 7. 标准的盲区和修订

| 版本 | 改动 | 触发它的证据 |
|---|---|---|
| v2 | §7 加 S7（停止都有来源）、S8（被依赖的资源丢失时通知依赖方）；S4 扩成"产出都送达"（模型贡献、保存的模型、client 的 workspace 结果） | H06、H07、H03 的坏状态，模型能走到（见 §5 的见证），但 v1 的性质都不读相应的端口证据。三条都写成通用条款，对所有带停止标志、结果源、产出的单元统一生效 |
| v3 | §10 过滤只按原因写：每个需要过滤的机制，由体现原因的动作在端口上留下原因记录（账本 id），过滤器只匹配这条记录；Q 类反例必须复核；S5 删去 FAILED_TO_RUN 一条 | 你的审阅：症状级过滤到步骤 4 会把新 bug 藏起来；S5 的两次误报（F12、F13） |

**v3 之前用过的过滤器有一部分是症状级的**：第二遍、第三遍的 `calib2.py` 里有 `~S6AckMeansDone`、`~GatherExact`、`pCommSJ.monitorCrashed`、`freedWhileRunning`、`Completed /\ SJPanicked`，以及"RUNNING 盖掉终态""SP 重启后状态停在运行中""CP 重启后挂起""admin stop 逃逸"几条。在校准区域里，它们可能盖住了违反同一性质的其他根因；第三遍里 H11、H05 修正后没被扫描重新找到，就是被这些过滤器盖住的。

v3 的做法：
- **端口上加原因记录**：状态被谁覆盖（`overwrite`）、由哪一代 SP 写的（`statusGen`）、SJ 退出时状态消息丢了（`exitObs`）、terminate 抢在 admin stop 之前（`termEarly`）、关机时留下未收尾的 job（`unfinalized`）、分配由谁释放（`freedBy`）、launch 由谁宣告结束（`endBy`），以及 completion 线程和 task monitor 的死因、attach 推断出的成功（`ackInferred`）、gather 关闭时还在 accept 里的贡献（`raced`）。
- **过滤器**改写在 `plans/calib3.py`，每条只在对应原因发生过之后为真。
- 只有第 3b/3c 遍用了 v3 的过滤器；第一到三遍没有用 v3 重跑。

## 8. 计数（按根因；证据等级和可能性档位分开）

| 栏 | 根因 | 证据等级 | 可能性档位（计价算出） |
|---|---|---|---|
| remix 已有的 22 个 | 可比的 21 个的校准召回见 §5；L5 是时间值的 bug，不在模型范围内 | 沿用 remix：REPRODUCED 22 | — |
| 本次在校准区域新增 | 1 个：cleanup 线程遍历注册表时被并发登录打断而退出（`Reg.cleanup.iterate`）。`get_clients()` 直接返回内部字典，`remove_dead_clients` 在 cleanup 线程里不加锁遍历；`authenticate` 在 `self.lock` 下往同一个字典 `update`（`fed_server.py:309-321`、`client_manager.py:166-192,431-437`）。后果和 T2 相同：死 client 再也不会被移除，SJ 收不到通知。remix §11 曾提过一句，但没建模、没复现、没计数 | STATIC + 模型反例；未复现（步骤 6 的事） | 很低（w8：一次失联 2 + 微秒窗口 6） |
| 本次在新区域找到 | 0（步骤 3 起才开始） | — | — |

另外看到、不单独计根因的：
- **R1 的新触发路径**：优雅的 shutdown/restart 也会把被停的 job 留成 RUNNING。关机路径不写终态，completion 线程在 `ask_to_stop` 后就退出了；重启后由于没有启动恢复，job 永远停在 RUNNING。remix 只认了"SP 非优雅退出"这一种触发。修了 R1（启动时恢复）它也就消失了，所以不单独计。
- **remix §15 记过、没计数的那条 S1 后果**：关机循环很慢时，启动窗口里的 job 没被 `mark_run_aborted` 标上（`job_runner.py:892-900` 只标 `running_jobs` 里的 job），最后记成 COMPLETED。依赖时序逃逸 slowShutdownAbort，w5，档位"低"。
- **remix 已有的线索和已知问题**：V8（容器 CJ 在 CP 重启后没有分配记录）、H20（Pod 删除失败仍当作已终止）、H21（回滚时释放了在用的分配）。

## 9. 局限，以及进入步骤 3 之前建议先做的事

1. **单失败点的格子到不了需要两个独立故障的问题**：C1-A、C1-B、S1、H06。建议加一层"罕见故障 × 运维事件"的成对格子，只配对同一组或相邻组的失败点。
2. **截停率高**（第三遍 86%），BFS 走不到终态。PROMPT 步骤 5 提到的切片还没做：只放这个失败点和依赖它的影响所在的几个组。我建议先做切片，再谈加时长。
3. **第一到三遍用了一部分症状级过滤器**（§7），校准区域里可能有被盖住的其他根因。建议用 v3 的过滤器把三遍里出现过反例的格子重跑一遍。
4. **计价会重复收费**：同一次故障的多步后果被分别计价（例如 L13 里的回调异常收了两次），档位会偏向"更罕见"。
5. **SP 重启后重新调度 SUBMITTED 的 job，模型里没有**：SP→CP 消息 id 没带 SP 的代数，违反了标准 §4。账本记为 gap，扫描里过滤掉了。
6. **模拟模式下的静止判定出过一次虚报**，原因未查明。Q 类反例报告前一律用 BFS 复核。

校准区域里没有做 TV。按 PROMPT，TV 是步骤 4 每块的验收内容。

## 11. 步骤 4（第 2 关）：全系统账本

**范围**（`notes/scope_rules.py` → `notes/scope.csv`，按文件划定）。nvflare 包共 1,217 个文件、229,361 行：

| 分类 | 代码行 | 文件 | 理由（STANDARD §8） |
|---|---:|---:|---|
| 排除：工具链 | 44,678 | 155 | provisioning、CLI、打包、job 配置和 recipe 生成，离线运行，不参与运行时组件交互 |
| 排除：数值聚合、过滤器、统计、PSI、同态加密 | 11,952 | 110 | 算出来的数值不在范围内；结果类别已在 workflow（Model 组）建模 |
| 排除：ML 框架适配 | 10,146 | 76 | PyTorch/TF/HF/Lightning/sklearn/MONAI 的模型与张量转换，组件内部，没有生命周期状态 |
| 排除：日志、指标、实验跟踪、统计上报 | 6,634 | 33 | 只写的旁路输出 |
| 排除：安全和机密计算 | 5,910 | 38 | 证书、签名、加密、机密计算需要攻击者模型；token 只当身份代数 |
| 排除：simulator | 4,048 | 27 | 单进程运行模式，不是部署形态 |
| 排除：dashboard / web UI | 1,669 | 14 | 不参与 job 生命周期 |
| 校准区（步骤 2） | 31,246 | 47 | — |
| 范围内，分 7 块 | 113,108 | 717 | — |

**单元提取**（`scripts/extract_units.py` → `notes/units-scope.csv`）：
- 对范围内的文件做统一的 AST 提取：线程入口、回调和消息 handler、对象状态（含按 key 的记录）、进程级全局状态、对外操作。
- 按 STANDARD §13 的初值规则填 `lifetime`、`sharing`，再按选择规则标出选中的单元。
- 全部写进账本：每块开建时逐行读代码复核，改为复核后的行。第一块已复核（`notes/ledger.d/11_c1.py`），其余在 `notes/ledger.d/90_scope_auto.py`。
- 对照：原 regex 粗扫在范围内有 947 个候选、70 个线程创建点，提取全部覆盖，另有 2 处是线程池创建。

| 块 | 区域 | 代码行 | 文件 | 粗扫候选 | 线程点 | 提取单元 | 规则选中 | 估计 spec 行（按选中单元 / 按代码行） |
|---|---|---:|---:|---:|---:|---:|---:|---|
| 1 | SP/CP 进程入口和重启、注册、心跳、服务器 admin | 9,168 | 41 | 62 | 3 | 128 | 65 | 550 / 1,180 |
| 2 | CP 侧 admin 命令代理、aux、admin 协议（hci）和 admin API | 13,171 | 62 | 93 | 6 | 184 | 131 | 1,110 / 1,700 |
| 3 | task worker、client API、其余 executor / launcher / workflow / widget、apis | 38,154 | 248 | 311 | 14 | 501 | 359 | 3,050 / 4,930 |
| 4 | 外部进程集成：XGBoost、Flower、TIE、tensor stream、P2P | 12,294 | 104 | 113 | 4 | 296 | 147 | 1,250 / 1,590 |
| 5 | edge、collab | 12,602 | 101 | 136 | 14 | 187 | 128 | 1,090 / 1,630 |
| 6 | 其余运行时工具（配置、组件、data event） | 9,896 | 79 | 46 | 2 | 51 | 32 | 270 / 1,280 |
| 7 | f3 传输层（cellnet、drivers、streaming、SFM、QAT） | 17,793 | 82 | 186 | 27 | 373 | 266 | 2,260 / 2,300 |

- **估计 spec 行的换算**：校准区自动选中 475 个单元，最终建模 131 行，spec 4,035 行，即每个选中单元约 8.5 行、每千行代码约 129 行。
- **第一块的实际情况**：新增 146 行 spec，低于估计。原因是第一块的大部分单元，要么已由校准区的组覆盖（服务器命令代理、部署、退出码文件），要么是配置解析和只读查询。
- **顺序**：按依赖从被依赖到依赖它的排，f3 放最后。f3 放最后，也用来检验"协议层粗化后产出会下降"。

**两列补到校准区的 153 行**：
- 已建模的 131 行都满足选择规则（寿命 ≥ job、共享 ≥ 跨组件）。
- 满足规则却被排除的 13 行，都有别的理由：没有对外的失败结果、已被别的行覆盖、时序假设撤回。
- 其中 `Model.x.helperTotals` 原先以"数值内部"排除。新两列把它标出来了：寿命跨轮（默认聚合器的 `reset()` 是空操作），读写跨线程。§10 的校准区新增根因正出在这里，这一行的理由已改写。
