# Specula 运行历史与发现对照（截至 2026-10-19）

这页把 2026-08-11 到 2026-10-12 的全部 Specula 运行、Specula 之外的验证记录，以及去重后的发现和上游 issue/PR 对照放在一处，供挑选下一轮 campaign、整理修复或准备上游报告时查阅。逐条可筛选的数据在同目录的 [asterinas-findings-issue-map-2026-10-19.csv](asterinas-findings-issue-map-2026-10-19.csv)。

本页只读整理，没有启动任何 phase、TLC、构建、guest 或复现程序，也没有改动已有记录。数据来源有三处：

- 原生运行目录 `/home/chin39/Documents/play/Specula/runs`（50 个目录，`latest` 指向 futex run，只算一次）。
- 主 checkout `/home/chin39/Documents/play/specula-profile` 的当前内容，包括本地提交 `62b8113` 和 2026-10-12 的未提交改动（发现目录、`reproduced.md`、`local-dedup-2026-10-12.json`）。本 worktree 停在 `4e1c569`，缺少 10-04 之后的记录，所以下文中的相对路径都指主 checkout 下的文件。
- 2026-10-19 对 `asterinas/asterinas`（main `d0dc799a4c`）的只读 issue/PR 刷新。

## 总览

- 50 个运行目录中有 13 个正式启动、37 个 dry-run。正式启动里，8 个跑完确认并产出 `confirmed-bugs.md`，1 个只做 analysis，1 个（wait/reap）流水线未完成，3 个启动失败或被中止。dry-run 都没有产出发现。
- 发现目录共 93 条（AST-01..93）。其中 35 条 REPRODUCED，去重后是 31 条有原生确认记录、2 条内核/设备测试记录（AST-07/08）、2 条只有运行结果（AST-92/93）。8 份原生报告共 54 条最终记录，其中 38 条 REPRODUCED 合并到 31 个 AST。
- 自 2026-09-14 上游去重以来，上游新修复了 AST-07、AST-14、AST-19，以及 AST-02 的空写入部分。AST-79/80 已有上游 issue #3964，AST-08 的机制已出现在上游汇总 issue #3920 的第 11 项。AST-75、AST-81、AST-82、AST-84 已复现，但上游没有对应报告。
- 2026-10-19 对这些记录做了一次系统审计，结果见 [records-audit-2026-10-19.md](records-audit-2026-10-19.md)。本页的错误已按审计结果更正。

## Specula 版本时间线

`run.json` 不记录 Specula 版本。下表由 Specula 仓库的 `git reflog` 与工作区里的身份记录对出来。所有 run 都以 editable install 运行当时 checkout 的 HEAD。

| 时间段（+08:00） | Specula commit | 版本 | 用到它的 run |
| --- | --- | --- | --- |
| 08-11 → 08-23 00:36 | `32f2d255` | v1.0.0-9 | FD 的 4 个 dry-run、FD full（失败）、FD pipeline |
| 08-23 00:36 → 08-28 10:54 | `c6aa3dfa` | v1.1.0 | Recon、01a、08-23 的 14 个 dry-run、GLM 的 analysis 到 validation 阶段和 08-26/27 的确认 |
| 08-28 → 09-08 14:14 | `feat/syscall-input-contracts`（`f80e458f`、`9a7b64ff` 加未提交改动） | 1.1.0 字符串 | GLM 08-28 的确认重启和分类、01b dry-run `626d`、01b 启动 `834e` |
| 09-08 14:38 → 09-24 10:27 | `4bb2202b` | v1.1.0-8 | 01b `85a1`、`5b3c`、`baa9`、`0a8c` |
| 09-24 10:27 → 10-19 11:13 | `aa93be67` | v1.2.0-15，旁边有 3 个未跟踪文件 | memfd、futex、SCM_RIGHTS、flock、wait/reap 及其 dry-run |
| 10-19 11:13 → 现在 | `39b4a015` | v1.2.0-22，3 个未跟踪文件仍在 | 之后还没有 run |

Codex 阶段读的是插件缓存里的 skills，不是 checkout。插件 1.0.0 用到 08-27，1.1.0 于 08-28 生成（harness-generation 有 3 个文件含未完成的 syscall-input 文字），1.2.0 于 10-03 从 checkout 重新生成。Recon、01a 和 GLM 的 analysis 到 validation 阶段因此是 CLI 1.1.0 配 1.0.0 skills。

GLM 的交接记录写的是 `c6aa3df`，这只对 08-26/27 成立。08-28 产出最终 verdict 的确认和分类跑在 feat 分支的代码上。08-28 15:20 之后的确认 prompt 含有 syscall-input sidecar 文字，例如 `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-2/turn01_A.prompt.md`。这段文字来自 `src/specula/prompts/confirmation/reproduce.md`，`c6aa3dfa` 里没有。15:20 时它还是 feat 分支上的未提交改动，20:19 才作为 `9a7b64ff` 提交。

## 正式 run（13 个）

`run.json` 的 `argv` 只记录第一次调用，后续阶段靠 resume 或 `--fresh-context` 继续，所以“阶段”一列以 pipeline 记录和交接为准。别名与发现目录的 campaign register 一致。

| 日期 | 别名 / Run ID | 阶段 | 目标 @ Asterinas pin | Specula | 路由 | 结果 |
| --- | --- | --- | --- | --- | --- | --- |
| 08-12 | `asterinas-fd-epoll-full-20260811T163837Z` | 启动失败 | fd-epoll @`4ba4abbe` | `32f2d255` | codex gpt-5.6-sol | Phase 1 前 SnapshotError，`--keep-original` 拒绝 linked worktree，无产物。 |
| 08-12 → 08-14 | FD `asterinas-fd-epoll-pipeline-20260811T164254Z` | 全流程加三个 review，debate 开 | fd-epoll @`4ba4abbe` | `32f2d255` | codex gpt-5.6-sol，确认和修复 gpt-5.6-terra | 8 REPRODUCED、1 FALSE POSITIVE、1 DROPPED，对应 AST-16..23、28、29。 |
| 08-23 | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z` | 只有 analysis 和 review | user-memory @`60494858` | `c6aa3dfa` | codex gpt-5.6-sol | 源码线索 AST-30..40，没有 spec 或 TLC。19 条历史 issue 归类不是新发现。 |
| 08-23 → 08-24 | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z` | 全流程，debate 开 | regular-file partial progress @`60494858` | `c6aa3dfa` | codex gpt-5.6-sol，确认 claude-code Opus | 6 REPRODUCED、1 MASKED、1 FALSE POSITIVE，对应 AST-01..06、24、26。Validation review 为 NEEDS_IMPROVEMENT。 |
| 08-26 → 08-28 | GLM `asterinas-glm53-eval-20260826T035049Z` | 全流程，validation review 跳过，debate 开 | 与 01a 同 guidance 和 pin | `c6aa3dfa`，08-28 起为 feat 分支 | codex gpt-5.6-sol，确认 pi GLM-5.3 | 4 REPRODUCED、1 FALSE POSITIVE、1 INCOMPLETE。新增 AST-09（CR-2，复现）和 AST-27（CR-1，误报），其余重复 01a。 |
| 09-08 00:26 | `20260908-002550-834e` | 启动后中止 | buffered file size @`60494858` | `9a7b64ff` 加未提交改动 | pi Kimi-K3 | pi adapter 卡死，exit 143。 |
| 09-08 14:42 | `20260908-144234-85a1` | 启动后中止 | 同上 | `4bb2202b` | pi Kimi-K3 | 用户为调整路由而终止。 |
| 09-08 → 09-09 | 01b `20260908-150910-0a8c` | 全流程加 review，debate 关 | buffered file-size/read consistency @`60494858` | `4bb2202b` | codex gpt-6-astra，确认 pi Kimi-K3 | 10 REPRODUCED，对应 AST-02、05、10..15，另提出契约线索 AST-25。Specgen 和 validation review 为 NEEDS_IMPROVEMENT。 |
| 10-03 → 10-04 | Memfd `asterinas-memfd-analysis-20261003T094028Z` | 全流程加 review | memfd seal/mapping admission @`0c605370` | `aa93be67` | codex gpt-6-astra，确认 pi GLM-5.3 | 2 REPRODUCED（AST-73、75），3 FALSE POSITIVE（AST-76..78）。不是盲测基线。 |
| 10-04 → 10-10 | Futex `asterinas-private-futex-requeue-20261004T064345Z` | 全流程加 review | private futex requeue @`0c605370` | `aa93be67` | codex gpt-6-astra；validation 遇 policy block 后经用户授权改用 claude-code Opus 5.5 重跑；确认 GLM-5.3 | 4 REPRODUCED（AST-79..82），1 FALSE POSITIVE（AST-83）。核心 MC.cfg 有时限，不构成并发协议验证。 |
| 10-04 → 10-10 | SCM `asterinas-unix-dgram-scm-rights-20261004T064345Z` | 全流程加 review，两项限制经用户接受 | unix dgram SCM_RIGHTS @`0c605370` | `aa93be67` | codex gpt-6-astra，确认 GLM-5.3 | 复现已知线索 AST-32、36（0 新增），2 FALSE POSITIVE（AST-90、91）。 |
| 10-05 → 10-09 | Flock `asterinas-local-flock-ownership-20261004T160159Z` | 全流程加 review | local flock ownership @`0c605370` | `aa93be67` | 同上 | 2 REPRODUCED（AST-84、85），4 FALSE POSITIVE（AST-86..89）。 |
| 10-05 → 10-10 | WaitReap `asterinas-child-wait-reap-20261004T160159Z` | analysis 和 spec 通过，harness 0 条 trace，validation 和 findings 都 exit 1 | child wait/reap @`0c605370` | `aa93be67` | 同上，确认阶段未到达 | 用户选择的运行对照记录了 AST-92、93。没有原生确认，流水线未完成。 |

10 月的四条 lane 都没有建立完整的并发协议验证。各自的覆盖缺口记录在主 checkout 的 `reports/asterinas-bug-findings-2026-08/README.md#concurrency-evidence-limits` 和各 lane 的 `result.md`。

## Dry-run（37 个）

dry-run 只检查配置和路由，不执行 phase，不增加覆盖。

| 日期 | 数量 | 内容 | Specula |
| --- | --- | --- | --- |
| 08-11 | 4 | fd-epoll 的 validation、staged、postsetup、plugin | `32f2d255` |
| 08-23 | 14 | fd-epoll opus-confirm 两个；user-memory 的 baseline、analysis-only、analysis-only-debate、positive-control；fd-lifecycle、vm-page-cache、process-signal-futex、vfs-credentials-namespaces、socket-ancillary、abi-integers-output、resource-rollback-dos 七个 scope；regular-file 一个 | `c6aa3dfa` |
| 09-08 | 3 | 01b 的 `626d`、`5b3c`、`baa9` | `626d` 为 `9a7b64ff` 加未提交改动，其余 `4bb2202b` |
| 10-03 → 10-04 | 5 | memfd 的 dryrun、glm-full、glm-stage1、harness、claude-harness | `aa93be67` |
| 10-04 | 6 | futex 和 SCM_RIGHTS 各三个：analysis、full-routing、full-routing-reviewed | `aa93be67` |
| 10-05 | 4 | flock 和 wait/reap 各两个：analysis、full-routing | `aa93be67` |
| 10-09 | 1 | futex opus-validate | `aa93be67` |

## Specula 之外的验证与准备记录

这些记录没有原生 run ID，但影响发现的状态。路径都在主 checkout 的 `reports/` 下。

| 日期 | 记录 | 对象 | 结果 |
| --- | --- | --- | --- |
| 08-06、08-07 | 外部包 CR-20、CR-11 @`4c1fdd1e4`（`CR-20-verification-report.md`） | AST-08、AST-07 | 原始内核/设备测试复现。 |
| 08-25 | 01a 补丁 v5 A/B（`patch-validation-report.md`） | AST-01..06 | SMP=2 下 pristine 全部复现，v5 补丁全部消除，负对照通过。 |
| 09-02 | AST-01..09 独立复核 @`60494858`（`ast-validation-2026-09-02/`） | AST-01..09 | 7 个用户态发现复现。AST-07 复现为错误结果，未复现内核死机。AST-08 复现。 |
| 09-03、09-14 | exFAT write race（`ast-validation-2026-09-02/exfat-write-race/`） | AST-11 | 09-03 在 `d76b4dcc0` 上确认。09-14 修复 A/B：未修 2000 轮中 65 到 93 轮出错，修复后 0。修复分支未推送。 |
| 09-04 | rw-matrix @`d76b4dcc0`（`rw-matrix-2026-09-04/`） | 普通文件 I/O 关系 | 没有新机制。 |
| 09-14 | TLPI v2 接收（`tlpi-audit-2026-09-14/`） | AST-42..71 | 只整理，测试 NOT_RUN。 |
| 09-14 | 上游去重（`upstream-dedup-2026-09-14/`） | AST-01..71 | 对 `bc12195` 的快照。 |
| 09-16 | 空写入修复批次（`empty-write-batch-2026-09-16/`） | AST-02、AST-14 | 本地只做静态检查。上游 PR #3875（同名，chinrw）已于 09-29 合入，未与本地 diff 逐行对比。 |
| 09-16 | 后端源码审计（`ast-02-empty-write-2026-09-14/related-filesystems-2026-09-16.md`） | AST-72 | 源码线索，运行 NOT_RUN。09-18 已有候选修复：你 fork 上的 `fix/virtiofs-empty-write`（`088088505`），没有测试，也没有开 PR。 |
| 09-24 | 发现打包（`asterinas-findings-pack-2026-09-24/`） | AST-01..72 | 当时的快照。已经注意到 AST-02 的 PR #3875，并指出目录没有记录它。 |
| 10-03 | memfd 源码审计与顺序用例（`memfd-sequential-cases-2026-10-03/`） | AST-73、74 | 只做宿主编译检查。AST-73 随后由 memfd run 复现。 |
| 10-12 | 本地去重审计（`asterinas-bug-findings-2026-08/reproduced.md`） | 全部 93 条 | 只核对记录，未运行任何东西，也未查上游。 |
| 10-12 | eventfd 试点准备（`eventfd-preparation-2026-10-12/`） | eventfd reader 登记、通知、重试 | 准备完成，未启动 run。 |

## 发现去重

去重按契约和源码机制匹配，不按相似症状合并。同一机制的重复观察计一次，原始 run 的 verdict 保留不改。主要合并如下：

| 原始记录 | 处理 |
| --- | --- |
| 01a:MC-4、GLM:MC-3、01b:MC-6、01b:MC-8 | 计为 AST-02 一条。空写入和零进度失败写共用 ramfs 的 size 发布机制。 |
| 01a:MC-3、GLM:MC-2、01b:MC-2、01b:CR-1 的 syscall 效果 | 计为 AST-05 一条。AST-10（过期的 size 采样）和 AST-25（契约问题）单列。 |
| GLM:MC-1 | 计入 AST-04 的读侧见证。AST-01 的写侧证据来自 01a:MC-2。 |
| GLM:MC-4 | 本 run 保持 INCOMPLETE，AST-03 的正面证据来自 01a:MC-5。 |
| SCM:MC-1、SCM:MC-2 | 是 Recon 线索 AST-32、AST-36 的复现，不新编号。 |
| Memfd 源码审计 M01/M02 与 Memfd:MC-1 | 同一机制的两种表现，计为 AST-73。AST-74、AST-75 单列。 |
| Futex 超时清理与之后的死条目消耗配额 | 计为 AST-79。AST-80、81、82 位置不同，单列。 |
| Flock 的 FL-SQ/FL-TV/FL-MC 别名和临时编号 | 归入 AST-84、85。FL-CR-1 与原生 CR-4 同为 AST-89 FALSE POSITIVE。 |

去重后的 35 条 REPRODUCED 如下。“出现的 run”列出每条正面记录，括号内是补充来源。上游状态为 2026-10-19 刷新结果。

| AST | 现象 | 出现的 run | 上游对应 | 上游状态 |
| --- | --- | --- | --- | --- |
| AST-01 | ext2 写入已落盘的前缀却返回 EFAULT | 01a:MC-2（GLM:MC-1 相关） | #711 部分重叠 | open |
| AST-02 | ramfs 在空写入或零进度写入前就发布 size | 01a:MC-4、GLM:MC-3、01b:MC-6、01b:MC-8 | PR #3875 修了空写入部分 | 09-29 合入，非空 fault 路径未覆盖 |
| AST-03 | 向量 I/O 在 iovec 之间释放 offset 锁 | 01a:MC-5 | PR #2230 相关 | 已合入，不是修复 |
| AST-04 | 已拷贝的读前缀被 EFAULT 抹掉 | 01a:MC-1、GLM:MC-1 | #711 直接报告 | open |
| AST-05 | ramfs/exFAT 读取拷贝超出返回的 EOF 前缀 | 01a:MC-3、GLM:MC-2、01b:MC-2、01b:CR-1 | PR #3778 覆盖 | open，未合入 |
| AST-06 | 失败的 append 推进共享 offset | 01a:MC-7 | PR #3481 覆盖 | open draft |
| AST-07 | 空 Segment 转换访问不属于它的首帧元数据 | 外部 CR-11（09-02 复测） | #3892、PR #3959 | 10-11 修复 |
| AST-08 | IOMMU 拆除时先释放帧再失效 IOTLB | 外部 CR-20（09-02 复测） | #3920 第 11 项报告了同一机制 | open，未修复；本地修复分支未推送 |
| AST-09 | 设置 SA_RESTART 后 pipe readv/writev 仍返回 EINTR | GLM:CR-2 | PR #3576 覆盖 | open，10-16 重推 |
| AST-10 | ramfs 在与 resize 串行化前就采样读长度 | 01b:MC-1 | PR #3778 覆盖 | open |
| AST-11 | exFAT 写准备在拷贝和发布前过期 | 01b:MC-3（09-03 race 验证） | 无直接匹配 | 本地修复未推送 |
| AST-12 | exFAT ftruncate 成功后仍保留旧逻辑大小 | 01b:MC-4 | 无直接匹配 | — |
| AST-13 | exFAT 重新长出的空洞暴露本文件旧数据 | 01b:MC-5 | 无直接匹配 | — |
| AST-14 | exFAT 空写入扩大 EOF 并可能分配簇 | 01b:MC-7 | PR #3875 | 09-29 修复 |
| AST-15 | exFAT cold-tail 扩展重入 inode 写锁并自死锁 | 01b:CR-2 | 无直接匹配 | — |
| AST-16 | epoll copy-out EFAULT 丢失边沿触发就绪 | FD:MC-1 | 无直接匹配 | — |
| AST-17 | epoll 在成功投递前就关闭 one-shot 兴趣 | FD:MC-2 | 无直接匹配 | — |
| AST-18 | 最终 close 后保留失效的 epoll interest 元数据 | FD:MC-3 | #200 相关 | open |
| AST-19 | 已消费的 timerfd 经 poll cache 仍显示就绪 | FD:MC-4（TLPI F17 未运行） | PR #3984 | 10-13 修复 |
| AST-20 | signalfd 改 mask 后不通知新出现的就绪 | FD:MC-5 | 无直接匹配 | — |
| AST-21 | timerfd 已可读后 poll 仍然超时 | FD:MC-6 | 无直接匹配 | — |
| AST-22 | signalfd 的 epoll 就绪绑定到注册线程 | FD:CR-4 | 无直接匹配 | — |
| AST-23 | epoll_pwait/pselect6 超时跳过延迟的 pipe 就绪 | FD:CR-5 | 无直接匹配 | — |
| AST-32 | SCM_RIGHTS 先安装 FD 再发布其编号 | SCM:MC-1（Recon 线索） | 无直接匹配 | — |
| AST-36 | Unix datagram 接收拷贝失败后仍保留该记录 | SCM:MC-2（Recon 线索） | 无直接匹配 | — |
| AST-73 | memfd seal 后的只读共享映射仍按可写计数 | Memfd:MC-1（源码审计 M01/M02） | PR #3481 相关 | open draft，不是修复 |
| AST-75 | 被 seal 拒绝的 MAP_FIXED 先删旧映射再返回 EPERM | Memfd:MC-2 | 未找到 | — |
| AST-79 | 跨 bucket requeue 后超时清理漏删条目，之后困住 live waiter | Futex:MC-1 | #3964 直接报告 | open，无 PR |
| AST-80 | FUTEX_REQUEUE 把唤醒数 0 变成 1 | Futex:MC-2 | #3964 第二段 | open |
| AST-81 | 同 bucket FUTEX_REQUEUE 在迁移配额为 0 时仍移动 waiter | Futex:MC-3 | 未找到 | — |
| AST-82 | FUTEX_REQUEUE 只返回唤醒数，不计迁移数 | Futex:MC-4 | 未找到 | — |
| AST-84 | 冲突的 flock SH→EX 转换保留调用者旧 SH 锁 | Flock:MC-1 | 未找到 | — |
| AST-85 | flock unlock 在 list Mutex 下释放临时引用，重入后自死锁 | Flock:MC-2 | #3283 相关，无直接报告 | open |
| AST-92 | 不带 WEXITED 的 waitid 回收了已退出子进程 | WaitReap:WR-LX，仅运行结果 | PR #2253 相关 | 已合入，不是修复 |
| AST-93 | 无事件的 waitid WNOHANG 不写 siginfo | WaitReap:WR-SQ，仅运行结果 | PR #2253 相关 | 已合入，不是修复 |

其余 58 条是 40 条 SOURCE LEAD、13 条 FALSE POSITIVE、2 条 UNSUPPORTED，以及 MASKED、DROPPED、MODEL ERROR 各 1 条。它们的上游对照在 CSV 中。其中 AST-35 在目录里仍是 SOURCE LEAD。本地修复分支 `fix/tcp-user-copy-atomic`（`4d1ed282b`）的提交信息记录了 TCP 路径上观察到的一次 panic，但工作区没有保留运行日志，详见审计报告。

## 上游对照要点

2026-10-19 用 `gh` 重新查询了已引用的 issue/PR（核查 agent 统计为 127 个，未独立复算），扫描了 09-14 之后新建的 189 个条目，并对从未去重的 AST-72..93 做了关键词搜索。没有在 GitHub 上写任何内容。

- **09-14 之后上游已修复。** AST-07 由 PR #3959 修复（10-11），AST-14 和 AST-02 的空写入部分由 PR #3875 修复（09-29），AST-19 由 PR #3984 修复（10-13）。AST-62 在 09-14 已由 PR #3824 修复。这些都只做了静态核对，没有本地重测。
- **已有直接报告、仍未修复。** AST-04（#711）、AST-08（#3920 第 11 项，只报告了机制，没有复现）、AST-42（#1097）、AST-64（#3746）、AST-79 和 AST-80（#3964）。
- **有开放 PR 覆盖、未合入。** AST-05 和 AST-10（PR #3778）、AST-06（PR #3481）、AST-09（PR #3576）、AST-40（PR #3297）。已引用的 PR 都没有合入。
- **已复现但上游没有对应报告。** AST-75、81、82、84 搜索无结果。AST-03、18、73、85、92、93 只有相关条目。AST-11、12、13、15、16、17、20..23、32、36 在 09-14 去重和这次新条目扫描中都没有直接匹配。
- **#2269 已关闭。** 它是 AST-15 的相关条目。10-05 stale 机器人只加了警告，随后维护者 lrh2000 以 completed 关闭，说明 #2937 和 PR #2953 应已解决。它的机制与 AST-15 不同。

“未找到”是有限关键词搜索的结果，不能证明上游从未讨论过。审计还发现，09-14 去重判为“无直接匹配”的若干条目，上游已合入的代码里其实有说明同一缺口的 FIXME/TODO，这部分尚未复核，见审计报告第三轮。

## 现有记录中的错误

这一节原先列出的成因分析和过时记录，已并入 [records-audit-2026-10-19.md](records-audit-2026-10-19.md)，并按审计复核结果做了更正。那份报告是现在的完整清单。

## CSV 字段

[asterinas-findings-issue-map-2026-10-19.csv](asterinas-findings-issue-map-2026-10-19.csv) 每行一个 AST，共 93 行，UTF-8 编码。

| 字段 | 含义 |
| --- | --- |
| `ast_id` | 稳定编号，与发现目录一致。 |
| `finding` | 目录中的英文名称。 |
| `catalog_status` | 目录状态：REPRODUCED、SOURCE LEAD、FALSE POSITIVE 等。 |
| `evidence_class` | 10-12 去重审计的证据类别，例如 `native_confirmation_record`。 |
| `first_seen` | 已知最早出现的日期，包括 Specula 之外的记录（例如 PR review 中第一次提出）。 |
| `seen_in` | 原始记录，格式为“run 别名:原始 ID”。“相关，未计入”表示不算作该条的复现。 |
| `native_reproduced_records` | 该条在原生报告中的 REPRODUCED 记录数，即重复观察次数。 |
| `upstream_refs` | 上游 issue（`#N`）和 PR（`PR #N`）。 |
| `upstream_match` | 匹配类别：直接报告、上游已修复、部分修复、部分重叠、开放 PR 覆盖、相关、无直接匹配、未找到，或误报、模型错误等无需跟踪的类别。 |
| `upstream_state_2026_10_19` | 刷新时的 open、closed、merged 状态和日期。 |
| `primary_link` | 主要对应条目的链接，只在直接报告、修复、部分重叠或开放 PR 覆盖时填写。 |
| `note` | 补充说明。 |

上游状态会继续变化。复用前可以用 `gh issue view <N> --repo asterinas/asterinas --json state,closedAt`（PR 用 `gh pr view` 加 `mergedAt`）刷新对应行。
