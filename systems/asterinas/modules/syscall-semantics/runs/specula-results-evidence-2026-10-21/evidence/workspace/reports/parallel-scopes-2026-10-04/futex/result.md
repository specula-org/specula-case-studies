# Private futex requeue/wake/timeout: lane result

Run `asterinas-private-futex-requeue-20261004T064345Z`, target
`asterinas-private-futex-requeue|asterinas/asterinas|Rust|Linux private futex requeue, wake, timeout and waiter ownership`.

Correction (2026-10-19): the MC-1 / AST-79 rating "NEW" below is wrong.
Open upstream issue #3964 (bdm-k, 2026-10-06, four days before confirmation)
reports the cross-bucket timeout cleanup miss in its main body. Its second
paragraph is AST-80. The MC-1 worker searched only with generic web search.
The nearest-prior-art note is also off: #1587 was closed by PR #1642, which
only skipped closed wakers. Dequeue-on-timeout came from PR #2377
(`888eecb35`). The native report is left unedited.

Current status, reconciled on 2026-10-12: final pipeline stages completed on
2026-10-10 after the user accepted validation limitations. AST-79..82 have
native REPRODUCED records and AST-83 is FALSE POSITIVE. This does not establish
concurrency protocol validation. Eighteen traces replayed, but cross-CPU clock
comparability, the registration/store-WAKE race and both wake/timeout outcomes
remain unvalidated. Core MC.cfg is time-limited. See the dated final section
below and the [deduplicated reproduction index](../../asterinas-bug-findings-2026-08/reproduced.md).

The following execution history retains earlier statuses and decisions. Its
resume commands are historical, not a request to start a run.

## Historical status through 2026-10-05

**Status at that checkpoint: BLOCKED_POLICY, incomplete.** Analysis, spec generation and harness
generation completed and passed their gates. Validation collected and replayed
all 18 implementation traces and was in bounded bug hunting when the Codex
provider returned a cybersecurity policy block (exit 76). The coordinator relayed
a rule to retry with `--fresh-context --policy-retries=3`, then fall back to Opus.
The Claude Code permission system denied that retry as a bypass of a provider
safeguard. An agent message is not the user's consent, and AGENTS.md forbids
circumventing provider safeguards, so no retry or model switch was made. The
validation review, confirmation and classification did not run. The user must
decide how to continue. Everything is preserved.

This is an informed scope, not a blind baseline.

## Phases

All stage commands are `stages.*` from `commands.json` exactly as written. Each
console log under `reports/runs/` has a `.receipt.json` with argv, times and exit.

| Stage invocation | Start to end (UTC) | Exit | Notes |
| --- | --- | --- | --- |
| analysis | 10-04 09:11:30 to 09:31:46 | 0 | Analysis and analysis review. |
| specgen | 10-04 09:32:59 to 10:42:56 | 0 | Waited for the heavy lock until 10:00:38. Review was NEEDS_IMPROVEMENT. |
| Spec fix round 1 (Codex, outside the run) | 10-04 22:48:48 to 10-05 00:27:00 | 0 | Lock wait from 10:44:11. Followed by an independent rerun, install, and a standalone native review. |
| Spec fix round 2 (Codex, outside the run) | 10-05 08:09:26 to 09:23:44 | 0 | Followed by an independent gated rerun, install, and a standalone native review (10:52:46 to 11:06:58). |
| harness-validation, attempt 1 | 10-05 11:08:04 to 12:28:57 | 1 | Harness generated and kernel built. Validation was blocked by the memory reserve, so prerequisites were not met. |
| harness-validation, attempt 2 (same argv without `--fresh-context`, resuming the unfinished validation conversation) | 10-05 12:31:09 to 16:37:14 | **76** | Policy block during Phase 3 bug hunting. |
| findings | not run | n/a | Depends on validation. |

No phase was repeated with changed inputs, routing, model, retry count or TLC
limits (4G / 2 workers throughout). The skipped phases are validation review,
bug confirmation and classification. The repair loop is disabled by
`--skip-repair-loop`, and no repair request exists.

## Gate records and review verdicts

- Analysis: [gate-1-analysis.md](reports/gate-1-analysis.md). Native review
  **PASS 35/35**, accepted after a source spot check.
- Spec generation: [gate-2-specgen.md](reports/gate-2-specgen.md). Native review
  **NEEDS_IMPROVEMENT 29/40**, then **NEEDS_IMPROVEMENT 32/40** after round 1, then
  **PASS 38/40** after round 2. The fixes, independent reruns, diffs and the
  original suite are in [spec-fix-2026-10-04/](reports/spec-fix-2026-10-04/).
- Harness and validation: no validation review exists because the phase did not
  finish. The validation agent's own status records the Category B concurrency
  quality requirement as unmet: maximum cross-thread event overlap was 0.382%,
  against the 20% requirement.
- Policy blocks: [policy-events.md](reports/policy-events.md) is not written,
  because the denied command included it. The event is recorded here instead.
  At 2026-10-05 16:37:07 UTC, in phase `spec_validation`, Codex gpt-6-astra max
  (`agent-config.json` sha256 `8058e175…bd3b`) returned "This content was
  flagged for possible cybersecurity risk ... apply for Daybreak access ...
  before retrying." Policy retries were 0, as configured.

## Identities

- Source: Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec…`,
  standalone copy, clean after every phase. The run's private copy holds
  instrumentation in `changes.patch` (59,724 bytes, 13 file diffs).
- Inputs: guidance `4fb22125…085de`, `commands.json` `b638663e…6d0`, config
  `8058e175…bd3b`, contracts `b444af0f…e0f`, resources `4093a89a…2313`. All match
  `SHA256SUMS` after every material phase. The protected
  `specula-asterinas-hybrid.json` (`29538770…`) and
  `asterinas-fd-epoll-guidance.md` (`50e5caf5…`) are unchanged.
- Authoritative checkouts are unchanged. `asterinas` is at `a5cb8f1` with its
  three pre-existing untracked entries. `asterinas-dev` is at `74d5631`, clean.
  Specula is at `aa93be6`, with its three recorded untracked files.
- Engine: Specula 1.2.0. All phases were routed to Codex gpt-6-astra max, and
  confirm was routed to pi GLM-5.3 (it did not run).
- Model: installed suite hashes are in `spec-fix-2026-10-04/installed-spec-round2.sha256`.
  base.tla is `09e15cca…ad49`, MC.tla `f00027b6…90c4`, and Trace.tla `5f39d7d6…d7`.
- Runtime: the guest had 2 CPUs, 512 futex buckets, and OVMF with earlycon.
  Instrumented kernel payload `39ae3549…f3cc`. The harness used ephemeral
  `sudo docker run --rm --cpus=2 ... --pids-limit 512` containers rather than the
  named `specula-futex-requeue-20261004`. No lane container exists to stop.
- Linux control: Linux 7.2.8 NixOS SMP PREEMPT_DYNAMIC x86-64, with waiters pinned
  to CPUs 0 and 1. It is separate from the v6.16.5 source reference.

## Trace and TLC evidence

Eighteen fresh-guest attempts produced 1,341 events, with zero buffer loss and
complete TLC replay witnesses for all 18 traces. They cover 53 of the 57
instrumented actions. The fault-retry actions and `WaiterSpuriousReturn` were
not exercised. Replay acceptance means the trace reaches `TraceIncomplete`
with only that sentinel violated and every per-stream cursor exhausted.
Ordering comes from per-stream order and recorded dependencies, not from NDJSON
line order. Evidence: `harness/coverage.md`, `spec/output/trace-results.json`.

TLC results for the reviewed suite (round 2, 2 GiB, 2 workers, 20-minute limit):
`MC_hunt_s1_mismatch`, `s1_registration`, `s2_unrelated_first`,
`s2_wake_zero_control`, `s2_zero_move_cross_bucket` and `s3_same_bucket` (57,330
distinct) complete with no violation. `MC.cfg`, `MC_hunt_completion` and
`MC_hunt_s3_opposite` are **time-limited and incomplete**. The validation agent's
own 30-minute MC.cfg BFS and simulation runs also reported no core-invariant
violation without exhausting the frontier. Expected candidate violations appear
in the seven configurations listed below.

## Candidates

No candidate went through native confirmation or classification. The runtime
observations come from the harness phase. None has a Linux runtime control for
the ownership path. Their dispositions are provisional.

| ID | Mechanism | Model | Asterinas runtime (SMP=2) | Linux | Provisional disposition |
| --- | --- | --- | --- | --- | --- |
| MC-1 (CR-1 is the same mechanism) | Cleanup after a cross-bucket requeue searches only the original bucket (`futex.rs:121-139`). A moved waiter that times out returns success, closes its waker and leaves its item in the destination bucket. A later REQUEUE counts the dead item against its migration quota, so a live waiter is not moved. | `MC_hunt_s3_owner` violates ResourceAccountingBalance (56 states). `MC_hunt_s4_live_migration` violates LiveMigrationExhaustion (93 states). The same-bucket control is clean. | F07, attempts 10/11: the cross-bucket timeout returns 0, the closed item stays, and a later WAKE accepts 0. F09, attempt 13: REQUEUE(1,1) B to A woke 4001 but moved dead 3001, so live 5001 stayed on B. WAKE A returned 0. | Source only (L2: cleanup follows `lock_ptr`). No runtime control. | **New. Implementation bug candidate, ambiguous until confirmed.** The Linux-visible effects are a lost requeue target for a live waiter and success instead of ETIMEDOUT. Each stranded item retains an `Arc<Waker>` and its task reference. Unbounded kernel-memory growth is plausible but not demonstrated, and no security impact is shown. |
| TV-1 | REQUEUE converts wake quota 0 to 1 (`syscall/futex.rs` `futex_val_to_max_count`). | `MC_hunt_s2_zero_wake` violates RequeueWakeQuota (20). `s2_quotas` violates RequeueQuotaAndResult (19). | Attempts 8/16: REQUEUE(0,0) wakes one and returns 1. | 7.2.8 control: REQUEUE(0,0) returns 0 and wakes none. | **New. Linux compatibility only.** Drafted by the validation agent as its MC-2. |
| TV-2 | Same-bucket `update_item_keys` processes a matching entry before checking a zero migration quota. | `MC_hunt_s2_zero_move_same_bucket` violates RequeueMoveQuota (22). The cross-bucket and unrelated-first controls are clean. | Attempt 5 moves one entry at quota 0 in the same bucket. Attempts 6/7 move none. | 7.2.8: REQUEUE(1,0) moves none. | **New. Linux compatibility only.** Bucket-collision dependent. |
| TV-3 | REQUEUE returns only `nwakes`, and the same-address shortcut returns the WAKE count. | `s2_return_count` and `s2_same_address` violate RequeueReturnCount (30 and 24). | Attempts 3/4: (1,1) returns 1. Attempt 9 (same address) returns 1. | 7.2.8: 2 and 2. The current man page documents only the wake count. | **New. Linux compatibility only.** |

Negative and bounded outcomes: locked compare/enqueue, mismatch, same-bucket
timeout cleanup and the unrelated-first control showed no violation in model or
runtime. Opposite-direction requeue (F10) completed at runtime with ascending
lock order, but its model search is incomplete. A wake/expiry race with both
winners (F08) was not captured. Historical futex issues (#981, #1587, #2306,
#2377, #2515 and others in the analysis report) are context only and were not
counted as findings. The catalog has no prior futex AST entries. Upstream dedup
for these four items is NOT_CHECKED, apart from the analysis agent's issue
search.

## Usage and cost

| Item | Reported cost | Tokens |
| --- | ---: | ---: |
| Analysis / analysis review | $29.80 / $3.79 | 19.5M / 1.7M |
| Spec generation / its review | $6.59 / $3.85 | 2.6M / 1.6M |
| Standalone spec reviews after rounds 1 and 2 | $4.88 / $8.22 | 2.6M / 5.6M |
| Harness generation | $12.22 | 7.3M |
| Validation attempt 1 / attempt 2 (blocked) | $13.50 / $40.91 | 10.5M / 30.2M |
| Codex spec-fix rounds 1 and 2 | unknown | 13.2M / 16.6M (input plus output) |
| Controller (this agent) | unknown | unknown |

The known total is $123.76. It excludes the two Codex fix rounds and the controller
session, whose costs are unknown, not zero.

## Retained artifacts

- Run root: `/home/chin39/Documents/play/Specula/runs/asterinas-private-futex-requeue-20261004T064345Z`.
  Under `.specula-output/`: modeling-brief, analysis-report, review-analysis,
  `spec/` (installed suite, three review versions, `review-checks-round2/`,
  `output/`, `bug-report.md` draft, `validation-status.json`), `harness/`
  (STATUS, coverage, logs, raw traces, built image), `traces/` (18 NDJSON).
  Instrumentation diff: `changes.patch`. Validation logs: `spec-validation*.log`.
- Lane records: `reports/gate-1-analysis.md`, `reports/gate-2-specgen.md`,
  `reports/spec-fix-2026-10-04/` (prompts, Codex activity and outputs, diffs,
  original suite tar, workspace tar, independent-verify logs, review copies).
- Checkpoints: `specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/checkpoints/`
  holds archives taken before specgen, before each spec install, before
  harness-validation, and before the validation resume. The resume archive
  excludes the cargo target tree, which is still in place in the run. A first
  attempt at the resume archive failed on container-owned cargo lock files.
  That partial tar, which this controller created, was replaced.
- Spec-fix workspace (git history of both rounds):
  `specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/spec-fix-ws`.

## How to continue (user decision)

The run is idle and the native validation conversation is preserved. Options:

1. Apply for or enable the provider access named in the block message, then
   resume the unfinished validation conversation with the stage argv minus
   `--fresh-context`. No change to routing or retries is needed.
2. Explicitly authorize, as the user, a retry with a changed retry count or a
   different model. That requires `--fresh-context` and an archive first, as in
   the handoff.
3. Accept the current evidence as an incomplete campaign. The four candidates
   then stay unconfirmed leads with the runtime observations above.

## 2026-10-09: validation rerun on claude-code Opus 5.5 (user-authorized)

**Status: VALIDATION_DONE_REVIEW_NEEDS_IMPROVEMENT, deferred.** The user directly authorized routing only the `validate` phase to claude-code `claude-opus-5-5` (effort max) after the Codex policy block. The validation review stayed on Codex. The coordinator ran this from its own session because the lane controller's relayed relaunch had been denied.

- **Preparation.**
  - Checkpoint `specula-profile-local-artifacts/parallel-scopes-2026-10-04/futex/checkpoints/before-validate-opus-fallback-20261009T063119Z.tar.gz` (sha256 `9ffc1d5e…`). Two container-owned cargo incremental `.lock` files could not be read and are missing from it.
  - Config `agent-config.claude-validate-fallback.json` (sha256 `d55f43e5…`) differs from `agent-config.json` only in the validate route. Its dry run (`reports/dry-run-opus-validate.log`, exit 0) confirmed the routing.
  - Specula skills were linked into `~/.claude/skills` per skill. `specula.skill_install` refused because the user's `weekly-session-report` skill has no frontmatter, and that skill was left untouched. See `reports/skills-install.log`.
- **Command.** `reports/run-validate-opus.sh`, which runs the stage argv with the fallback config plus `--fresh-context --skip-harness --policy-retries=3` under `heavy.lock`.
  - A first launch at 14:38 was killed while still queued by Claude Code's background-shell memory guard. That guard was misled by `vm.watermark_scale_factor=2000`, which has since been reset to 10 at runtime.
  - The relaunch took the lock at 15:39:53 and ended at 18:57:20 with exit 0. There was no policy block.
  - Log: `reports/runs/asterinas-private-futex-requeue-20261004T064345Z.validate-opus.attempt1.console.log`.
- **Cost.** Validation (Opus) $15.17 and validation review (Codex) $2.02, as reported in the run's usage files.
- **Validation review: NEEDS_IMPROVEMENT.** Syntax PASS. MC FAIL only because of the classified counterexamples. Trace replay is ready.
  - All 18 traces have complete replay witnesses.
  - Core `MC.cfg` BFS and simulation hit their 30-minute budgets without a violation. BFS reached depth 6 with 32.0M distinct states and 31.4M still queued. This is bounded exploration, not a pass.
  - Nine searches completed clean, seven found the classified counterexamples, and six were budget-limited.
  - Open items:
    - `validation-report.md` is missing.
    - Cross-thread overlap is 0.382%, against the 20% requirement.
    - Cross-CPU clock comparability is unproven.
    - The `FutexWaitFault`, `FutexWaitFaultUnlock`, `HandlePageFault` and `WaiterSpuriousReturn` probes have no runtime coverage.
    - The registration/store-WAKE race and both outcomes of the wake/timeout race are not captured.
- **Candidates (`spec/bug-report.md`, `spec/findings.json`).** These are the same four mechanisms as before. MC-1 is cross-bucket cleanup stranding (proposed AST-79). MC-2 is a zero wake quota becoming one (AST-80). MC-3 is a same-bucket zero move quota (AST-81). MC-4 is the REQUEUE return count (AST-82). The review agrees they are implementation defects. None is confirmed, because confirmation has not run.
- **Deferred by user decision (2026-10-09).** The futex findings stage (GLM confirmation and classification) and any fix for the review's items wait until the SCM_RIGHTS, flock and wait/reap lanes finish. Nothing for this lane is queued.

## 2026-10-10: findings stage (confirmation and classification)

**Status: COMPLETE with accepted validation limitations.** The user accepted the validation review's open items as disclosed limitations (`reports/user-decision-2026-10-10-accept-validation-limits.md`). No concurrency claim is drawn from this run's traces.

- **Attempt 1** (`reports/run-findings.sh`, `stages.findings` argv unchanged, checkpoint `before-findings-20261010T095019Z.tar.gz` sha256 `aa6d6ec0…`): 17:50–20:28, exit 1.
  - MC-2 and MC-3 were REPRODUCED.
  - MC-1 was INCOMPLETE because Specula's issue-proposal validator rejected its record, which linked model actions without model dependencies.
  - MC-4 and CR-1 were INCOMPLETE because the GLM provider stream stalled.
- **Attempt 2** (`reports/run-findings-resume.sh`, same argv without `--fresh-context`): 20:29–20:41, exit 1.
  - MC-1 was REPRODUCED.
  - MC-4 stalled again.
- **Attempt 3** (`reports/run-findings-resume3.sh`, the user's one further resume): 21:18–22:08, exit 0.
  - MC-4 was REPRODUCED and CR-1 was FALSE POSITIVE.
  - Classification ran ($1.40) and wrote `bug-severity.md`.

Final dispositions (`.specula-output/confirmed-bugs.md`: 4 reproduced = 3 NEW + 1 KNOWN-unfixed, 1 false positive, 0 incomplete):

| Finding | Mechanism | Disposition | Specula severity | Proposed ID |
|---|---|---|---|---|
| MC-1 | Cleanup after a cross-bucket requeue searches only the original bucket. A moved waiter that times out leaves a dead entry, which consumes a later migration quota and strands a live waiter. | REPRODUCED, NEW. The nearest prior art, #1587 and PR #1642, fixed the total absence of cleanup, which is a different mechanism. | Critical | AST-79 |
| MC-2 | REQUEUE converts a zero wake quota to one. | REPRODUCED, KNOWN-unfixed: upstream #3964 (open, filed 2026-10-06 and acknowledged by a maintainer). | High | AST-80 |
| MC-3 | A same-bucket REQUEUE with a zero migration quota still moves one waiter. | REPRODUCED, NEW | Critical | AST-81 |
| MC-4 | REQUEUE returns only the wake count, including on the same-address path. | REPRODUCED, NEW | High | AST-82 |
| CR-1 | Code-review candidate | FALSE POSITIVE | — | — |

Workspace assessment: all four are Linux-compatibility defects reachable through the public futex API.
- MC-1 and MC-3 can leave an untimed waiter blocked on the wrong futex, which is a local liveness failure within the caller's own threads.
- No privilege boundary is crossed, and no security impact is demonstrated.
- Specula's Critical ratings are broader than this assessment.

Cost: GLM confirmation reports $0.00, so its cost is unknown. Classification cost $1.40.
