# SONiC ICCPD run

## Reviewed result

The independent review records **2 new bugs**:

- A crash after peer socket teardown but before disconnect cleanup can permanently skip failover cleanup and leave State DB and CLI state reporting the dead peer as up (MC-1).
- Peer and sidecar transport activity can diverge from the single scheduler's progress: partial ICCP frames block the scheduler, unsupported APP traffic can hold an incomplete session, and mclagsyncd EOF can suppress reconnect (CR-4).

MC-2 is not counted because its demonstrated consequence is the already recorded `EXCHANGE` to `ERROR` full-sync bug. MC-3's stale-descriptor mechanism is folded into CR-4 rather than counted a second time.

Read [independent-review.md](review/independent-review.md) for the final ledger and [confirmed-bugs.md](confirmed-bugs.md) for the original pipeline report.

## Provenance

- Source archive: `specula-runs.zip`
- Archive SHA-256: `9b9464b4659f431a8e8ce96c9b2121c9b1385d6fbb24bc904874f9dacc9bd01d`
- Archive size: 79,594,534 bytes; 1,706 entries
- Member prefix: `sonic-iccpd-vm-codex-gpt56-sol-max-20260801/`
- Prefix inventory: 272 files, 3,647,237 expanded bytes
- Run created: `2026-07-31T22:20:40-05:00`
- Agent: `codex`, requested model `gpt-5.6-sol` from `run.json`
- Target source: [`sonic-net/sonic-buildimage@9df8ccbf72c31948741b5554d09c38ac6c1ec6e9`](https://github.com/sonic-net/sonic-buildimage/tree/9df8ccbf72c31948741b5554d09c38ac6c1ec6e9)

## Included evidence

This record retains 60 byte-exact archive files: run metadata and reports; all four core confirmation records; reproduction scripts; the instrumentation harness; the core TLA+ models and hunt configurations; selected validated counterexamples; and validation traces. The generated `index.md` only replaces its dead pipeline-log link with an exclusion notice.

The raw ZIP, logs, prompts, agent worktrees, caches, harness build products, TLC state directories, generated `MC_TTrace_*` files, and intermediate model-checker outputs are excluded. Some preserved reports and wrappers contain archive-local absolute paths and require a matching source checkout before they can be rerun.
