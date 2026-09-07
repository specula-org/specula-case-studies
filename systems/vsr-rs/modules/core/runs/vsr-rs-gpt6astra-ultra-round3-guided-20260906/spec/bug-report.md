# Bug Report — vsr-rs

## Summary

**INCOMPLETE: trace validation passed; MC.cfg timed out; the spec has not converged and bug hunting was not started.** This is an interim report of an inconclusive validation run, not a completed no-bug result.

- Source revision: `3ac0104a567092139534c9022205d02281a2da41`. The preexisting Phase 2.5 instrumentation was preserved.
- Implementation traces: **7/7 passed**, 884 records, 33 event types including Init. TraceMatched and full normalized post-state checks remained active. The installed `run_trace_validation_parallel` Python handler was used directly because this session did not expose the MCP transport. Parsed per-trace outcomes, commands and hashes are in [trace-round1.json](output/trace-round1.json); raw logs are `output/specula_*.round1.tlc.log` (for example [rolling recovery](output/specula_rolling_recovery.round1.tlc.log)).
- Phase 2: unchanged **MC.cfg**, BFS, 64 workers, 48 GiB heap + 96 GiB off-heap, managed **30-minute timeout**. No invariant violation was observed. Last periodic observation at **2026-09-06 10:30:14 UTC**: **1,260,140,453 generated, 216,199,137 distinct, depth 22, 96,919,949 queued**. These are last reported counts, not an exhaustive diameter or necessarily exact exit counts.
- Convergence: **not achieved**. Hunting configurations completed: **0/7**. No Case A/B repair or MC Case C finding was established.
- `findings.json` contains zero **MC findings from this incomplete run**. It does not mean all hunting scenarios passed. The integration evidence below is retained implementation evidence and is not relabeled as a newly discovered MC counterexample.

## Workflow decision

The installed validation workflow requires Phase 2 to complete before Phase 3, and hunting explicitly has the precondition: **"Spec has converged (Phase 3 passed)."** The 30-minute rule ends this run; a timeout with a nonempty queue does not satisfy that precondition. No configuration bound, safety oracle, transport assumption, or phase gate was relaxed. Repeating the same fresh BFS would revisit the same shallow prefix and does not establish completion.

Methodology: Specula validation workflow. Machine-readable execution state:
[validation-status.json](validation-status.json).

## Model-checking evidence

Enabled `MC.cfg` invariants: `CommittedPrefixAgreement`, `DistinctQuorumAndPrimary`, `NoAssertionFailure`, and `MCTypeOK`. This configuration has one crash, two invocations and no integration framing. The extension invariants and broader crash/view-change/liveness combinations in hunting configs were not checked by this run.

Raw logs: [MC_round1b.out](output/MC_round1b.out), [managed launch/wait log](output/MC_round1b.driver.log), [periodic progress](output/MC_round1b.progress.json). The first launch exited before initialization (cause not established) and is retained in `output/MC_round1.out`; it is not counted as a checking run. The successful launch kept the prescribed PID waiter and launcher in one bounded foreground command. The provider interruption did not stop or restart TLC: the same wrapper PID 1103522 continued, and its waiter was reattached ([resumed wait](output/MC_round1b.resumed-wait.log)). The standard background wrapper writes overlapping header/progress copies to its raw log; the raw bytes are preserved and the progress JSON deduplicates exact repeated observations only.

## Retained integration finding: incomplete peer frame becomes a successful altered write

This run re-audited a maintainer-actionable **kvstore integration data-integrity defect** already established by the supplied implementation experiments. `run_peer_acceptor` uses `lines()` and accepts a nonempty unterminated line at clean EOF (`examples/kvstore/main.rs:397-411`). A strict prefix of a valid PREPARE ending inside its final PUT value is still accepted by `decode` (`237-254`). The core library receives an already-altered typed operation; it is not a core protocol defect under intact-message delivery.

The verified byte evidence contains **1,794,048 surviving bytes** from the unchanged sender's **33,554,458-byte encoded body**, with no newline. The value becomes **1,794,022 of 33,554,432 bytes**. These are every byte surviving the actual sender interruption, not an arbitrarily selected substring. A separate acceptor connection forwards all those bytes unchanged. Complete fragmented forwarding preserves content; the synchronized reset/read-error case dispatches nothing. EOF after the complete payload, before only its newline, is content-preserving.

The freshly validated EOF trace preserves the original Put(AA), admits Put(A), commits A after view change, accepts the original client's success, and returns A to a different client's later Get; the recovered replica retains A. Duplicate Prepare processing keeps an existing slot (`lib.rs:716-730`), so retransmission is not an unconditional repair. With one successful write and no intervening write, the later read has no legal sequential explanation.

An independent retained three-binary experiment sends a real 16 MiB SET, briefly deschedules the receiver, crashes the original primary during its write, resumes the receiver, observes **+OK**, then issues a fresh-connection GET returning a **2,623,764-byte strict prefix of 16,777,216 bytes**. Its binary, driver, result and process logs match their recorded hashes. That run does not retain a raw peer/EOF capture; the separately audited sender/acceptor experiment establishes the framing mechanism. Neither experiment was re-executed in this Phase 3 validation.

Full sequence, source anchors, bytes/hashes, independent-route limits and repair direction: [integration-evidence.md](output/integration-evidence.md), [evidence-audit.md](output/evidence-audit.md). Require a complete delimiter-terminated frame before decoding; combining two writes does not make TCP transmission atomic. Other reply/log-frame variants remain unconfirmed and are not counted as additional findings.

## Not Reproduced

The table records **unexecuted** hunting configs, not no-violation passes.

| Config | States explored by this phase | Result |
|---|---:|---|
| `MC_hunt_s1_eof_client_result.cfg` | 0 (not run) | Not run: convergence precondition unmet |
| `MC_hunt_s1_eof_prefix.cfg` | 0 (not run) | Not run: convergence precondition unmet |
| `MC_hunt_s2_rolling_history.cfg` | 0 (not run) | Not run: convergence precondition unmet |
| `MC_hunt_s3_recovery_views.cfg` | 0 (not run) | Not run: convergence precondition unmet |
| `MC_hunt_s4_partial_publication.cfg` | 0 (not run) | Not run: convergence precondition unmet |
| `MC_hunt_s5_stable_minority.cfg` | 0 (not run) | Not run: convergence precondition unmet |
| `MC_hunt_s5_stable_recovery.cfg` | 0 (not run) | Not run: convergence precondition unmet |

## Coverage and assurance limits

- The finite rolling trace covers recovery during view change, authentic response overwrites, sequential recoveries of all three replicas, cross-client order, and partial publication after persistence. None is a general safety proof.
- The actual minority trace skips unavailable primary 1 with healthy replicas {0,2} and continues serving requests. The supplied S5-minority hunt instead uses healthy {1,2} and cannot cover skipping a future unavailable primary. Its liveness premise is a synchronous drain/tick subcase with three total calls, not an infinite-work theorem.
- DVC quorum omission and response-map overwrite are faithfully modeled, including the actual persisted-floor and exact latest-primary guards. No core bug follows merely from those implementation choices.
- The history observer checks installations; it is not a direct recoverability oracle over every set of current replica/buffer states. N=2 trace coverage has zero failure budget, with no one-crash availability claim.
- Novelty exclusions were preserved. No simulator was run, no Rust regression or fix commit was created, and no external issue/PR/message was published.

Detailed question mapping: [coverage-assessment.md](output/coverage-assessment.md), [core-audit.md](output/core-audit.md). Original inputs and hashes: [initial-manifest.json](output/initial-manifest.json). Final bindings: `output/final-manifest.json`.
