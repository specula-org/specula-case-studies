# SONiC warm reboot run

## Reviewed result

For tracker curation, the independent review records **3 new bugs** from this run:

- MC-1: restarting `rebootbackend` during an accepted host reboot loses accepted-reboot ownership and exposes stale gNOI status plus a false second success.
- MC-2: a warm-aware extension component registered after the warmboot finalizer's startup snapshot is omitted from the restoration barrier, so global warm finalization can complete while the new component is still restoring.
- MC-4: an interrupted `docker cp` publishes a non-empty partial Redis snapshot that restore gates accept, causing Redis/database startup failure until external cleanup or cold recovery.

MC-3 is retained as a masked finding because SWSS startup replay repairs the tested post-freeze configuration crossing. MC-5 is retained as pipeline evidence but is not added to the tracker from this review because the transport-loss versus host-outcome boundary still needs direct validation before treating it as a recordable bug.

Read [independent-review.md](review/independent-review.md) for the final ledger, [mc2-contract-review.md](review/mc2-contract-review.md) for the support-contract check requested for MC-2, and [confirmed-bugs.md](confirmed-bugs.md) for the original pipeline report.

## Provenance

- Source archive: `effort_EXP/sonic-sol-high.zip`
- Archive SHA-256: `b0a22ac7ac2610cce985e8092c414ff8baca7b87b94bd4bdf417d3d02efc8057`
- Archive size: 4,574,079 bytes; 1,310 entries
- Member prefix: `sonic-warmreboot-vm-codex-gpt56-sol-high-20260803/warmreboot/`
- Prefix inventory: 195 files, 4,318,669 expanded bytes
- Run created: `2026-08-03T12:28:05-05:00`
- Agent: `codex`, requested model `gpt-5.6-sol`, effort `high` from `run.json`
- Target source: [`sonic-net/sonic-buildimage@9914efc028c3835c564eb0c6028a019991b5c422`](https://github.com/sonic-net/sonic-buildimage/tree/9914efc028c3835c564eb0c6028a019991b5c422)

## Included evidence

This record retains the selected archive evidence: run metadata and reports; all five confirmation records; reproduction programs and scripts; the instrumentation harness; the core TLA+ models and hunt configurations; selected final model-checker outputs; and reduced traces. The generated `index.md` only replaces its dead pipeline-log link and removes a link to an excluded binary.

The raw ZIP, logs, prompts, agent worktrees, caches, binaries, coverage/object files, TLC state directories, generated `MC_TTrace_*` files, and intermediate model-checker outputs are excluded. Some preserved reports and wrappers contain archive-local absolute paths and require a matching source checkout before they can be rerun.
