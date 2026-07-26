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

`overview.md` is the summary for a system. It records which modules were studied and summarizes the confirmed bugs. It may be absent until that system has been reviewed.

The run directory is the experiment record. Original files keep their relative paths directly beneath it. Generated provenance and file inventories are kept under `.record/`.
