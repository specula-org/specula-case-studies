# SlateDB BYOM follow-up

This record preserves the reviewed results of a full Specula BYOM run against SlateDB distributed compaction. The run reused the model, TraceSpec, instrumentation, harness, and five traces from the earlier [2026-07-21 case study](../slatedb-dist-compaction-20260721-213543/README.md).

## Reviewed result

The follow-up adds two independent ledger entries:

- **Known, unfixed, High (MC-1):** duplicate external `Full` submissions can reach one worker with the same destination sorted-run id and panic it. This is the mechanism reported in upstream [Issue #1838](https://github.com/slatedb/slatedb/issues/1838).
- **New, High (CR-6):** a custom scheduler can submit L0 sources oldest-to-newest; the compactor records the wrong L0 watermark, retains an already-compacted L0, and eventually blocks a normal public memtable flush.

The run also reproduced the coordinator-wide capacity bypass twice (MC-2 and MC-3). That is the same root cause already recorded by the earlier case study, so it is not counted again.

## BYOM result

- All 25 supplied files remained unchanged at their original path.
- Five supplied traces passed twice; the harness was reused without rerunning.
- Nineteen workspace copies remained byte-identical and six received documented portability or model-fidelity changes.
- The final standard model check covered 121,149,670 distinct states in 30 minutes without a standard-property violation.
- The source checkout remained clean; no production patch was applied.

The generated Phase 4 report counted four reproduced entries. The [independent review](review/independent-review.md) is authoritative for root-cause deduplication and novelty.

## Reproduction

Run both selected reproductions against a fresh checkout of the archived source commit:

```bash
./repro/run_all.sh
```

To reuse an existing clean checkout:

```bash
SOURCE_REPO=/path/to/slatedb ./repro/run_all.sh
```

The runner verifies [`slatedb/slatedb@cc69461d902560bb5f4407a506f32cd154ede79d`](https://github.com/slatedb/slatedb/tree/cc69461d902560bb5f4407a506f32cd154ede79d), uses bounded commands, and leaves the source checkout unchanged.

## Provenance and limits

- Run ID: `byom-slatedb-complete-20260903`
- Specula commit: `16e121adf0d21d7bcbfa855ec3eccbe09a34db86`
- Default model: `gpt-5.6-sol`; confirmation model: `gpt-5.5`
- Completed: 2026-09-03 18:54:44 UTC after 323 minutes
- Three initial parallel hunting JVMs crashed in OpenJDK performance sampling. Those partial results were excluded and every affected configuration was rerun sequentially.
- Violation-free TLC runs were time-bounded, not exhaustive proofs.

See `evidence/` for the generated reports and `confirmation/` for the two selected finding records.
