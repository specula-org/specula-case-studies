# cometbft CI evaluation

Record `cometbft-byom-ci-20260908` preserves a September 2026 CI evaluation and its source metadata.

The final confirmation report contains zero reproduced bugs and three false positives. The supplied model and implementation exercise parameter updates, durable block-application boundaries, and recovery; none of the three candidates was confirmed.

See the [confirmation report](confirmed-bugs.md), [pipeline summary](summary.md), [modeling brief](modeling-brief.md), and [original run metadata](provenance/original-run.json). Models, harness artifacts and available reproduction evidence are retained alongside them. Summary completion labels and missing reporting/accounting fields are preserved as recorded, rather than interpreted as a proof of safety.

This curated subset excludes dependency caches, nested source trees, credentials, runtime conversations and model-checker scratch. Historical workspace paths and references to omitted artifacts remain in original reports. No new runtime confirmation was performed during archiving. The payload inventory is [.record/files.tsv](.record/files.tsv).
