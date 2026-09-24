# Asterinas findings collection — 2026-09-24

This collection preserves 72 findings supplied in `asterinas-findings-pack-2026-09-24.zip`. It brings
together four Specula runs, one analysis-only run, two external reproduction
packages, an interface audit, and a backend source audit. The original finding
IDs and source dispositions are retained.

## Results

The Specula tracking set contains **22 entries: 21 REPRODUCED and one MASKED**.
AST-01, AST-04, AST-16, and AST-17 remain separate entries; the source reports
describe their shared mechanisms. Rediscoveries in other runs remain aliases.
These counts describe findings reported by the supplied collection, rather
than independent reproductions performed during archival.

| Source disposition | Entries | Treatment |
|---|---:|---|
| REPRODUCED, Specula runs | 21 | Included in the tracking set |
| MASKED, Specula run | 1 | Included with the harm limitation |
| REPRODUCED, external packages | 2 | AST-07/08; external references |
| SOURCE LEAD | 41 | Retained as unverified leads |
| UNSUPPORTED | 2 | Retained as unsupported-feature records |
| FALSE POSITIVE / DROPPED / MODEL ERROR | 5 | Retained with the rejected disposition |

The [tracking ledger](review/tracking-ledger.json) classifies these 22 entries
as 17 New and five Known, using earlier upstream issue, review, or fix coverage.

See the [system overview](../../../../overview.md) for the 22-entry summary,
the [complete source index](source-README.md#index) for all 72 entries, and
[findings.json](findings.json) for structured records. The supplied
`specula-known-findings/asterinas.json` includes the two external entries and
therefore has 24 entries; it is not the 22-entry Specula tracking set.

## Evidence and reproduction

The collection includes finding reports, metadata, reproduction sources,
selected test and harness patches, and historical output excerpts. The original
TLA+ models, counterexample files, complete runtime logs, confirmation verdict
files, and source checkouts were not supplied. Absolute evidence paths refer
to unavailable files on the supplier's machine. This is one collection record
in the catalog; it does not establish additional complete pipeline runs.

Use each finding's `repro/README.md` and the
[reproduction guide](docs/running-reproducers.md) to select the correct pinned
commit and environment. Scripts may require local path adaptation. Some tests
report a detected defect with exit code zero; read their documented markers.
No reproducer was executed during this import.

AST-11 separates a timing-hook reproduction at `604948581` from later
hook-free regression evidence at `bc12195df`. AST-21 retains an ordering and
log-provenance qualification. AST-24 is MASKED: later-write corruption was
not observed. The [confirmation provenance](docs/confirmation-provenance.md)
describes the original confirmation process and later checks.

## Archival provenance

- Archive SHA-256: `6d9d3b472350c77475d11c0365fa4afb41e10c531060cf8532eca615c90b8d4d`.
- [Intake record](.record/intake.json): source runs, selection, and missing artifacts.
- [File inventory](.record/files.tsv): source and published file hashes.
- [Import notes](review/import-notes.md): navigation changes and upstream reconciliation.

Use this collection for confirmation, deduplication, and repair. Keep findings
out of discovery-stage inputs when measuring independent discovery.
