# Specula

## Scope

Specula analyzed its own pipeline orchestration, confirmation caching, repair and resume state, artifact handling, workspace isolation, and model-check process lifecycle.

## Findings

The [September 2026 self-check](modules/pipeline-orchestration/runs/specula-self-20260929/README.md) records 12 findings: two Fixed and ten Confirmed.

- [PR #172](https://github.com/specula-org/Specula/pull/172) binds confirmation results to the code snapshot the worker inspected.
- [PR #173](https://github.com/specula-org/Specula/pull/173) preserves the repair-round limit across interruption and resume.

The run summary lists the remaining findings individually.
