# Spec review probes, 2026-10-05

These are bounded diagnostics for the specification review. They contain no kernel execution, production trace, Linux runtime control, bug confirmation or repair. The source checkout is Asterinas `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd7da14bed4f1541eba593f123059c`.

The copied `base.tla`, `MC.tla` and `Trace.tla` are byte-identical to the reviewed files. [input-hashes.json](input-hashes.json) records all eight inputs. The previous review is preserved in [prior-review.md](prior-review.md).

## Execution

SANY parsing and semantic analysis passed for the three original modules through `validate_spec_syntax`. The caller's ancestor PID 1293639 held the prescribed heavy-stage lock, and MemAvailable was approximately 10 GiB before the probes. No second heavy lane or subagent was started.

The resource-budgeted TLC launcher was attempted first with a 512 MiB heap, 128 MiB off-heap memory, one worker and one minute. It stopped before TLC because this tool connection did not inherit the run's persisted 4 GiB policy. Its task ID is `d4b994b6b2c64546ab142c0b93924872`. This is a launcher configuration failure, not a specification result.

The completed probes used `mcp__tracedebugger__run_trace_validation` sequentially, with `timeout: 30`, the working directory containing this file, the module/config pairs below, and the corresponding NDJSON input. The tool uses a 4 GiB maximum heap, one TLC worker, `-lncheck final`, and `-fpmem 0.9`. The failing-run logs report 3641 MiB heap and 64 MiB off-heap memory. Each probe completed in under one second. Tool responses are saved as `*-result.json`; failure responses include raw TLC output. Selected raw logs are also saved separately.

The tool calls follow this shape:

```json
{
  "spec_file": "ReviewProbe.tla",
  "config_file": "overlap.cfg",
  "trace_file": "overlap.ndjson",
  "work_dir": "/home/chin39/Documents/play/Specula/runs/asterinas-unix-dgram-scm-rights-20261004T064345Z/asterinas-unix-dgram-scm-rights/.specula-output/spec/output/specgen-review-20261005",
  "timeout": 30
}
```

`ReviewProbe.tla` changes only the trace-file selection and adds an inverse completion predicate for the witness query. The six trace configurations retain the original `Trace.cfg` checks. The witness configuration deliberately replaces the universal `TraceMatched` property with the invariant `CompleteMatchExists == ~(ThreadsWithEvents = {})`. Violating that inverse invariant supplies a complete matching path. It does not mean that the original temporal property passed. All original safety and terminal-cleanup invariants remain enabled for that query.

## Results

| Module / configuration | Result |
| --- | --- |
| `ReviewProbe / valid.cfg` | The existing 55-event synthetic fixture passes. The tool reports 58 generated states. It exercises original sender close, reuse, string object IDs, received entries and final release. |
| `ReviewProbe / bad-source.cfg` | An explicit source-identity assertion rejects the input. |
| `ReviewProbe / unknown-event.cfg` | An explicit event assertion rejects the input. |
| `ReviewProbe / truncated.cfg` | `TraceEndComplete` fails after two states. |
| `ReviewProbe / corrupted-post.cfg` | `TraceMatched` fails with one reachable state. |
| `ReviewProbe / overlap.cfg` | `TraceMatched` fails. TLC finishes the graph with 57 distinct states and depth 56. |
| `ReviewProbe / overlap-witness.cfg` | The inverse completion invariant fails at state 56, exhibiting a complete matching path for exactly the same overlapping input. The final state has all cursors exhausted, cleanup requested, the queue closed and both object balances zero. |
| `PeekProbe / peek-control.cfg` | The unchanged PEEK action passes the nine protocol/structural checks and the restricted `ActualPeekRetention` oracle. The tool reports 37 generated states. |
| `PeekProbe / peek-mutant.cfg` | The deliberately consuming PEEK mutant also passes all nine existing checks, including `PeekPreservesQueueRights`. The tool reports 37 generated states. |
| `PeekProbe / peek-mutant-oracle.cfg` | Adding `ActualPeekRetention` detects that same mutant at state 17: the queue is empty and consumed once, despite no ordinary receive or disposal in this driver. |

## Probe construction

`valid.ndjson` and the four rejection inputs are copied from `generation-checks/`. `overlap.ndjson` changes only two timestamps in the valid fixture: `SenderReuse.end` becomes 31 and `RecvBegin.start` becomes 28. Both timeboxes are then [28, 31]. Event identities, arguments and every captured post-state remain unchanged. Per-thread timestamps remain valid. The original source-faithful order still fits the intervals, as the witness query demonstrates.

The failing branch instead matches `RecvBegin` first. The pending `SenderReuse` requires every receiver to remain Idle and is now permanently disabled. The next receiver event starts at 32, so it must wait for the pending sender event ending at 31. `TraceStep` is disabled and weak fairness cannot force progress. A stuttering suffix therefore violates the universal temporal property. This is a synthetic partial-order test, not evidence that this exact overlap occurred in a production fixture.

`PeekProbe.tla` uses one thread, one attempt, four rights, a successful send and one full-buffer PEEK. It has no ordinary receive, cleanup or disposal. Its mutant changes the PEEK clone into a reference-preserving move that empties the queue and increments consumption. It retains the original ghost-snapshot assignments. The extra retention oracle is valid only for this restricted driver. It must not be applied globally after a later ordinary receive.

