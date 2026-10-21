# Asterinas

## Scope

The [October results and evidence collection](modules/syscall-semantics/runs/specula-results-evidence-2026-10-21/README.md) covers Linux file I/O and shared offsets, ramfs/ext2/exFAT consistency, epoll/poll/timerfd/signalfd readiness, memfd mapping admission, futex requeue, SCM_RIGHTS publication, flock ownership, and wait/reap behavior. It also preserves interface-audit source leads and independent kernel/device tests.

Early mutex, reader-writer mutex, spinlock, and SPSC ring-buffer experiments recorded no bugs in their respective scopes. The [September collection](modules/syscall-semantics/runs/asterinas-findings-pack-2026-09-24/README.md) remains available as an unchanged historical snapshot.

## Findings

The [current index](modules/syscall-semantics/runs/specula-results-evidence-2026-10-21/FINDINGS.md) contains **76 selected tracking entries** from a 93-entry source catalog. Seventeen false-positive, unsupported-operation, dropped, or model-error records are excluded from this tracking set; their source dispositions are retained in the evidence archive.

| Evidence | Entries |
|---|---:|
| Native confirmation, deduplicated by AST | 31 |
| Independent kernel/device runtime records | 2 |
| Outcome-only wait/reap observations | 2 |
| Source leads | 40 |
| MASKED | 1 |

The tracker snapshot has **28 Confirmed, 7 Fixed, and 41 blank statuses**, classified as **61 New and 15 Known**. Existing higher tracker labels are retained; evidence and complete upstream repair coverage are recorded separately. These counts are not completed protocol proofs or a count of independently verified security vulnerabilities.

Eleven selected records are new since September: AST-73/74/75, AST-79..82, AST-84/85, and AST-92/93. AST-32 and AST-36 now have native SCM_RIGHTS confirmations. [Individual records and structured metadata](modules/syscall-semantics/runs/specula-results-evidence-2026-10-21/findings.json) preserve each entry's aliases, confirmation models, dates, and qualifications.

## Upstream repairs

As checked on 2026-10-21, complete merged repairs cover AST-07 ([#3959](https://github.com/asterinas/asterinas/pull/3959)), AST-14 ([#3875](https://github.com/asterinas/asterinas/pull/3875)), AST-19 ([#3984](https://github.com/asterinas/asterinas/pull/3984)), and AST-62 ([#3824](https://github.com/asterinas/asterinas/pull/3824)). PR #3875 also covers AST-02's empty-write subcase, while nonempty zero-progress faults remain outside it. AST-05/10's PR [#3778](https://github.com/asterinas/asterinas/pull/3778) remains open. Their retained tracker labels do not change these repair facts.

## Evidence

Use the [run index](modules/syscall-semantics/runs/specula-results-evidence-2026-10-21/RUNS.md) for 50 recorded run identities and eight native final confirmation reports. The published subset includes models, harnesses, scenario traces, reproducers, runtime logs, and provenance hashes. No experiment was rerun during archival.

The [qualification guide](modules/syscall-semantics/runs/specula-results-evidence-2026-10-21/REMAINING.md) retains incomplete reviews and searches, limited concurrency coverage, timing assistance, the wait/reap outcome-only boundary, and corrected novelty claims. Original reports are preserved rather than silently rewritten.
