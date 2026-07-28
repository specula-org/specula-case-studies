# Analysis Report: slatedb-dist-compaction

## 1. Scope and Method

- **Audit date**: Tuesday, July 21, 2026
- **Repository**: `/home/ubuntu/Specula/case-studies/slatedb-dist-compaction/artifact/slatedb`
- **Focus**: SlateDB distributed compaction coordination, not SST merge internals
- **Category**: **Category A (Distributed / Message-Passing)**
- **Method followed**: Specula `code-analysis` workflow, including reconnaissance, bug archaeology, deep analysis, and modeling-brief synthesis

## 2. Coverage

### 2.1 Files Read

Read in full:

- `slatedb/src/compactor.rs`
- `slatedb/src/compactor_state.rs`
- `slatedb/src/compactor_state_protocols.rs`
- `slatedb/src/compaction_worker.rs`
- `slatedb/src/compactions_store.rs`
- `slatedb/src/manifest/store.rs`
- `rfcs/0025-distributed-compaction.md`

Read for adjacent safety context:

- `slatedb/src/garbage_collector/compacted_gc.rs`
- `slatedb/src/garbage_collector/compactions_gc.rs`
- `slatedb/src/admin.rs`
- `slatedb/src/size_tiered_compaction.rs`

Approximate audited core size: **14,679 LOC** across the six primary files plus RFC-0025.

### 2.2 Git / GitHub Archaeology Coverage

- Keyword scan over the six primary files returned **44** candidate commits touching the scope with bug-fix-like keywords.
- GitHub archaeology collected and deeply read **34** issue / PR threads through `gh` and parallel archaeology subagents.
- Classification of those 34 threads:
  - **22** directly relevant confirmed items
  - **5** partial / design-antecedent items
  - **7** excluded or context-only items

Key excluded/context-only items:

- `#879` - performance-only write-frequency idea for compaction-file updates
- `#1127`, `PR #1129` - `.compactions` file housekeeping, not protocol safety
- `#1035` - off-target hypothesis about protecting compaction inputs rather than unpublished outputs
- `PR #1529` - embedded compactor takeover path, not the main distributed worker/coordinator risk
- `#1165`, `#1853` - context around later fixes, but not the best primary evidence

No harness was built in this pass; the current write-up is based on source reading, RFC comparison, and archaeology.

## 3. Reconnaissance Summary

### 3.1 Architecture

The protocol is centered on two separately durable objects:

- `.manifest`: live DB state, checkpoints, compactor epoch
- `.compactions`: submitted/running/compacted/terminal coordination state

Workers do not publish manifest changes directly. Their role is:

- claim `Scheduled` jobs
- periodically refresh heartbeat plus resumable context
- write `Compacted` with produced SST handles

The coordinator is solely responsible for:

- validating `Submitted` compactions against the current manifest
- reclaiming stale `Running` jobs
- publishing `Compacted` results into the manifest
- writing `.compactions` terminal state after manifest publication

### 3.2 Atomicity Boundaries

There is **no** cross-object transaction between `.manifest` and `.compactions`.

Current write ordering is:

1. write checkpoint
2. write manifest
3. write `.compactions`

Current read ordering is:

1. read `.compactions`
2. read manifest

These orderings are explicit in `slatedb/src/compactor_state_protocols.rs:93` and `slatedb/src/compactor_state_protocols.rs:247-329`, and GC depends on them in `slatedb/src/garbage_collector/compacted_gc.rs:200-232`.

### 3.3 Semantic Caveat

Do **not** interpret `.compactions = Failed` as "manifest definitely not updated."

The code explicitly documents and relies on the opposite possibility: a crash can happen after manifest publication but before `.compactions` is updated to `Completed`, and recovery may later mark the compaction `Failed` even though the manifest change is already durable. See `slatedb/src/compactor.rs:914-929`.

## 4. Archaeology Summary by Mechanism

### 4.1 Publication / GC / Recovery Ordering

Most important historical items:

- `#604` - early report that GC could delete compacted SSTs before durable shared-state protection
- `#1044` - distributed variant of that bug: process-local watermarks were insufficient once GC and compactor were separated
- `PR #487` - temporary checkpoint pinning to keep manifest-referenced SSTs from disappearing under compactor reads
- `#1192` and `PR #1194` - restart could resurrect stale remote `Running` state and wedge scheduling forever
- `PR #1212` - restart semantics changed again to resume persisted running jobs using stored output context
- `#1095` and `PR #1152` - fence/init had to explicitly synchronize `.manifest` and `.compactions` epochs

Takeaway: shared-state publication order and recovery semantics are the oldest and densest bug family in this subsystem.

### 4.2 Worker Claim / Heartbeat / Reclaim

Most important historical items:

- `PR #1730`, `PR #1753`, `PR #1786` - the worker protocol landed incrementally and needed follow-up fixes
- `#1838` - open manual-submission conflict bug; maintainer confirmed the `Submitted -> Scheduled` gate should reject source/destination conflicts
- `#1850` and `PR #1856` - reclaiming a timed-out but still-running job could panic by duplicating local execution
- `#1862` - large compactions could loop through reclaim / re-claim without finishing
- `PR #1926` - slot accounting already required a recent fix

Takeaway: admission control and liveness control are still active bug surfaces as of July 21, 2026.

### 4.3 Fencing / Stale Merge / Invariant Repair

Most important historical items:

- `#352` - stale updater can write behind a GC tail after missing intermediate versions
- `#877` - design intent for coupling active compactor epoch across manifest/compactions
- `PR #1152` - explicit epoch synchronization in `CompactorStateWriter::fence`
- `PR #1840` - merge path had to accept stale `Compacted` and terminal entries after conflicts
- `PR #1836` - validation rules for `Compacted` versus `Submitted` needed refinement
- `#1935` - remote manifest merge could resurrect already-pruned metadata until re-prune logic was added
- `#779` - version-skewed stale readers/writers can drop unknown metadata fields

Takeaway: separate refresh/merge logic is necessary for the architecture, but historically fragile.

## 5. Deep Analysis Findings

### Finding 1: External `Submitted` Compactions Bypass the Coordinator's Full Admission Rules

**Severity**: High

This is the strongest current bug family and the main modeling target.

#### Evidence

- `Admin::submit_compaction()` calls `Compactor::submit()` and persists a new `Submitted` entry directly to `.compactions` without going through `CompactorState::add_compaction()`:
  - `slatedb/src/admin.rs:192-200`
  - `slatedb/src/compactor.rs:478-502`
- `CompactorState::add_compaction()` is where the coordinator currently enforces active destination uniqueness and an explicit active-drain guard:
  - `slatedb/src/compactor_state.rs:988-1023`
- `validate_compaction()` explicitly says cross-compaction conflicts are enforced upstream in `add_compaction()` and are not re-checked here:
  - `slatedb/src/compactor.rs:1022-1028`
- The only active-compaction check still performed in `validate_compaction()` is same-segment parallel L0 compaction:
  - `slatedb/src/compactor.rs:1130-1155`
- `maybe_validate_submitted_compactions()` promotes every valid `Submitted` entry to `Scheduled` with no global capacity gate on that path:
  - `slatedb/src/compactor.rs:1308-1356`
- Each worker budgets capacity only locally:
  - `slatedb/src/compaction_worker.rs:304-308`
  - `slatedb/src/compaction_worker.rs:327-387`

#### Why this is a real current protocol gap

Locally proposed compactions go through `add_compaction()`. Externally inserted `Submitted` entries do not. The coordinator later validates them against the manifest, but that validator intentionally omits the active-compaction conflict checks that `add_compaction()` performs.

That means the `Submitted -> Scheduled` path for external/manual entries does **not** currently guarantee:

- no active destination collision
- no explicit re-run of the active-drain guard from `add_compaction()`
- no global capacity bound before promotion to `Scheduled` on that path

This matches the maintainer response in `#1838`:

- on July 2026, a maintainer stated the coordinator should validate source/destination conflicts when transitioning `Submitted -> Scheduled`
- the reporter confirmed the failing path was CLI submission

#### Likely impact

The downstream effect depends on the overlap pattern:

- duplicate work and orphaned output SSTs
- unnecessary worker panics or claim/reclaim churn
- potential bound violations where the total running work exceeds the configured maximum
- additional pressure on recovery and commit logic that assumed these conflicts were filtered earlier

I am treating this as a **current confirmed protocol gap**, not merely a historical regression reference.

### Finding 2: Reclaim / Ownership Transfer Still Has Open Duplicate-Execution Risk

**Severity**: High, but not re-confirmed as a fresh current bug in this pass

#### Evidence

- Coordinator reclaim uses timeout based on coordinator-local time:
  - `slatedb/src/compactor.rs:790-835`
- Workers claim based on `.compactions`, then dispatch local executor work:
  - `slatedb/src/compaction_worker.rs:327-387`
  - `slatedb/src/compaction_worker.rs:421-469`
- Worker heartbeats and completion ownership checks are keyed by `worker_id` plus heartbeat timestamp, not a unique claim generation:
  - `slatedb/src/compaction_worker.rs:581-582`
  - `slatedb/src/compaction_worker.rs:610-617`
  - `slatedb/src/compaction_worker.rs:719-747`
  - `slatedb/src/compaction_worker.rs:805-817`
- Executor stop is asynchronous:
  - `slatedb/src/compaction_worker.rs:780-787`
- `handle_finished()` drops local bookkeeping before the durable write or claim release succeeds:
  - `slatedb/src/compaction_worker.rs:827-837`

Historical confirmation:

- `#1850` documented a deterministic panic when reclaim let the same worker re-dispatch a still-running job
- `#1862` documented repeated timeout / reclaim loops on large compactions

#### Current assessment

The current worker is more defensive than the buggy revision from `#1850`:

- on seeing a candidate already present in `job_progress`, it stops the local job instead of dispatching a duplicate immediately (`slatedb/src/compaction_worker.rs:338-350`)
- on heartbeat ownership loss, it stops execution (`slatedb/src/compaction_worker.rs:610-617`)

Those are real compensations. I did **not** re-confirm the exact old panic in the current tree.

What remains open, and worth model checking, is the same-worker stale-execution case:

- reclaim can happen while an old local execution is still winding down
- ownership is checked by `worker_id`, not by a per-claim nonce
- `handle_finished()` removes local bookkeeping before durable transition completion

That combination is sufficient to keep this as a top modeling target.

### Finding 3: Publication / Recovery Ordering Is Deliberate and Probably Safe, but It Must Be Modeled Explicitly

**Severity**: High modeling priority, not a newly confirmed bug

#### Evidence

- Readers fetch `.compactions` before manifest: `slatedb/src/compactor_state_protocols.rs:93-101`
- Writers persist checkpoint -> manifest -> `.compactions`: `slatedb/src/compactor_state_protocols.rs:247-329`
- `commit_compacted_entries()` intentionally marks `Failed` when validation no longer matches the manifest, even if the manifest already contains the result: `slatedb/src/compactor.rs:914-983`
- GC intentionally reads compactions before manifest and uses both views to avoid deleting unpublished outputs: `slatedb/src/garbage_collector/compacted_gc.rs:200-232`

#### Current assessment

I did **not** find a direct current bug in the publication ordering itself. The present implementation appears intentionally structured around the historical failures.

However, this is exactly the sort of logic that produces subtle bugs only under crash interleavings, and the subsystem already has a long history here:

- `#604`
- `#1044`
- `#1192`
- `PR #1194`
- `PR #1212`

This family belongs in the model even though I am not reporting a fresh direct defect today.

### Finding 4: Stale Refresh / Merge / Fencing Remains a Bug-Dense Axis

**Severity**: Medium

#### Evidence

- Writer fencing couples `.compactions` to the manifest epoch at init:
  - `slatedb/src/compactor_state_protocols.rs:177-204`
- Coordinator refreshes `.compactions` and manifest independently, then merges each remote view into local state:
  - `slatedb/src/compactor_state_protocols.rs:212-228`
  - `slatedb/src/compactor_state.rs:882-944`
  - `slatedb/src/compactor_state.rs:951-974`
- Manifest fencing and compactor fencing are separate interfaces:
  - `slatedb/src/manifest/store.rs:34-66`

Historical confirmation:

- `#352`, `PR #1152`, `PR #1840`, `PR #1836`, `#1935`, `#779`

#### Current assessment

The current code has meaningful repairs:

- merge logic now preserves stale `Compacted`/terminal entries when needed
- fencing explicitly synchronizes epochs
- manifest mutation paths prune external SST ids after finish

Still, the mechanism itself is fragile and historically broad. It should remain a modeled family, especially because the architecture fundamentally requires separate refresh/merge of two durable objects.

## 6. Lower-Level Findings Better Suited for Tests or Review

### 6.1 Test-Verifiable

1. `maybe_schedule_compactions()` silently drops `add_compaction()` errors because it maps to `Result<()>` and then calls `.count()`:
   - `slatedb/src/compactor.rs:1255-1268`
2. Post-claim invalid specs are released back to `Scheduled`, not `Submitted`, so the worker path can thrash on the same invalid entry:
   - `slatedb/src/compaction_worker.rs:446-453`
   - `slatedb/src/compaction_worker.rs:791-823`
3. `available_capacity = max_concurrent_compactions - running_compaction_count` can underflow if the persistent state already contains more `Running` jobs than the configured bound:
   - `slatedb/src/compactor.rs:1239-1240`

### 6.2 Code-Review-Only

1. `CompactorState::add_compaction()` does not reject duplicate compaction ids and will overwrite an existing map entry:
   - `slatedb/src/compactor_state.rs:1018-1023`
2. `retain_active_and_last_finished()` keeps the max ULID among finished compactions, not the most recently finished by completion time:
   - `slatedb/src/compactor_state.rs:773-790`
3. `CompactionContext::validate_update()` and `set_ctx()` use `assert!` / `assert_eq!` on persisted state transitions:
   - `slatedb/src/compactor_state.rs:394-419`
   - `slatedb/src/compactor_state.rs:560-567`
4. `finish_compaction()` assumes the first L0 source is the newest and leaves a TODO instead of validating that ordering:
   - `slatedb/src/compactor_state.rs:1072-1115`

## 7. Exclusions and False Positives

I explicitly excluded the following from the main modeling target set:

- `#879`: performance-only proposal about reducing compactions-file write frequency
- `#1127` / `PR #1129`: old `.compactions` file cleanup, not protocol safety
- `#1035`: off-target hypothesis about input protection rather than the confirmed unpublished-output family
- `PR #1529`: embedded compactor takeover path; useful context, but not the main distributed worker/coordinator failure mode here
- compression / encoding / bloom / iterator correctness
- byte-level SST merge logic

## 8. Bottom Line

The audit found one clear current coordination gap and four strong modeling families.

The clearest current defect is the split admission path for externally submitted compactions: the coordinator's `Submitted -> Scheduled` promotion path does not currently centralize the conflict and capacity checks that other paths rely on. That is directly acknowledged in `#1838` and visible in the current code.

The rest of the high-value work is modeling-oriented rather than code-review-only:

- shared-state publication across `.manifest` and `.compactions`
- heartbeat / reclaim / ownership transfer
- stale refresh / merge / fencing
- global concurrency accounting under external/manual backlog

Those are the areas most likely to produce new information from TLA+ rather than simply re-deriving already-fixed bugs.
