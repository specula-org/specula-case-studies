# Unix DGRAM SCM_RIGHTS lane: final pipeline result with coverage limitations

Current status, reconciled on 2026-10-12: the final findings attempt exited 0
on 2026-10-10 and classification ran. AST-32 and AST-36 have native REPRODUCED
records for known mechanisms; AST-90/91 are FALSE POSITIVE. Critical-interleaving
coverage is incomplete. PEEK is outside default MC.cfg, five hunts are
time-limited, and whole-trace overlap is 3/936 and 7/899 event pairs. Those
are genuine overlaps, not concurrency state-space coverage percentages.
Pipeline completion does not establish complete protocol verification.
See the [local dedup and reproduction index](../../asterinas-bug-findings-2026-08/reproduced.md).

The dated history below preserves earlier pauses and incomplete attempts.
Its resume commands are historical, not a request to launch a run.

## Historical status through 2026-10-06

Run `asterinas-unix-dgram-scm-rights-20261004T064345Z`. Status on
2026-10-06 03:09 UTC: **PAUSED at the end of validation attempt 3**, at the
user's soft-pause request. Analysis and spec generation passed their review
gates. Harness and trace validation produced 23 accepted production traces.
Phase 2 model checking and hunting did not complete, so validation review,
confirmation and classification have not run. No new defect candidate was
found. The pipeline is blocked on a methodology conflict that needs a user
decision (section 6). No process for this lane is running, and the heavy lock
is released.

Stage gate records with full detail:
[gate 1](execution/gate-1-analysis.md), [gate 2](execution/gate-2-specgen.md),
[gate 3](execution/gate-3-harness-validation.md).

## 1. Identity

| Item | Value |
| --- | --- |
| Target | `asterinas-unix-dgram-scm-rights\|asterinas/asterinas\|Rust\|Linux Unix datagram SCM_RIGHTS ownership and receiver FD publication` |
| Run root | `/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z` |
| Source | standalone copy at `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`, clean, full history |
| Guidance | `guidance/06a-unix-dgram-scm-rights-publication.md`, sha256 `bf2982e6…ec53a59f919c` (unchanged) |
| Agent config | `agent-config.json`, sha256 `8058e175…c9bd3b` (unchanged). Codex `gpt-6-astra` effort `max` for every phase run so far. No routing change and no fallback was used. |
| Engine | Specula `aa93be678b95f6aa33c34d21ff6e6a8f82d84504` with its three recorded untracked files |
| TLC policy | 4G / 2 workers, unchanged on every stage |
| Commands | every stage launched from `commands.json` argv through `execution/launch_stage.py`; argv receipts sit beside each console log in `reports/runs/` |

After every material phase, all 48 prepared hashes, the source copy, Specula,
`asterinas-dev` (clean at `74d5631c`) and `/home/chin39/Documents/asterinas`
(at `a5cb8f12`, with its three pre-existing untracked paths `all.txt`,
`runlist.txt`, `research/`) matched the pre-launch baseline.
See `execution/identity-post-*.txt`.

## 2. Phases

| Stage | UTC | Exit | Result |
| --- | --- | --- | --- |
| Analysis + review | 10-04 09:12:14–09:31:00 | 0 | Review **PASS 35/35**. One coherent protocol: four scenarios, eleven properties, zero new candidates. AST-32 and AST-36 are attributed, AST-31 excluded. |
| Spec generation + review | 10-04 09:32:05–10:00:34 | 0 | Review **NEEDS_IMPROVEMENT 31/40**. Three P1 TLC evaluation and vacuity defects, one P3. |
| Spec fix rev. 1 (Codex, isolated workspace) | 10-04 10:42:56–22:48:48 | 0 | Findings 1–4 fixed by representation-only changes. Most original-bound MC configurations time-limited. |
| Spec fix rev. 2 | 10-05 01:06:09–05:23:03 | 0 | 39 companion configurations added, 25 complete. Every property has a complete witness. Model unchanged. |
| Independent verify + install + review rerun | 10-05 07:04:58 / 07:20:36–07:29:17 | 3 / 0 | First run false-failed on my SANY grep and did not install. Second run installed. Review **NEEDS_IMPROVEMENT 35/40**: two new P2 oracle findings. |
| Spec fix rev. 3 | 10-05 17:03:24–17:32:42 | 0 | PEEK after-snapshot from `queue'`. `TraceSearch.cfg` witness rule added. |
| Verify + install + review rerun 2 | 10-05 18:18:45–18:31:15 | 0 | 18/18 independent checks, including my own PEEK mutant. Review **PASS 40/40**. |
| Harness + validation attempt 1 | 10-05 19:01:56–20:11:27 | 1 | 23 traces. Validation Phase 0 blocked: TSC cross-CPU calibration failed in 4 fixtures, competition overlap was zero. |
| Harness + validation attempt 2 | 10-05 20:56:46–23:01:21 | 1 | HPET clock. Phase 0 passed, traces 23/23 passed. Phase 2 blocked: `MC.cfg` time-limited. |
| Harness + validation attempt 3 | 10-05 23:03:05–10-06 03:09:26 | 1 | Traces 23/23 passed. `MC.cfg` time-limited again. Both controller decisions declined by the native workers. |
| Validation review, confirmation, classification | — | NOT RUN | Validation never produced `bug-report.md`. |

The first revision-1 launch was killed by a user interrupt while still
waiting for the lock. Codex never started (`spec-fix-2026-10-04/attempt1-killed-while-queued.txt`).
No provider policy block (exit 76) or rate limit occurred in any stage. The
controller session itself stopped once overnight on a Claude HTTP 429 and
resumed on approval. Revision 2 kept running independently during that stop.

## 3. Model, traces and TLC

The reviewed suite is installed in the run's `.specula-output/spec/`
(`base.tla` sha256 `4fc5f1aa…3380c5`, `Trace.tla` `b837e1ee…20c492`,
`TraceSearch.cfg` `21213873…c9ab`). The revision history is in
`spec-fix-2026-10-04/` (original suite tar, three revision diffs, workspace
tars, Codex prompts and activity logs) and the workspace
`/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/spec-fix-workspace`
(commits `fc729ea` → `9573ffb` → `75538ce` → `d0f6170` → `bcb7c4b`).
The TLC metadata (`states/`, about 77 GB) is preserved there and not committed.

**Trace acceptance.** A trace is accepted if `Trace.cfg` passes
(`TraceMatched`, ten safety and terminal invariants, nonzero initial states),
or if it fails only on `TraceMatched` and `TraceSearch.cfg` finds a complete
witness on the same bytes. Any other failure rejects it.

**Bounded model checking** (each run 2 workers, ≤3 GiB heap):

- Complete with no violation: 25 revision-2 companions, all with two
  receivers and 16 free FD slots. Examples: `MC_hunt_scenario3_layouts_fault`
  (28,908 states), `MC_hunt_scenario2_rights3_peek1_recv2` (6,987,879),
  `MC_hunt_scenario1_separate_tables` (25,318,204, original bounds),
  `MC_cleanup_layout_later_fault` (liveness `BoundedCleanupProgress`, 40,062).
  Every brief property has at least one complete witness. The list is in
  `spec/generation-checks/README.md` § Revision 2.
- Time-limited, not passed: `MC.cfg` at original bounds (5,400 s at 25.2M
  states, and twice 30 min at about 12.5M states), the original-bound
  scenario 1 (shared table), 2, 3 and 4, original-bound `MC_cleanup`, and
  `base.cfg`. The `Full` layout with full operation budgets never completed.
  Several concurrency witnesses use `RightsCount = 3` (A, B, A).
- Expected compatibility counterexamples: `NoFailedNumberInstalled` (31
  states) and `ReportedPrefixMatchesLinux` (36) for AST-32, and
  `PayloadFaultConsumptionMatchesLinux` (18) for AST-36.

**Production traces.** The accepted batch is harness attempt
`20261005T220019Z`: 23 fixtures, 1,117 events, all 34 event types, a 2-CPU
2 GiB guest, and the HPET global clock with all 23 fixtures passing 128
cross-CPU exchanges. All 23 passed `Trace.cfg` in validation attempts 2 and
3. Competition case 17 (two ordinary receivers) has 2 strictly overlapping
receiver pairs, and case 18 (PEEK plus ordinary receive of the same message,
both successful) has 14 to 15. Both are far below the timebox guide's 20%
whole-trace figure. Instrumentation is in `changes.patch` (1,541 lines,
sha256 `705787c3…4679`).

**Runtime controls.** The same fixture programs ran on Asterinas (guest) and
on the running Linux kernel, reconciled against the pinned v6.16.5 source
(`harness/evidence/20261005T194207Z/linux-source/RECONCILIATION.md`). These
harness observations are recorded in
`harness/evidence/20261006T022240Z/reference-comparison.json`:

| Case | Layout | Asterinas | Linux |
| --- | --- | --- | --- |
| 10 | first FD integer faults | `msg_controllen` 0, CTRUNC, FD 5 → A installed | length 0, CTRUNC, no FD installed |
| 11, 12 | third integer faults (full, partial) | length 0, CTRUNC, 3 FDs (A, B, A) installed | length 24, CTRUNC, 2 FDs (A, B) |
| 13 | header unwritable | length 0, CTRUNC, no FD | length 0, flags 0, 4 FDs installed |
| 20 | payload fault, ordinary receive | EFAULT, message retained, the retry installs 4 FDs | EFAULT, message consumed, nothing on the retry |
| 21 | payload fault, PEEK | same as Linux | message retained |

Cases 10–12 are AST-32 and its prefix refinement. Case 20 is AST-36. Case 13
is the planned negative control (Linux-permitted). These are harness
observations with Linux controls. The confirmation phase, which owns
reproduction verdicts, has not run.

## 4. Findings and dispositions

| Candidate | Disposition | Evidence |
| --- | --- | --- |
| New MC candidates | None. Analysis found 0. Bounded MC found no protocol violation in any complete configuration. | `modeling-brief.md` §6; generation-checks README |
| AST-32 (installed FD for a failed number; zero length after a delivered prefix) | Known lead. Model counterexamples, plus runtime harness observation with a Linux control (cases 10–12). Not new. Confirmation NOT RUN. | above; `spec/generation-checks/MC_hunt_AST32_*.log` |
| AST-36 (ordinary payload fault retains the record) | Known lead. Model counterexample plus runtime observation (case 20). Not new. Confirmation NOT RUN. | `MC_hunt_AST36-r3.log`; case 20 |
| Linux header-fault behavior (case 13) | Linux-permitted behavior and control, not an Asterinas bug | contracts SCM-07 |
| Spec-review findings 1–6 | Model/specification bugs, fixed and re-reviewed (PASS 40/40) | gate 2 |

Security impact: AST-32 leaves an extra descriptor installed in the
receiving process for an object the sender already chose to transfer. No
privilege boundary is crossed and no object the receiver could not already
receive becomes reachable. It is a Linux-compatibility and FD-leak issue.
No security impact was demonstrated. AST-36 is a compatibility difference
in consumption semantics.

## 5. Usage and cost

Codex-reported costs: analysis $48.90 + review $5.44; spec generation $6.52
+ review $6.56; spec review reruns $6.24 and $3.47; harness/validation
attempt 1 $24.55 + $5.60, attempt 2 $15.53 + $23.06, attempt 3 $6.24 +
$10.42. The known total is **$162.53**. The three `codex exec` spec fixes
reported tokens but no cost: revision 1 204.8M input (203.9M cached) / 292K
output, revision 2 29.0M / 253K, revision 3 4.36M / 36K. Their cost is
**unknown**. The controller's own Claude usage is **unknown**. Heavy-lock
waits dominated wall time: about 9.5 h for revision 3 and several hours
before others.

## 6. Blocker and decision needed

The native validation workflow requires `MC.cfg` to complete before
convergence and hunting. The timebox guide asks for 20% overlapping
cross-thread pairs. Neither is attainable at this scope:

- `MC.cfg` at the brief's starting bounds does not finish in 90 minutes.
- For these fixtures, the validator proved overlap is bounded at about 2–3%.

I wrote two controller decisions into the run
(`harness/CONTROLLER-DECISION-2026-10-06.md`, sha256 `b7e76d3a…0e1a`, and
`spec/CONTROLLER-DECISION-2026-10-06-phase2.md`, sha256 `e453e4cb…d82dda7`),
each with a labelled pointer at the top of `harness/RESULTS.md` and
`spec/validation-report.md`. Unmodified copies are in `execution/`. Attempt 2
followed the clock and overlap decision. Attempt 3's workers declined both
decisions, citing the phase prompt's rule not to relax any skill step.
Rerunning unchanged will repeat attempt 3.

Options for the user:

1. **Authorize the scope adaptations through an input the workers honor.**
   For example, a guidance addendum stating the overlap criterion and the
   companion-set convergence rule. This changes the input identity. Under
   AGENTS.md that means a new run ID, which can reuse this run's reviewed
   suite and traces as evidence with a reuse receipt.
2. **Revise the suite so `MC.cfg` itself completes.** Rename the original as
   an explicit time-limited configuration, take a completing companion as
   `MC.cfg`, and redesign the competition fixtures toward 20%. This keeps the
   unmodified workflow but needs another spec review, and it moves `MC.cfg`
   off the brief's starting bounds.
3. **Close the lane at this point.** Keep the result as is: reviewed model,
   23 validated traces, bounded MC, and known-lead runtime observations,
   with confirmation and classification not run.

## 7. Resume

To resume after a decision, check that no writer is live and that the lock
is free. Then archive and run the next stage exactly as in `commands.json`.
For an unchanged rerun of the incomplete stage, that is:

```sh
L=/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04
R=/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z
tar -czf "$L/scm-rights/checkpoints/before-harness-attempt4-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" \
  -C "$R" .specula-resume 'asterinas-unix-dgram-scm-rights/.specula-output'
python3 /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/scm-rights/execution/launch_stage.py \
  harness-validation harness-validate.attempt4
```

`launch_stage.py` executes `stages.harness-validation.argv` verbatim
(`flock --exclusive …/heavy.lock …/specula run … --fresh-context --skip-analysis
--skip-specgen --skip-confirmation --skip-classification --skip-repair-loop
--run-id=asterinas-unix-dgram-scm-rights-20261004T064345Z <target>`) from cwd
`/home/chin39/Documents/play/Specula`, with the PATH prefix, `PI_DEADLINE=3600`,
`CARGO_BUILD_JOBS=2` and `VNC_PORT=48`. Check 10 GiB MemAvailable before
launch. After validation produces `bug-report.md` and its review passes, the
next stage is `stages.findings` (archive first). Without one of the decisions
in section 6, the rerun will stop at Phase 2 again.

## 8. Retained artifacts

- Run: `/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z` (outputs, `changes.patch`, harness evidence, traces, validation outputs).
- Console logs and argv/exit receipts: `reports/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z.{analysis,specgen,harness-validate,harness-validate.attempt2,harness-validate.attempt3}.*`.
- Checkpoints: `/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/checkpoints/` (before specgen, spec installs, each harness attempt).
- Spec fixes and independent verification: `spec-fix-2026-10-04/`.
- Gate records, identity checks, launcher: `execution/`.
- Container: the lane container `specula-scm-rights-20261004` was never created. The harness used short-lived `scm-trace-<run_id>` containers with the lane limits and removed them itself.

## 9. Update 2026-10-09: user decision and revision 4

The user chose option 2 from section 6: revise the suite so that `MC.cfg`
completes, keep the brief-bound configuration as an explicitly time-limited
`MC_brief_bounds.cfg`, and redesign the competition fixtures toward 20%
overlap. That decision **supersedes both of my earlier controller decisions**,
on cross-CPU clock and overlap (`harness/CONTROLLER-DECISION-2026-10-06.md`)
and on companion-set convergence
(`spec/CONTROLLER-DECISION-2026-10-06-phase2.md`). Both files in the run now
begin with a SUPERSEDED notice and are kept as records. The memory gate also
changed, to MemFree + Inactive(file) via `effective-mem-gib.sh`, with the
same 10 GiB and 6 GiB thresholds.

Revision 4 attempt 1 (Codex `gpt-6-astra` max, under the heavy lock,
06:38:21–07:18:46 UTC) was **stopped by Claude Code because of host memory
pressure**. The kill took the controller's background shell, and with it
`flock` and Codex. Partial, unverified workspace changes are preserved in
`spec-fix-2026-10-04/revision4/partial-killed.diff`. Nothing was installed
into the run. The run is unchanged since attempt 3. The full record is in
[gate 4](execution/gate-4-revision4.md).

Claude Code's memory-pressure guard stopped every background shell of the
controller session at about 07:18 UTC (15:18 local). The guard most likely
reads MemAvailable, which this host understates because of
`vm.watermark_scale_factor=2000`. MemFree + Inactive(file) was about 39 GiB.
The workspace was left exactly as the kill left it: uncommitted partial
changes on top of `593a85c` (new `MC.cfg`, `MC_brief_bounds.cfg`, seven
`MC_hunt_*` companions moved to `MC_timelimited_*`, edits to `Trace.tla`,
`harness/src/scm_rights_trace.c` and `harness/src/normalize.py`, records,
`r4-*` logs, and `states-r4/`). Nothing will restart until the user relaunches
Claude Code with `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` or decides
otherwise.

Resume command, run from a background shell that blocks until it finishes.
Codex continues on the partial working tree. The prompt asks it to rerun every
check, so leftover partial results are revalidated:

```sh
W=/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/scm-rights/spec-fix-workspace
R4=/home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/scm-rights/spec-fix-2026-10-04/revision4
flock --exclusive /home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/heavy.lock \
  codex exec -m gpt-6-astra -c model_reasoning_effort=max --sandbox workspace-write -C "$W" --json \
  -o "$R4/attempt2-codex-last-message.md" - < "$R4/codex-prompt-revision4.md" \
  > "$R4/attempt2-codex-activity.jsonl" 2> "$R4/attempt2-codex-stderr.log"
```

To restart from a clean baseline instead, the partial diff is already saved.
Running `git -C "$W" stash push -u -m r4-attempt1-partial` before the
command above restores `593a85c`.

After revision 4, the sequence is: independent spec check, install, and a
standalone native spec review. Then an independent fixture review and
install. Then `stages.harness-validation` with a checkpoint first (section
7). After the validation review passes, `stages.findings`.

## 10. Update 2026-10-09: revision 4 completed, spec gate blocked

Revision 4 attempt 2 and one correction ran under the lock. Details are in
[gate 4](execution/gate-4-revision4.md).

- `MC.cfg` now completes: RightsCount 4, all 14 layouts, all three fault
  limits, two receivers, RecvLimit 2, ReuseLimit 1, **PeekLimit 0**.
  3,596,537 states, 635–669 s.
- `MC_brief_bounds.cfg` keeps the brief bounds as an explicitly time-limited
  configuration.
- Seven incomplete revision-2 companions were renamed to `MC_timelimited_*`.
- The competition fixtures were redesigned: one right in case 18, pinned
  CPUs, and `SCM_WINDOW` markers.
- Codex's attempt to move sender events into trace metadata, which would
  shrink the overlap denominator, was rejected in my review and reverted.
- The whole-trace overlap bound is still below 20%: 3.205% for case 17 and
  3.560% for case 18 (up from 2.097%). The serialized sender setup, send and
  cleanup that every message needs keep the fraction low.
- No PEEK-including convergence configuration finishes within the
  workflow's 30-minute budget at the run's fixed 4G / 2-worker TLC limit.

Independent checks passed. The suite and fixture change are installed
(identity: `revision4/independent-verify/installed-*.sha256`). The fourth
native spec review gives **NEEDS_IMPROVEMENT 38/40**, with one P2: the
default `MC.cfg` excludes PEEK from convergence. The Codex attempt budget for
this slice is used up, and harness validation has not started.

Options for the user:

1. **Accept the P2 as a disclosed limitation** and proceed to harness
   validation. Convergence would then be described as ordinary-receive
   coverage. PEEK safety would be covered by the completed PEEK companions
   and hunting.
2. **Authorize a model-level search-cost reduction**, for example coarser
   atomic steps where the source holds a lock throughout, or object symmetry.
   That is another spec revision, review and verification cycle.
3. **Use a smaller PEEK-inclusive `MC.cfg`**, for example RightsCount 3 with
   a reduced layout set. This conflicts with the review's four-right request
   and needs measurement first.
4. **Stop the lane** at its current evidence.

Resume after option 1, checkpoint first:

```sh
L=/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04
R=/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z
tar -czf "$L/scm-rights/checkpoints/before-harness-attempt4-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" \
  -C "$R" .specula-resume 'asterinas-unix-dgram-scm-rights/.specula-output'
python3 /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/scm-rights/execution/launch_stage.py \
  harness-validation harness-validate.attempt4
```

Known Codex-reported cost is now $169.47 ($162.53 plus the $6.94 review).
The cost of the `codex exec` revisions is unknown. Revision 4 attempt 2 used
13.25M/101K tokens and the correction 15.11M/106K. Attempt 1 has no
completion record.

## 11. Update 2026-10-10: user accepted the P2

The user chose option 1. The decision is recorded in
[execution/user-decision-2026-10-10-accept-p2.md](execution/user-decision-2026-10-10-accept-p2.md).

- The default `MC.cfg` convergence check covers ordinary receive with four
  rights.
- PEEK is covered only by the completed PEEK companions and by hunting.
- No PEEK-inclusive configuration completed within 30 minutes at 4G / 2
  workers.

Harness validation attempt 4 followed. Its result is recorded below.

Harness validation attempt 4 (01:38:41–03:12:19 UTC) ended with **exit 76**,
a Codex provider security-policy block, during bug hunting. Details are in
[gate 5](execution/gate-5-harness-attempt4-policy-block.md).

- Fresh traces were built with the redesigned fixtures, and 46/46 traces
  passed.
- `MC.cfg` completed at its ordinary-receive bounds.
- The workflow converged at the supplied bounds. This is not full-protocol
  convergence.
- Hunting stopped at 4 of 20 configurations, with only the known
  AST-32/AST-36 compatibility violations and no new candidate.
- Measured whole-trace overlap was 0.321% and 0.779%, against bounds of
  3.205% and 3.560%. The serialized sender setup, send and cleanup explain
  the gap. No pass is claimed.

I did not retry or switch models. The user decides. If the user authorizes
resuming the interrupted native conversation as it is (same model, same
stored retry count 0), the command is:

```sh
python3 /home/chin39/Documents/play/specula-profile/reports/parallel-scopes-2026-10-04/scm-rights/execution/launch_stage.py \
  harness-validation harness-validate.attempt5 --drop-fresh-context
```

Known Codex-reported cost is now $201.24.

The user chose to resume the interrupted Codex conversation unchanged: same
model, retry count 0, no `--fresh-context`. The decision is recorded in
[execution/user-decision-2026-10-10-resume-codex.md](execution/user-decision-2026-10-10-resume-codex.md).
The resumed stage is `harness-validate.attempt5`.

Validation attempt 5 (03:38:35–04:57:18 UTC) exited 0. The results:

- 46/46 traces passed.
- Default `MC.cfg` completed exhaustively.
- All 20 hunts were recorded: 12 complete, 5 time-limited, 3 expected
  AST-32/AST-36 counterexamples.
- `findings.json` holds MC-1 (AST-32) and MC-2 (AST-36), and no new candidate.

The validation review is NEEDS_IMPROVEMENT, solely because of the two
user-accepted limitations: PEEK is outside `MC.cfg`, and whole-trace overlap
bounds are 3.205% and 3.560%. I accepted the gate with both limitations
stated, as recorded in [gate 6](execution/gate-6-validation-attempt5.md),
and continued to findings.

## 12. Final state (2026-10-10 09:08 UTC)

The findings stage ran three times. All three exited 1, with no rate limit
or policy block. Details are in [gate 7](execution/gate-7-findings.md).

| Finding | AST | Final disposition |
| --- | --- | --- |
| MC-1, failed-number FD installed | AST-32 | Specula INCOMPLETE. Its issue-proposal validator rejected the record twice, after GLM stalls on the earlier attempts. The confirming agent's own verdict is REPRODUCED (Level 0), against a Linux 7.2.8 control. Known lead, not new. |
| MC-2, ordinary payload fault retains datagram | AST-36 | REPRODUCED, known and unfixed. Linux control included. Not new. |
| CR-1, ownership across reuse and release | none | FALSE POSITIVE |
| CR-2, PEEK/ordinary selection and publication order | none | FALSE POSITIVE (2-CPU guest, 173 overlapping deliveries, 0 failures) |

- No new defect.
- Classification and severity did not run.
- No security impact was demonstrated. AST-32 leaves a stray descriptor in
  the receiver's own table. AST-36 is a consumption-semantics compatibility
  difference.
- Every protocol result carries the two accepted limitations: PEEK is outside
  `MC.cfg`, and the 20% overlap criterion is unmet (bounds 3.205% and
  3.560%).
- Identity after the stage: inputs, source copy and Specula unchanged
  (`execution/identity-post-findings.txt`). `changes.patch` sha256 is
  `65cc9618…c8c3`.
- No process is live, and no lane container exists.

Codex-reported cost through validation attempt 5 is $234.41 if the resumed validation session's $55.68 is cumulative (it includes attempt 4's $24.43), or $258.84 if it is not. This could not be determined from the usage files. The
GLM confirmation turns reported $0.00 (35.1M tokens), which I treat as
unknown cost, not zero. Classification did not run. The cost of the
`codex exec` spec revisions and of the controller session is unknown.

The user authorized one more unchanged findings run (attempt 4), recorded in [execution/user-decision-2026-10-10-findings-rerun.md](execution/user-decision-2026-10-10-findings-rerun.md).

## 13. Final state after findings attempt 4 (2026-10-10 09:44 UTC)

Findings attempt 4 exited **0**. MC-1 (AST-32) is now **REPRODUCED**, known
and unfixed, and its record was accepted. Classification ran. The final
dispositions are: MC-1/AST-32 REPRODUCED, MC-2/AST-36 REPRODUCED, CR-1 and
CR-2 FALSE POSITIVE. Neither reproduction is new. Specula rated AST-32
Critical and AST-36 High. My assessment is a Linux-compatibility bug plus a
self-inflicted FD leak for AST-32, and a compatibility difference for
AST-36, with no demonstrated security impact. See
[gate 7](execution/gate-7-findings.md).

The final pipeline stages completed with the two user-accepted limitations: PEEK
is outside the default `MC.cfg`, and whole-trace overlap is below 20%
(bounds 3.205% and 3.560%). Identity is unchanged
(`execution/identity-final.txt`). No process is live.

The process observation above belongs to the 2026-10-10 checkpoint. The
2026-10-12 documentation audit did not rerun any phase or runtime check.
