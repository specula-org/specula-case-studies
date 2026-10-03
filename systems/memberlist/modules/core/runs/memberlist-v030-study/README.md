# HashiCorp memberlist / core / memberlist-v030-study

This run records the 2026-07-27 Specula evaluation of
`hashicorp/memberlist` at `1d81b5cab210e1e32fbb0f65bdc3e79744b41144`.
The pipeline was run with `--keep-original`, `gpt-5.6-sol`, TLC limited to
8G and 4 workers.

## Result

Specula produced four final dispositions:

| ID | Tracker action | Status | Summary |
| --- | --- | --- | --- |
| `MC-1` | New | `REPRODUCED` | `deadNode` discards a higher terminal incarnation for an already-dead record, so a delayed `Alive(2)` can resurrect a crashed node. |
| `MC-2` | Known, issue #312 | `MASKED` | A delayed pre-restart `Alive` can bind a node name to its retired address; normal probing later removes the stale member. |
| `MC-3` | Known, issue #132 | `REPRODUCED` | A receiver-side `NotifyMerge` rejection does not stop the initiator from accepting and gossiping the rejected state. |
| `CR-2` | New | `REPRODUCED` | Suspicion evidence is keyed only by node name, so higher-incarnation evidence can prematurely expire an older-incarnation timer. |

The tracker records `MC-2` as a real masked finding rather than a false
positive. It is contested only on counting: the wrong `NotifyJoin` and
`Members()` result are observable, but the reproduced membership snapshot is
later cleaned up by normal failure detection.

## Files

- `confirmed-bugs.md`: final Phase 4a report.
- `bug-severity.md`: Phase 4b severity classification.
- `spec/bug-report.md`: original model-checking bug report.
- `repro/`: the four executed Go repro programs.
- `run.json` and `pipeline-summary.md`: run metadata and phase summary.

## Verification Notes

The four repros were re-run locally against a clean archive of commit
`1d81b5cab210e1e32fbb0f65bdc3e79744b41144`. `MC-1`, `MC-3`, and `CR-2`
triggered confirmed bugs; `MC-2` reproduced the stale address exposure and
the downstream probe/suspicion cleanup.
