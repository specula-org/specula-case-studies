# Takeover review — nvflare-job BYOM Phase 2

Current continuation status: Phase 3 validation is complete; see section 9 for
its evidence and the launcher-owned confirmation handoff. Sections 1–8 preserve
the adoption and harness audits as written at those phase boundaries.

Phase 2 adoption/specification is complete as a handoff to the harness phase. The supplied suite is accepted as reusable working material, **not as a fully faithful or verified model**. Its semantic limitations and required repairs are recorded below. Historical confirmations, trace PASS records and stage-completion labels do not complete any continuation stage.

Source pin: 53ba7ee567468ea7971dad4faccef13c6cb35dc2.
Working source: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/source.
Original assets: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/handoff/full/run/nvflare-job/.specula-output.
Working output: /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output.

## 1. Phase ownership and provenance

The launcher prompt assigns BYOM Phase 2. The pinned [BYOM guide](/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/skills/byom/guide.md) says: “During the initial inventory and Scenario analysis, do not make semantic changes to supplied artifacts” and “Stop after satisfying the current phase's output contract. The pipeline launches each later phase separately.”

Accordingly, this invocation audited actions, assumptions, properties, exclusions and harness semantics, completed the brief/coverage/review, and verified artifact usability. It did not execute the later harness, validation, confirmation or classification phase. No approval is needed for those already-authorized later phases; the launcher owns their sequencing and model selection.

The original Claude full run ended with an API credit-balance error during hunting, before separate Phase 4 confirmation. Some deep-analysis children were interrupted before all their leads reached the main report. This is an authorized **mixed-model continuation**, not an independent pure-model trial. Prescribed continuation: GPT-6 Astra at max for reasoning/verification/repair/classification; GPT-5.5 at xhigh for separate confirmation through the configured launcher, without substitution.

Original Claude spend including preflight: **$180.5573146**. New Codex subscription usage is separate; any API-equivalent Codex estimate is not a new Claude-account charge. This review has no measured new-dollar total and does not invent one. Launcher accounting files and final summary own fresh usage reporting.

Only pinned source/docs, supplied artifacts/conversations and pinned framework skills were used for this audit. No newer commits, issue/PR discussions, Lite results, other case studies, user memory or external answers were consulted. Historical commit messages/file lists were treated as context, not verified patch diffs.

## 2. Inventory and preservation

[adoption/inventory.json](adoption/inventory.json) records original→working paths and SHA-256 values. Initial inventory verified 4301 original assets against the supplied manifest and all 20 raw conversation hashes against conversations/index.json. Adopted 4238 files:

| Working group | Files | Disposition |
|---|---:|---|
| spec | 128 | Base/MC/Trace, 27 cfgs, instrumentation map, history, logs and counterexamples preserved. Only current brief-coverage.md is rewritten as an adoption audit; original copy retained. |
| harness | 3911 | Instrumentation patch, six Python sources, six shell scripts, historical build/reports/validation artifacts preserved. Historical build is not a fresh runtime. |
| evidence | 164 | Analysis probes, scripts, stdout, controls, notes and deep reports preserved without rewriting their historical claims. |
| analysis-report.md | 1 | Historical analysis unchanged; status/coverage claims qualified by this review and reconciliation. |
| adoption supplied copies | 34 | Original brief/coverage/summary/index plus 30 official historical traces, quarantined from active traces/. |

No root traces directory has been populated with old evidence. Launcher-owned summary/accounting state was not copied over with old completion state. Existing summary remains incomplete pending later phases. Original supplied assets were not modified; no product implementation was edited. Source status is only the pre-existing launcher-installed untracked .agents/ directory.

New Phase 2 deliverables:

- [modeling-brief.md](modeling-brief.md): supplied scope plus focused Scenario supplement.
- [spec/brief-coverage.md](spec/brief-coverage.md): actual cfg wiring, bounds, seeds and explicit gaps.
- [adoption/model-audit.md](adoption/model-audit.md): every base.Next action family, atomicity, invariants, residuals and V01–V10 repair obligations.
- [adoption/harness-audit.md](adoption/harness-audit.md): tracing/stub/projection audit and concrete fresh-run requirements.
- [adoption/findings-reconciliation.md](adoption/findings-reconciliation.md): F1–F20, R1, all deep/lower leads, refutations, MC-A–E and recovered MC-U1, with routes to confirmation.
- Static checks, diagnostic evidence, preservation checks and conversation navigation under adoption/.

## 3. Conversation records inspected

Started with handoff/conversations/README.md and index.json. All four main records were reviewed in phase order using manageable chunks and line-preserving navigation. All visible assistant decision prose was inspected; relevant commands/tool results and child communications were followed to the actual retained scripts, logs and pinned source. Repeated full-file/tool dumps were navigated selectively, not represented as a fresh execution or exhaustive byte-by-byte reread.

The generated adoption/conversation-navigation/*.decisions.txt files retain original line ranges and verbatim visible prose; *.index.txt maps tool calls/results; child *.communications.txt preserves handoffs. They supplement the original records, not replace them.

| Main record | Material inspected and used |
|---|---|
| 01-analysis.md (raw 4fbca144-2f19-45a2-89bf-31e009d9fb70.jsonl) | Scope/contract choices, failed blob reads, archaeology batches, source seeds, reproduction commands, report/brief construction, deep-child interruption and omitted leads. Opening instructions and final handoffs checked against original transcript. |
| 02-specification.md (raw 2d86c9d5-5ea2-4717-8bfe-f96ceeac02ea.jsonl) | Model construction, atomicity decisions, seed failures/refinements, residual/view/fairness choices, synthetic replay and early smoke counterexamples. Original lines 13065–13108 include synthetic negative controls and smoke context. |
| 03-harness.md (raw c385e188-6185-4a1e-82bd-f242ccea3ba4.jsonl) | Patch, stubs, timing gates, trace schema, scenario/validation failures and test claims. Original lines 16734–16825 cover wrong hook argument failures and correction; patch/build/source were independently compared. |
| 04-validation-and-hunting.md (raw 4acdeb06-535c-4c2e-a8e0-d13ddd4481db.jsonl) | Trace repairs (message bag, duplicate abort counts, heartbeat busy, waiter stale reference), convergence bounds, F16 correction, MC-A–E, added residuals, unfinished resource hunt, last unclassified outcome trace and credit interruption. Original lines 13880–14038 checked, including MC-U1 at 14024–14034. |

All 16 analysis-child readable records were inspected through their decision prose and relevant command/evidence chunks:

| Child ID(s), file prefix analysis-agent- | Role and audit result |
|---|---|
| af8950cf0b5506204 | Archaeology batch 1; source-derived seed provenance, blob availability limitations. |
| a267668ab856685f8 | Batch 2; resource arithmetic, process outcome/control-file and cleanup leads. |
| a081cbdbdaad23944 | Batch 3; status/RMW, scan, typed rc, lock/cleanup leads. |
| a4a3a8c3b97587a0d | Batch 4; PID, binding, disable, restart and workspace leads. |
| aa0363a54ac635e53 | Batch 5; scheduler/resource/lifecycle contracts and portable resource cases. |
| ae456212eab6bd35a | Contracts; T/X/U distinctions, default differences and narrowed T5 claim. |
| aa05006549b97b289 | Runner/status deep analysis, RS-1–11, N/K probes and controls, benign/refuted claims. Original 8200–8290 and 8860–8950 command/results checked in addition to report/scripts and extracted decisions. |
| a9b2b77d6bf662997 | Client lifetime, path matrix, CL-1–6. Original 9815–9871 covers real CellNet CP-kill retry evidence, explicitly short of a full worker run. |
| ab99a5ff5dbe12529 | Server/client-manager deep analysis, SE-1 A/B/C, disable/remove and unmerged SE-3 token replacement. Original 7375–7437 checked with repro/outputs; auth-stub errors limit evidence. |
| ac097fcff7aa25dcb | Process mains/MPM/rc-file E1–E7. Original 9771–9802 exposes the E6 invalid initial control and repair; 10110–10129 captures late E7 result/interruption. |
| a322965fd524a4311; a5d7891d190bf58fb; a8de6eaea0daa745a; aa8059accef7272f3; abd485055f7e06c13; a14de96014509afe9 | Aborted predecessor/setup investigations, including missing historical blobs. Inspected for discarded leads and reasoning; they provide no additional completed finding that can be accepted as a reproduction. |

The exact raw paths, sizes and hashes remain in handoff/conversations/index.json. Navigation filenames preserve full child IDs, avoiding ambiguous short labels.

## 4. Evidence accepted, with limits

Accepted as **historical evidence**: actual model counterexample logs, command/results, original scripts and controls, repair snapshots and 30 official traces. A historical local probe establishes only what its actual product/stub boundary permits. No copied “CONFIRMED” word or severity is adopted as a completed continuation verdict.

Accepted as **fresh source/static evidence**:

- HEAD matches the pin; adjacent callers, exception handlers, defaults/docs and component APIs were checked alongside all action families and properties. Source citations use pristine pin lines, not shifted instrumentation lines.
- SANY accepts base.tla, MC.tla and Trace.tla using pinned framework jars: [syntax-checks.json](adoption/syntax-checks.json).
- Unmodified VAV reports one all-variable warning at grouped CpNext existentials: [vav-check.json](adoption/vav-check.json). A separate diagnostic copy distributes equivalent existential disjunctions and gives zero issues: [vav-diagnostic-result.json](adoption/vav-diagnostic-result.json). This diagnoses a checker parsing/control-flow limitation; it is not behavioral validation and does not alter adopted base.tla.
- The full patch applies to pristine copies of all 11 target files; patched bytes match historical build. Eleven patched files and six harness files parse; six shell scripts pass bash -n. All 27 actual cfgs were inventoried: [static-checks.json](adoption/static-checks.json). Reproducible read-only check: python3 adoption/check_assets.py.

Not fresh evidence: old runtime tests, official/stress/random trace PASS results, TLC bounded runs, real-process probes or full confirmation. None was rerun under the continuation runtime during adoption. No claim of unbounded correctness or full trace conformance is made.

## 5. Material discrepancies and corrections

1. The old coverage claim “split at every check-then-act and blocking boundary” is false. Startup registration, pending initialization, client fanout, failure handling, finalizer reads/latch, report/free, heartbeat and waiter state contain source-visible intermediate states. V01–V10 specify them.
2. The old residual claim “exactly the seed mechanism” is false. Residuals exempt whole writer families/jobs and, for orphan slots, all jobs after service-thread death. Strict seed properties remain valuable; old residual success is conditional.
3. Original F16 seed initially reproduced F1. Later dedicated NoRefreshWriteOverwrite is the relevant evidence; future regression must witness the refresh mechanism.
4. Trace locks/stubs alter timing and omit default resource/process behavior. Synthetic negative controls prove some comparisons are nontrivial, not independent implementation conformance. Active fields partly derive from tracer events; full audit is separate.
5. Existing ClientCrash assumes children/descendants die immediately and cleanup liveness exempts dead CP. CL-4/F11 contradict accepting that assumption as a guarantee. Default GPU memory/binding is also outside list-unit invariants.
6. Earlier F14 default-GPU exclusivity allegation used a list-manager example. F6 immediate cancellation, F15 uniform start policy, F17 guaranteed status delivery and raw -9 classification each need narrower source contracts. F9/F19 remain unsupported/defensive.
7. Prior broad benign claims about fail_run/CMP and shared UPDATE dictionary identity do not settle all unprotected windows. Conversely, T5's inactive fail_run insertion claim is not supported by its active-only else branch.
8. F18 ordinary local restart is not automatically out of scope merely because HA is excluded. Retain it, CL-6 and related session/control-file effects as out-of-model questions.
9. RS-3/5/7/11, CL variants, SE-1 A/C, SE-3, E6/E7, marker/workspace/exception leads and all archaeology/contract aliases are now reconciled. No lower finding was dropped because it lacked a main F number.
10. The last historical outcome counterexample, MC-U1, was not classified before credit exhaustion. Its accepted-pending versus authoritative-recorded distinction and early clean SJ exit assumption require V03/V04 plus confirmation. It is neither an accepted bug nor an unexplained PASS.

## 6. Concrete remaining work through the launcher

**Harness phase (next):**

- Read harness-audit.md; adapt copied scripts to current source/runtime/output, rebuild from the pin and preserve the original assets.
- Correct result propagation, identify timing/fault controls and derived observations, and address trace-lock/stub limitations where required for the scenario evidence.
- Rerun all 30 default scenarios, collecting fresh NDJSON, commands, exit codes, hashes and controls under active traces/. The user's rerun instruction overrides BYOM's usual reuse default. Old traces must not stand in for new evidence.
- Verify full input schema/cursor coverage and corrupt selected fresh traces to ensure checks reject wrong state/order and missing/filtered records.

**Validation/repair and hunting:**

- Replay fresh traces, diagnose Case A property mismatch / Case B model-harness mismatch / Case C candidate using pinned source, then repair behavior/Trace/harness consistently in their normal phases.
- Complete V01–V10 audit obligations, recheck all named seeds (including dedicated F16), strict properties, fairness, views/symmetry, normal-operation bounds and all residuals.
- Exercise uncovered SJ-launch failure/backoff, strict/required-site policy and post-poison context where justified; document out-of-model checks rather than silently claiming coverage.
- Classify MC-U1 and finish convergence and hunting after repairs. Ordinary bounded/time-limited searches may end honestly with explored-state/queue/fault bounds; no overall wall-clock deadline applies. An interrupted or bounded run is not an exhaustive theorem.

**Confirmation, repair/evolve loop and final reporting:**

- Pass every eligible C candidate in findings-reconciliation.md, including source-only/omitted lower leads, to configured GPT-5.5 xhigh confirmation. One concurrent per-finding task; no model substitution.
- Use public APIs and real local deployment where feasible, retain passing controls and precise injection/stub limits, and separate implementation reproductions from model traces, unsupported cases and environment limits. Feed mismatches back through the normal repair/evolve loop.
- Astra max performs subsequent verification/repair/classification. Report the original interruption, mixed-model provenance, fresh checks, remaining limits and separate usage accounting. Only the launcher-assigned final reporting phase writes byom-modification-report.md after confirmation/repair/classification.
- Preserve aggregate TLC limits of 64 GiB and 16 workers, service memory 80 GiB. Use the Specula budgeted TLC wrapper. Product fixes, upstream publication, pushes and tracker writes remain unauthorized.

## 7. Deliverable status

The ordinary Phase 2 contract is present: modeling-brief.md; spec/base.tla and base.cfg; spec/MC.tla, MC.cfg and 16 hunt cfgs; spec/Trace.tla and Trace.cfg; spec/instrumentation-spec.md; mandatory spec/brief-coverage.md; this takeover-review.md. Additional seven seed cfgs, historical artifacts and audits preserve continuity. The next step is the launcher-owned harness phase, with fresh trace generation required.

## 8. Phase 2.5 continuation handoff (2026-09-26)

The assigned harness phase is now complete; the preceding Phase 2 audit remains intact as its historical baseline. See [the Phase 2.5 report](harness/phase2_5-report.md), [updated instrumentation guide](harness/INSTRUMENTATION.md), and [fresh evidence audit](harness/evidence/continuation/final-audit.json). All 30 supplied default scenarios were rerun against a fresh isolated build of the pin, plus two actual-deadline scenarios. The 32 traces contain 2,244 events covering 64/65 action names and passed basic replay against the unchanged adopted spec. Strict input/report checks, fresh negative controls, resource-call projection checks and three configurations of 392 targeted unit tests are recorded. Original supplied assets/conversations and all adopted spec files remain unchanged.

This completes the harness bullets in section 6, with scheduling/stub coverage gaps explicitly retained rather than repaired in the model during this phase. The next phase is launcher-owned validation/repair/convergence/hunting, not a new adoption pass. V01–V10, strict seed fidelity, MC-A–E/MC-U1 reconciliation, residual exclusions and the entire configured confirmation queue remain pending. No final finding/severity or full-conformance verdict follows from the smoke replay. The report preserves the original interruption, mixed-model provenance and separate historical Claude/subscription usage accounting.

## 9. Phase 3 validation handoff (2026-09-27)

Validation completed the adoption obligations through C1–C8 repairs and explicit
coverage dispositions, preserving the original audit and every historical lead.
See [continuation-audit.md](spec/continuation-audit.md),
[changelog.md](spec/changelog.md), and [brief-coverage.md](spec/brief-coverage.md).
The repaired suite separates source-visible startup, waiter, report and completion
steps; requires the actual SJ/CJ prerequisites for clean exits; preserves children
across CP death; and permits the independent server START deadline after CP death.
Unsupported immediate-cancel, uniform START-tolerance and unconditional signal-
delivery requirements were reclassified rather than counted as contract PASSes.
Default GPU arithmetic/binding, ordinary restart, retained object identity and the
other explicit source-only gaps remain for confirmation.

The fresh harness suite was regenerated where the repair exposed inaccurate
process stubs. Its final 32 scenarios contain 2,286 events and 46 actual waiter-
read hooks, with all 65 event types represented. All 32 replay on final C8 with
active TraceMatched and post-state checks; corruption/input/truncation controls,
zero-issue VAV and the generator rebuild are retained. The controlled transport,
process and authentication edges and global trace lock remain limits. These are
fresh projection checks, not full implementation conformance or a real local
deployment confirmation.

Final C8 MC.cfg completed its 30-minute budget with no reported violation, at
depth 39 and 74,561,992 distinct states, leaving 32,570,191 queued. The final matrix
contains all 25 hunting configurations, all eight seed checks and one optional
depth-100 simulation. Every task is observed and collected; interrupted attempts
remain separate. Every no-violation BFS exceeded depth 25. The searches are not
exhaustive, and finalization's last temporal check was still in progress at cutoff.

The [bug report](spec/bug-report.md) and [findings index](spec/findings.json) contain
13 source-classified MC candidates with current C8 primary evidence and provisional
severity. MC-A–E and MC-U1 each have fresh, inspected witnesses; the generic F16
seed remains an F1 duplicate, dedicated F16 refresh is independently witnessed,
and F9 remains a defensive unsupported case. The V04 finalization witness is new
concrete continuation model evidence for a reopened source concern. The report
does not call historical seeds new independent discoveries or any candidate an
independently confirmed deployment defect.

All 33 source-review Scenarios and every lower-priority C/Q/D row remain mandatory
inputs in [findings-reconciliation.md](adoption/findings-reconciliation.md). The
next launcher-owned work is serial GPT-5.5/xhigh confirmation, with no model
substitution, followed by normal GPT-6 Astra/max repair/evolution, classification
and final reporting. Source-only leads must be consolidated alongside the MC
index; a bounded non-rediscovery does not close them. Public APIs, real local
deployment where feasible, supported failures, precise timing/fault labels and
passing controls remain required. Only later final reporting writes the final
BYOM modification report and overall findings/severity summary.

Original assets (4,301 files), all 20 raw conversation records and the product pin
remain preserved; the product worktree has no tracked changes. Evidence checks
are recorded in `spec/output/continuation-final-preservation.json` and
`spec/output/continuation-C8-artifact-final.json`. Original Claude spend remains
$180.5573146 including preflight. Codex subscription usage is separate; the
launcher finalizes this worker's usage after return and must not sum cumulative
resume exports or treat API-equivalent estimates as new Claude-account charges.
