# SONiC FDB run

## Reviewed result

The independent review records **4 new bugs** for the tracker batch:

- A delayed AGE notification deletes the current FDB row after a newer incarnation has been learned (MC-2).
- A delayed LEARN notification reclassifies a newer MCLAG remote row as local and leaves hardware/software ownership inconsistent (MC-5).
- Deferred SET replay can apply an obsolete destination after newer desired state has arrived (MC-6).
- The one-shot kernel NHG dump can be discarded before NVO readiness with no replay path (MC-7).

The run also retains two known, unfixed bugs (MC-1 and MC-3) and one known, masked finding (MC-4). They are preserved as experiment evidence but are not part of this New-only tracker batch.

Read [independent-review.md](review/independent-review.md) for the final ledger and [confirmed-bugs.md](confirmed-bugs.md) for the original pipeline report.

## Provenance

- Source archive: `sonic-fdb-warmreboot.zip`
- Archive SHA-256: `bb5ae60a286d8c2fb22226379f897e32d58cef44040af37e1361afc2a3d4b586`
- Archive size: 4,146,750 bytes; 1,028 entries
- Member prefix: `sonic-fdb-vm-codex-gpt56-sol-max-20260801/`
- Prefix inventory: 718 files, 18,021,378 expanded bytes
- Run created: `2026-08-01T09:10:01-05:00`
- Agent: `codex`, requested model `gpt-5.6-sol` from `run.json`
- Target source: [`sonic-net/sonic-swss@4f3dda156e52ed7647b1dbf900d54d87efaea455`](https://github.com/sonic-net/sonic-swss/tree/4f3dda156e52ed7647b1dbf900d54d87efaea455)

## Included evidence

This record retains 112 byte-exact archive files: run metadata and reports; all seven core confirmation records; reproduction scripts; the instrumentation harness; the core TLA+ models and hunt configurations; the repair ledger and requests; selected final RR-003 counterexamples; and validation traces. The generated `index.md` only replaces its dead pipeline-log link with an exclusion notice.

The raw ZIP, logs, prompts, agent worktrees, caches, confirmation build products, TLC state directories, generated `MC_TTrace_*` files, and intermediate model-checker outputs are excluded. Some preserved reports and wrappers contain archive-local absolute paths and require a matching source checkout before they can be rerun.
