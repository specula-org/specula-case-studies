# SREGym run

## Reviewed result

The independent review records **4 new bugs** and **2 previously known bugs**:

- New: cleanup can start while submission evaluation is in flight (MC-1).
- New: a delayed duplicate submission can be graded in the next stage (MC-2).
- New: partial baseline observations are treated as authoritative during reconciliation (CR-3).
- New: a noise apply can complete after stop cleanup (CR-4).
- Known: a persisted baseline can be reused across cluster replacement (MC-3, PR #767).
- Known, masked: a pod restart temporarily removes the injected fault during diagnosis before the normal reinjection monitor restores it (MC-4, issue #568).

The masked MC-4 interval is retained as a bug in this ledger because diagnosis remains publicly available while the replacement PID is fault-free; the record also states the downstream mask explicitly.

Read [independent-review.md](review/independent-review.md) for the final ledger and [confirmed-bugs.md](confirmed-bugs.md) for the original pipeline report.

## Provenance

- Source archive: `specula-runs.zip`
- Archive SHA-256: `9b9464b4659f431a8e8ce96c9b2121c9b1385d6fbb24bc904874f9dacc9bd01d`
- Archive size: 79,594,534 bytes; 1,706 entries
- Member prefix: `sregym-vm-codex-gpt56-sol-max-20260727/`
- Prefix inventory: 285 files, 3,165,237 expanded bytes
- Run created: `2026-07-27T08:18:15-05:00`
- Agent: `codex`, requested model `gpt-5.6-sol` from `run.json`
- Target source: [`SREGym/SREGym@d9a0663e3930d90bd98122e8a852cf8d27c410ec`](https://github.com/SREGym/SREGym/tree/d9a0663e3930d90bd98122e8a852cf8d27c410ec)

## Included evidence

This record retains 67 byte-exact archive files: run metadata and reports; all six core confirmation records; reproduction scripts; the instrumentation harness; the core TLA+ models and hunt configurations; selected counterexamples; and validation traces. The generated `index.md` only replaces its dead pipeline-log link with an exclusion notice.

The raw ZIP, logs, prompts, agent worktrees, caches, Python bytecode, TLC state directories, generated `MC_TTrace_*` files, and intermediate model-checker outputs are excluded. Some preserved reports and wrappers contain archive-local absolute paths and require a matching source checkout before they can be rerun.
