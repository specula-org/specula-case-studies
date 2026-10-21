# Asterinas results and evidence — 2026-10-21

This collection updates the [September collection](../asterinas-findings-pack-2026-09-24/README.md) with the supplied October result package. It preserves selected native reports, confirmation verdicts, models, harnesses, traces, reproduction programs, runtime logs, and record-audit material. No experiment was rerun during import.

Start with [the 76 selected findings](FINDINGS.md), [the native run index](RUNS.md), and [known qualifications](REMAINING.md). The September collection remains an unchanged historical snapshot.

## Results

| Evidence among selected entries | Count |
|---|---:|
| Native positive confirmation, deduplicated by AST | 31 |
| Independent kernel/device runtime records | 2 |
| Outcome-only wait/reap observations | 2 |
| Source leads | 40 |
| MASKED record | 1 |
| Selected tracking entries | 76 |

The eight native final reports contain 54 dispositions, including 38 positive observations mapping to 31 AST entries. The source catalog has 93 entries; its 17 false-positive, unsupported, dropped, and model-error entries are excluded from the selected tracking set. The record-audit CSV contains 221 documentation/provenance issues grouped into 214 handling groups; these are not Asterinas bugs.

The tracker snapshot contains **28 Confirmed, 7 Fixed, and 41 blank statuses**, with **61 New and 15 Known** tracking labels. Existing higher tracker statuses are preserved. Evidence disposition, tracker status, novelty, and complete upstream repair coverage are separate fields in [findings.json](findings.json).

## Changes since September

- Eleven selected entries are new to the case-study archive: AST-73/74/75, AST-79..82, AST-84/85, and AST-92/93.
- AST-32 and AST-36 now have native runtime confirmations from the SCM_RIGHTS run.
- Native confirmation reports and selected supporting artifacts supplement the earlier curated package, which did not contain complete original run outputs.
- The October audit corrects source mappings, novelty statements, coverage descriptions, and cost/provenance claims. Read [the retained audit](evidence/audit/codex-audit-2026-10-20.md) alongside original reports.

## Upstream repair snapshot

Checked on 2026-10-21 against main `f40d6222dc140cc278bd110757b52f3f0fb496aa`:

| AST | Complete upstream repair |
|---|---|
| AST-07 | [PR #3959](https://github.com/asterinas/asterinas/pull/3959), merged 2026-10-11 |
| AST-14 | [PR #3875](https://github.com/asterinas/asterinas/pull/3875), merged 2026-09-29 |
| AST-19 | [PR #3984](https://github.com/asterinas/asterinas/pull/3984), merged 2026-10-13 |
| AST-62 | [PR #3824](https://github.com/asterinas/asterinas/pull/3824), merged 2026-09-14 |

AST-02 has a partial empty-write repair in #3875. AST-05/10 have an open repair PR #3778. Their existing Fixed tracker labels are retained, without converting those labels into claims of a complete merged repair. AST-24 remains MASKED in source evidence although its existing Confirmed tracker label is retained. [Upstream receipts](.record/upstream-status.json) record the inspected references.

## Reading the evidence

- Each finding page links to its confirmation verdict, report, or historical description.
- `evidence/native-runs/` preserves original relative paths for selected files, including the `.specula-output` subdirectory. Programs retain original execution assumptions and paths; this import is not a portable execution bundle.
- `evidence/workspace/` retains supporting validation and lane reports. Failed reviews and outcome-only limits are retained with the successful observations.
- `.record/files.tsv` maps every copied evidence file to its archive path, byte count, SHA-256, and selection category.
- Intermediate captures, build products, nested source checkouts, full agent activity streams, and most raw buffers are not published. All selected evidence is byte-identical to the supplied archive.

The source archive SHA-256 is `1229e56e068e016be004b482524917f8342935d7016881615b615d38e7b4868a`. [Import metadata](.record/intake.json) records the archive identity and selection boundary. [Artifact checksums](.record/SHA256SUMS) cover the published record; run `sha256sum -c .record/SHA256SUMS` from this directory.
