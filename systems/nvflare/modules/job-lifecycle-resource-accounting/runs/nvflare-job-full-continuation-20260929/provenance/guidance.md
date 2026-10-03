# NVFlare job lifecycle and resource accounting

## Goal
Investigate whether job lifecycle and resource management follow their intended contracts under overlapping operations and ordinary failures.

## Scope
Study the default local-process launch path, including resource reservation, deployment, startup, termination, and cleanup across the server and participating clients.
Follow adjacent callers and exception handlers that determine resource ownership, job status, or the admission of later jobs.
Exclude training aggregation, model transfer, GPU computation, alternative launcher backends, and high-availability recovery.

## Questions
1. When concurrent jobs reserve, acquire, and release resources, is resource ownership preserved without conflicting assignments or lost capacity?
2. When deployment or startup only partly succeeds, do recorded job status and cleanup responsibilities match the actual outcome?
3. When cancellation, completion, and cleanup overlap, do lifecycle transitions preserve the applicable job-status and resource-lifetime contracts?
4. When an ordinary operation fails, can its remaining state incorrectly affect a later eligible job?

## Interactions and assumptions
Follow the server scheduler/runner, client resource and start handlers, local job executor, resource manager, and process-exit cleanup.
Use cooperative participants and supported APIs/configurations. Derive the exact guarantees and failure assumptions from the pinned source and its documentation; the questions above do not presume defects or prescribe model guards.
Verify candidates in the actual implementation, retain commands and evidence, and distinguish unsupported assumptions from product defects. Report findings without fixing product implementation logic.


## Explicit continuation instructions from the user

This is an authorized cross-provider continuation of an incomplete full Specula run. Use GPT-6 Astra at max for reasoning/verification/repair/classification and GPT-5.5 at xhigh for the separate confirmation/reproduction phase, as configured by the pipeline. Do not substitute models. This is a mixed-model continuation, not an independent pure-model trial.

Read the previous run's conversations in `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/handoff/conversations` (start with README.md and index.json), including the four main phase transcripts and relevant analysis child transcripts. The original records and artifact hashes are under `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/handoff`. Use these records to understand prior commands, decisions, counterexamples, model repairs, discarded leads, and unfinished work; do not rely only on the summary. Read them in manageable chunks instead of dumping all transcripts into one tool result.

The supplied verification assets are `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/handoff/full/run/nvflare-job/.specula-output`. Original source commit: 53ba7ee567468ea7971dad4faccef13c6cb35dc2. Your working source is `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/source`. Source and installed skills are pinned to the original experiment revisions. Historical blob lazy fetching is permitted only as needed for ancestors of this exact source pin. Do not inspect newer commits, upstream issue/PR discussions, Lite results, other Specula case studies, user memory, or unrelated experiment results.

The user's requirement is serious completion, not merely trusting or formatting the previous partial work. Before accepting the adopted model, cross-check its actions, atomicity boundaries, invariants, failure assumptions, and all residual/hunt exclusions against the pinned implementation. Audit the old trace mappings and harness stubs for semantic changes or vacuous validation. Trace replay does not prove full conformance, and bounded TLC success is not unbounded correctness. Reclassify prior alleged bugs or prior PASS claims when evidence does not support them.

During the BYOM adoption/specification phase, write a review in `.specula-output/takeover-review.md` identifying inspected conversation records, accepted evidence, discrepancies, remaining coverage gaps, and specific checks still required. Reconcile all prior analysis/deep-analysis findings and MC-A through MC-E from the validation changelog; do not lose lower-priority findings merely because they were omitted from the main report. Preserve source-derived seeds and distinguish them from genuinely new model-checking discoveries. Follow phase ownership: write the audit during adoption, then perform semantic repairs in the normal validation/repair phases and pass every eligible bug to the configured confirmation phase.

In the harness phase, adapt copied scripts to the new source/runtime/output paths and rerun the scenario suite to establish fresh trace evidence. This explicitly overrides BYOM's default to adopt old traces without rerunning. In validation, replay the fresh traces, recheck seed fidelity, and finish the full convergence and bug-hunting workflow. Previous PASS records and previous stage-completion state do not mark the new stage complete. Ordinary bounded/time-limited TLC searches may be reported honestly without claiming exhaustive completion; no overall wall-clock deadline is imposed.

Do not run copies of old commands blindly: many reference inaccessible `/home/experiment` or transient `/tmp` paths. Repair these paths only in adopted working copies. Do not modify original supplied assets. Keep real-code reproductions separate from model counterexamples, unsupported defensive cases, and environment-limited findings. Use public APIs and a real local deployment where feasible, label timing controls/fault injection, and retain passing controls and source provenance.

Complete the normal confirmation, repair/evolve loop, classification and final reporting through the launcher. Investigation and verification artifact changes are authorized; product bug fixes, upstream publication, pushes and tracker writes are not. Final reports must state the original run's interruption, the mixed-model provenance, what was independently rechecked, and outstanding limits. Do not stop simply because the old run had already spent effort or labelled findings confirmed.

Resource limits remain aggregate 64 GiB TLC memory and 16 TLC workers, 80 GiB service memory, and one concurrent per-finding confirmation task. The original Claude spend ($180.5573146 including preflight) and new Codex subscription usage must be reported separately; API-equivalent Codex estimates are not new Claude-account charges. Do not fetch or consult external answers.
