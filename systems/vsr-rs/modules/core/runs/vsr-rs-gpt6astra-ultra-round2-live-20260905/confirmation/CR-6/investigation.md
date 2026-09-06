# CR-6 Investigation

## Finding

- Source: Code Review.
- Claimed mechanism: simulator/DST/proof observers omit important state and transport histories, so they can miss future regressions.
- Primary locations audited: `simulator/properties.rs`, `simulator/lib.rs`, `lib.rs`, and the retained Lean files on `origin/lean`.
- Worktree head: `3ac0104a567092139534c9022205d02281a2da41`.
- Worktree note: the checkout already contained local trace-harness edits in `Cargo.toml`, `lib.rs`, and untracked `tla_trace/`; the audited simulator files are unmodified.

## Step 1: Code Audit

### Property observer surface

`simulator/properties.rs:9-18` defines `SimContext` with only:

- current `tick`,
- current replicas,
- the cumulative list of replies received by clients,
- the liveness/safety core.

The property trait at `simulator/properties.rs:20-35` has `check`, `finalize`, and `on_reboot`; it has no per-send, per-delivery, per-drop, per-delay, or pre/post-message callbacks. Therefore transport history is not part of the default simulator property interface except through the current in-flight queue visible via `Simulator::snapshot()` and aggregate `MessageSummary`.

### Incremental property cursors

Several properties intentionally avoid rechecking previously verified committed entries:

- `Durability` stores `verified: Vec<usize>` and checks `log.iter().enumerate().take(commit).skip(self.verified[id])` at `simulator/properties.rs:61-101`.
- `StateMatchesCommittedLog` stores `(verified, value)` and checks only `log.iter().enumerate().take(commit).skip(*verified)` at `simulator/properties.rs:155-201`.
- `CommittedPrefixAgreement` stores canonical entries plus per-replica `verified` and checks only `.skip(self.verified[id])` at `simulator/properties.rs:210-245`.
- `NoDuplicateOps` stores per-replica `(verified, seen)` and checks only `.skip(*verified)` at `simulator/properties.rs:253-286`.
- `RepliesMatchCommits` stores `committed` and `verified` cursors; it derives new expected replies only when `commit > self.committed`, then checks only `ctx.replies[self.verified..]` at `simulator/properties.rs:298-348`.

The comments explicitly state the design assumption: committed prefixes are never truncated, so each committed index needs checking once per replica (`simulator/properties.rs:51-59`).

### Simulator scheduling and reply path

The normal call chain is `Simulator::run` / `run_script` -> `step_run` -> `tick` -> `check_properties`:

- `Simulator::step_run` runs safety and liveness phases at `simulator/lib.rs:535-600`.
- `Simulator::tick` runs requests, crash/restart/reboot, heartbeat, network delivery, then checks properties at `simulator/lib.rs:711-719`.
- `tick_network` first flushes all current outboxes, delivers every due network envelope for the tick, flushes again, and only then returns to `tick` for property checks (`simulator/lib.rs:904-927`).
- `flush` persists the current view into the in-memory `durable_view`, sends replica/client messages through `Network::send`, but delivers replica `Reply`s directly to `Client::on_reply` and appends them to `replies` rather than passing replies through `Network::send` (`simulator/lib.rs:929-969`).

This confirms that properties observe a batched post-tick state, not every intermediate state in the tick. It also confirms that client replies are outside the simulated network fault path.

### Reboot and liveness assumptions

`Simulator::reboot_replica` creates `Replica::recover` from an in-memory `durable_view[id]` and a PRNG nonce (`simulator/lib.rs:694-708`). This is an idealized durability model, not a filesystem crash model.

`Simulator::transition_to_liveness_mode` disables network faults, clears partitions, chooses a core that includes a quorum of non-recovering replicas, and then only that core is required to converge (`simulator/lib.rs:723-781`). The liveness check therefore deliberately models a post-healing majority core, not arbitrary fault persistence.

`Options::validate` allows `replica_count >= 1` (`simulator/lib.rs:258-260`), while the retained Lean invariant branch explicitly has `TwoReplicas` at `lean/Vsr/Invariant.lean:168-170`: "the invariant is for clusters of at least two." This is a coverage/assumption boundary rather than an observed single-replica safety failure in the audited simulator run.

### Retained Lean evidence

The Lean files are not present in the pinned `HEAD` worktree, but local git metadata has an `origin/lean` branch. Reading that branch without switching showed:

- `lean/Vsr/System.lean:12-19` models `sent` as every message ever sent and `started` as ghost history.
- `lean/Vsr/Safety.lean:197-205` leaves the main safety theorem as `sorry`.
- `lean/Vsr/Liveness.lean:82-93` leaves the general liveness theorem as `sorry`.
- `lean/README.md:25-35`, `66-92`, and `166-192` document the proved/open split, the ghost histories, and that candidate checks holding on traces are evidence worth proving, not proof of truth.

### Reachability and trigger scenario

The cited observer limitations are reachable as code paths: every normal simulator run uses `tick`, `tick_network`, `flush`, and `check_properties`.

However, a concrete false-negative trigger for the current system would require a real protocol path that changes a previously checked committed prefix, corrupts a previously derived expected reply, or makes a history-dependent transport violation visible only between batched checks. I did not find such a public API sequence in the current library/simulator without either:

- mutating private simulator/replica state directly, or
- patching the library to introduce a new regression.

The closest concrete scenario is hypothetical mutation testing: if a future regression rewrote an already verified committed log entry without advancing `commit_number`, the incremental properties would not recheck that entry. That is not a current reachable bad state produced by the pinned source.

### Safeguards and boundaries

- `Replica` internals are private; public clients and replicas are stepped through `on_request`, `on_reply`, `on_idle`, `on_message`, and drain methods.
- The simulator's final `Convergence` property checks final core log equality, full commit, and state value at `simulator/properties.rs:365-408`, but it still does not give a full historical transport log to properties.
- The retained Lean branch is explicitly where broader message history (`sent`) and ghost started-view history are modeled, which reduces the claim that all retained evidence lacks history.

## Step 2: Developer Knowledge Search

### Comments and docs

- README verification docs say the simulator "checks a set of safety properties after every tick" and list committed-prefix agreement, durability, replies matching commits, and duplicate execution (`README.md:171-182`).
- README also documents a coverage script (`scripts/coverage`) that reports line coverage from random simulator seeds (`README.md:210-222`).
- `simulator/properties.rs:51-59` documents the intentional incremental optimization: committed prefixes are assumed append-only and each index is checked once per replica.
- `simulator/lib.rs:438-440` documents that `durable_view` is the one simulated persistent item.
- `simulator/lib.rs:723-728` documents that after safety, faults are disabled and a random majority core is kept up for liveness.
- `lean/README.md:184-192` says trace checks are evidence for candidate invariants, "not that they are true."

### Issues and PRs

I searched upstream issues and PRs with `gh`:

- `gh issue list --repo penberg/vsr-rs --state all --limit 100 --json ...` returned issues #1, #4, #5, #7, #8, #9.
- `gh pr list --repo penberg/vsr-rs --state all --limit 100 --json ...` returned PRs #2, #3, #6, #10.
- `gh search issues --repo penberg/vsr-rs "simulator properties observer replies committed prefix transport history liveness reboot" --state open --include-prs ...` returned `[]`.
- The same search with `--state closed --include-prs` returned `[]`.

Relevant non-duplicates:

- Issue #9 reports kvstore example issues: connection backoff/view changes, missing disconnect cleanup, and client identity reuse. It does not report simulator observer omissions.
- PR #10 is the kvstore connection-lifecycle fix and is not this mechanism.
- Issue #5 says the project adopted a deterministic simulator and that it checks safety properties every tick; it does not report the exact observer-history omission as a defect.

### Git history

`git log --all -- simulator/properties.rs simulator/lib.rs lib.rs README.md lean` shows the simulator introduced in `2686986`, README coverage docs in `a67f1f8`, the main branch head `3ac0104`, and multiple Lean branch commits. I found no commit message reporting or fixing the exact CR-6 observer-history mechanism.

## Step 3: Known Status

No public issue, PR, or local git-history entry found in this repository reports the same mechanism at the same site. Novelty evidence supports `NEW`, subject to the Phase 2 reproduction outcome.
