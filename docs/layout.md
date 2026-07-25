# Case-study archive layout

The archive has three top-level content directories:

```text
case-studies/
├── systems/
├── catalog/
└── docs/
```

- `systems/` contains the experiment records.
- `catalog/` contains machine-readable indexes derived from run manifests.
- `docs/` contains documentation about the archive itself.

## Systems and runs

```text
systems/<system>/
├── overview.md
└── modules/<module>/runs/<run-id>/
    ├── README.md
    ├── .record/
    │   ├── manifest.json
    │   ├── source-ref.json  # full local provenance; ignored by Git
    │   └── files.tsv
    ├── run.json or an original ZIP input
    ├── .specula-output/     # full local runtime output; ignored by Git
    ├── spec/
    ├── harness/
    ├── traces/
    └── other original run files
```

`overview.md` is the human-written summary for a system. It records which
modules were studied and summarizes the confirmed bugs. It may be absent until
that system has been reviewed.

The run directory is the experiment record. Original files keep their relative
paths directly beneath it; there is no extra compatibility or `legacy/`
wrapper. Generated provenance and file inventories are kept under `.record/`.

An immutable ZIP source is also a normal run record. The original ZIP remains
at the run root, with its inspected member index under `.record/`.

Partial, failed, diagnostic, and verification-only runs remain records. Their
status is recorded rather than silently treating them as successful runs.

Material that is not an experiment run does not belong under `systems/`.

## Git boundary

The filesystem tree is the complete local archive; the Git repository is its
reviewable index and curated evidence layer. Each run's README,
`.record/manifest.json`, and `.record/files.tsv` are tracked, together with
reports, specifications, harnesses, reproductions, and immutable run inputs.

Full source indexes, source snapshots, `source-ref.json`, and raw
`.specula-output/` trees are intentionally ignored. They remain in place on the
archive host and in the verified backup. Their entries in the tracked manifests
and file inventories provide sizes and hashes for integrity checks.

## Naming

A top-level system name identifies the software project or product being
studied. A protocol, subsystem, crate, or source file within that project is a
module. For example, Asterinas synchronization primitives are stored as
`systems/asterinas/modules/{mutex,rwmutex,spin}/`, rather than as unrelated
top-level systems.

Repository names are evidence for this classification, but not the only rule.
An independently named and released library can remain a system even when its
source lives in a larger monorepo.
