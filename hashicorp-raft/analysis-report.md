# hashicorp/raft 代码分析报告

## 1. 调查范围与方法

### 1.1 目标

对 hashicorp/raft 库进行静态代码分析，寻找潜在的协议安全性问题和代码缺陷，
为后续 TLA+ 建模和 Bug 发现提供方向。

### 1.2 分析的代码

代码位于 `case-studies/hashicorp-raft/artifact/raft/`，主要分析文件：

| 文件 | 大小 | 职责 |
|------|------|------|
| `raft.go` | ~2200 行 | 核心状态机：runFollower/runCandidate/runLeader, RPC 处理, 选举, 快照 |
| `replication.go` | ~660 行 | 日志复制: replicate, heartbeat, pipelineReplicate |
| `configuration.go` | ~370 行 | 集群成员配置变更逻辑 |
| `commitment.go` | ~105 行 | Commit index 推进与 quorum 计算 |
| `snapshot.go` | ~279 行 | 快照管理 |
| `api.go` | 公开 API |

### 1.3 分析方法

1. **并行静态代码分析** — 对 raft.go、replication.go、configuration.go 进行独立的逐行分析
2. **Git 历史 Bug 模式分析** — 分析历史 commit 中的 bug fix 模式
3. **GitHub Open Issues 分析** — 检查当前未解决的 issue 和已确认的 bug
4. **PreVote 实现专项分析** — 分析 PreVote 扩展的实现质量
5. **深度验证** — 对初步发现的可疑点进行逐一深入验证，区分真实 bug 与误报

---

## 2. 代码分析发现

### 2.1 raft.go 核心逻辑

#### 发现 1: heartbeat 协程不检查 resp.Term

**位置**: `replication.go:412-437`

**描述**: 在 `heartbeat()` 函数中，成功收到 AppendEntries 响应后，代码完全忽略了 `resp.Term`。
对比 `replicateTo()` (line 239-241) 和 `pipelineDecode()` (line 548-550) 都检查了 `resp.Term > req.Term`
并调用 `handleStaleTerm(s)` 触发 leader step-down。

```go
// replication.go:412-437 (heartbeat - 缺失 term 检查)
if err := r.trans.AppendEntries(peer.ID, peer.Address, &req, &resp); err != nil {
    // ... 错误处理
} else {
    s.setLastContact()
    failures = 0
    // 注意: 这里没有检查 resp.Term > req.Term
    s.notifyAll(resp.Success)
}

// 对比 replication.go:238-242 (replicateTo - 有 term 检查)
if resp.Term > req.Term {
    r.handleStaleTerm(s)
    return true
}
```

**分析**: 这是三条代码路径中唯一缺失 term 检查的。当集群空闲（无新写入）时，只有心跳协程活跃，
`replicateTo` 不会被调用。如果此时另一个节点当选了更高 term 的 leader，旧 leader 的心跳协程
不会检测到更高的 term，leader step-down 需要依赖其他机制（lease 超时、收到 RequestVote 等）。

**验证状态**: **代码不一致已确认**。但是否能导致协议违反尚需通过 TLA+ 建模或构造具体触发场景验证。
Leader 最终会通过 lease 超时等其他机制 step down，所以这可能只是延迟 step-down 而非造成安全性违反。

**初步评估**: 代码不一致（Medium）

---

#### 发现 2: timeoutNow 无状态守卫

**位置**: `raft.go:2210-2215`

```go
func (r *Raft) timeoutNow(rpc RPC, req *TimeoutNowRequest) {
    r.setLeader("", "")
    r.setState(Candidate)
    r.candidateFromLeadershipTransfer.Store(true)
    rpc.Respond(&TimeoutNowResponse{}, nil)
}
```

**描述**: `processRPC` 在 `runFollower` (line 172), `runCandidate` (line 326), `runLeader` (line 686)
三个状态循环中都会被调用。`timeoutNow` 不检查当前节点的状态。

**场景分析**:

| 当前状态 | 收到 TimeoutNow 的后果 |
|---------|----------------------|
| Follower | 正常：设置 Candidate，退出 runFollower（`for r.getState() == Follower`），进入选举 |
| Candidate | 设置 `candidateFromLeadershipTransfer=true`，赋予特权选举状态（跳过 PreVote，其他节点即使有 leader 也投票）|
| Leader | 强制 step down：leaderLoop 退出（`for r.getState() == Leader`），停止复制，进入选举 |

**分析**: 正常操作中 TimeoutNow 只由 leader 发给目标 follower，不会发给 candidate 或 leader 自身。
但协议层面没有防护。如果集群内有异常节点发送 TimeoutNow 给 leader，可以强制 leader step down。

**验证状态**: **代码行为已确认**。在正常操作下不会触发，属于防御性编程缺失。

**初步评估**: 鲁棒性问题（Low-Medium）

---

#### 发现 3: requestVote 中非投票者请求导致先 bump term 后拒绝

**位置**: `raft.go:1665-1684`

```go
// 先 bump term（line 1665-1672）
if req.Term > r.getCurrentTerm() {
    r.setState(Follower)
    r.setCurrentTerm(req.Term)
    resp.Term = req.Term
}

// 后检查是否是非投票者（line 1679-1684）
if len(req.ID) > 0 {
    candidateID := ServerID(req.ID)
    if len(r.configurations.latest.Servers) > 0 && !hasVote(r.configurations.latest, candidateID) {
        r.logger.Warn("rejecting vote request since node is not a voter", "from", candidate)
        return  // 拒绝投票，但 term 已经被 bump 了！
    }
}
```

**描述**: 当一个非投票者（NonVoter）发送带有更高 term 的 RequestVote 时，接收节点会先将自己的
term 提升到请求的 term（可能导致当前 leader step down），然后才检查请求者是否有投票权。
即使最终拒绝投票，term bump 的副作用已经发生。

**分析**: 这个问题在 hashicorp/raft PR #526 中被讨论过，代码注释（line 1674-1678）说明了
这是有意为之的设计选择：

> "if we get a request for vote from a nonVoter and the request term is higher,
> step down and update term, but reject the vote request.
> This could happen when a node, previously voter, is converted to non-voter.
> The reason we need to step in is to permit to the cluster to make progress in such a scenario."

**验证状态**: **设计决策，非 bug**。但一个被降级的节点可以通过不断发送高 term 的 RequestVote
来反复扰乱集群（让 leader step down）。PreVote 机制可以缓解此问题。

**初步评估**: 已知的设计权衡（Low）

---

#### 发现 4: 投票/预投票使用未 committed 的 latest 配置进行成员检查

**位置**: `raft.go:1645, 1681, 1758, 1785`

```go
// requestVote (line 1645) - 使用 latest 配置
if len(r.configurations.latest.Servers) > 0 && !inConfiguration(r.configurations.latest, candidateID) {
    // 拒绝投票
}

// requestPreVote (line 1758) - 同样使用 latest 配置
if len(r.configurations.latest.Servers) > 0 && !inConfiguration(r.configurations.latest, candidateID) {
    // 拒绝预投票
}
```

**描述**: `requestVote` 和 `requestPreVote` 都使用 `r.configurations.latest` 来判断候选人是否
在集群中以及是否有投票权。`latest` 可能包含尚未 committed 的配置变更。

**分析**: 这在 Raft 实现中是常见的做法。使用 committed 配置会导致新加入的 voter 在配置
committed 之前无法参与选举。但使用 latest 配置意味着不同 follower 可能对同一个候选人的
资格有不同判断（因为不同 follower 可能有不同的 latest 配置）。

hashicorp/raft 通过限制一次只能有一个未 committed 的配置变更（`configurationChangeChIfStable`,
line 659）来减轻此问题的影响。

**验证状态**: **代码行为已确认，是否为 bug 有争议**。大多数 Raft 实现都使用 latest 配置。
单一未 committed 配置变更的约束限制了影响范围。

**初步评估**: 已知设计权衡（Low）

---

#### 发现 5: processConfigurationLogEntry 在 follower 上的 committed 语义

**位置**: `raft.go:1586-1601`

```go
func (r *Raft) processConfigurationLogEntry(entry *Log) error {
    switch entry.Type {
    case LogConfiguration:
        r.setCommittedConfiguration(r.configurations.latest, r.configurations.latestIndex)
        r.setLatestConfiguration(DecodeConfiguration(entry.Data), entry.Index)
    }
    return nil
}
```

**描述**: 当 follower 收到配置变更日志条目时，将当前的 `latest` 提升为 `committed`，然后
设置新的 `latest`。但当前的 `latest` 本身可能尚未被 committed。

**对比 leader 的做法** (line 795-797):
```go
// Leader 只在 commit index 推进时才更新 committed
if r.configurations.latestIndex > oldCommitIndex &&
    r.configurations.latestIndex <= commitIndex {
    r.setCommittedConfiguration(r.configurations.latest, r.configurations.latestIndex)
}
```

**分析**: 由于 hashicorp/raft 限制一次只能有一个未 committed 的配置变更，在处理新的配置条目时，
之前的 `latest` 通常已经 committed。所以在实践中这个行为大概率是正确的。

此外，follower 在 `appendEntries` 中也有正确的 committed 更新逻辑 (line 1571-1572)：
```go
if r.configurations.latestIndex <= idx {
    r.setCommittedConfiguration(r.configurations.latest, r.configurations.latestIndex)
}
```

**验证状态**: **代码不一致已确认**。但由于单一未 committed 配置变更的约束，在实践中可能不会导致问题。

**初步评估**: 代码不一致（Low）

---

#### 发现 6: installSnapshot 不验证快照是否比当前状态更新

**位置**: `raft.go:1815-1953`

**描述**: `installSnapshot` 在接收并应用快照时，没有明确检查快照的 index/term 是否比当前
状态更新。理论上可能导致状态回退。

**分析**: 在正常操作中，leader 只会在 follower 落后太多时发送快照。快照的 index 应该比
follower 当前的 lastApplied 更高。但代码没有显式检查这一点。

**验证状态**: **需要进一步验证**。需要确认是否有其他机制（如 term 检查）隐式防止了此问题。

**初步评估**: 需进一步验证（Low-Medium）

---

#### 发现 7: dispatchLogs 失败后 inflight 列表清理问题

**位置**: `raft.go:1256-1273`

```go
// 日志已加入 inflight 列表
for idx, applyLog := range applyLogs {
    r.leaderState.inflight.PushBack(applyLog)
}

// StoreLogs 失败
if err := r.logs.StoreLogs(logs); err != nil {
    for _, applyLog := range applyLogs {
        applyLog.respond(err)  // 响应错误
    }
    r.setState(Follower)  // 但 inflight 列表中的条目没有移除！
    return
}
```

**描述**: 当 `StoreLogs` 失败时，代码向所有 applyLog 响应错误并转换为 Follower。
但这些 logFuture 仍然在 `inflight` 列表中。当 `runLeader` 的 defer 清理函数执行时，
它会遍历 inflight 列表并对每个条目调用 `respond(ErrLeadershipLost)`，这意味着
这些 future 会被 respond 两次。

**分析**: 需要检查 `respond()` 是否有幂等保护（只响应一次）。

**验证状态**: **需要检查 respond() 实现**

**初步评估**: 需进一步验证（Medium）

---

#### 发现 8: lastLog 缓存在 truncation + StoreLogs 失败后状态错误

**位置**: `raft.go:1540-1543`

```go
if err := r.logs.StoreLogs(newEntries); err != nil {
    r.logger.Error("failed to append to logs", "error", err)
    // TODO: leaving r.getLastLog() in the wrong
    // state if there was a truncation above
    return
}
```

**描述**: 这是开发者自己承认的 TODO。在 `appendEntries` 中，如果先执行了日志截断
（`DeleteRange`, line 1526）然后 `StoreLogs` 失败，`lastLog` 缓存会处于错误状态：
它仍然指向截断前的值，但实际日志已经被截断了。

**分析**: 这可能导致后续操作（如 `getLastEntry`）返回错误的值，影响 Log Matching 属性。

**验证状态**: **开发者已确认的已知问题**

**初步评估**: 已知问题（Medium-High）

---

### 2.2 replication.go 复制逻辑

#### 发现 9: nextIndex 的非原子读写

**位置**: `replication.go:256`

```go
atomic.StoreUint64(&s.nextIndex, max(min(s.nextIndex-1, resp.LastLog+1), 1))
```

**描述**: `atomic.StoreUint64` 内部读取 `s.nextIndex` 时没有使用 `atomic.LoadUint64`。
`s.nextIndex` 被心跳协程和复制协程并发访问。

**验证状态**: **代码问题已确认**，是一个数据竞争。

**初步评估**: 数据竞争（Medium）

---

#### 发现 10: s.peer.ID 在无锁情况下被访问

**位置**: `replication.go:521, 647, 660`

```go
// line 660 - commitment.match 使用了无锁的 s.peer.ID
s.commitment.match(s.peer.ID, last.Index)
```

**描述**: `s.peer` 可以被 `startStopReplication` 通过 `peerLock` 修改（更新地址等），
但某些访问点没有加锁。

**分析**: line 660 在 `updateLastAppended` 中，传递 `s.peer.ID` 给 `commitment.match`。
如果此时 `s.peer` 被并发修改（torn read），可能传入错误的 server ID。
不过 `peerLock` 只保护地址更新，ID 在实践中不会改变。

**验证状态**: **代码问题已确认**，但实际影响可能很小（ID 不变，只有 Address 会变）。

**初步评估**: 代码问题（Low）

---

#### 发现 11: closed stopCh 影响 best-effort 复制

**位置**: `replication.go:147, 272`

**描述**: `replicate` 的 `CHECK_MORE` 标签处有一个 select 检查 `stopCh`。当 `stopCh` 被关闭时，
select 会立即选中 `stopCh` 分支，绕过 best-effort 复制逻辑。

**验证状态**: **代码行为已确认**

**初步评估**: 小问题（Low）

---

### 2.3 configuration.go 配置变更逻辑

#### 发现 12: AddNonvoter 的 suffrage 处理逻辑

**位置**: `configuration.go:252-272`

```go
case AddNonvoter:
    for i, server := range configuration.Servers {
        if server.ID == change.serverID {
            if server.Suffrage != Nonvoter {
                // 如果已经是 Voter/Staging，只更新地址，不改变 suffrage
                configuration.Servers[i].Address = change.serverAddress
            } else {
                configuration.Servers[i] = newServer
            }
        }
    }
```

**描述**: 调用 `AddNonvoter` 对一个已有的 Voter 节点不会将其降级为 Nonvoter，只会更新地址。

**分析**: 通过查看 API 文档（`api.go:959-963`），这是设计如此：
> "If the server is already in the cluster, this updates the server's address."

降级需要使用 `DemoteVoter`。

**验证状态**: **非 bug，符合设计意图**

**初步评估**: 符合设计（非问题）

---

#### 发现 13: EncodeConfiguration/DecodeConfiguration 在错误时 panic

**位置**: `configuration.go:352-368`

**描述**: 这两个公开函数在序列化/反序列化失败时调用 `panic` 而不是返回 error。
如果收到损坏的日志条目，会导致节点崩溃。

**验证状态**: **代码行为已确认**

**初步评估**: 鲁棒性问题（Low-Medium）

---

#### 发现 14: committed vs latest 配置的不一致使用

**位置**: 多处

| 功能 | 使用的配置 | 位置 |
|------|-----------|------|
| Leader step-down 检查 | `committed` | raft.go:798 |
| `quorumSize()` | `latest` | raft.go:1089 |
| `checkLeaderLease()` | `latest` | raft.go:1049 |
| `setupLeaderState` commitment | `latest` | raft.go:458 |
| Vote 资格检查 | `latest` | raft.go:1645 |

**描述**: 不同功能使用了不同版本的配置。这在大多数情况下不是问题（因为 latest 和 committed
通常相同），但在配置变更期间可能导致不一致的决策。

**验证状态**: **代码不一致已确认**

**初步评估**: 代码不一致（Low-Medium）

---

### 2.4 PreVote 实现

#### 发现 15: metrics 标签 copy-paste 错误

**位置**: `raft.go:1738`

```go
func (r *Raft) requestPreVote(rpc RPC, req *RequestPreVoteRequest) {
    defer metrics.MeasureSince([]string{"raft", "rpc", "requestVote"}, time.Now())
    //                                                    ^^^^^^^^^^^ 应该是 "requestPreVote"
```

**验证状态**: **确认为 bug**（copy-paste 错误）

**初步评估**: 确认 bug（Low，仅影响 metrics）

---

#### 发现 16: requestPreVote 缺少 len(req.ID) > 0 守卫

**位置**: `raft.go:1758`

**描述**: `requestVote` 在检查 candidateID 前有 `if len(req.ID) > 0` 的守卫（向后兼容旧协议），
但 `requestPreVote` 没有。由于 PreVote 只存在于新版本协议中，这在实践中不是问题。

**验证状态**: **代码不一致已确认，但无实际影响**

**初步评估**: 代码不一致（Very Low）

---

#### 发现 17: 不支持 PreVote 的节点被当作 granted

**位置**: `raft.go:2083-2091`

```go
if err != nil && strings.Contains(err.Error(), rpcUnexpectedCommandError) {
    resp.Term = req.Term
    resp.Granted = true
}
```

**描述**: 使用 `strings.Contains` 做错误匹配，比较脆弱。但这是为了混合版本集群的兼容性。

**验证状态**: **设计决策**

**初步评估**: 鲁棒性问题（Low）

---

## 3. Git 历史 Bug 模式分析

### 3.1 Bug 热点文件

| 文件 | 变更次数 | 主要 Bug 类型 |
|------|---------|-------------|
| `raft.go` | 36 | 状态转换、竞态条件、选举安全 |
| `api.go` | 28 | API 接口、Leadership Transfer |
| `replication.go` | 18 | 竞态条件、peer 状态管理 |
| `configuration.go` | 12 | 配置变更安全 |

### 3.2 历史 Bug 分类

| 类别 | 数量 | 严重度 |
|------|------|--------|
| 竞态条件 | 5+ | High |
| Leadership Transfer 逻辑错误 | 4 | High |
| 选举/投票安全违反 | 3 | Critical |
| PreVote 实现 Bug | 2 | High |
| 未处理错误导致 Panic | 2+ | High |
| Channel 通知失败 | 2 | Medium |

### 3.3 重要历史 Bug 修复

| Commit | 描述 | 教训 |
|--------|------|------|
| `49bd61b` | `candidateFromLeadershipTransfer` 非原子访问 | Leadership Transfer 是竞态高发区 |
| `1a62103` | Peer 访问与心跳的竞态 | replication.go 的并发模型复杂 |
| `d68b78b` | Leadership Transfer 标志设置时序错误 | 标志在协程启动后才设置 |
| `38cb186` | 已移除节点仍可投票 | 配置变更与选举的交互是 bug 温床 |
| `656e6c0` | NonVoter 可转换为 Candidate | Suffrage 概念增加了状态空间 |
| `6b4e320` | NonVoter 高 term 导致 leader step-down | 同上 |
| `497108f` | Leader 自己的 PreVote 被拒绝 | 地址比较在特定网络环境下可能失败 |
| `42d3446` | 授予 PreVote 错误地更新了 leader last-contact | PreVote 与心跳超时的交互 |

---

## 4. GitHub Open Issues 与 PRs 分析（已逐一验证）

### 4.1 已标记为 Bug 的 Issues

| Issue | 描述 | 开放时间 | 验证结果 |
|-------|------|---------|---------|
| #275 | `inmemPipeline` 中 `shutdownCh` 和 `consumerCh` 的竞态 | 2018 | **确认 bug**（仅影响测试基础设施，有完整复现程序） |
| #503 | Leader LogStore 挂起导致整个集群挂起，无法重新选举 | 2022 | **确认 bug**（严重，有生产环境复现，心跳协程独立于 leader 主循环运行导致 follower 不会超时选举） |
| #522 | Leader 无法加载快照，集群无法恢复 | 2022 | **确认 bug**（严重，leader 无法发送快照但不 step down，有生产日志证据） |
| #85 | 从旧快照恢复后 panic | 2016 | **确认 bug**（快照回退导致日志缺口，有 Gist 复现测试，开放近10年未修复） |
| #86 | `TrailingLogs=0` 在快照后崩溃 | 2016 | **确认 bug**（边界条件，2024年有人确认仍可复现，开放8年未修复） |
| #66 | Peer/configuration 变更与日志操作非原子 | 2015 | **设计问题/不确定**（极简描述，无复现，无评论，可能已被新配置模型缓解） |

### 4.2 未标记 Issues（已逐一验证）

| Issue | 描述 | 验证结果 |
|-------|------|---------|
| #614 | 存储损坏的节点持续赢得选举 | **确认 bug** — 自降级后无选举惩罚机制，节点保留 term 优势反复当选，真实生产事件（持续10分钟） |
| #612 | 复制到 follower 静默停止（详细报告） | **确认 bug**（严重）— pipeline 复制路径可能吞掉 follower 端 StoreLogs 失败，leader 侧无错误日志，有生产日志和 metrics 截图 |
| #611 | 复制停止（简短报告） | **不确定** — 报告过于简短，无日志/复现，可能与 #612 同根因 |
| #498 | `Apply()` 在 quorum 丢失时永久死锁 | **确认 bug**（严重）— `deferError` future 的 `errCh` 永远不会被信号通知，多人独立确认，2025年2月仍可复现，开放3年+ |
| #634 | LeaderLeaseTimeout 可能导致不必要的 leader step-down | **设计讨论** — 理论关注，默认配置下安全，无具体复现 |
| #652 | LeaderLeaseTimeout 短于 HeartbeatTimeout 的影响 | **非 bug** — 用户对心跳机制的误解，HashiCorp 成员已解释心跳间隔为 HeartbeatTimeout/10 |
| #472 | 配置分歧导致选举卡在 Candidate 状态 | **确认 bug**（严重）— 3节点集群中2个存活节点配置分歧导致永久无法选举，多个独立生产系统确认 |
| #586 | `max(uint64)` term 导致极慢选举 | **超出设计范围** — 需要人为注入故障，非拜占庭协议不处理此场景，维护者明确表示不优先 |
| #643 | 节点身份跨集群冲突 | **用户错误** — 两个独立集群共享同一 transport 地址，Raft 设计上不支持 |
| #621 | 线性化读优化无法安全实现 | **确认设计缺陷** — 库不暴露 leader 初始 noop 的 commit 状态，PR #625 已提出修复 |
| #549 | Commit index 未持久化 | **确认设计缺陷** — 重启后节点无法重放已 committed 日志，HashiCorp 贡献者提出 `CommitTrackingLogStore` 接口 |

### 4.3 Open PRs（已逐一验证）

| PR | 描述 | 验证结果 |
|----|------|---------|
| #665 | 修复 requestPreVote metrics 标签 | **我们提交的 bug fix** |
| #651 | Snapshot RPC 错误修复 | **真实 bug fix**（严重）— 快照传输中大小变化导致连接协议损坏，后续 RPC 解析错误 |
| #638 | 降低 "nothing new to snapshot" 的日志级别 | **真实 bug fix**（日志噪音）— 正常行为被记录为 error |
| #625 | 支持 Leadership 断言检查 | **重要增强** — 实现 Raft 论文 Section 8 所需的线性化读前提条件，修复 #621 |
| #613 | 在 LogStore 中持久化 commit index | **增强** — 修复 #549，加速重启恢复 |
| #588 | 允许在快照传输期间 shutdown | **真实 bug fix** — 大快照传输期间 Shutdown() 永久阻塞 |
| #579 | WIP: 异步日志写入（leader 磁盘并行复制） | **增强（WIP）** — Ongaro 论文 Section 10.2.1 优化 |
| #571 | 升级 golang.org/x/sys (CVE) | **过时** — 已被后续依赖更新取代 |
| #538 | gRPC transport 实现 | **增强（草案）** — 3年未活跃，极度过时 |
| #518 | 导出 SkipStartup + 添加 Start() | **增强** — 3.5年未活跃 |
| #427 | 使 LeaderCh() 每次返回新 channel | **增强** — 5年未活跃 |

---

## 5. 深度验证结果

对初步分析中的高优先级发现进行了深入验证：

### 5.1 排除的误报

| 原始发现 | 排除原因 |
|---------|---------|
| "Leadership Transfer 候选人收到同 term AppendEntries 不 step down 可能导致两个 leader" | `runFollower` 循环条件是 `for r.getState() == Follower`，timeoutNow 设置 state=Candidate 后，下一次循环迭代立即退出，进入 runCandidate。不会卡在 runFollower 中。 |
| "AddNonvoter 反转 suffrage 逻辑" | 设计如此：AddNonvoter 仅用于添加新的 nonvoter 或更新已有节点地址。降级用 DemoteVoter。API 文档明确说明了此行为。 |
| "checkLeaderLease 可能因 replState 缺少 voter 而 panic" | 所有配置更新和 replState 更新在主线程同步执行（`appendConfigurationEntry` 中 `setLatestConfiguration` 和 `startStopReplication` 连续调用），不会出现不一致窗口。 |
| "dispatchLogs inflight 列表双重 respond" (raft.go:1256) | `respond()` 在 `future.go:125-126` 有 `d.responded` 幂等保护，第二次调用是 no-op。即使 StoreLogs 失败后 inflight 清理再次调用 respond，也不会产生副作用。 |
| "processConfigurationLogEntry committed 语义" (raft.go:1586) | `configurationChangeChIfStable()` (line 659) 限制一次只有一个未 committed 的配置变更。处理新配置条目时，前一个 latest 已经 committed，所以将其提升为 committed 是正确的。 |

### 5.2 确认的发现（二次深度验证后，按置信度排序）

| # | 发现 | 置信度 | 严重度 | 详细验证结论 |
|---|------|--------|--------|-------------|
| 1 | Metrics 标签 copy-paste 错误 (raft.go:1738) | **确认 bug** | Low | "requestVote" 应为 "requestPreVote"。已提交 PR #665 修复。 |
| 2 | lastLog 缓存在 truncation+StoreLogs 失败后错误 (raft.go:1540) | **确认（开发者 TODO）** | Medium-High | `DeleteRange` 成功后 `StoreLogs` 失败，lastLog 缓存指向已截断的位置。可导致后续 PrevLog 检查错误、commit index 虚高。需要磁盘故障触发。 |
| 3 | Heartbeat 不检查 resp.Term (replication.go:412) | **确认真实问题** | Low | `replicateTo` (line 239) 和 `pipelineDecode` (line 548) 都检查了 resp.Term，唯独 heartbeat 没有。集群空闲时仅心跳运行，leader 无法通过此路径发现更高 term。但 heartbeat 不携带日志，不会导致错误 commit，LeaderLeaseTimeout 最终兜底。 |
| 4 | timeoutNow 无状态守卫 (raft.go:2210) | **确认真实问题** | Moderate | 任何能发送 RPC 的节点均可发送 TimeoutNow：让 leader step down，或让 candidate 获得特权选举状态（跳过 PreVote，其他节点即使有 leader 也投票）。正常操作不触发，属防御性编程缺失。 |
| 5 | nextIndex 非原子读写 (replication.go:256) | **确认数据竞争** | Medium | `atomic.StoreUint64` 内部读 `s.nextIndex` 未用 `atomic.LoadUint64`，存在数据竞争。 |
| 6 | EncodeConfiguration panic (configuration.go:352) | **代码行为确认** | Low-Medium | 鲁棒性问题，收到损坏日志条目会导致节点 panic。 |

---

## 6. Bug 家族分析与 TLA+ 建模策略

通过分析历史 bug 修复、已确认的 open issues 和代码静态分析发现，我们识别出 **5 个 Bug 家族**。
每个家族有共同的根因模式，并关联了历史 bug 和新发现的潜在问题。

### 6.1 家族 1: 竞态条件

**共同根因**: 多个 goroutine 并发访问共享状态，缺少适当的同步机制。

**历史 Bug**:
- `candidateFromLeadershipTransfer` 非原子访问 (commit `49bd61b`) — Leadership Transfer 标志在设置前可被其他 goroutine 读取
- Peer 访问与心跳竞态 (commit `1a62103`) — peer 地址更新与心跳 goroutine 并发访问
- `inmemPipeline` shutdownCh 竞态 (#275) — channel 操作缺少同步保护

**新潜在问题**:
- **P1-C**: `nextIndex` 非原子读写 (`replication.go:256`) — `atomic.StoreUint64` 内部读 `s.nextIndex` 未用 `atomic.LoadUint64`

**TLA+ 建模启示**: 在 spec 中对共享变量的读写建模为独立的原子步骤，检查 interleaving 是否导致 nextIndex 回退或跳跃。

---

### 6.2 家族 2: Leader 无法自检失败（最关键）

**共同根因**: Leader 在自身出现异常（存储挂起、快照失败、被更高 term 取代）时，未能及时检测并 step down，
导致集群不可用。**这是 hashicorp/raft 生产环境中最严重的 bug 根因模式。**

**历史 Bug**:
- #503: LogStore 挂起 → 心跳独立运行 → follower 不超时 → **整个集群卡死**
- #522: Leader 无法加载快照但不 step down → **集群无法恢复**
- #614: 存储损坏节点自降级后无选举惩罚，保留 term 优势 → **反复当选，持续10分钟**

**新潜在问题**:
| ID | 描述 | 代码位置 | 风险 |
|----|------|----------|------|
| P2-A | heartbeat 不检查 resp.Term | `replication.go:412` | 空闲集群中 leader step-down 延迟 |
| P2-C | `checkLeaderLease` 使用 latest 配置 | `raft.go:1049` | 配置变更期间可能错误计算 lease |
| P2-D | 无 stable store 健康检查 | 整体设计 | 磁盘故障后 leader 不知自己异常 |
| P2-E | 快照错误被吞掉 | 快照相关代码 | 快照失败仅 log 不触发恢复动作 |

**TLA+ 建模建议**:
- 建模 leader 的 "liveness obligation": leader 必须在有限步内检测到自身异常并 step down
- 将 heartbeat 建模为**独立于 log replication** 的路径（这是 #503 的根因）
- 建模 LeaderLeaseTimeout 作为最终 step-down 机制
- 属性: `LeaderHealthProperty == [](isLeader(s) /\ ~canReachQuorum(s) => <>~isLeader(s))`

---

### 6.3 家族 3: 配置变更安全（最复杂）

**共同根因**: `committed` 和 `latest` 配置在不同代码路径中不一致使用，加上配置变更与选举/复制的交互，
创造出难以预见的状态组合。

**历史 Bug**:
- 已移除节点仍可投票 (commit `38cb186`)
- NonVoter 可转换为 Candidate (commit `656e6c0`)
- 配置分歧导致选举永久卡死 (#472) — 3节点集群中2个存活节点配置分歧，**永久无法选举**
- Peer/configuration 变更与日志操作非原子 (#66)

**committed vs latest 使用不一致一览**:

| 功能 | 使用的配置 | 代码位置 |
|------|-----------|----------|
| Leader step-down 检查 | `committed` | raft.go:798 |
| `quorumSize()` | `latest` | raft.go:1089 |
| `checkLeaderLease()` | `latest` | raft.go:1049 |
| `setupLeaderState` commitment | `latest` | raft.go:458 |
| Vote 资格检查 | `latest` | raft.go:1645 |
| `electSelf` 请求投票范围 | `latest` | raft.go:1096 |
| `startStopReplication` | `latest` | raft.go:459 |

**新潜在问题**:
| ID | 描述 | 代码位置 | 风险 |
|----|------|----------|------|
| P3-A | `quorumSize()` 使用 latest | `raft.go:1089` | 配置变更期间 quorum 大小不正确 |
| P3-B | `electSelf` 使用 latest | `raft.go:1096` | 向未 committed 成员请求投票 |
| P3-C | follower 截断后配置 commit | `raft.go:1586` | 截断可能移除配置条目但 committed 不回退 |
| P3-E | `startStopReplication` 使用 latest | `raft.go:459` | leader 可能向未 committed 新成员复制 |

**TLA+ 建模建议**:
- **区分建模 `committed` 和 `latest` 配置**（这是关键差异点）
- 允许同时存在最多一个 uncommitted 配置变更
- 在配置变更进行中时触发 leader crash 和重新选举
- 覆盖 Voter/NonVoter/Staging 三种 suffrage
- 属性: `ElectionSafety == [](\A s1,s2 \in Servers: isLeader(s1) /\ isLeader(s2) /\ sameTerm(s1,s2) => s1 = s2)`
- 属性: `ConfigSafety == [](committedConfig # latestConfig => AtMostOneUncommittedChange)`

---

### 6.4 家族 4: Copy-paste / 不完整实现

**共同根因**: PreVote 功能通过复制 RequestVote 代码实现，部分路径遗漏了必要的修改。

**历史 Bug**:
- metrics 标签 copy-paste 错误（已提交 PR #665 修复）
- PreVote 授予错误更新 leader last-contact (commit `42d3446`)

**新潜在问题**:
| ID | 描述 | 代码位置 | 风险 |
|----|------|----------|------|
| P4-E | `requestPreVote` 地址解码与 `requestVote` 不同 | `raft.go:1736` | 地址解析不一致 |
| P4-F | `requestPreVote` 缺少 `len(req.ID) > 0` 守卫 | `raft.go:1758` | 无实际影响（PreVote 仅新协议）|
| P4-G | `preElectSelf` 日志消息写 "requestVote" | 日志代码 | 调试混淆 |

**分析**: 此家族更适合代码审查而非形式化验证。可通过系统性对比 RequestVote 和 RequestPreVote 的每一行来发现剩余不一致。

---

### 6.5 家族 5: 错误处理缺口

**共同根因**: 磁盘写入/读取失败后的恢复路径不完整，中间状态不一致。

**历史 Bug**:
- 从旧快照恢复后 panic (#85) — 开放近10年未修复
- `TrailingLogs=0` 在快照后崩溃 (#86) — 开放8年未修复

**新潜在问题**:
| ID | 描述 | 代码位置 | 风险 |
|----|------|----------|------|
| P5-B | `persistVote` 非原子 | `raft.go:1135-1141` | 先写 term 再写 candidate，中间崩溃导致不一致 |
| P5-D | `installSnapshot` 不更新 lastLog 缓存 | `raft.go:1815+` | 安装快照后 lastLog 指向旧值 |
| P5-E | truncation + StoreLogs 失败 | `raft.go:1540` | 已确认（开发者 TODO），lastLog 缓存 stale |
| P5-F | 配置 decode 失败导致 panic | `configuration.go:352` | 收到损坏日志 → 节点崩溃 |

**TLA+ 建模建议**:
- 建模崩溃-恢复场景（crash after partial write）
- 在 `persistVote` 的两次写之间、`DeleteRange` 和 `StoreLogs` 之间插入崩溃
- 属性: `CrashRecovery == [](crashed(s) /\ recovered(s) => consistentState(s))`

---

## 7. TLA+ 建模优先级

### 7.1 第一优先级: 配置变更 + 选举交互

**理由**: 历史 bug 最密集（4+ critical bugs），目前有确认的未修复问题 (#472)，
committed vs latest 配置使用不一致是代码中最系统性的可疑模式，
TLA+ 最擅长发现此类状态空间交互问题。

**可能发现的新 bug**: P3-A, P3-B, P3-C, P3-E

### 7.2 第二优先级: Leader 健康检测与 step-down

**理由**: 3个已确认的严重生产环境 bug (#503, #522, #614) 共享同一根因模式。
心跳独立于 log replication 运行是一个架构性的设计选择，其副作用可能还有未发现的问题。

**可能发现的新 bug**: P2-A, P2-C, P2-D

### 7.3 第三优先级: 崩溃恢复一致性

**理由**: 2个长期未修复的 bug (#85, #86)，开发者确认的 lastLog 缓存问题（有 TODO 注释）。
崩溃恢复是形式化验证的经典应用场景。

**可能发现的新 bug**: P5-B, P5-D, P5-E

---

## 8. 总结

### 8.1 代码分析发现

1. **1 个确认的 bug**: metrics 标签 copy-paste 错误（已提交 PR #665）
2. **1 个开发者已知的问题**: lastLog 缓存状态错误（有 TODO 注释）
3. **3 个真实代码问题**: heartbeat term 检查缺失、timeoutNow 无状态守卫、nextIndex 数据竞争
4. **5 个排除的误报**: 通过深度代码验证排除了看似可疑但实际安全的代码路径
5. **14 个新潜在 bug 实例**: 通过 Bug 家族分析从历史 bug 模式推导出的新可疑代码路径

### 8.2 Issue/PR 验证结论

已逐一验证报告中提到的所有 issues 和 open PRs：

- **确认为真实 bug 的 issues**: #275, #503, #522, #85, #86, #614, #612, #498, #472（共9个）
- **确认为设计缺陷的 issues**: #621, #549（共2个）
- **排除为非 bug 的 issues**: #652（用户误解）, #586（超出设计范围）, #643（用户错误）
- **不确定的 issues**: #66（过于陈旧）, #611（报告不足，可能与 #612 同根因）, #634（理论讨论）
- **值得关注的 open PRs**: #651（快照 RPC 损坏修复）, #625（线性化读 API）, #588（shutdown 阻塞修复）

### 8.3 Bug 家族与 TLA+ 策略

| 家族 | 历史 Bug 数 | 新潜在实例 | TLA+ 优先级 | 关键建模差异 |
|------|------------|-----------|------------|-------------|
| 竞态条件 | 3 | 1 | 低 | 需建模细粒度并发步骤 |
| Leader 自检失败 | 3 | 4 | **高** | 需建模 heartbeat 独立路径 |
| 配置变更安全 | 4 | 4 | **最高** | 需区分 committed/latest 配置 |
| Copy-paste | 2 | 3 | 低 | 更适合代码审查 |
| 错误处理缺口 | 2 | 4 | **高** | 需建模 crash-recovery |

### 8.4 建议的后续方向

**TLA+ 建模**: 从"配置变更 + 选举交互"开始，区分建模 committed 和 latest 配置，
在配置变更进行中时触发 leader 故障和重新选举，重点检查 Election Safety 和 Log Matching 属性。

**代码修复 PR 目标**:
1. `Apply()` 死锁 (#498) — 长期未解决，多人确认，影响严重
2. heartbeat resp.Term 检查缺失 — 代码一行修复，影响明确
3. `preElectSelf` 日志消息 copy-paste 错误 — 与 PR #665 同类问题
