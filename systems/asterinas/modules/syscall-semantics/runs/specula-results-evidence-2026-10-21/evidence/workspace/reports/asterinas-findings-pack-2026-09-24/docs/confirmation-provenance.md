# Who confirmed each finding

This page says how much trust each REPRODUCED or MASKED entry has earned. It
separates three kinds of evidence: Specula's automated confirmation phase,
human intervention needed to get that phase to finish, and later checks run
outside Specula. Source leads and TLPI entries never reached confirmation and
are not listed.

## Specula's confirmation phase (Phase 4a)

Every REPRODUCED, MASKED, FALSE POSITIVE and DROPPED verdict from the four
Specula runs was written by Specula's own confirmation agents into
`confirmation/<ID>/verdict.json`. No verdict was written or edited by hand.
The agents wrote the reproducer, ran it in a QEMU guest, and in most cases ran
a Linux control. Only GLM MC-4 (AST-03's rediscovery) ended without a verdict
(INCOMPLETE).

| Run | Confirmation model | Challenge | Entries | Human intervention needed to finish the phase |
|---|---|---|---|---|
| FD & epoll | Codex `gpt-5.6-terra` | A/B debate, one challenger round per positive verdict | AST-16..23, AST-28, AST-29 | The first launch produced 8 verdicts. CR-5 exhausted its policy retries on Daybreak blocks and a BrokenPipe killed the pipeline. A relaunch under `setsid` produced CR-5 and CR-6. |
| Short I/O & offsets | Claude Opus 5 | A/B debate, one round | AST-01..06, AST-24, AST-26 | Attempts 1 to 3 failed (orphaned lock, non-git source, map check). `is_git` was edited by hand in `source-map.json`, and attempt 4 finished. |
| Short I/O & offsets, repeat | GLM-5.3 via pi | A/B debate, one round | AST-09, AST-27, and rediscoveries of AST-01/04, 02, 05 | About six launches, a `PI_DEADLINE` timeout wrapper, and a pi `developer`-role setting. MC-4 stayed INCOMPLETE. |
| File size & reads | Kimi-K3 via pi | **Debate off. Each verdict comes from a single agent.** | AST-10..15, and rediscoveries of AST-02 and AST-05 | The first pass left all 10 INCOMPLETE (non-git source). Five resumes followed. |

Two File size & reads reproductions needed timing help. AST-11 (MC-3) did not
trigger in 500 unassisted trials and reproduced only with a kernel timing
hook. AST-10 (MC-1) used userspace timing assistance.

## Checks outside Specula

These ran in separate agent sessions directed by the user after the pipeline
finished.

| Entries | Check | Result |
|---|---|---|
| AST-01..06, AST-09 | Re-run of the unmodified reproducers on Linux 7.1.9 and on Asterinas at `604948581`, SMP=2, 2026-09-02 | All 7 reproduced on Asterinas and passed on Linux |
| AST-01..06 | A/B of the 01a v5 fix series | Reproduced before the fix and not after |
| AST-02 (01b MC-6) | A/B of the empty-write guard | `BUG_TRIGGERED` before, `MC6_RESULT OK` after |
| AST-11 | A/B of `fix/exfat-write-size-race`, 2026-09-14 | 65 to 93 of 2000 rounds bad before, 0 after |
| AST-16..20 | Independent review of the evidence by a separate `gpt-5.6-terra` agent (no re-run) | All five accepted |
| AST-21 | Same review | Held ambiguous at first. Later ordering probes kept the finding. |
| AST-07, AST-08 | Not from Specula (external packages at `4c1fdd1e4`). Re-run of the ktests at `604948581`, 2026-09-02 | AST-08 reproduced. AST-07's wrong answers reproduced, but the reported kernel death did not. |

A human reviewer on asterinas/asterinas#3778 independently pointed out the race
behind AST-10.

## Specula's verdict only

AST-12, AST-13, AST-14 and AST-15 (File size & reads, single-agent verdicts)
and AST-22 and AST-23 (FD & epoll CR-4 and CR-5) have no check beyond
Specula's own confirmation. AST-14's fix has passed static checks only.
Re-run these before relying on them.
