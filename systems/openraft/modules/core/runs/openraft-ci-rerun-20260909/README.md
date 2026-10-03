# openraft CI evaluation

Record `openraft-ci-rerun-20260909` preserves a September 2026 CI evaluation and its source metadata.

The final confirmation material contains zero reproduced bugs, one false positive, and four dropped known findings. The rerun retained confirmation results from the earlier 2026-09-07 acceptance run; the copied `inherited-confirmation/` evidence preserves that lineage. It is not a fresh repetition of each confirmation test.

See the [confirmation report](confirmed-bugs.md), [pipeline summary](summary.md), [modeling brief](modeling-brief.md), and [original run metadata](provenance/original-run.json). Models, harness artifacts and available reproduction evidence are retained alongside them. Summary completion labels and missing reporting/accounting fields are preserved as recorded, rather than interpreted as a proof of safety.

This curated subset excludes dependency caches, nested source trees, credentials, runtime conversations and model-checker scratch. Historical workspace paths and references to omitted artifacts remain in original reports. No new runtime confirmation was performed during archiving. The payload inventory is [.record/files.tsv](.record/files.tsv).
