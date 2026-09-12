# temporal-update-20260909-restart-1600

## Scope

Workflow Update commit, rollback, cache recovery, speculative workflow tasks, response publication, and retry progress.

The run analyzed [`temporalio/temporal@0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`](https://github.com/temporalio/temporal/tree/0c010ce5fe8c0180aa7573c72fe8fc87c6df7025). Analysis, specification, trace validation, and review phases used GPT-6 Astra at xhigh effort. Bug confirmation used GPT-5.5 at xhigh effort. The run used 30 policy retries; Update and Reset allowed 224 GiB and 64 TLC workers, while the other four runs allowed 112 GiB and 32 TLC workers.

## Retained findings

- Update CR-1
- Update CR-2A
- Update CR-2B
- Update CR-3A
- Update CR-3B
- Update CR-4

The cross-run independent review controls the public count. Original per-run reports retain their own entry-level dispositions and may group more than one independent mechanism under one entry.

## Evidence boundary

This is a curated record. It preserves the final reports, relevant TLA+ models and configurations, harness and reproduction sources, bounded trace evidence, and finding-local confirmation material. Build caches, compiled binaries, model-checker state directories, temporary databases, nested source checkouts, and agent runtime transcripts are excluded.

Implementation reproduction is not upstream maintainer confirmation. Bounded TLC or trace replay does not establish an unbounded proof. See the [record manifest](.record/manifest.json) and [file inventory](.record/files.tsv) for provenance.
