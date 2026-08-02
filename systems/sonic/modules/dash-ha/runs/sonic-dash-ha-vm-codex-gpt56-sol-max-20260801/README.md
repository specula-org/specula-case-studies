# SONiC DASH HA run

## Reviewed result

The independent review records **4 new bugs** and **2 previously known, unfixed bugs**:

- New: logical HA scope state can redirect traffic before ASIC acknowledgement (MC-2).
- New: a delayed old peer-state request can regress an accepted HA term (MC-3).
- New: a delayed former-peer message can contaminate a newly paired HA scope (MC-4).
- New: restart can create two actionable pending-operation UUIDs for one DPU flag (MC-5).
- Known: a late DPU acknowledgement can regress an Active scope's ASIC role (MC-1, issue #171).
- Known: vote completion can reset an in-progress switchover retry budget (MC-7, PR #145 review).

MC-6 is retained as run evidence but is not counted again: it matches the existing parent-cleanup finding, and sairedis currently masks the hardware consequence with `SAI_STATUS_OBJECT_IN_USE`.

Read [independent-review.md](review/independent-review.md) for the final ledger and [confirmed-bugs.md](confirmed-bugs.md) for the original pipeline report.

## Provenance

- Source archive: `specula-runs.zip`
- Archive SHA-256: `9b9464b4659f431a8e8ce96c9b2121c9b1385d6fbb24bc904874f9dacc9bd01d`
- Archive size: 79,594,534 bytes; 1,706 entries
- Member prefix: `sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/`
- Prefix inventory: 393 files, 4,352,319 expanded bytes
- Run created: `2026-07-31T22:31:12-05:00`
- Agent: `codex`, requested model `gpt-5.6-sol` from `run.json`
- Target source: [`sonic-net/sonic-dash-ha@f53422a4b5f0de372714fd309d1975ce34445633`](https://github.com/sonic-net/sonic-dash-ha/tree/f53422a4b5f0de372714fd309d1975ce34445633)

## Included evidence

This record retains 85 byte-exact archive files: run metadata and reports; all seven core confirmation records; reproduction scripts; the instrumentation harness; the core TLA+ models and hunt configurations; selected final counterexamples; and validation traces. The generated `index.md` only replaces its dead pipeline-log link with an exclusion notice.

The raw ZIP, logs, prompts, agent worktrees, caches, binaries, TLC state directories, generated `MC_TTrace_*` files, and intermediate model-checker outputs are excluded. Some preserved reports and wrappers contain archive-local absolute paths and require a matching source checkout before they can be rerun.
