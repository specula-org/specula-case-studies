# Specula Summary

## Result

- Run status: **Complete**

The report records five reproduced bugs, no masked or environment-limited findings, and one other disposition. The reproduced results affect election safety, client proposal handling, membership-change ordering, and read authorization.

## Findings

- **CR-1 — Protocol promises cross Ready, durability, and recovery boundaries** — Status: `REPRODUCED`. Impact: Restarting with a persisted vote but an empty log can permit a second vote in the same term, allowing two candidates to become leaders. Evidence: A public RawNode API test persisted both votes and observed both candidate nodes become leaders.
- **CR-2 — Election and transfer eligibility depend on local configuration progress** — Status: `REPRODUCED`. Impact: Leadership transfer can elect a node awaiting its own removal, which then remains leader after removal and rejects client proposals. Evidence: A protocol test controlled removal-application timing and observed a proposal rejection from the removed leader.
- **CR-3 — Released application work and effective membership are different state** — Status: `REPRODUCED`. Impact: A second membership change can be committed before the first becomes effective, and the application can apply both without subsequent revalidation. Evidence: A public Node API test delayed membership application and observed the second committed configuration entry in Ready.
- **CR-5 — ReadIndex evidence must survive membership and application interleavings** — Status: `REPRODUCED`. Impact: A removed leader can return an old read basis after the remaining node has applied a newer value. Evidence: A public RawNode API test delayed heartbeat messages and observed the old ReadState reach the application.
- **CR-6 — Admission, rejection, cancellation, and retry are protocol outcomes** — Status: `REPRODUCED`. Impact: Node.ProposeConfChange can report success for a rejected membership proposal that never reaches Ready, with no automatic retry or correction of the returned result. Evidence: A public API test exhausted proposal quota and observed success despite the missing configuration entry.
- Other dispositions: 1.

## Validation limits

- The election-recovery result requires persisted term and vote state with an empty log; the transfer and membership-ordering results used controlled delays in applying configuration changes.
- The read request preceded leader removal and the newer write; the observed old read basis reached the application after that write. Later CheckQuorum step-down may occur but does not revoke the emitted ReadState.
- The removed leader's proposal failures persist until another leadership change. The proposal-result test used exhausted quota while application consumption of Ready was delayed.


## Run coverage

- Independent reviews were not run.

## Run details

| Item | Value |
|---|---|
| Target | etcd-raft |
| Original source commit | 98047a97b87252c328c9c6eee3fe72671d23a785 |
| Current attempt source commit | 98047a97b87252c328c9c6eee3fe72671d23a785 |
| Agent / model | codex / Varies by task |
| Reasoning effort | xhigh |

## Detailed reports

- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Phase 1 | 45m 57s | 10.8M total (10.0M cached) | $20.24 |
| Phase 2 | 50m 10s | 5.8M total (5.5M cached) | $11.71 |
| Phase 2.5 | 1h 13m | 9.4M total (9.1M cached) | $16.29 |
| Phase 3 | 1h 46m | 22.0M total (21.4M cached) | $31.32 |
| Phase 4a | 19m 7s | 12.3M total (11.3M cached) | $14.47 |
| Phase 4b | 3m 50s | 188.2K total (122.9K cached) | $1.04 |
| **Total** | 4h 59m | 60.4M total (57.5M cached) | $95.07 |

- Configured maximum parallelism: phase defaults (ordinary phases 1 at a time; per-finding confirmation 4 at a time)
- Configured TLC limits: 200G memory; 60 workers
