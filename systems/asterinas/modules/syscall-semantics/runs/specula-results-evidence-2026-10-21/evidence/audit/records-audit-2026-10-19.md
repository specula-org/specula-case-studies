# 运行与发现记录审计（2026-10-19）

这份报告列出 specula-profile 里运行记录、发现目录、状态文档和项目记忆中经核实的错误，供修订这些记录时逐条处理。审计全程只读：没有改动主 checkout、原生 run 产物、Asterinas 或 Specula 仓库，也没有在 GitHub 上写任何内容。

逐条数据在 [records-audit-issues-2026-10-19.csv](records-audit-issues-2026-10-19.csv)，含每条的复核结论、建议改法和涉及文档。运行汇总和发现与 issue 对照表见 [specula-run-history-2026-10-19.md](specula-run-history-2026-10-19.md) 和 [asterinas-findings-issue-map-2026-10-19.csv](asterinas-findings-issue-map-2026-10-19.csv)，这两份已按本报告更正。

## 结论

- 共复核 158 个根问题：之前已知的 15 个，加上两轮审计新找到的 143 个。116 个确认，32 个两位核对者意见不一，10 个被否定。
- 确认和有争议的问题中，高严重度 8 个、中等 32 个、低 108 个。高严重度的问题都可能误导上游报告或修复决策，应先改。
- 第三轮审计找到 59 条原始发现，因暂停未归并、未复核，单列在最后。
- 审计没有收敛：第二轮新增 22 个根问题，第三轮还有 59 条原始发现，多为低严重度。按你的要求，在第三轮之后停止，所以这不是穷尽结果。

“高”指可能误导修复、上游报告或上游决策；“中”指会误导状态跟踪或证据判断；“低”指措辞、计数、路径或不影响结论的细节。严重度取两位核对者中较高的一个。

## 方法与限制

1. 第一轮用 21 个只读审计单元覆盖：发现目录的每一行和其他各节、`current-state.md`、各交接文档、每个 run 的原生产物、Specula 版本历史、本地分支与推送状态、全部上游 issue/PR 引用、链接与路径、输入哈希、今天的笔记和 CSV，以及项目记忆。共 297 条原始发现，归并为 121 个根问题。
2. 每个根问题由两位独立核对者重新取证：A 从事实来源重新推导并尝试否定；B 判断它是真缺陷，还是已标注日期的历史快照或无关紧要的措辞。两人都认定为缺陷才算“确认”，只有一人认定算“有争议”，两人都否定算“否定”。之前已知的 15 条中，12 条在第一次运行中用三位核对者复核。
3. 补漏轮次由一个评审 agent 根据未覆盖范围提出新的审计单元。第二轮 6 个单元找到 22 个新根问题并已复核；第三轮 6 个单元找到 59 条原始发现，未复核。
4. 第一次运行因账号用量上限中断，大部分复核失败，之后分批重跑。两次运行合计约 520 个 agent，第一次约 1310 万 subagent token；第二次的用量因中途停止没有拿到。

## 高严重度（8）

### 1. #3964 被记成只对应 AST-80（K1、K14，确认）

目录、id-map、`current-state.md`、futex 的 `result.md` 都写 AST-80 对应 #3964、AST-79 没有上游报告，原生报告也把 MC-1 记为 NEW。实际上 #3964（bdm-k，10-06，open，无关联 PR）的主体就是 AST-79：跨 bucket requeue 后超时清理只搜原 bucket，条目留下；报告者 10-14 又补了 musl 复现程序，Asterinas 返回 0 而 Linux 返回 ETIMEDOUT。第二段才是 AST-80。#3964 没提到死条目消耗后续配额、困住 live waiter 的后果。

- 成因：futex 确认阶段每个 finding 一个独立 pi worker。MC-1 的 worker 最先运行，只用 pi 的通用 `web_search`，三组查询都没搜到 #3964；MC-2 的 worker 约 55 分钟后用 `futex_val_to_max_count` 搜到了；MC-3、MC-4 的 worker 也在各自报告中写明 #3964 覆盖 cleanup-bucket 问题。流水线不会回头修改已给出的 verdict，所以确认报告汇总（`confirmed-bugs.md:5`）记为 “3 NEW + 1 KNOWN”。10-11 的目录合并和 10-12 的本地审计都明确不刷新上游。
- 原生报告不改，更正写在目录 AST-79/80 行、“Current upstream cross-check”、futex campaign 行、id-map 和 futex `result.md`。

### 2. AST-48 写成“未观察到 panic”（K2，确认）

目录 AST-48 行写 “no complete runtime case and no observed panic impact”。TLPI 原包（`tlpi-audit-2026-09-14/package/findings.json` F05）的标题写明 todo! 在有效状态下可达，qualification 写的是“没有运行此触发，panic 的整机影响没有测量”；空的 `provided_cases` 记录在 `finding-map.json`。编目时把“没运行所以没看到”压缩成了像“没有影响”的说法。上游 #3962（open，10-06，无 PR）报告了无特权用户可触发的整核 panic，日志来自上游 main `73ef2b9b`，另有一句说在 `0c60537098f4` 上也观察到。该文件在 `a5449e62`、`0c605370`、`73ef2b9b` 和今天的上游 main 上是同一个 blob。本地没有运行时复现。

### 3. AST-02/07/14/19 已被上游修复，记录没跟上（K3、K5 高，K6 中，均确认）

- AST-02 的空写入部分和 AST-14：你的 PR #3875 于 09-20 提交、09-29 合入，改动的正是本地批次那 6 个文件（exFAT 部分相同，ramfs guard 移到了取时钟和加锁之前）。目录、id-map、`current-state.md`、`active-specula-run-handoff.md`、`empty-write-batch-2026-09-16/README.md` 和 AST-02 的 description 仍写 FIX_PENDING_VALIDATION、未提交上游、运行时验证推迟，引用的工作目录 `/home/chin39/Documents/asterinas-ast02-empty-write` 已不存在。AST-02 非空零进度 fault 路径（01a CASE A/C/D/E、01b MC-8）仍未修。
- AST-07：#3892（joshlf，09-22）直接报告了这个机制，PR #3959（10-11）让 `Segment::slice` 拒绝空范围。
- AST-19：PR #3984（10-13）在 `set_time` 和 `try_read` 中失效 pollee，并加了回归测试。
- 09-24 的发现打包其实已经发现 AST-02 有 PR #3875 并指出目录没有记录，之后没人更新目录。以上都只做了静态核对。

### 4. PR #3576 已重推，AST-09/39 的覆盖判断过时（K7，确认，部分成立）

PR #3576 在 09-14 之后被强推了四次（10-09 两次、10-10、10-16），head 从 `8e02d0e94` 变成 `694f86051`。这是同样三个 commit 的 rebase，唯一的内容变化在 commit 1 的 `syscall_restart.c` 测试。“带超时的 socket syscall 不重启”这个 commit 7 月就在 PR 里，不是新增；我之前的笔记把它写成新增，已更正。目录对 AST-09“经检查覆盖”和 AST-39“部分覆盖”的判断基于旧 head，需要按新 head 复核。记忆里“自 07-23 起无活动”和 “`pr-3576` 在 asterinas-dev 中”也已过时，后者这个 ref 已不存在。

### 5. AST-08 已出现在上游汇总 issue #3920（R1-1，确认）

#3920（joshlf，09-22 起，open）第 11 项报告了 x86 VT-d DMA unmap 清除二级 PTE 却不失效 IOTLB，引用的正是 `unmap_dma_remap` 的 FIXME。它没写释放帧被重用的后果，也没有复现，这两点正是 AST-08 的 vIOMMU A/B 证据补上的。上游 main 仍保留该 FIXME，问题未修。AST-08 的 description、目录行、我的笔记和 CSV、记忆都写“未报告/无直接匹配”，09-14 的判断在当时是对的。以后为 AST-08 起草 issue 或 PR 应引用 #3920 第 11 项。

### 6. AST-35 的 TCP 路径已复现并有本地修复，目录没记（R1-28，确认）

asterinas-dev 的分支 `fix/tcp-user-copy-atomic`（`4d1ed282b`，09-27，基于上游 main `3eb661e12`，工作目录 `/home/chin39/Documents/asterinas-tcp-fault`，未推送）的提交信息记录了：TCP send/recv 在另一线程改动地址空间时碰到尚未建立映射的用户页，触发 “This function might break atomic mode” panic，在 Asterinas NixOS 里执行 `nix develop` 时遇到。分支带回归测试 `tcp_unpopulated_buffer.c`。目录没有记录这些，也没有引用跟踪这类问题的上游 open issue #2165。UDP 路径仍是线索。更正（10-20 Codex 复查）：之前这里写的 SMP=4、Linux 对照和 7/7 通过等细节，提交信息里都没有，工作区也没有保留运行日志，所以这些细节未经证实，AST-35 在目录里保持 SOURCE LEAD。

## 中等严重度（32，其中 K6 已并入上面第 3 条）

### 上游状态与发现目录

- **AST-79 的先例归错了 PR（R1-20，确认）。** #1587 由 PR #1642 关闭，但 #1642 只让唤醒跳过 waker 已关闭的条目，没有加超时后的出队清理。出队清理是 PR #2377（`888eecb35`，2025-08-26）加的，PR #2515 又改了返回值。目录和 futex `result.md` 沿用了原生报告的混淆。
- **AST-72 已有候选修复分支，没有记录（R1-19，确认）。** 你 fork 上的 `fix/virtiofs-empty-write`（`088088505`，09-18，基于 `bc12195df`）给 virtiofs `direct_write_at` 加了 `write_len == 0` 早返回，没有测试，也没开 PR。目录、后端审计记录、发现打包和我的笔记都把 AST-72 写成没有补丁的线索。AST-72 仍是 SOURCE LEAD、运行 NOT_RUN。
- **PR #3778 的状态记录有三处过时（K10、R1-43、R1-46，确认）。** 09-11 你把 lock-order 修复和测试 CPU 放置的改动提交并两次强推，PR head 变成 4 个 commit 的 `d007cbb62`，同时回复了两个 review 线程。`pr-3778-handoff.md`、`workspace-handoff.md`、`ast-validation-2026-09-02/README.md` 和记忆仍写 GitHub 上是 `3aa75efd3`、本地 5 个 commit 的 `690a8651f` 未推送，还有“不要提交”的指示。09-14 cchanging 接受了 preadv 的解释，同时请求把 clone-and-limit 逻辑移到 `VmIo` 的默认方法，这条评论没有回复，也没有记录。10-08 本地分支又 rebase 成 `35244712f`（patch-id 与 PR 的 4 个 commit 相同），未推送，旧 head 保留为 `backup/ramfs-read-past-eof-pre-rebase-20261008`。
- **AST-72..93 仍标为未做上游去重（K8，确认）。** 目录自己的限定写得准确，但 10-19 已对其中 12 条做过关键词去重，结果只在我的笔记和 CSV 里。应在目录里补一条带日期的记录，说明这只是关键词搜索。
- **AST-75 记为“0 new”依赖自我引用（R1-105，有争议）。** 原生确认把 AST-75 记为 KNOWN，引用的是同一 run 的 TV-2 记录。A 认为应算这个非盲测 run 新增的一条；B 指出 10-03 的 memfd 源码契约文档已写过 MAP_FIXED 先拆除再检查 seal，所以不算新。需要你判断计数口径。
- **原生报告的行号指向插桩副本（R2-15，确认）。** futex（AST-80..83）、memfd（AST-76/77）、flock（AST-85/86）、SCM（AST-32）的 `confirmed-bugs.md` 中未标注的行号来自各 run 的插桩源码副本，有的连副本也偏 1 到 3 行，在 pin `0c6053709` 上对不上。原生报告不改，应在目录或 id-map 加一条坐标勘误。

### 当前状态文档过时

- **Specula 版本和仓库身份表过时（K9、R1-8，确认）。** `current-state.md` 的 “Current repositories and run identity” 表还写 Specula `4bb2202b`、上游 `bc12195`，以及已删除的工作目录，同一文件另一节写 `aa93be67`。Specula 今天 11:13 已快进到 `39b4a015`（v1.2.0-22，新增 `confirmlib.py` 的 verdict 绑定和 `pipelinelib.py` 的修复轮数保留，以及 `skills/specula-lite`），`tool-identity.json`、eventfd 的 `inputs.json`、升级评估和目录 Evidence 一节仍把 `aa93be67` 或 `4bb2202b` 当作当前版本。Codex 插件缓存仍是 1.2.0，与新 checkout 不再一致。
- **“先读这里”的段落停在 9 月（R1-32，确认）。** `current-state.md` 的 09-16 快照和 `active-specula-run-handoff.md` 的 “Read this first” 仍写目录是 AST-01..74、最新完成的 campaign 是 01b。实际是 AST-01..93，之后 memfd、futex、SCM_RIGHTS、flock 都跑完了。
- **flock 和 wait/reap 被写成没有 run（R1-38，确认）。** `guidance-and-prompts.md` 由 `62b8113` 加入的 “No native phase has run for these two prepared IDs” 没有限定；两条 lane 已运行到 10-10。`current-state.md` 中对应一节是标注日期的历史记录，问题较轻。
- **安全审计文档的“当前”列描述的是 08-23 之前的计划（R1-10，确认）。** `asterinas-syscall-security-audit.md` 的 “Current classification”“Current disposition”“Next priority” 仍写候选或只有 dry-run，包括后来已完整运行的 01a、01b、memfd、futex、wait/reap、flock、SCM_RIGHTS，以及已复现的 AST-03、AST-32。
- **MC-6 的屏蔽原因写错（R1-33，确认）。** `current-state.md`、`active-specula-run-handoff.md` 和 `aster-syssec-reverse-contribution.md` 仍说 AST-24 是被按序 virtqueue 屏蔽、换 NVMe 会暴露。01a 原生 debate 已更正：屏蔽来自每设备单 worker 的 FIFO staging queue 和 `zero_new_blocks` 中的阻塞 `wait_all()`，NVMe 也测过，同样被屏蔽。
- **watermark_scale_factor=2000 是持久设置（R1-34，确认）。** 记录和记忆都说这是运行时设置、已改回 10、没有持久来源。实际上 NixOS 的 `/etc/sysctl.d/60-nixos.conf` 设为 2000，09-29 起的每个系统 generation 都如此，10-12 重启后又回到 2000。10-09 的 `sysctl -w` 只是临时改动。
- **本地提交和未提交的记录（K11，确认）。** `62b8113`（并入 AST-79..93）比 origin/main `4e1c569` 超前一个提交且未推送，所以 GitHub 上看到的仍是 78 条目录、25 条 REPRODUCED。10-12 审计的 11 个修改文件和 4 个未跟踪项也都未提交。
- **handoff-01b 里 AST-11 的提交号过时（R1-2，确认）。** 它仍写 `d5b645d84` + `97199dd30`，而 `fix/exfat-write-size-race` 自 09-14 起是 `864356cec` + `3ece54702`（基于 `bc12195df`，在 `/home/chin39/Documents/asterinas-exfat`）。目录、`current-state.md` 和 active handoff 仍把 handoff-01b 当作当前提交号的权威来源。
- **01a-v2 review 交接的身份信息不对（R1-48，确认）。** 交接引用的路径现在放的是 v1，v2 在 `-v2.md`（`a64c6865`）。review 已于 09-03 完成并给出 E1 到 E9 的修改，没有 run 用过 v2。照交接操作会去审错误的文件。
- **教程说没有 run 用过 pi（R1-47，确认）。** `specula-tutorial.md` 这样写，但 GLM、memfd、futex、flock、SCM_RIGHTS 的确认都走 pi GLM-5.3，01b 的确认走 pi Kimi-K3。
- **Specula 经验报告已提交为 #168（R1-91，确认）。** `specula-experience-issue-2026-09.md` 仍标为草稿；它已于 09-24 以缩短版提交为 specula-org/Specula#168，维护者有回复。

### run 记录与证据

- **GLM run 的 Specula 身份（K4，确认）。** analysis 到 validation 和 08-26/27 的确认跑在 `c6aa3dfa`。六个最终确认 verdict（08-28 16:08 到 20:51）来自 14:44 在 feat 分支上的重启，当时的代码是 `f80e458f` 加未提交改动，20:19 才提交为 `9a7b64ff`；分类 20:54 开始，在这次提交之后。`glm53-eval-handoff.md` 和 `workspace-handoff.md` 只写 `c6aa3df`。
- **01b harness 用了未记录的 `d034e000` 代码（R1-63，确认）。** harness agent 按 Codex 插件 1.1.0 的 skill 需要 `specula syscall-inputs`，而 `4bb2202b` 没有这个命令，所以它通过 `harness/tools/specula` 和 `dispatch.py` 跑了本地专有提交 `d034e000` 里的 `syscall_inputs.py`（不在 origin 也不在 fork）。`run-record.md` 只写 `4bb2202b`，原生报告还把它称作上游代码。
- **FD run 的 policy retry 次数写错（R1-57，确认）。** CR-5 的第一次中断是 adapter exit 1，不是 76，没有触发 retry；21:30 的那次属于 CR-6；Stage 2 的恢复用完了两次 retry。`workflow-validation.md` 和 `active-stage3-handoff.md` 的计数不对。
- **AST-83 的 “371,000 次竞争迭代”包含对照（R1-24，确认）。** 其中 Phase E 的 1,000 次是不竞争的顺序对照，竞争迭代是 370,000 次。测试只检查 `sched_setaffinity` 调用成功，Asterinas 不会因 affinity 变化迁移线程，所以没有确立不同 CPU 的放置。
- **SCM 的 20% overlap 限制并非用户接受（R2-9，确认）。** 用户 10-10 只接受了 PEEK 不在默认 MC.cfg 中这一条。overlap 3.2%/3.6% 低于 20% 这一条是 lane controller 在 gate 6 接受的；“达不到 20% 就记录实际值”那句话是 coordinator 转达时加的。目录和 id-map 写的是“两项用户接受的限制”。
- **socket-fd 范围评估引用的 Linux 行号错了（R2-14，确认）。** `socket-fd-scopes.md` 中 v6.15 的四处行号范围落在无关函数里；`scm-rights/contracts.md` 中 v6.16.5 的引用是对的。

### 成本与身份记录

- **memfd 的 Codex 成本少算（R1-73，确认）。** 记录写 $95.6，原生记录合计至少 $106.63，加上单独重跑的 spec review 至少 $111.67，另有一次流水线外的 spec-fix 会话没有记录成本。
- **resume 的 Codex 会话用量被重复计算（R1-80，确认）。** resume 后的 usage 文件是累计值。futex 的合计把 attempt 1 算了两次，SCM 没有说明，flock attempt 1 引用的是累计文件。
- **SCM 的 GLM 确认 token 数少算（R2-5，确认）。** `--fresh-context` 的每次 findings 尝试都会覆盖 `turn01_A.usage.json`。从检查点恢复后，attempt 1 到 3 约 48.7M token（含 attempt 4 约 55.6M），记录的 35.1M 把较早的尝试当成了 0。
- **10 月 lane 期间 agent CLI 版本变过（R1-81，确认）。** Codex CLI 从 0.160.0 变到 0.162.0、0.162.1，pi 从 0.99.2 变到 1.1.0 并改了设置，claude-code 带 hooks 运行。两份 `tool-identity.json` 只记了 pi 0.99.2，没记 Codex CLI 版本。

### 项目记忆

- **policy block 的记忆与 AGENTS.md 和实际做法冲突（R2-10，确认）。** 记忆写“遇到 policy block 不要停下来问用户，这覆盖默认的不换模型规则”。实际上 10-05 coordinator 转达这条规则时，权限分类器把重试判为绕过 provider 保护而拒绝；之后每次 policy block 都交给你决定：futex 是你指定用 Opus 5.5 重跑 validation，SCM 是你选择原样恢复 Codex。AGENTS.md 也禁止加 fallback 或静默换模型。已在本次更新记忆。

## 低严重度与有争议（低）

下表列出 108 个低严重度根问题（77 个确认、31 个有争议），标题保留核对时的英文原文。每条的建议改法和涉及文档见 CSV。

| ID | 状态 | 问题 | 主要涉及文档 |
| --- | --- | --- | --- |
| K12 | 确认 | Identity records omit Codex skill/plugin version | references/active-specula-run-handoff.md; notes/specula-run-history-2026-10-19.md |
| K13 | 有争议 | run.json only records first invocation | notes/specula-run-history-2026-10-19.md; runs/asterinas-private-futex-requeue-20261004T064345Z/run.json 等 |
| K15 | 确认 | 01b launch 85a1 recorded as clean, unverifiable | notes/specula-run-history-2026-10-19.md |
| R1-3 | 确认 | AST-01/04 descriptions claim Linux control used identical binary | reports/asterinas-bug-findings-2026-08/AST-01-ext2-buffered-write-prefix/description.md; reports/asterinas-bug-findings-2026-08/AST-04-read-prefix-efault/description.md 等 |
| R1-4 | 确认 | GLM MC-1 mapping rationale wrongly calls the record read-only | reports/asterinas-bug-findings-2026-08/id-map.md; reports/asterinas-bug-findings-2026-08/reproduced.md 等 |
| R1-5 | 确认 | AST-08 description references nonexistent verification-package.md | reports/asterinas-bug-findings-2026-08/AST-08-iommu-stale-iotlb/description.md |
| R1-6 | 确认 | 01a MC-2/AST-01 #711 KNOWN status misrecorded | reports/asterinas-bug-findings-2026-08/README.md; references/active-specula-run-handoff.md 等 |
| R1-7 | 确认 | AST-06/09 descriptions contradict the 09-14 dedup coverage | reports/asterinas-bug-findings-2026-08/AST-06-append-offset-on-fault/description.md; reports/asterinas-bug-findings-2026-08/AST-09-pipe-readv-eintr-restart/description.md 等 |
| R1-9 | 有争议 | Specula usage docs still pinned to 1.1.0/c6aa3dfa CLI facts | references/specula-tutorial.md; README.md 等 |
| R1-11 | 有争议 | 09-14 dedup labeled current despite later upstream drift for AST-01..71 | references/asterinas-syscall-security-audit.md; reports/asterinas-bug-findings-2026-08/README.md 等 |
| R1-12 | 确认 | AST-37 IoVec::is_empty subcase fixed by #3720 without disposition | reports/asterinas-bug-findings-2026-08/README.md; reports/asterinas-bug-findings-2026-08/id-map.md 等 |
| R1-13 | 有争议 | Repair entry points leave reproduced AST-32/36 under 'pending' | reports/asterinas-bug-findings-2026-08/README.md |
| R1-14 | 确认 | Repair entry claims AST-92/93 confirmation records name fix sites | reports/asterinas-bug-findings-2026-08/README.md |
| R1-15 | 确认 | Notes CSV AST-35 link and AST-32/36 'merged' state misleading | notes/asterinas-findings-issue-map-2026-10-19.csv; notes/specula-run-history-2026-10-19.md |
| R1-16 | 确认 | TLPI intake 'matches current HEAD' no longer true | references/current-state.md |
| R1-17 | 有争议 | TLPI finding-map footer says novelty unchecked despite the dedup | reports/tlpi-audit-2026-09-14/finding-map.md; reports/tlpi-audit-2026-09-14/README.md 等 |
| R1-18 | 有争议 | #3962 run record on lane pin 0c60537098f4 overstated | notes/specula-run-history-2026-10-19.md; memory/asterinas-upstream-status.md |
| R1-21 | 确认 | AST-91 '173 overlapping deliveries' overstates overlap evidence | reports/asterinas-bug-findings-2026-08/README.md; reports/asterinas-bug-findings-2026-08/id-map.md 等 |
| R1-22 | 确认 | Reproduction index described as covering all entries with runtime records | references/active-specula-run-handoff.md |
| R1-23 | 确认 | AST-85 'uninstrumented' run used the instrumented kernel | reports/asterinas-bug-findings-2026-08/README.md; reports/asterinas-bug-findings-2026-08/id-map.md |
| R1-25 | 确认 | AST-75 F_SEAL_WRITE divergence claimed for both overlap cases | reports/asterinas-bug-findings-2026-08/README.md |
| R1-26 | 有争议 | AST-73 still stated as SOURCE LEAD outside the register | reports/asterinas-bug-findings-2026-08/id-map.md; reports/asterinas-bug-findings-2026-08/README.md 等 |
| R1-27 | 确认 | memfd preparation sections still labeled Active/Current | references/current-state.md; references/active-specula-run-handoff.md 等 |
| R1-29 | 有争议 | Wait/reap provisional WR1/WR2 aliases not resolved to AST-92/93 | reports/flock-wait-handoff-2026-10-05/wait-reap/candidate-ledger.md; reports/flock-wait-handoff-2026-10-05/wait-reap/result.md 等 |
| R1-30 | 有争议 | Records disagree on which Asterinas checkout is authoritative | references/current-state.md; reports/parallel-scopes-2026-10-04/futex/result.md 等 |
| R1-31 | 确认 | Lane identity sections claim no change despite checkout and resources changes | reports/parallel-scopes-2026-10-04/scm-rights/result.md; reports/parallel-scopes-2026-10-04/futex/result.md 等 |
| R1-36 | 确认 | Patch-work section cites a gone worktree and nonexistent B1 logs | references/current-state.md; reports/patch-validation-report.md |
| R1-37 | 确认 | Patch validation pristine guard failed open; suite not retained | reports/patch-validation-report.md; references/current-state.md |
| R1-39 | 确认 | 01a completion record omits the NEEDS_IMPROVEMENT validation review | references/active-specula-run-handoff.md; references/current-state.md |
| R1-40 | 确认 | 01a validation duration ~1h52m is unsupported | references/active-specula-run-handoff.md |
| R1-41 | 确认 | 01a confirmation attempt-3 evidence missing; backup location misstated | references/active-specula-run-handoff.md |
| R1-44 | 确认 | Scratch branches/worktrees cited as evidence are deleted | references/pr-3778-handoff.md; reports/ast-validation-2026-09-02/README.md 等 |
| R1-45 | 确认 | ramfs-read-past-eof worktree WIP and stash unrecorded | memory/asterinas-upstream-status.md; references/pr-3778-handoff.md |
| R1-49 | 确认 | README staged execution skips the analysis-only brief gate | README.md |
| R1-50 | 确认 | README preflight claims both Codex pairs are probed | README.md |
| R1-51 | 确认 | README guidance inventory says nine variants | README.md |
| R1-52 | 确认 | guidance-and-prompts guidance map stale | references/guidance-and-prompts.md |
| R1-53 | 确认 | Tutorial archive-hash pointer and artifact path broken | references/specula-tutorial.md; references/current-state.md |
| R1-54 | 确认 | Confirmation prompt disposition list conflicts with the six-way classification | prompts/bug-confirmation.md; prompts/category-b-code-analysis.md |
| R1-55 | 有争议 | AST-01 'submitted upstream' claim has no evidence | references/workspace-handoff.md; reports/ast-validation-2026-09-02/README.md 等 |
| R1-56 | 有争议 | GLM phases 1-3 cost $135.83 unsupported | references/glm53-eval-handoff.md |
| R1-58 | 确认 | FD validation terra override absent from run.json, config lost | references/asterinas-syscall-security-audit.md; README.md 等 |
| R1-59 | 确认 | 01a confirmation debate counts wrong | references/current-state.md; reports/glm53-eval-final-report.md 等 |
| R1-60 | 确认 | 01a harness '22 traces, 59 events' wrong | references/current-state.md; references/active-specula-run-handoff.md |
| R1-61 | 确认 | GLM final report claims all phases completed | reports/glm53-eval-final-report.md |
| R1-62 | 确认 | completed-runs line anchors drifted | reports/specula-scope-assessment-2026-10-02/completed-runs.md |
| R1-64 | 确认 | 01b source-map backup claimed but never made | reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/run-record.md |
| R1-65 | 确认 | 01b attempt 2 duration overstated | reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/run-record.md |
| R1-66 | 有争议 | 01b final report confirm-resume count wrong | reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/final-report.md |
| R1-67 | 确认 | Notes cite invalid commit d76b4dc0 | notes/specula-run-history-2026-10-19.md |
| R1-68 | 确认 | #2269 closure misattributed to stale cleanup | notes/specula-run-history-2026-10-19.md; notes/asterinas-findings-issue-map-2026-10-19.csv 等 |
| R1-69 | 有争议 | 01b prep report checksum count wrong | reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/preparation-report.md |
| R1-70 | 确认 | 01b dry run for executed config v3 unrecorded | reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/run-record.md; reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md |
| R1-74 | 确认 | memfd '90 traces matched' hides duplication | reports/memfd-readiness-review-2026-10-03/gate-3-harness.md; references/current-state.md 等 |
| R1-75 | 有争议 | memfd revised brief reviewed outside the pipeline | references/current-state.md; references/active-specula-run-handoff.md 等 |
| R1-76 | 确认 | memfd gate-4 pi wrapper and extension state unrecorded | reports/memfd-readiness-review-2026-10-03/gate-4-confirmation.md |
| R1-77 | 确认 | memfd reproductions ran on an instrumented kernel; caveat dropped | reports/asterinas-bug-findings-2026-08/README.md; reports/memfd-readiness-review-2026-10-03/gate-4-confirmation.md 等 |
| R1-78 | 确认 | memfd harness dry run unrecorded | reports/memfd-readiness-review-2026-10-03/gate-3-harness.md; reports/memfd-readiness-review-2026-10-03/commands.json |
| R1-79 | 有争议 | pi 'exit 0 on provider error' claim unverifiable | reports/memfd-readiness-review-2026-10-03/README.md; reports/memfd-readiness-review-2026-10-03/readiness-review.json 等 |
| R1-82 | 确认 | SCM MC-1 validator rejection count wrong | reports/parallel-scopes-2026-10-04/scm-rights/result.md |
| R1-83 | 确认 | Dismissed candidate IDs inconsistent in futex/SCM results | reports/parallel-scopes-2026-10-04/futex/result.md; reports/parallel-scopes-2026-10-04/scm-rights/result.md 等 |
| R1-84 | 确认 | Before-review receipts reference the wrong logs | reports/parallel-scopes-2026-10-04/futex/dry-run-full-routing-before-review.json; reports/parallel-scopes-2026-10-04/futex/preflight-before-review.json 等 |
| R1-85 | 确认 | wait/reap d4m 'killed by reaper' wrong | reports/flock-wait-handoff-2026-10-05/wait-reap/result.md; reports/flock-wait-handoff-2026-10-05/wait-reap/execution/result.pre-final-20261010.md |
| R1-86 | 有争议 | flock container removal unrecorded | reports/flock-wait-handoff-2026-10-05/flock/result.md |
| R1-87 | 有争议 | flock findings-resume.sh edited after review | reports/flock-wait-handoff-2026-10-05/flock/execution/memory-measure-change-2026-10-09.md; reports/flock-wait-handoff-2026-10-05/flock/result.md |
| R1-88 | 有争议 | wait/reap gates.md overstates actors_on_distinct_cpus | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/gates.md |
| R1-89 | 确认 | flock SHA256SUMS fails on resources.json and is unannotated | reports/flock-wait-handoff-2026-10-05/README.md; reports/flock-wait-handoff-2026-10-05/SHA256SUMS 等 |
| R1-90 | 有争议 | empty-write-batch retained snapshots gone | reports/empty-write-batch-2026-09-16/README.md; reports/empty-write-batch-2026-09-16/identity.json 等 |
| R1-92 | 有争议 | Experience report tokens-per-finding definitions inconsistent | reports/specula-experience-issue-2026-09.md; specula-org/Specula#168 body |
| R1-94 | 确认 | AST-08 08-07 dynamic reproduction misrecorded | reports/ast-validation-2026-09-02/README.md; reports/cr20/HANDOFF.md 等 |
| R1-95 | 确认 | fixes-patch-review line counts include file headers | reports/ast-validation-2026-09-02/fixes-patch-review.md |
| R1-96 | 确认 | Reverse-contribution doc says seven pitfalls but lists six | reports/aster-syssec-reverse-contribution.md; references/workspace-handoff.md |
| R1-97 | 确认 | CR11 zero-exception claim lacks a retained QEMU log | reports/ast-validation-2026-09-02/README.md; reports/asterinas-findings-pack-2026-09-24/findings/AST-07-segment-empty-slice/finding.md |
| R1-98 | 确认 | AST-10/11 races still described as uncataloged | memory/asterinas-exfat-write-size-race.md; reports/rw-matrix-2026-09-04/README.md |
| R1-100 | 确认 | Access-control docs reference missing 02/04/06 documents | reports/access-control/01-mechanism-inventory.md; reports/access-control/03-capability-sites.md 等 |
| R1-101 | 确认 | Upgrade assessment install-readiness claims false since 10-03 | reports/specula-upgrade-assessment-2026-10-02/README.md; reports/specula-upgrade-assessment-2026-10-02/performance-and-checks.md 等 |
| R1-102 | 确认 | Upgrade assessment line links into the live Specula checkout drifted | reports/specula-upgrade-assessment-2026-10-02/README.md; reports/specula-upgrade-assessment-2026-10-02/reuse-and-workflow.md 等 |
| R1-103 | 确认 | Findings pack meta.json does not match the findings.json schema | reports/asterinas-findings-pack-2026-09-24/README.md |
| R1-104 | 确认 | ultraplan-concurrency-next unverifiable and unindexed | reports/specula-scope-assessment-2026-10-02/ultraplan-concurrency-next-2026-10-12.md; reports/specula-scope-assessment-2026-10-02/README.md 等 |
| R1-106 | 有争议 | Scope assessment pin date is the author date | reports/specula-scope-assessment-2026-10-02/README.md |
| R1-107 | 有争议 | Futex result calls PRs issues | reports/parallel-scopes-2026-10-04/futex/result.md |
| R1-110 | 有争议 | Memory notes describe gone worktrees and main=4ddbfae | memory/specula-profile-main-landing.md; memory/MEMORY.md 等 |
| R1-111 | 有争议 | Futex result links to a nonexistent policy-events.md | reports/parallel-scopes-2026-10-04/futex/result.md |
| R1-112 | 有争议 | Futex console logs lack promised receipts | reports/parallel-scopes-2026-10-04/futex/result.md |
| R1-113 | 有争议 | Notes promise absolute paths but use relative ones | notes/specula-run-history-2026-10-19.md |
| R1-114 | 确认 | SCM result abbreviated hashes have wrong suffixes | reports/parallel-scopes-2026-10-04/scm-rights/result.md |
| R1-115 | 确认 | continuation-prompt stale with no historical banner | reports/continuation-prompt.md |
| R1-116 | 确认 | Notes CSV first_seen dates inaccurate | notes/specula-run-history-2026-10-19.md; notes/asterinas-findings-issue-map-2026-10-19.csv 等 |
| R1-117 | 确认 | Notes say GLM added only AST-09 | notes/specula-run-history-2026-10-19.md |
| R1-118 | 确认 | Memory lists AST-62 as fixed after the dedup | memory/asterinas-upstream-status.md |
| R1-119 | 确认 | Known-findings memory reads as a live mechanism | memory/specula-known-findings-dataset.md; memory/MEMORY.md |
| R1-120 | 确认 | Policy-block and run-hygiene memories conflict on confirmation routing | memory/specula-policy-block-autonomy.md; memory/MEMORY.md 等 |
| R2-1 | 确认 | wait/reap gates.md receipt hashes read as review-document hashes | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/gates.md |
| R2-2 | 确认 | SCM '46/46 traces validated' hides duplicated trace bodies | reports/asterinas-bug-findings-2026-08/README.md; reports/parallel-scopes-2026-10-04/scm-rights/result.md |
| R2-3 | 确认 | wait/reap 21/21 inconclusive blamed solely on the truncated marker line | reports/flock-wait-handoff-2026-10-05/wait-reap/result.md; reports/flock-wait-handoff-2026-10-05/wait-reap/execution/gates.md 等 |
| R2-4 | 有争议 | SCM result lists an original config as a revision-2 completion | reports/parallel-scopes-2026-10-04/scm-rights/result.md; reports/memfd-readiness-review-2026-10-03/gate-3-harness.md |
| R2-6 | 确认 | flock Codex spec-fix usage marked unknown despite reported tokens | reports/flock-wait-handoff-2026-10-05/flock/result.md; reports/flock-wait-handoff-2026-10-05/flock/execution/gate-2b-spec-revision.md 等 |
| R2-7 | 确认 | memfd gate-3 attempt-2 pointers resolve to attempt-3 artifacts | reports/memfd-readiness-review-2026-10-03/gate-3-harness.md; memory/specula-policy-block-autonomy.md |
| R2-8 | 确认 | GLM final report omits the classification phase cost | reports/glm53-eval-final-report.md; memory/asterinas-exfat-write-size-race.md and MEMORY.md |
| R2-12 | 确认 | GLM PI_DEADLINE and INCOMPLETE counts overstated (also in Specula issue #168) | reports/glm53-eval-final-report.md:61, :69-70, ; reports/specula-experience-issue-2026-09.md 等 |
| R2-13 | 有争议 | Policy-block memory frontmatter timestamp predates its rate-limit paragraph | memory/specula-policy-block-autonomy.md; runs/asterinas-memfd-analysis-20261003T094028Z/asterinas-memfd-seal-mapping-admission/.specula-output/confirmed-bugs.md |
| R2-16 | 有争议 | Campaign plan's prescribed launch command cannot run on the linked worktree | reports/syscall-security-campaign-plan.md; prompts/README.md 等 |
| R2-17 | 确认 | known-findings README attributes GLM CR-2 -> AST-09 to the hand dedup report | reports/known-findings/README.md; reports/specula-non-tla-syscall-input-patterns.md |
| R2-18 | 确认 | AST-09 issue draft says issue #1578 introduced the restart logic | reports/asterinas-bug-findings-2026-08/upstream-issues/AST-09-issue-draft.md; reports/pre-resume-backup-20260813T2027/pipeline.log.dryrun-clobbered-20240813T2024 |
| R2-19 | 确认 | AST-09 issue draft calls a merge validation a rebase and omits d76b4dcc0 | reports/asterinas-bug-findings-2026-08/upstream-issues/AST-09-issue-draft.md; reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/run-record.md |
| R2-20 | 有争议 | Non-TLA syscall-input report links into the live Specula checkout unpinned | reports/specula-non-tla-syscall-input-patterns.md; reports/asterinas-bug-findings-2026-08/README.md; reports/parallel-scopes-2026-10-04/scm-rights/result.md |
| R2-21 | 确认 | Pre-resume backup file name carries year 2024 instead of 2026 | reports/pre-resume-backup-20260813T2027/pipeline.log.dryrun-clobbered-20240813T2024; reports/workflow-validation.md 等 |
| R2-22 | 有争议 | 01b run-record identity block contradicts its ledger; closeout overstated | reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/run-record.md; reports/git-closeout-2026-10-04/README.md 等 |

## 被否定的问题（10）

两位核对者都认为不构成记录缺陷，或者重新取证后不成立。

| ID | 问题 | 否定理由（核对者 B） |
| --- | --- | --- |
| R1-35 | Admission doc still cites the superseded MemAvailable gate | The filename and title date the doc to 2026-10-04 (mtime 10-04 23:32). Line 66 of the same doc is an explicit 23:29 snapshot ('MemAvailable 约 13.45 GiB'). The handoff links it under '## Existing owners and future candida… |
| R1-42 | Active handoff says development 'now uses' feat/syscall-input-contracts | `grep -n '^#'` on active-specula-run-handoff.md shows line 278 '# Historical: 01a regular-file partial-progress (completed 2026-08-24)' and line 291 '## Authority (unchanged through the entire campaign)', with the senten… |
| R1-71 | Scope assessment claims 864b9138 was chosen on 09-07 | /home/chin39/.codex/sessions/2026/09/07/rollout-2026-09-07T15-41-57-01a07ad1-11b5-7940-921a-7df5b002217a.jsonl is a Codex thread whose cwd is specula-profile and which received the 01b prompt-pack zip. At 07:44:12Z that … |
| R1-72 | completed-runs 'current' inventory stale | The reported reality is accurate: ls -la runs/latest shows -> asterinas-private-futex-requeue-20261004T064345Z (mtime Oct 10), and 51 directories hold run.json. However, the page sits in a directory named specula-scope-a… |
| R1-93 | Merged PR #3703 effect on AST-01/04/05 not evaluated | The row sits under the header '## Upstream status (searched 2026-09-02)', an explicitly dated snapshot. 'PR #3703 (open)' was true on that date. The other rows still hold: `gh api` shows #711, #3297, #3481 and #3576 open… |
| R1-99 | Access-control docs stale on #3639 and C1a/C2 | 00-baseline.md is titled '访问控制审计基线（2026-09-02 冻结）' (audit baseline, frozen 2026-09-02). 01-mechanism-inventory.md opens with '基线：upstream/main = e60087be1' (baseline pinned to that commit). The status column in 05 is hea… |
| R1-108 | Notes '127 queried issue/PR' count unreproducible | The receipt exists in today's session transcript for the upstream-refresh subagent: ~/.claude/projects/-home-chin39-Documents-play-specula-profile--claude-worktrees-bridge-cse-01TfAjow4K6HHRtB8gJSynSQ/447cf603-4f38-590e-… |
| R1-109 | workspace-handoff says specula-profile has no remote | The '## Git' section (lines 146-153) sits under '## Historical workspace snapshot'. That section says 'Snapshot: 2026-09-07 (fix-branch table and AST-05 sections); the rest from 2026-09-04', tells the reader to use the e… |
| R1-121 | Global cargo-osdk no longer built from asterinas-dev | `ls -la ~/.cargo/bin/cargo-osdk` shows 2026-10-08 17:16:36 +0800. Both `strings` and ~/.cargo/.crates2.json show 'cargo-osdk 0.18.1 (path+file:///home/chin39/Documents/asterinas-nix-vdso-docker/osdk)'. So the reviewer is… |
| R2-11 | Memory attributes 'AST-15 kept separate' to the user without a record | The memory frontmatter has originSessionId 5e5bc1fa-9486-42be-98d4-fe1dda5f9ab8 and modified 2026-09-14T08:45:16.723Z, matching the file mtime. No transcript or job directory named 5e5bc1fa exists under ~/.claude. A grep… |

## 第三轮发现（59 条，未归并、未复核）

这些来自第三轮 6 个审计单元，因暂停没有归并和复核，可能与上面的问题重复，也可能不成立。其中几类值得优先复核：

- **AST-04 与 #711 是否真的是同一问题（第 41 条）。** 09-14 去重把 AST-04 记为 #711 的 EXACT_MATCH，但核对者读到 #711 的输出与 AST-04 相反：EFAULT 之后缓冲区里没有前缀，下一次读跳过了数据。如果属实，目录中“#711 直接报告 AST-04”的说法要改。
- **09-14 去重漏看了上游代码里的 FIXME/TODO（第 32 到 49 条）。** 对 AST-03、05、08、11、13、30、35、50、55、63、65、66、67、68、69、70，核对者在被引用的已合入 PR、保存的源码或已有 issue 中找到了明确描述同一缺口的 FIXME/TODO、review 讨论或报告，说明上游早已知道，而去重判为“无直接匹配”。这会影响是否值得向上游报告。
- **FD run 的模型来自流水线外的手工修订（第 1 到 3 条）。** 流水线自己的 spec-generation review 是 24/40 NEEDS_IMPROVEMENT，最终模型经过五轮手工 remediation，当前记录没有说明。
- **wait/reap 的 harness 收据（第 21 条）。** 唯一有 Asterinas 结果证据的那次运行所依据的 d9 收据标为 APPROVED，但它绑定的 review 是 NOT_APPROVED 且有未关闭的中等问题，违反 controller 自己的规则。
- **AST-05 PR 草稿与实际提交不符（第 6、7 条）。** 草稿写的提交和 base 与 PR #3778 实际提交的不同，Linux 对照的 readv race 测试日志也没有保留。

| # | 审计单元 | 文档 | 严重度 | 已标注快照 | 内容（英文原文摘要） |
| --- | --- | --- | --- | --- | --- |
| 1 | fd-epoll-specgen-remediation | reports/workflow-validation.md | high | 是 | Stage 1 was `scripts/run.sh --execute --stage 1` (run.json argv: --enable-reviews --skip-harness --skip-validate --skip-confirmation --skip-classification --skip-repair-loop). It exited 0 at 2026-08-12 03:15 with a Spec Gen Review… |
| 2 | fd-epoll-specgen-remediation | references/asterinas-syscall-security-audit.md; README.md; reports/asterinas-bug | medium | 否 | No current record says that the pipeline's own spec-generation review was 24/40 NEEDS_IMPROVEMENT. None says that the shipped model came from five hand-driven remediation rounds outside the pipeline, or that the score went 24→28→3… |
| 3 | fd-epoll-specgen-remediation | reports/specula-experience-issue-2026-09.md | medium | 否 | The 728M figure is reproducible from rollouts: sol 401.25M, which includes 50.61M of archived analysis subagents, plus terra 327.11M. It therefore includes the hand-driven Phase-2 work. Specula's summary counts 33.08M for Phase 2,… |
| 4 | fd-epoll-specgen-remediation | specgen-remediation-prompt.md | low | 否 | At the pinned commit, Rust calls `entry.update(...)` before `interest.insert(...)`, both under the interest lock. The 'interest-inserted, poller-not-yet-registered' state is therefore unreachable. The round-1 prompt copied the 24/… |
| 5 | fd-epoll-specgen-remediation | references/guidance-and-prompts.md | low | 否 | Five further prompt files have been tracked at the repository root since 3a4f465 (08-26): specgen-remediation-prompt.md and specgen-remediation-round2..5-prompt.md. The supervising Codex agent wrote them on 08-12 and used them to … |
| 6 | patch-artifacts-vs-branches-prs | reports/asterinas-bug-findings-2026-08/upstream-issues/AST-05-pr-draft.md; repor | medium | 否 | PR #3778 was not filed with aba0bfe41/0f7389044 on 51c59734e. It was filed with b13b3252b + 3aa75efd3 on e60087be1. The root patch 0001 (aba0bfe41) is not the filed fix commit. The filed commit b13b3252b has no code comments in ei… |
| 7 | patch-artifacts-vs-branches-prs | reports/asterinas-bug-findings-2026-08/upstream-issues/AST-05-pr-draft.md; repor | medium | 否 | The workspace keeps no Linux log for any version of the readv race test: not for the one-writer readv_append_race (README:409) and not for the eight-writer preadv_fills_iovecs_in_order case that the posted comment covers. It also … |
| 8 | patch-artifacts-vs-branches-prs | reports/asterinas-bug-findings-2026-08/upstream-issues/AST-08-pr-draft.md; repor | low | 否 | The queue holds 256 descriptors, and each teardown appends an IOTLB descriptor followed by a wait descriptor. The draft itself says the queue fills after 128 teardowns (lines 14-15, 68-69). So 1024 teardowns use 2048 slots, which … |
| 9 | patch-artifacts-vs-branches-prs | reports/asterinas-bug-findings-2026-08/upstream-issues/AST-09-issue-draft.md; re | low | 否 | PR #3576 is open with head 694f86051, re-pushed on 2026-10-16. The retained patch no longer fits it. Its preimage blob 8ab0a1386 is the 8e02d0e94 version of syscall_restart.c. At 694f86051 that file is blob 7bda90601. The patch's … |
| 10 | patch-artifacts-vs-branches-prs | reports/ast-validation-2026-09-02/README.md | low | 是 | The retained log for this table records a run on HEAD 9f338d737, the two-commit tip, with an uncommitted working tree. It is not a run on the three-commit tip bfef1ca11. bfef1ca11 was committed at 04:22:04Z, after the chain's ktes… |
| 11 | patch-artifacts-vs-branches-prs | reports/ast-validation-2026-09-02/README.md | low | 是 | The cited log has no strace output. It holds 8 lines: three check lines, the '3 tests passed' summary, and `time` output (real 0m0.005s). No retained file anywhere contains the 20002 and 9277 syscall counts. |
| 12 | patch-artifacts-vs-branches-prs | reports/asterinas-bug-findings-2026-08/upstream-issues/AST-05-pr-draft.md | low | 否 | The 1767/20000 and 0/20000 counts come from scratch trees on base 819d6628c: 254c19b76 (in-place) and d1c027870 (wip-check). Their read_eof.c is a predecessor of the committed test. It names the test `readv_fills_iovecs_in_order` … |
| 13 | patch-artifacts-vs-branches-prs | reports/asterinas-bug-findings-2026-08/upstream-issues/AST-05-pr-draft.md | low | 是 | Across the base move from 1601bf537 to 4d395b885 the trees are not the same. Only the patch content is unchanged, which `git range-diff` shows as '='. 58ccd4470 has tree 2a45d916, while 2e355d3ef and b4e96d67b have 95dfcee0. 690a8… |
| 14 | patch-artifacts-vs-branches-prs | reports/asterinas-findings-pack-2026-09-24/findings/AST-14-exfat-empty-write-enl | low | 是 | The same 2026-09-24 pack contradicts this. Its AST-02 entry records PR #3875, open since 2026-09-20 with head 37b18435c, whose second commit 'Preserve exFAT metadata on empty writes' is the AST-14 fix. So at snapshot time the pack… |
| 15 | native-summaries-and-ledgers | runs/asterinas-local-flock-ownership-20261004T160159Z/pipeline-summary.md | low | 否 | The run holds 18 accepted scenario traces, not 163. Note that `traces/` contains 18 top-level files, not 19. Specula counts every `*.ndjson` file under `traces/` recursively. The 163 adds 145 raw per-thread and preprocessed buffer… |
| 16 | native-summaries-and-ledgers | reports/glm53-eval-final-report.md | low | 否 | The GLM harness produced 5 merged scenario traces. The figure 13 copies the native recursive file count, which adds 8 raw per-thread files (two per scenario for four scenarios). completed-runs.md says only five traces were replaye… |
| 17 | native-summaries-and-ledgers | references/active-specula-run-handoff.md | low | 是 | The 01a harness produced 7 merged traces: 6 pinned and 1 reference-capability. The other 15 of the 22 files are raw per-CPU buffers. completed-runs.md:52 correctly records six pinned traces and one reference-capability trace, so t… |
| 18 | native-summaries-and-ledgers | reports/flock-wait-handoff-2026-10-05/flock/result.md | low | 否 | Most of the gap between the native $163.23 and the record's $167.44 is explained by the standalone spec re-review ($4.19, gate-2b), which ran outside the pipeline. The remaining $0.02 is an arithmetic error in the record. Spec gen… |
| 19 | native-summaries-and-ledgers | runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-r | low | 否 | Both totals are presented as complete, without the '(incomplete)' marker that the flock, futex and memfd summaries carry. In both runs, Phase 4a is pi confirmation reported at $0.00 (SCM: GLM-5.3, 56.2M tokens; 01b: Kimi-K3, 106.8… |
| 20 | native-summaries-and-ledgers | runs/asterinas-child-wait-reap-20261004T160159Z/pipeline-summary.md | low | 否 | The run's final summary is stale. Validation ran on 2026-10-10 (invocation 05ef84ae, 16:23-16:30 local) and exited 1 at Phase 0 on its prerequisite check. Findings ran at 17:07 (invocation 3a59d1bd) and exited 1 on 'bug-report MIS… |
| 21 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/gates.md | medium | 否 | The d9 receipt that gated the only run with Asterinas outcome evidence sets `"status": "APPROVED"`, even though its bound review (review-v6j.md) is NOT_APPROVED with an open Medium finding. That breaks the controller rule at line … |
| 22 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/gates.md | low | 否 | In the first v6 outcome run, every Linux control aborted at the fixture's `affinity_count == 2` assertion. Rootless Docker had discarded --cpuset-cpus, so all 21 Linux outcomes are inconclusive. The record presents this run as hav… |
| 23 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/gates.md | low | 否 | Only the forked child actor (actor 3) exited 78. The fixture process that run.sh waited on stayed blocked until its 20 s alarm fired and died of SIGALRM. The runner therefore recorded exit 142 (128+14), not 78. The record gives a … |
| 24 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/gates.md | low | 否 | The v3 instrumentation touches 20 files: 15 tracked files modified and 5 new files. Review-v3 had already verified all 20 installed-source entries in the private source before the harness phase ended. |
| 25 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/gates.md | low | 否 | The file states that times are local unless marked UTC. The v5 install happened at 03:21 local, which is 19:21Z, so the directory name and the 'Z' label disagree. The v6-outcome runner was launched at about 10:04 local, not 10:12.… |
| 26 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/harness-fix-2026-10-06/review-ga | low | 否 | The block was carried over unchanged from the memgate receipt and no longer describes this receipt. Its own reviewed_inputs bind run.sh 396bc6f7 (the D5 runner), not the e3582794 that it calls 'installed'. Its approved_by cites th… |
| 27 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/gates.md | low | 否 | These controller pre-checks are stated as completed results, and several were passed to reviewers as facts. No output, log or script for any of them is kept in the lane or in local artifacts. The D8 compile check is the only pre-c… |
| 28 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/harness-fix-2026-10-06/review-pr | low | 否 | Each prompt calls the latest failure the first admitted execution. Memory admission had already passed at v5 attempt 2 (05:17, which then failed at image inspect) and at d1 (10:15). The d4m attempt was therefore the third admitted… |
| 29 | waitreap-harness-fix-chain | references/current-state.md | low | 否 | user-decision-2026-10-10-accept-d9r5.md requires that "Every report of an outcome run under this receipt cites D9R5-S1 as an accepted residual and keeps the review verdict visible." The current-state row and today's notes report t… |
| 30 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/result.pre-final-20261 | low | 是 | The snapshot was only partly updated and contradicts itself as of its own 14:50 timestamp. Its d8 section (lines 65-77) reports a kernel build, 21 Linux controls and 21 guest boots. At 14:50 the live receipt was bbdd0f0d (review-v… |
| 31 | waitreap-harness-fix-chain | reports/flock-wait-handoff-2026-10-05/wait-reap/execution/result.pre-final-20261 | low | 是 | Review v5e usage was captured. Its activity log ends with a turn.completed event that reports 662,551 input and 11,875 output tokens. The log was written on 10-06, before the snapshot. |
| 32 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | high | 是 | The cited #1294 receipt does contain the UDP send candidate. Its merged diff adds, on the UDP send path, an upstream FIXME that states AST-30's exact mechanism and a warning that a malformed packet will be sent. Reviewers then dis… |
| 33 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | medium | 是 | Both cited merged PRs carry an upstream FIXME that states AST-50's exact mechanism. The introducing PR #622 (2024) added it, #3115 moved it, and it remains in the saved source. Upstream has documented this gap since 2024. No fix e… |
| 34 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | medium | 是 | The cited merged PR #2912 introduced a FIXME for this exact gap, and its PR body has a dedicated "Why FIXME in the code" section explaining it. A maintainer discussed it in review. That no fix exists is true, but the gap is public… |
| 35 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | medium | 是 | The cited merged PR #2859 explicitly records AST-68's gap. Its body and the gVisor blocklist it adds both say that MOVE_* events are not reported at rename(), and they block the move-event tests. That is a matching upstream record… |
| 36 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | medium | 是 | The cited #3494 diff shows the upstream TCP sendmsg TODO that states AST-70's exact gap, and the saved bc12195 source still has it. The cited #1851 is not a "runtime syscall trace". It is a requirements table that lists sendmsg MS… |
| 37 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | medium | 是 | Two of the entry's own references, the merged PRs #2351 and #3108, are never discussed in the rationale, and both carry the upstream FIXME for exactly the DMA-unmap IOTLB instance. #3108 also adds a TODO saying that freed device-a… |
| 38 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | medium | 是 | The cited #3303 review is directly about inheriting listener options into accepted sockets. The reviewer asked for an inheritance test and pointed to the TODO about updating options for newly accepted sockets. A review hunk even s… |
| 39 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | medium | 是 | Upstream explicitly documents the hazard on the IP TCP path itself. #2412 added a FIXME on StreamSocket that says userspace copies happen while spin locks are held, which breaks atomic mode. The FIXME also appears as diff context … |
| 40 | dedup-rationales | reports/upstream-dedup-2026-09-14/README.md | medium | 是 | The outcome categories are applied inconsistently. AST-55 (merged #2025 keeps a TODO) is PARTIAL_MATCH/PUBLIC_DOCUMENTED_GAP. AST-71 (merged #3254 warns that the flag "is accepted, but still does not disable ASLR", and open #3560 … |
| 41 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | medium | 是 | #711's Asterinas output shows the opposite observations. After read(fd, buf, 2) returned EFAULT the buffer still held 'x', so no prefix was delivered. The next read returned 'c', so the offset had moved past 'b' and data was skipp… |
| 42 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | medium | 是 | The rationale never addresses #2953, a retained, merged receipt that is in AST-11's own search hits. #2953 contains a maintainer review describing the exact exFAT write_at window: the page cache is resized under the write lock, th… |
| 43 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | low | 是 | The second sentence is correct, but #3121 is not just a panic fix and is not distinct. Its merged clone3 change replaces `value.exit_signal as u8` with `u8::try_from` before SigNum validation, after a review noting that values abo… |
| 44 | dedup-rationales | reports/upstream-dedup-2026-09-14/README.md | low | 是 | The select half is also publicly documented. #2025's own discussion quotes the Linux select()/pselect6() timeout-modification behaviour and argues that no user program depends on it. In retained #1831, a maintainer says the select… |
| 45 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | low | 是 | The cited merged PR #3600 defines RecvFlags::SUPPORTED as MSG_PEEK \| MSG_TRUNC, so MSG_DONTWAIT is an explicitly unsupported flag. TCP recvmsg logs "unsupported flags" at bc12195. The cited #1851 is a requirements table that lists… |
| 46 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | low | 是 | The cited #2230 diff and the saved preadv.rs/pwritev.rs carry an upstream TODO that explicitly acknowledges AST-03's mechanism: readv/writev must be atomic and the current per-iovec implementation does not ensure it. The rationale… |
| 47 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | low | 是 | #2953, a retained receipt in AST-05's own search hits, contains an earlier public report of AST-05's exact mechanism. On 2026-02-12, seven months before #3778, a Copilot review on ramfs read_at said the page-cache read can overwri… |
| 48 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | low | 是 | Open issue #579 ("A bug about VMO's resize") reports that reading after an ftruncate shrink and regrow returns old data, which is AST-13's observable. #579 appears in the ftruncate query hits of AST-10 and AST-12, but no entry ref… |
| 49 | dedup-rationales | reports/upstream-dedup-2026-09-14/matches.json | low | 是 | #3147's merged patch, revised at a reviewer's request, is the CLOCK_MONOTONIC_RAW and coarse-clock EOPNOTSUPP check itself. That is the sleep-clock validation AST-67's fast path bypasses, because do_clock_nanosleep returns early f… |
| 50 | dedup-rationales | reports/asterinas-bug-findings-2026-08/README.md | low | 是 | The dedup uses eight outcomes. This summary omits three of them: merged fix verified (AST-62), documented unsupported-operation gap (AST-46/52), and retained negative/model disposition (AST-26..29/41). The sentence also directly f… |
| 51 | findings-pack-entries | reports/asterinas-findings-pack-2026-09-24/findings/AST-14-exfat-empty-write-enl | medium | 是 | By the pack date the exFAT guards were committed (fix/ramfs-empty-write got ramfs+exFAT commits on 09-17 and was pushed to the user's fork on 09-18), and the owner's PR #3875, opened 09-20 and open on 09-24, carries the exFAT guar… |
| 52 | findings-pack-entries | reports/asterinas-findings-pack-2026-09-24/findings/AST-03-vector-atomicity/find | medium | 是 | The retained source is v4 (`MC4_REPRO_VERSION 4`). Its retained guest run triggered on both readv and writev (`MC4_SUMMARY readv=1 writev=1`). The variant README that this sentence points to says the same. Only the earlier v3 and … |
| 53 | findings-pack-entries | reports/asterinas-findings-pack-2026-09-24/findings/AST-03-vector-atomicity/find | low | 是 | 79/92/97 and 234,560 come from the 2026-08-25 patch-validation A run, not from the 01a Specula run. The 01a confirmation recorded 71, 89, and 100 torn rounds and 338,048 foreign bytes, so the recorded range is 71 to 100, not 79 to… |
| 54 | findings-pack-entries | reports/asterinas-findings-pack-2026-09-24/findings/AST-07-segment-empty-slice/f | low | 是 | This was not true on 09-24. feat/nix-flake-devenv was rebased on 2026-09-21/22, and its local head became fc526c136, which does not contain 4c1fdd1e4. Today 4c1fdd1e4 is reachable from no ref, and no local feat/nix-flake-devenv br… |
| 55 | findings-pack-entries | reports/asterinas-findings-pack-2026-09-24/docs/confirmation-provenance.md | low | 是 | The 500 trials were not unassisted. They were Level 0/1 trials with userspace timing assistance (CPU pinning, TSC rendezvous, swept entry delay). The pack's own AST-11 entry says "500 timing-assisted trials". |
| 56 | findings-pack-entries | reports/asterinas-findings-pack-2026-09-24/docs/confirmation-provenance.md | low | 是 | AST-24, the only MASKED entry, also has no check outside Specula. It was excluded from the v5 patch validation and is absent from the 2026-09-02 re-run of AST-01..06 and AST-09. The page places it in neither "Checks outside Specul… |
| 57 | findings-pack-entries | reports/asterinas-findings-pack-2026-09-24/specula-known-findings/asterinas.json | low | 是 | The values do not follow the Specula dataset contract at known-findings-dataset a0393181. There, `fix_status` must be `unfixed`, `fix-pending` or `fixed`, and the confirmation guide requires `fix-status: unfixed\|fixed` in KNOWN ci… |
| 58 | findings-pack-entries | reports/asterinas-findings-pack-2026-09-24/findings/AST-26-regular-file-eintr-re | low | 是 | Linux ran a separately compiled build of the same source, not the guest binary. The 01a CR-1 driver builds `cr1_linux` with host gcc, and the guest binary comes from the initramfs build. The GLM CR-1 guest build went through `AUTO… |
| 59 | findings-pack-entries | reports/asterinas-findings-pack-2026-09-24/findings/AST-09-pipe-readv-eintr-rest | low | 是 | #1578 is a feature request issue. PR #1598 ("Enable restart of signal-interrupted syscalls on x86-64 platform") added the restart machinery. This is the same false attribution as R2-18 (the AST-09 issue draft), here in a separate … |

## 建议的处理顺序

1. 先改高严重度的 6 组：目录中 AST-79/80、AST-48、AST-02/07/14/19、AST-08、AST-35 的行和 “Current upstream cross-check”，以及 PR #3576 的覆盖判断。这些会直接影响是否向上游报告、报告引用哪个 issue。
2. 再统一刷新 `current-state.md` 和 `active-specula-run-handoff.md` 的当前状态部分：Specula `39b4a015`、目录 AST-01..93、PR #3778 和 AST-11 的分支状态、MC-6 的屏蔽原因、watermark 的持久设置，以及未推送的 `62b8113`。
3. 复核第三轮里 AST-04 与 #711 的对应关系和 09-14 去重漏看的 FIXME/TODO，再决定这些条目的上游状态。
4. 低严重度的问题可以在下次整理对应文档时顺手修正。

原生 run 产物保持不改，所有更正都写在目录、id-map 和状态文档里。

## 2026-10-20：已写入主 checkout 的更正

写入前逐条复核了要写的事实：上游 issue/PR 状态、PR #3576 的强推记录、PR #3778 的 review 评论、本地和 fork 分支、Specula HEAD、watermark 设置、AST-83 的 guest 日志、SCM 的用户决定文件、MC-6 的原生 debate 更正和 memfd 的成本合计。都与报告一致，只有一处收紧：AST-35 的 TCP 复现目前只有提交 `4d1ed282b` 的提交信息为证，工作区没有保留运行日志，所以目录里它仍是 SOURCE LEAD，只补充了这条证据和本地修复分支。

修改都没有提交，叠加在 10-12 的未提交改动之上。改动前的文件备份在会话 scratchpad 中，全部改动保存为同目录的 [main-checkout-corrections-2026-10-20.patch](main-checkout-corrections-2026-10-20.patch)，可以在主 checkout 里用 `git apply -R` 撤回。

改动的文件（18 个）：

- 发现目录：`README.md`（新增 10-19 上游刷新、20 行登记表、修复入口、campaign 记录、证据说明）、`id-map.md`、`reproduced.md`，以及 AST-02、AST-07、AST-08 的 `description.md`。
- 状态文档：`current-state.md`（顶部新增 10-19 当前状态一节，过时的节标为历史并更正）、`active-specula-run-handoff.md`、`guidance-and-prompts.md`、`workspace-handoff.md`、`pr-3778-handoff.md`、`glm53-eval-handoff.md`、`01a-v2-review-handoff.md`、`asterinas-syscall-security-audit.md`、`specula-tutorial.md`。
- 与上述状态直接相关的记录：`handoff-01b.md`、futex 的 `result.md`、`empty-write-batch-2026-09-16/README.md`。

原生 run 产物没有改动。没有写入、留待决定的中等问题：

- R1-105（有争议）：AST-75 在 memfd run 中算不算新发现，需要你定计数口径。
- 不属于目录和状态文档的记录：`workflow-validation.md` 和 `active-stage3-handoff.md` 的 policy retry 次数（R1-57），01b `run-record.md` 未记录的 `d034e000` 代码（R1-63），各 lane `result.md` 的成本和 token 统计及 `tool-identity.json` 的 CLI 版本（R1-80、R2-5、R1-81），经验报告已提交为 #168（R1-91），`socket-fd-scopes.md` 的 Linux 行号（R2-14），以及 `aster-syssec-reverse-contribution.md`、futex `result.md` 第 194 行、gate-6 记录、后端审计、发现打包、`ast-validation-2026-09-02/README.md` 中已标注日期的旧说法。

## 2026-10-20：Codex 独立复查（gpt-6.1-sol，xhigh）

Codex 在只读沙箱里运行约 18 分钟，执行了 88 条只读命令，上游状态使用当天的离线快照。完整输出见 [codex-audit-2026-10-20.md](codex-audit-2026-10-20.md)，逐条结论已写入问题 CSV。

**10-20 写入主 checkout 的更正中有三处错误，已改正：**

- C1：GLM 交接中写“分类跑在 `f80e458f` 加未提交改动上”。实际上分类在 20:54 开始，那时这些改动已在 20:19 提交为 `9a7b64ff`。
- C2：`current-state.md` 把 AST-01..74 归到 09-16 的快照。AST-73/74 来自 10-03 的 memfd 分析，9 月时目录只到 AST-72。
- C3：发现目录修复入口仍说 AST-92/93 的确认记录写明了修复位置。AST-92/93 只有运行结果，没有原生确认记录。

**本报告自身的一处错误，已改正：** 高严重度第 6 条（AST-35）里的 SMP=4、Linux 对照和 7/7 通过等细节，提交 `4d1ed282b` 的信息里都没有，工作区也没有保留运行日志。R1-28 改为“部分成立”。目录里 AST-35 本来就保持 SOURCE LEAD，不受影响。

**第三轮 59 条未复核发现：** 41 条成立，16 条部分成立，2 条不成立（第 26、50 条）。值得注意的中等问题：

- 09-14 的上游去重漏记了上游已有的说明：AST-08、30、35、50、66、68、70 等在被引用的已合入 PR 或保存的源码中有描述同一缺口的 FIXME/TODO，AST-11 在 PR #2953 的 review 中有维护者描述的同一竞争窗口（第 32 到 49 条）。
- FD run 的流水线 spec review 原为 24/40，经五轮流水线外的人工修订才到 40/40；`workflow-validation.md` 只写了 40/40（第 1 条）。
- AST-05 的 PR 草稿写错了实际提交的 commit 和 base（第 6 条）。
- SCM 和 01b 原生汇总的总成本没有标注不完整，pi 确认的费用记为 $0（第 19 条）。
- 发现打包里 AST-03 的 GLM 变体其实触发了，AST-14 仍写未提交（第 51、52 条）。

**新问题：**

- N1（中，已抽查）：AST-04 的 description 说 #711 只检查返回值、从未检查缓冲区和 offset。实际上 #711 的 PoC 在两次读之后都打印了缓冲区：EFAULT 后缓冲区仍是 `x`，下一次读得到 `c`，也就是没有交付前缀、数据被跳过。AST-04 观察到的是交付了前缀而 offset 不动。两者同属 EFAULT 中途处理的问题，#711 可以继续作为对应 issue，但 description、发现打包和 09-14 去重对 #711 的描述都需要改。

Codex 还标出 4 处离线快照无法核实的细节（PR #3576 的强推时间、#3778 的 review 评论、#3964 的复现评论、#3920 第 11 项的日期）。这些我在 10-19 和 10-20 用在线 `gh` 核实过：#3920 第 11 项的原始评论是 2026-09-22T08:53:52Z，09-26 合并进汇总。
