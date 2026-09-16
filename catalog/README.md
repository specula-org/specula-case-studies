# Catalog

This directory contains machine-readable indexes generated from `systems/**/.record/manifest.json`.

- `runs.jsonl` has one JSON object per run.
- `systems.json` groups the same records by system and module.

The indexes include curated runs, archive snapshots, and review records. Archive metadata is read from the manifest's `record` and `source` fields; directory names identify the system, module, and run when a review manifest omits them. Fields not recorded by the manifest remain `null`. Record totals are not counts of unique bugs.
