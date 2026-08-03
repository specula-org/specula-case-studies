# Modeling Brief: SONiC warm-reboot orchestration

## 1. System Overview

- **System**: `warmreboot` in `sonic-net/sonic-buildimage`, primarily C++ with Bash/Python orchestration; 32,358 C++ lines in the selected 29-file, 36,756-line core.
- **Category**: **Category A (Distributed / Message-Passing)** because independently scheduled containers and daemons coordinate through Redis tables, request/reply channels, files, signals, and systemd rather than one shared-memory algorithm.
- The protocol freezes orchagent producers, places syncd in `INIT_VIEW`, checkpoints Redis, restarts processes, rebuilds warm state, applies a reconciled ASIC view, reconciles auxiliary daemons, and finally clears warm flags.
- The implementation has no single operation epoch or global coordinator transaction: per-ASIC shell jobs, component state fields, dump files, and syncd phases progress independently.
- Unlike an ideal reference ordering, `READY` precedes the final drain/flush/freeze, while checkpoint and APPLY publication are multi-step; concurrency spans processes, Redis event loops, timers, per-ASIC shell jobs, a route-ring worker, and syncd's mutex-guarded notification worker.
- Redis commands and pruning Lua scripts are locally atomic, but there is no cross-database, filesystem, process-quiescence, hardware, or ASIC_DB commit boundary.

## 2. Scenarios

### Scenario 1: Reboot epoch admission and cancellation ownership

**Mechanism**: A warm reboot is represented by loosely related flags and side effects rather than an atomically acquired, owner-scoped operation epoch.  
**Evidence**:

- Historical: utilities commit `14840074` and related flag/timer fixes show recurring coordination defects; closed fixes remain mechanism evidence only.
- Code analysis: `src/sonic-utilities/scripts/fast-reboot:341-370,883-894,973-996` separately reads/writes flags, uses no lock/CAS, and a caught signal performs cleanup without terminating the caller.

**Affected code paths**: `check_warm_restart_in_progress`, `clear_boot`, signal traps, warm/fast enable writes, DBus/CLI entry paths.  
**Suggested modeling approach**:

- Variables: `epoch`, `owner`, `requestKind`, `phase`, `cancelled`, `flags`, `cleanupOwner`.
- Actions: acquire/reject an epoch, publish flags, cancel, owner cleanup, retry, and begin irreversible work.
- Granularity: split acquisition, flag publication, cancellation, and cleanup so competing callers and stale cleanup can interleave.

**Priority**: High
**Rationale**: Admission races can launch overlapping global reboots; the state space is small and naturally exposes ownership and monotonic-phase violations.

### Scenario 2: Acknowledgement before a global quiescence fence

**Mechanism**: A local readiness reply is treated as a freeze acknowledgement before all producers, queues, and post-reply mutations are fenced.  
**Evidence**:

- Historical: swss commits `721f47d9`, `bab7b933`, and closed PRs #1556/#1103 successively repaired route/FDB warm-freeze ordering.
- Code analysis: `orchdaemon.cpp:1190-1221,1347-1413` sends `READY` before drain/FDB/flush/freeze; `orchagent_restart_check.cpp:108-140` returns on an uncorrelated reply; `fast-reboot:1137-1163,1199-1204` can suppress freeze failure and validates stop order after the point of no return.

**Affected code paths**: `OrchDaemon::warmRestartCheck`, RESTARTCHECK handling, route-ring worker, `pause_orchagent`, per-ASIC freeze loops, order-file validation.  
**Suggested modeling approach**:

- Variables: per-producer `state`, `inflight`, `queue`, `readySent`, `quiescent`, `freezeResult`, and coordinator `phase`.
- Actions: request freeze, scan pending work, reply, enqueue/drain work, mutate FDB mode, flush, freeze heartbeat, fail/continue, and checkpoint.
- Granularity: preserve every post-reply step and each producer/channel as a separate transition.

**Priority**: High
**Rationale**: The reply is a cross-process safety boundary, but present checks are local and an immediate restart path can consume it without an implicit delay.

### Scenario 3: Per-ASIC shutdown, mode choice, and checkpoint aggregation

**Mechanism**: Independent participant outcomes are collapsed into global progress while command failures and partial snapshots are masked.  
**Evidence**:

- Archaeology: closed utilities commit `6eedf8a7` intended to remove a failed ASIC before continuing; open buildimage issue #7072 records partial APPLY/shutdown failure behavior.
- Code analysis: `fast-reboot:452-506,1137-1204` masks failures; `swss.sh:522-543` targets literal `swss` for `swss@N`; `syncd.sh:145-173` does not verify local mode, while `Syncd.cpp:6982-7029` can downgrade and `docker_image_ctl.j2:105-109,296-299` accepts dump existence.

**Affected code paths**: dynamic stop-order generation, systemd stop helpers, syncd PRE/final shutdown, `centralize_database`, dump copy/load, per-ASIC/global flag finalization.  
**Suggested modeling approach**:

- Variables: per-ASIC `freeze`, `writerStopped`, `localMode`, `shutdownStatus`, `snapshotEpoch`, `snapshotValid`; global `decision` and `sharedFlags`.
- Actions: stop a participant, report or lose status, downgrade mode, write/rename/load a snapshot, aggregate decisions, fail/crash, and restart.
- Granularity: separate producer stop, Redis SAVE, dump copy/publication, per-ASIC completion, and global commitment.

**Priority**: High
**Rationale**: A mixed or incomplete checkpoint can become authoritative across reboot, and multi-ASIC execution multiplies partial-completion cuts.

### Scenario 4: Split hardware/APPLY and database commit

**Mechanism**: APPLY performs irreversible hardware operations and then independently rewrites Redis/maps without a journal, commit marker, rollback, or resume rule.  
**Evidence**:

- Historical: sairedis commits `85a579b3`, `3026945b`, `4b2638ca`, and `584ce03d` show recurring operation-order and Redis-publication defects.
- Code analysis: `Syncd.cpp:5716-5980` executes SAI then rebuilds Redis/maps through independent writes (`RedisClient.cpp:582-600,664-680,886-908`); `ComparisonLogic.cpp:3681-3893` warns retry may be unsafe, and `WarmRestartTable.cpp:20-43` has no APPLY/dirty/epoch state.

**Affected code paths**: `processNotifySyncd`, `applyView`, `ComparisonLogic::executeOperationsOnAsic`, Redis ASIC-state/map replacement, restart-query recovery.  
**Suggested modeling approach**:

- Variables: `plannedOps`, `opCursor`, `hardwareView`, `dbView`, `maps`, `applyEpoch`, `applyState`, `recoveryMode`.
- Actions: compare, execute one hardware operation, delete/write one DB portion, replace one map, crash, resume, or force cold recovery.
- Granularity: one transition per irreversible operation and publication fragment, with crashes between every pair.

**Priority**: High
**Rationale**: Crash consistency spans two authorities and is precisely the kind of non-atomic protocol TLA+ can explore exhaustively.

### Scenario 5: Nondeterministic identity reconciliation

**Mechanism**: Reconciliation may choose among structurally similar objects without a deterministic, globally injective identity rule.  
**Evidence**:

- Archaeology: closed issue #449 and commit `d6eee421` repaired special-case ACL matching; open sairedis PR #2007 reports random virtual-router correspondence.
- Code analysis: `ComparisonLogic.cpp:67-71,2874-2999,3895-3917` seeds randomness, partially pre-matches, and conditionally validates maps; `AsicView.cpp:405-499` traverses unordered candidates while `SaiSwitch.cpp:321-361,488-578,1188-1251` permissively synthesizes some missing mappings.

**Affected code paths**: switch discovery, pre-match, candidate selection, VID/RID translation, object transfer, map consistency validation.  
**Suggested modeling approach**:

- Variables: old/new object graphs, stable labels, candidate relation, chosen matching, `vidToRid`, `ridToVid`.
- Actions: choose a candidate nondeterministically, bind identities, transfer unmatched objects, validate reciprocity, and execute an identity-sensitive operation.
- Granularity: one bind per transition so alternate permutations and graph automorphisms remain visible.

**Priority**: High
**Rationale**: Small symmetric graphs can expose duplicate/nonreciprocal bindings that randomized testing may miss.

### Scenario 6: Timeout-driven reconciliation and premature completion publication

**Mechanism**: Silence is interpreted as convergence, while terminal state and warm-flag clearing can precede durable output publication or late participants.  
**Evidence**:

- Issue evidence: open swss #4579 reports route convergence beyond the timer; open buildimage #17943 reports pmon/xcvrd observing flags after finalization.
- Code analysis: `fpmsyncd.cpp:154-218` reconciles on EOIU/timeout and publishes before normal pipeline flush; `warmRestartHelper.cpp:159-176,256-346` deletes absent refresh entries; `finalize-warmboot.sh:240-302` clears flags after logged timeout.

**Affected code paths**: route refresh caching/comparison, timer/EOIU handlers, buffered route publication, warmboot finalizer waits, per-component flag clearing.  
**Suggested modeling approach**:

- Variables: `inputComplete`, `timerExpired`, `cachedOld`, `refreshedNew`, `outputBuffered`, `outputPublished`, participant terminal states, `flagsCleared`.
- Actions: receive early/late input, timeout, reconcile/delete, publish/flush output, fail terminally, observe/clear a flag.
- Granularity: keep timeout, state publication, output flush, late arrival, and flag clearing distinct.

**Priority**: High
**Rationale**: The protocol conflates timeout with proof of completeness and exposes both safety and liveness properties.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **Admission and global fence**: model atomic epoch ownership plus each Redis/channel/ring producer and post-ack mutation for Scenarios 1-2.
- **Checkpoint and APPLY**: model participant-local mode/status/snapshot validity for Scenario 3 and operation-level crash cuts with dirty/journal state for Scenario 4.
- **Identity and completion**: use small symmetric graphs for Scenario 5; model silence, late input, buffered output, terminal failure, and flag observers for Scenario 6.

### 3.2 Do Not Model (with rationale)

- **Exact SAI objects, attributes, vendor behavior, or packet timing**: abstract these as graph nodes, success/failure, and a data-plane outcome; detail obscures protocol cuts.
- **Linux, Docker, systemd, kexec, or Redis wire internals**: abstract process availability, stop acknowledgements, local atomic commands, and crashable file publication.
- **Exact graph/timer and direct shell/C++ defects** such as `-N`, literal `swss`, paired-route comparison, or missing RID guard: retain abstract edges/expiry; route concrete defects to tests/review.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| RebootEpoch | `epoch`, `owner`, `phase`, `cancelled`, `cleanupOwner` | Serialize requests and bind cleanup to one attempt | Scenario 1 |
| ProducerFence | `producerState`, `inflight`, `queue`, `readySent`, `quiescent` | Distinguish local reply from global quiescence | Scenario 2 |
| ParticipantSnapshot | `localMode`, `shutdownStatus`, `globalDecision`, `snapshotEpoch`, `snapshotValid`, `writerStopped` | Explore mixed outcomes and checkpoint provenance | Scenario 3 |
| ApplyJournal | `applyEpoch`, `applyState`, `opCursor`, `hardwareView`, `dbView` | Represent split commit and crash recovery | Scenario 4 |
| IdentityGraph | `stableLabels`, `candidates`, `matching`, `vidToRid`, `ridToVid` | Explore ambiguous object correspondence | Scenario 5 |
| CompletionBarrier | `inputComplete`, `outputPublished`, `terminal`, `flagsCleared` | Separate timeout, publication, and finalization | Scenario 6 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| InitBeforeApply | Safety | No participant applies a temporary view before successful INIT for the same epoch | Standard algorithm, Scenario 4 |
| SingleAuthoritativeView | Safety | At most one current hardware/DB view is authoritative per epoch | Standard algorithm, Scenarios 3-4 |
| PhaseMonotonicity | Safety | An attempt never returns to a reversible phase after freeze/commit begins | Standard algorithm, Scenarios 1-3 |
| EventualRecoveryDecision | Liveness | Every admitted attempt eventually commits warm state or chooses explicit cold recovery | Standard algorithm, Scenarios 1, 3-4 |
| AtMostOneActiveEpoch | Safety | No two owners execute irreversible work concurrently | Scenario 1 |
| FreezeAckImpliesQuiescence | Safety | `READY` implies all modeled producers are fenced and all prior work is drained | Scenario 2 |
| CheckpointAfterQuiescence | Safety | No snapshot is published while a producer for that namespace can still write | Scenarios 2-3 |
| CompleteSameEpochSnapshot | Safety | Every consumed namespace dump is complete and belongs to the selected epoch | Scenario 3 |
| ApplyCommitAgreement | Safety | A committed APPLY has equivalent hardware, ASIC_DB, and reciprocal identity maps | Scenario 4 |
| NoWarmFromDirtyApply | Safety | Recovery never selects warm mode from an incomplete/dirty APPLY attempt | Scenario 4 |
| IdentityMapBijective | Safety | Each matched VID/RID has exactly one reciprocal correspondence | Scenario 5 |
| ReconciledImpliesOutputsPublished | Safety | Terminal reconciliation is not visible before all derived output is durable | Scenario 6 |
| WarmFlagSafeToClear | Safety | Flags clear only after every required participant is terminal and outputs are published | Scenario 6 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-1 | With epoch CAS added, can cancellation/retry cleanup by an old owner erase a newer owner's flags or snapshot? | AtMostOneActiveEpoch, PhaseMonotonicity | Scenario 1 |
| MC-2 | After moving the local reply after drain/flush, can another producer or channel still cross the global freeze fence before checkpoint? | FreezeAckImpliesQuiescence, CheckpointAfterQuiescence | Scenario 2 |
| MC-3 | With a durable APPLY journal, is every single crash cut resumable to agreement or forced cold recovery without accepting dirty state? | ApplyCommitAgreement, NoWarmFromDirtyApply, EventualRecoveryDecision | Scenario 4 |
| MC-4 | Can a policy that permits per-ASIC warm downgrade still derive one consistent global decision and same-epoch checkpoint? | CompleteSameEpochSnapshot, SingleAuthoritativeView | Scenario 3 |
| MC-5 | With explicit terminal failure and late-input actions, can flags be both safely retained and eventually cleared? | WarmFlagSafeToClear, EventualRecoveryDecision | Scenario 6 |
| MC-6 | After labeling all currently known special objects, can remaining graph automorphisms produce externally distinct or non-bijective bindings? | IdentityMapBijective, ApplyCommitAgreement | Scenario 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | `fast-reboot -N` returns status 23 even on successful teamd stop; `-t` is documented but absent from `getopts`. | Shell test with mocked `systemctl`/`docker` and exact exit assertions. |
| TV-2 | Route warm comparison sorts `nexthop`, `ifname`, and weight values independently, so a positional pair swap can compare equal. | Unit test with two paired route vectors whose independent multisets match but tuples differ. |
| TV-3 | One fpmsyncd warm helper is bound to `ROUTE_TABLE`, causing label/EVPN updates to reconcile into the wrong table and deletes to disappear. | Integration test with colliding keys across route, label-route, and EVPN tables. |
| TV-4 | A `swss@N` warm stop executes `docker kill swss` rather than `swssN`. | Multi-ASIC service test recording the addressed container and remaining Redis writers. |
| TV-5 | Normal non-ZMQ fpmsyncd can publish `RECONCILED` before its buffered route writes flush. | Crash-injection test between helper state update and pipeline flush. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | Stop-order publication directly truncates the target and silently omits packages with no graph edges. | Decide whether every extension daemon must join the fence; publish the graph by temp-file rename. |
| CR-2 | Syncd PRE/final commands have unbounded calls, weak status handling, and no coordinator read-back of the final local mode. | Define a participant status contract, time bounds, and mixed-mode policy. |
| CR-3 | Equal-size VID/RID maps bypass the detailed reciprocal validator. | Invoke validation unconditionally and decide whether repair or cold fallback is authoritative. |

## 7. Reference Pointers

- Detailed audit: `analysis-report.md` in this output directory.
- Core source: `fast-reboot:341-506,883-1204`; `swss.sh:497-556`; `syncd.sh:111-173`; `orchdaemon.cpp:1190-1221,1347-1413`; `orchagent_restart_check.cpp:108-140`; `Syncd.cpp:5565-5980,6257-7059`; `ComparisonLogic.cpp:2658-3283,3681-3917`; `warmRestartHelper.cpp:159-346`; `fpmsyncd.cpp:154-218`.
- Threads: current [sairedis #2007](https://github.com/sonic-net/sonic-sairedis/pull/2007), [swss #4579](https://github.com/sonic-net/sonic-swss/issues/4579), [buildimage #12257](https://github.com/sonic-net/sonic-buildimage/issues/12257), [#17943](https://github.com/sonic-net/sonic-buildimage/issues/17943), [#7072](https://github.com/sonic-net/sonic-buildimage/issues/7072); historical swss [#1556](https://github.com/sonic-net/sonic-swss/pull/1556)/[#1103](https://github.com/sonic-net/sonic-swss/pull/1103), sairedis [#449](https://github.com/sonic-net/sonic-sairedis/issues/449), utilities [#2860](https://github.com/sonic-net/sonic-utilities/pull/2860)/[#2410](https://github.com/sonic-net/sonic-utilities/pull/2410). No standalone formal spec was found; obligations derive from documented INIT/APPLY, freeze, checkpoint, restart, and recovery ordering.
