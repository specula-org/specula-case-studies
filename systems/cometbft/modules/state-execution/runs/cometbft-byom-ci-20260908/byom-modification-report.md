# BYOM Modification Report — cometbft

The comparison covered all 32 files supplied under `inputs/byom` and their adopted workspace counterparts. Of those files, 23 are byte-identical at the same relative path, 8 were adapted only in `.specula-output`, and the input-only `README.md` was not copied. The supplied directory remained unchanged.

## Reused without modification

- The reference, model-checking, and trace modules and configurations were reused byte-for-byte: `base.tla`, `MC.tla`, `Trace.tla`, their three primary configurations, all three Scenario hunt configurations, and all seven reachability configurations.
- All six retained NDJSON traces were reused byte-for-byte, and the validation phase replayed those retained files. Phase 2.5 also exercised the adapted harness with separate diagnostic output; those fresh traces did not replace the retained copies.
- `harness/patches/instrumentation.patch` was reused byte-for-byte and applied only to disposable or otherwise separate writable checkouts.

## Modified in the workspace

- `analysis-report.md`, `model-scope.md`, and `modeling-brief.md` were adapted to replace historical `/work` references, identify the supplied V0-generation wording as preparation history, bind the baseline to source commit `af998de26e82b796590b14fb2417864fc3c31202`, and record the focused source-correspondence supplement and remaining coverage gaps. These edits preserved the supplied consensus-parameter execution, persistence, and startup-recovery scope and did not require a semantic TLA+ model change.
- `harness/README.md`, `harness/INSTRUMENTATION.md`, `harness/apply.sh`, and `harness/run.sh` were adapted to the final workspace layout. The runner now defaults to a disposable clone of the sibling source checkout, rejects unsafe or mismatched writable checkouts, supports explicit source, trace, and log locations, and documents current hook locations and safe small adjustments.
- `spec/instrumentation-spec.md` was reconciled with the supplied patch and retained event payloads: it documents `updatePresent`, removes fields not emitted for response-save or rejection events, and explains the trace-wrapper derivation. No model action or state mapping was changed.

## Added by Specula

- `spec/brief-coverage.md` was added to audit Scenario, invariant, reachability, trace, and instrumentation wiring for the adopted suite.
- `spec/changelog.md`, `spec/bug-report.md`, `spec/output/`, `spec/states/`, reachability witness records, and TLC-generated trace/checkpoint files were added to retain this run's trace-validation and model-checking evidence.
- `spec/candidates.json`, `spec/findings.json`, `spec/confirmation-generation.json`, the `confirmation/` and `repro/` trees, `confirmed-bugs.md`, `bug-severity.md`, and `.summary-findings.md` were added by the standard finding, confirmation, and final-reporting phases.
- Pipeline prompts, activity logs, resume/resource records, isolated confirmation worktrees, and `index.md` are current-run operational and navigation artifacts; they were not supplied verification inputs.

## Uncertain correspondence

- The supplied `README.md` was an intake/adoption note and was not promoted as a verification artifact. It states that historical reports, debug counterexamples, provenance helpers, and old run outputs were omitted, so those unavailable materials cannot be mapped one-to-one to the current run's generated logs, states, checkpoints, or confirmation records.
- No other unresolved correspondence was found among the 31 supplied files adopted at matching relative paths. This report is a human-oriented comparison, not a mechanically complete provenance manifest.
