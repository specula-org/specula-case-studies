# BYOM Modification Report — slatedb-byom-complete

All 25 supplied files were adopted into the final workspace: 19 remain byte-for-byte unchanged, six workspace copies were modified, and none are missing. The original BYOM directory was treated as read-only.

## Supplied assets reused without modification

- The five supplied NDJSON traces were preserved byte-for-byte. They were validated and replayed successfully; the harness was not rerun.
- The supplied harness documentation, instrumentation patch, and two trace-source modules were reused unchanged.
- The core MC wrapper and config, five unchanged hunting configs (including the safety-only Family 3 config), the Trace and base configs, and the instrumentation specification were reused unchanged.

## Supplied assets modified in the workspace

- `harness/apply.sh` and `harness/run.sh` were made workspace-relative so they target this run's source checkout and Specula TLC installation instead of the supplier's absolute paths. The instrumentation patch was confirmed applicable, but no new traces were generated.
- `spec/Trace.tla` gained an `IOEnv.JSON` override and the required `IOUtils` import so validation could select each supplied trace without rewriting it; its replay semantics were otherwise retained.
- `spec/base.tla` was repaired after model checking exposed a fidelity issue in `PollAndClaim`: its capacity guard now counts durable same-batch worker claims as well as locally executing jobs, matching the implementation's fixed-capacity batch claim.
- `spec/MC_hunt_family3.cfg` stopped checking `TimedOutOrFailedJobsDoNotLivelock` because the supplied behavior and implementation provide neither the fairness nor eventual-success premise that property requires; Family 3 safety checks remained enabled.
- `spec/brief-coverage.md` was extended with the focused custom-scheduler/L0-watermark Scenario gap, the supplemental conflict config, and the validation outcomes for the fidelity and liveness-oracle repairs.

## Verification assets added by Specula

- `modeling-brief.md` records the supplied scope and focused Scenario supplement, including the ordered-L0 coverage gap that the supplied set-based model cannot express.
- `spec/MC_hunt_family1_conflicts.cfg` was added to isolate the cross-compaction conflict oracle from the earlier capacity violation.
- TLC run logs, counterexamples, generated trace artifacts, and `spec/changelog.md` record trace validation, model checking, repairs, infrastructure limits, and the final converged runs.
- Candidate, finding, bug-report, confirmation, and reproduction artifacts were added to carry the model-checking results through code-level confirmation. The final reporting artifacts are `confirmed-bugs.md`, `bug-severity.md`, and `.summary-findings.md`.
- Workflow prompts, activity logs, and usage metadata were retained as execution audit records.

## Correspondence and uncertainty

Every supplied file has a direct same-relative-path workspace counterpart, so no supplied-file ownership or correspondence remained uncertain. Timestamped TLC traces, run logs, and confirmation worktrees are generated evidence rather than one-to-one replacements for supplied files; this report does not assert a finer correspondence among those generated artifacts.
