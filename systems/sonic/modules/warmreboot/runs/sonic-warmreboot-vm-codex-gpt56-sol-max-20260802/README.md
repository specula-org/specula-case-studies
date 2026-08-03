# SONiC warm reboot run

## Reviewed result

For tracker curation, the independent review records **1 new finding** from this run:

- New: fpmsyncd publishes `RECONCILED` before its queued route operations are flushed (MC-5). The following unconditional flush masks a persistent route-state consequence, but the externally visible completion ordering is still wrong.

MC-3 is not counted again because it is the same `READY`-before-freeze-fence bug already recorded as tracker New #221. MC-1, MC-2, MC-4, MC-6, and CR-5 have prior upstream reports and are retained as evidence but excluded under the current new-only tracker policy.

Read [independent-review.md](review/independent-review.md) for the final ledger and [confirmed-bugs.md](confirmed-bugs.md) for the original pipeline report.

## Provenance

- Source archive: `sonic-fdb-warmreboot.zip`
- Archive SHA-256: `bb5ae60a286d8c2fb22226379f897e32d58cef44040af37e1361afc2a3d4b586`
- Archive size: 4,146,750 bytes; 1,028 entries
- Member prefix: `sonic-warmreboot-vm-codex-gpt56-sol-max-20260802/`
- Prefix inventory: 172 files, 18,063,837 expanded bytes
- Run created: `2026-08-01T17:37:01-05:00`
- Agent: `codex`, requested model `gpt-5.6-sol` from `run.json`
- Target source: [`sonic-net/sonic-buildimage@d5a2f4d1df9fdf71e48777905cd3f032b3d78a94`](https://github.com/sonic-net/sonic-buildimage/tree/d5a2f4d1df9fdf71e48777905cd3f032b3d78a94)

## Included evidence

This record retains 82 byte-exact archive files: run metadata and reports; all seven confirmation records; reproduction programs and scripts; the instrumentation harness; the core TLA+ models and hunt configurations; and selected final model-checker outputs. The generated `index.md` only replaces its dead pipeline-log link with an exclusion notice.

The raw ZIP, logs, prompts, agent worktrees, caches, binaries, TLC state directories, generated `MC_TTrace_*` files, and intermediate model-checker outputs are excluded. Some preserved reports and wrappers contain archive-local absolute paths and require a matching source checkout before they can be rerun.
