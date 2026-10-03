# Specula Summary

## Result

- Run status: **Complete**

V01 has two reproduced defects: a released-versus-applied configuration boundary and joint-snapshot recovery that discards the outgoing quorum. Five other dispositions are retained separately.

## Findings

- **CR-3 — Advance releases the configuration admission guard before ApplyConfChange** — Status: `REPRODUCED`. Impact: two membership changes can commit before the first becomes effective. Evidence: exercised through the public Node API with the second change committed before the first callback.
- **MC-1 — Joint snapshot recovery drops the outgoing quorum** — Status: `REPRODUCED`. Impact: a recovered node can elect a leader without the persisted outgoing configuration's majority. Evidence: exercised through public RawNode, snapshot, restart, and message-delivery operations.
- Other dispositions: 5.

## Validation limits

- Some prior findings still lack current public-interface confirmation and are not counted as reproduced bugs.
- Bounded model checking did not establish exhaustive safety or liveness.


## Run coverage

- Model generation and checking ran automatically; confirmation and publication were completed manually after provider interruptions.
- Recorded resource totals exclude untracked manual completion work; incomplete accounting does not mean the manually finalized CI result is missing.

## Run details

| Item | Value |
|---|---|
| Target | etcd-raft |
| Original source commit | 16c5274b589aa75c634a1a5f2b05cf66aaf37dcc |
| Current attempt source commit | 16c5274b589aa75c634a1a5f2b05cf66aaf37dcc |
| Agent / model | codex / gpt-5.6-sol |
| Reasoning effort | xhigh |

## Detailed reports

- CI verdict: **FAIL** ([finding dispositions](ci-verdict.json))
- [Incremental CI report](ci-report.md)
- [Confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)

## Resource usage

| Phase | Runtime | Tokens | Estimated cost |
|---|---:|---:|---:|
| Incremental workflow | 2h 37m | 59.2M total (58.2M cached) | $29.19 |
| **Total (incomplete)** | 2h 37m | 59.2M total (58.2M cached) | $29.19 |

- Configured maximum parallelism: 1 workflow Agent
- Configured TLC limits: 200G memory; 60 workers
