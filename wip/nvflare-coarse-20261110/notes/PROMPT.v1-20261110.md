# 任务：NVFlare 全系统粗粒度组合建模

工作目录：`~/nvflare-coarse-20261110/`（本文件所在目录）。

## 1. 动机

NVFlare 这类大型控制面系统里，单个组件的逻辑不复杂，消息层面的协议交互也简单；复杂度在几万行代码、几十个组件的组合上。上一个案例（`~/nvflare-remix-20261103`，下称 remix）在真实代码上复现了 22 个根因，按机制分：

- A 异常路径（调用抛异常，长期线程退出或状态改了一半）：C1-B、H11、T1、T1-b、T2、T3、S1、H04
- B 重启和身份（重启后内存状态丢失、新旧代身份混淆、进程全局状态被继承）：R1、R2、V7、H07、H08
- C 线程交错：C1-A、S4、N2、H03、H05
- D 消息丢失：L13、H01
- 其他：H06（事件分发）、L5（跨节点时钟）

已评估严重度的 16 个里，高严重度 6 个全在 A/B。Phase 1 没点名的 14 个几乎都跨进程、跨组件，而且都浅：两三个组件各出一个特殊情况凑在一起。反过来，remix 里最细的部分（payload，2,422 行）这次产出 0 个；只有 187 行的 Reg 组出了 3 个。

所以这次的做法是：**极粗化每个组件，只保留它的 happy path、错误结果和特殊情况，以及这些结果对别的组件的影响；把整个 NVFlare 都按同一个标准建进来，再组合起来做系统扫描。** 有价值的问题出在"组件 A 对组件 B 某个特殊情况的假设不成立"的地方，例如：

| 根因 | 调用方的假设 | 实际 |
|---|---|---|
| V7 | CP 重启了，它的 CJ 也死了 | K8s 下 Pod 不随 CP 退出，能跑完训练 |
| H20 | terminate 返回了，资源就能释放 | 删除 Pod 失败时 Pod 还在跑 |
| H07 | 一个 job 只有一代 launch 记录 | 旧 handler 删掉替换 launch 的新记录 |
| C1-A | 走到 except 分支时没人写过终态 | completion 线程已经发布了终态 |
| R2 | client 的身份就是启动 job 时的 token | 重新登录换了 token，通知按旧 token 匹配不上 |

目标：在 NVFlare 上找到约 100 个"组合上的问题"（定义见 §6）。这是冲刺目标，不是必须达到的门槛；更重要的是标准在没覆盖过的区域里的产出。主指标是：新区域里可能性和严重度都在"中"以上、在真实代码上复现的根因数（见 §6）。

## 2. 输入（全部只读，不要写，不要拷贝大目录）

- NVFlare 源码，pin `c411a201ead0ec2d4bd0df27fc8b88955c086cfd`：`/home/ubuntu/nvflare-integrated-model-20261103/sources/current`
- remix 工作目录 `~/nvflare-remix-20261103`：
  - `DESIGN.md`（端口、组合规则、静态检查；§16 是 v11 的粗变体方案）
  - `RESULTS.md`（§12 的状态空间诊断和 v7 搜索改造；§16.5、§18.3 是根因汇总）
  - `notes/impact-assessment.md`（严重度、可能性）、`notes/v11-audit.md`、`notes/timing-inventory.md`、`notes/phase1-hazards.md`
  - `spec/`（粗变体 `*_C.tla`、`Trainer_A.tla`、`Trainer_X.tla`，端口 `Ports*.tla`，`Consts.tla`、`Timing.tla`、`JobPhase.tla`、`GenericProps.tla`、`rarity.json`、`registry.json`）
  - `scripts/`（`gen_mix.py`、`mkmc.py`、`run_mc.py`、`ckpt.py`、`tlc.sh`、`rarity.py`、`ce.py`、`hunt.py`）
  - `checks/confirm/*.py`（各根因的真实代码复现脚本）
  - `lib/tla2tools.jar`（2026.09 nightly）、`lib/CommunityModules-deps.jar`

## 3. 工作目录和资源

- **开工前先查磁盘**（`df -h /home/ubuntu`）。工作目录所在的 `/home/ubuntu` 和容器根分区 `/`（含 `/tmp`）不是同一个设备，根分区很小。工作目录所在设备的可用空间少于 30 GB 时不要跑 TLC：把可清理的候选（路径、大小、是什么、是否已备份；remix 已同步到 `~/specula-case-studies-nvflare-remix-20261105/wip/nvflare-remix-20261103/`，但 `logs/` 没有同步）写进 `notes/cleanup-candidates.md`，停下来让用户批准。**你自己不删工作目录以外的任何东西。**
- 把需要的 remix 粗层和脚本拷进本目录（小文件，几 MB）。细变体（`*_F.tla`）不拷，需要时去 remix 里只读参考。
- TLC 的 `-metadir`、`TMPDIR`、`java.io.tmpdir` 都放在本目录下，绝不放 `/tmp`（/tmp 写满会 SIGBUS，所有命令都会卡死）。
- CPU：机器 96 核，你最多同时用 64 个 TLC worker。每个 JVM 显式设 `-Xmx`。
- 长时间的 TLC 运行用 `setsid nohup ... &` 脱离启动，日志写在本目录，记下 PID。等待时按 PID 查，不要用会匹配到自己的 `pgrep -f`。

## 4. 粗粒度标准（第一件事：写成 `STANDARD.md`）

标准是这次的核心产物，必须是通用的书面契约，对所有组件统一适用。至少包括：

1. **组件单位**：一个长期线程或 handler，或者一个有状态对象（连同它的锁）。沿用 remix 的端口约定：每组一个自己写的端口变量，加上只追加的消息日志；生成器的静态检查（只写自己的变量、只发自己拥有的消息类型、不引用别组私有变量）保留。
2. **每个对外操作的四种结果**：成功；影响发生前失败；影响已发生但报失败；影响只做了一半。每种结果写清对外的影响（发了什么消息、改了什么端口、释放了什么、留下了什么记录、哪个线程还活着）。
3. **失败要有原因**：抛异常、返回 None、找不到记录等，写成别的组件状态上的条件（例如"该 job 已被删除""token 已被替换""字典正在被另一个线程修改"）。没有明确原因的失败（存储 EIO、磁盘满）作为计价故障，权重进 `rarity.json`。
4. **状态和身份**：每个状态标明持久化还是只在内存（进程重启后丢失）；每个按 key 的记录标明 key 和它代表的那一代身份（launch、token、attempt、job）。进程级全局状态（`os.environ`、模块级变量）单独标出。
5. **步骤**：一个对外可见的影响（别的组件能看到或能在上面动作）单独成一步；组件内部步骤全部合并。生命周期窗口（例如"工作流返回后 monitor 还在跑"、"关机开始时一轮调度已经在跑"）必须是两步。
6. **运维事件清单**：SP/CP/SJ/CJ 重启、重试、删除、relaunch、超时、重新登录、同 site 第二个 job、管理员 abort / shutdown / restart。这些按常见事件处理（低价或免费）；罕见故障计价。
7. **性质**（通用，不按具体 bug 写）：
   - 静止状态下的后果性质：系统里除故障外再没有动作可走时，每个提交的 job 都有和实际发生的事相符的终态；每个分配的资源都已释放，且没有同时分给两个 job；没有孤儿进程还在跑却没人管。
   - 每个长期线程都还活着（`xxxCrashed` 标志为假）。
   - 记为 COMPLETED 的 job 没有发生过 panic、没有丢过结果。
8. **排除**：数值、ML 计算、工具链（provisioning、CLI 打包）、安全鉴权、simulator、dashboard。排除要写理由。
9. **覆盖账本格式**（`notes/ledger.*`，建议 CSV 或 JSONL）：每行一个单元（线程入口 / 对外操作 / 内存状态 / 按 key 的记录），列：id、`file:line`、单元类型、所属组、建模的结果、失败原因条件或计价故障名、对外影响、状态（已建模 / 排除及理由）、对应的 spec 动作名。

**防拟合规则**：spec 里每个动作和故障都标注它对应的账本行 id，不出现 bug 编号。不允许为某个已知 bug 单独加机制；如果通用标准到不了某个已知 bug，把它记为标准的盲区，修改标准本身并对所有组件统一生效。

## 5. 步骤

### 步骤 0：准备
磁盘检查（§3）；拷贝 remix 粗层和脚本；把生成器改成只用粗变体（去掉按 site 选粒度、covering array、自由组合和完整组合里的 receipt；端口和静态检查保留）。

### 步骤 1：写 `STANDARD.md` 和账本格式

### 步骤 2：校准（在 remix 已覆盖的区域上）
1. 把拷来的粗层按标准改造（四种结果、失败原因、状态和身份标注、通用性质），同时为这片区域建账本。
2. 用 §5 步骤 5 的系统扫描方式（不是盲搜，不用按 bug 写的性质）跑这片区域。
3. 对照 remix 有模型反例的 21 个根因：C1-A、C1-B、H08、H11、T1、T1-b、T2、T3、R1、R2、L13、H03、N2、S1、S4、H01、V7、H06、H07、H04、H05。每个记：被扫描找到（哪个格子、深度、耗时）/ 只能靠定向见证到达 / 到不了（缺的是标准的哪一条）。
4. 同时记假警报：扫描报出、但判为模型错误或现实不可达的反例，各是什么原因。
5. **写进 `RESULTS.md` 后停下来，向用户汇报，等确认再进入步骤 3。**

### 步骤 3：全系统覆盖账本
对范围内所有代码做局部提取（静态分析 + 读代码），把单元登记进账本。参考：nvflare 包共 22.9 万行；用正则粗扫的线程/定时器/线程池创建点 122 个，remix 的 spec 只引用到其中 35 个。没覆盖、并发又多的区域：`fuel/f3`（streaming、cellnet、drivers）、`private/fed/app`（进程入口、启停、重启）、`app_opt/xgboost/histogram_based_v2`、`app_common/tie`、`app_opt/flower`、`edge/`、`app_opt/job_launcher/slurm`、`app_common/streamers`、`fuel/hci`、client 侧剩余部分。范围的最终划定由你按标准第 8 条决定并写明理由。

### 步骤 4：按块扩展
建议顺序：f3（建成一个 Cell 组，向外暴露连接状态，由它驱动 Net 的投递和丢失，已有组不用改）→ 进程入口和重启 → 外部进程集成（xgboost / tie / flower）→ edge → Slurm → 其余。**边建边组合**：每块建完就和邻居组合冒烟，不要等全部建完。每块验收：
- 账本对应行都填上；
- 模板里每种结果都有可到达的见证；
- 和邻居组合冒烟，无死锁、无性质违例（或违例已分诊）；
- 至少一条真实 happy-path trace 和一条真实错误路径 trace 被接受，至少一条改错 trace 被拒绝（做法同 remix `checks/trace/`）；
- 静态检查通过，SANY 通过。

### 步骤 5：系统扫描
对每个"失败点或运维事件 × 生命周期阶段"组合：用 `ckpt.py` 取该阶段的检查点，只开这一个故障（加上它需要的开关），跑有界 BFS。能切片就切片：只放这个失败点和依赖它的影响的那几个组。每个格子的结果（干净 / 反例 / 时限停止）记进覆盖表 `checks/sweep/`。反例分诊：按根因去重；判模型错误还是候选；用计价算出可能性档位并排序。

### 步骤 6：真实代码确认
在 pin 上写复现脚本放 `checks/confirm/`，做法同 remix（真实类和线程，尽量不用强制调度和注入；需要时写明用了什么）。核对上游 main 上相关文件是否变化、有没有相关 issue（只读 GitHub）。**任何东西都不提交上游。**

## 6. 计数口径

- 按根因计数，同一根因的不同触发只算一个。
- "组合上的问题"：原因、缺陷、后果至少跨两个组。
- 证据等级分开报，不合并：REPRODUCED（再分无强制 / 靠强制调度、桩、注入故障或时序巧合）、MASKED、STATIC（只读代码确认）、MODEL-ONLY。
- 按可能性分档（高 / 中 / 低 / 很低，定义同 `notes/impact-assessment.md`）。
- 分开报：remix 已有的 22 个；这次在校准区域新增的；这次在新区域找到的。最后一项是检验标准的主要指标。
- 有界检查跑满时限不算证明；SANY 通过、有界 TLC 不等于完成。

## 7. 记录

- `STANDARD.md`、`RESULTS.md`（唯一的结果汇总，中文，按里程碑更新）、`notes/ledger.*`、`notes/cleanup-candidates.md`（需要时）。不要为日常进度新建报告文件。
- 任何"模型修正"都必须带代码锚点或 trace 证据，不能按"系统应该怎样"去修。remix 里把"panic 一定被记录"当模型错误修掉，后来 L13 证明真实代码确实会丢。

## 8. 已知的坑（remix 踩过的）

- 用 `lib/tla2tools.jar`（2026.09 nightly）。`tla2tools-2.20-old.jar` 在 `-simulate` 找到违例后 worker 会崩，run 挂起，违例丢失。
- TLC 会预先计算零参数定义。在 `INSTANCE ... WITH Faults <- X` 里，依赖 `Faults` 的零参数定义仍沿用旧值，定价失效；写成以故障集为参数的算子。
- `ACTION_CONSTRAINT` 在检查不变式之前不生效，不能用它剪掉违例路径。
- TLC 日志里的 `trace length mean` 不可信；不查 deadlock 时终态会一直 stutter 到深度上限。
- 按步抽签的节流会过度采样"一直可用"的故障，trace 走不到 RUNNING 之后；用 `JobPhase.tla` 的按阶段放行和检查点 BFS。宣布"没有新违例"之前先测覆盖：trace 到达了哪些阶段。
- 没有可走步骤时 TLC 沿长 `\/` 链递归，栈要 `-Xss64m`（`tlc.sh` 已设）；`-XX:-UsePerfData` 也已设。
- 性质语义写偏是常见错误（remix 里 RECEIVED 被当成"已接受"）。

## 9. 禁止

- 不修改 remix 工作目录、Codex 工作区 `~/nvflare-integrated-model-20261103`、Specula 仓库、case-studies worktree。
- 不做外部写操作：不 push、不开 issue/PR/评论、不发消息。不 commit，除非用户要求。
- 不删除本目录以外的任何文件。
