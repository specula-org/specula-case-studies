# Archive scope and lineage

The full arm began alongside the Lite arm on 2026-09-25. Provider interruptions led to a continuation using the original full arm's model, harness, traces, and discussion handoff. The two phases remain one logical experiment, with separate original and continuation run metadata under `provenance/`.

This is a curated evidence archive. It preserves reports, models, checking receipts, harness sources and patch, final traces, reproduction sources, and per-finding investigation/verdict/output records. Original bytes are retained except for separately identified curated documents. The portable component runner relocates a source path in memory; its archive-time replays are additional validation and do not change the original result history.

Excluded: nested source worktrees, dependency and build caches, TLC state/checkpoint binaries, runtime conversation transcripts, credentials, generated deployment workspaces, and oversized expansions. Original reports may reference excluded files or absolute paths. Such references document the original execution and are not promises that the entire original filesystem was published.

The original confirmation report's NEW/KNOWN labels and severity ratings remain source assessments. MC-9 and CR-32 even disagree on the fix status of the same final mechanism. The reconciliation ledger therefore keeps original labels separate from cross-run identity and admission decisions. CR-26 is held for missing evidence of an exception producer on the default path; CR-30 remains the original false positive.
