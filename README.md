# Specula Case Studies

Experiment records produced with [Specula](https://github.com/specula-org/Specula), organized by system, module, and run.

## Repository layout

```text
case-studies/
├── systems/    experiment records grouped by system
├── catalog/    machine-readable system and run indexes
└── docs/       archive layout and maintenance notes
```

Each experiment is stored at:

```text
systems/<system>/modules/<module>/runs/<run-id>/
```

The run directory is the record. Original reports, specifications, harnesses, traces, prompts, logs, and other evidence retain their relative paths beneath it. Generated provenance and file inventories live in the run's `.record/` directory.

System summaries belong at `systems/<system>/overview.md`. They will be added as the experiment results are reviewed.

See [docs/layout.md](docs/layout.md) for the complete organization rules.
