# Flock lane candidate ledger (final, 2026-10-09)

Run `asterinas-local-flock-ownership-20261004T160159Z`, Asterinas
`0c60537098f4c2949ad2d382aaf499de72263d76`, model revision 1. Paths are
relative to the run's `asterinas-local-flock-ownership/.specula-output/`
unless they are absolute. The coordinator assigned AST-84..89 on 2026-10-11.
The 2026-10-12 local audit resolves FL-CR-1 to CR-4 / AST-89 below. The proposed
text at the end is retained as the historical 2026-10-09 draft.

| Lane ID | AST | Mechanism | Disposition | Evidence |
|---|---|---|---|---|
| MC-1 (FL-SQ-1, FL-TV-1, FL-MC-1; C05, C06) | AST-84 | `FlockList::try_set_lock` checks for conflicts before replacing the caller's own old item, so a conflicting SH→EX conversion keeps the old SH. Linux removes it first (`fs/locks.c:1101–1125`). | **Confirmed implementation bug.** Linux compatibility, local denial of progress, no security impact shown. Specula rates it Critical. | `confirmation/MC-1/reproduction.md`, `repro-guest-run2.log`, `repro-guest-run3.log`, `repro-linux-control.log`, `repro/test_bugMC-1_flock_conversion_retention.c`, `spec/output/round1-20261005T202037Z/MC_hunt_2_conversion_oracle-bfs.log`, `MC_hunt_2_converters-bfs.log` |
| MC-2 (FL-SQ-2, FL-TV-2, FL-MC-2; C11) | AST-85 | `FlockList::unlock` upgrades a Weak owner while it holds the list Mutex. A concurrent `close()` can make that temporary Arc the last reference. Dropping it then runs `InodeHandle::drop` → `unlock_flock` on the same non-recursive Mutex. | **Confirmed implementation bug.** Local denial of service on an inode's flock and close paths. Specula rates it Critical. Cross-user impact was not demonstrated. | `confirmation/MC-2/investigation.md`, `issue.json`, `repro/mc2-run-20261005T235447Z/MC2-L0.log` (no gate, `deadlock: true`), `MC2-L1.log` (gated, `deadlock: true`), `MC2-L1-ctl.log` (alias control, no deadlock), `repro/mc2-run-plain-20261005T235758Z/MC2-L0-plain.log` (not hit in 128 crossings), `spec/output/round1-20261005T202037Z/MC_hunt_5_temporary_last_reference-bfs.log` |
| CR-1 | AST-86 | Ownership across independent opens and aliases. | False positive. | `confirmation/CR-1/` |
| CR-2 (Scenario 3; C07–C09) | AST-87 | Waiter registration, notification and retry against a new blocker. | False positive, after three runs. The intermediate hangs came from the agent's own test-gate fixtures. | `confirmation/CR-2/`, `…/flock/findings-attempt1-leftover-guest/`, `…/flock/findings-attempt3-leftover-guest/` |
| CR-3 (Scenario 4) | AST-88 | The last FD removal is not the final OFD release. | False positive. The behavior matches Linux OFD lifetime. | `confirmation/CR-3/` |
| CR-4 | AST-89 | Extra wake and retry. | False positive. Intended behavior with negligible cost. | `confirmation/CR-4/` |
| FL-CR-1 | AST-89 (same as CR-4) | A successful request's Drop drains the queue outside the list Mutex while losers re-enqueue. | Final FALSE POSITIVE record for the same mechanism and claimed scheduling impact. The source-only question is an earlier stage of CR-4, not another open finding. | `analysis-report.md` FL-CR-1, `modeling-brief.md` §6.3, `confirmed-bugs.md` Entry 6, `confirmation/CR-4/` |
| MC-2 plain-L0 side observation | — | A freeze in unrelated waits while the flock Mutex was free. The agent attributes it to the lost-wakeup family of upstream issue #3283. | Unverified lead with its source recorded. It is outside the signal-free contract, was not analyzed further, and is not a new finding. | `confirmation/MC-2/investigation.md` (Escalation ladder), `repro/mc2-run-plain-20261005T235758Z/MC2-L0-plain.log` |

Bounded non-findings: 13 clean hunts and 18 accepted traces. `MC.cfg` showed
no violation in its 30-minute budget, but that search is incomplete. Pipeline
stages completed; campaign-wide critical-interleaving coverage did not.

## Historical proposed catalog text (2026-10-09, superseded)

Use the [current catalog](../../asterinas-bug-findings-2026-08/README.md) and
[ID map](../../asterinas-bug-findings-2026-08/id-map.md) for assigned IDs and
evidence qualifications. The draft below records the original handoff only.

AST register rows:

```markdown
| AST-NEW-FL1 | Local flock: a conflicting SH→EX conversion keeps the caller's old SH lock | Confirmed implementation bug (Linux compatibility); local denial of progress, no security impact shown | `asterinas-local-flock-ownership-20261004T160159Z` MC-1 | Level 0 reproduction on Asterinas 0c605370 (SMP 2, ramfs): after A's EX\|NB fails and B unlocks, C's EX\|NB returns EAGAIN, while Linux 7.2.8 returns success. Two blocking SH→EX converters both stay parked; on Linux one completes. Model: C05 `ConversionOracle`, C06 `ConvertersDrain`. Specula severity Critical; workspace assessment: compatibility with local progress impact. |
| AST-NEW-FL2 | Local flock: a temporary owner Arc dropped under the list Mutex re-enters unlock and self-deadlocks | Confirmed implementation bug; local denial of service on the inode's flock/close paths | `asterinas-local-flock-ownership-20261004T160159Z` MC-2 | Model C11 `NoRecursiveListWait` (34 states). Runtime on 0c605370, SMP 2: pure syscall race with trace observers deadlocked after 3 crossings (no gate, no injection); the gated run reproduces it deterministically; the extra-alias control does not deadlock; the plain run did not hit in 128 crossings (window of tens of ns). Specula severity Critical; cross-user impact not demonstrated. |
```

Old-ID map rows (`id-map.md`; these replace the two unassigned FL-SQ rows):

```markdown
| `asterinas-local-flock-ownership-20261004T160159Z` | FL-SQ-1 / MC-1 | AST-NEW-FL1 | Failed or blocked mode conversion keeps the previous SH ownership. |
| `asterinas-local-flock-ownership-20261004T160159Z` | FL-SQ-2 / MC-2 | AST-NEW-FL2 | Last temporary owner reference and destructor re-entry during release. |
| `asterinas-local-flock-ownership-20261004T160159Z` | CR-1, CR-2, CR-3, CR-4 | Unassigned (false positive) | Code-review candidates dismissed by confirmation. |
```

Run entry (replaces the PREPARED row):

```markdown
| Local flock: `asterinas-local-flock-ownership-20261004T160159Z` | `0c60537098f4c2949ad2d382aaf499de72263d76` | COMPLETE on 2026-10-09. Analysis PASS 34/35; spec PASS 40/40 after one reviewed revision; 18 runtime traces accepted (user-ratified existential adapter); validation PASS; MC.cfg time-limited. MC-1 (AST-NEW-FL1) and MC-2 (AST-NEW-FL2) reproduced; CR-1..4 false positive. | [Lane result](../flock-wait-handoff-2026-10-05/flock/result.md) |
```
