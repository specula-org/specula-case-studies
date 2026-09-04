# Nanvix

## Scope

Specula analyzed process and thread lifecycle management in Nanvix, including
sleep, wakeup, join and detach, signal delivery and masks, mutexes and condition
variables, IPC error paths, capability updates, and MMIO ownership. The primary
reviewed run targets
[`nanvix/nanvix@a47b0904c20dbe92ede704eb5ee431a7d29fec46`](https://github.com/nanvix/nanvix/tree/a47b0904c20dbe92ede704eb5ee431a7d29fec46).

## Developer-reviewed findings

The developer review accepts 16 new bug mechanisms. Its compact source table
labels 11 entries `Confirmed` and five entries `Likely`; both labels are treated
as approval in this review. PM-13 and PM-18 are explicitly rejected and are not
counted.

| Reference | Source label | Run evidence | Finding |
| --- | --- | --- | --- |
| PM-01 | `Confirmed` | MC-1, reproduced | A condvar or join notification can be consumed without waking a sleeper embedded in an interrupted process. |
| PM-02 | `Confirmed` | MC-2, reproduced | A caught signal can starve when its only eligible recipient sleeps in a non-suspended process. |
| PM-03 | `Confirmed` | MC-3, reproduced | A terminated process can resume user code on a carried-forward interrupted thread. |
| PM-04 | `Confirmed` | MC-4, reproduced | `do_exit` can panic while waking an orphaned rendezvous peer after clearing the running slot. |
| PM-05 | `Likely` | MC-6, reproduced | `cond_wait` can return after interruption without reacquiring the caller's mutex. |
| PM-06 | `Likely` | MC-7, reproduced | An interrupted `cond_wait` reacquire can leave an orphaned mutex-map entry. |
| PM-07 | `Confirmed` | MC-8, reproduced | A masked default-action signal can be acted on immediately instead of remaining pending. |
| PM-08 | `Confirmed` | MC-9, reproduced | Changing a pending signal's disposition can strand it permanently. |
| PM-09 | `Likely` | MC-10a, reproduced | Nested `sigsuspend` handling can overwrite the saved signal mask. |
| PM-10 | `Confirmed` | CR-1, reproduced | `join_thread` reaps an exit status before a failed user copyout, preventing a retry. |
| PM-11 | `Confirmed` | CR-2, reproduced | `execv` clears process-pending signals instead of preserving them. |
| PM-12 | `Likely` | CR-3, reproduced | A caught signal without a restorer can be dropped while the temporary `sigsuspend` mask remains installed. |
| PM-14 | `Confirmed` | CR-5, reproduced | A CPU-bound thread can starve a caught signal when delivery occurs only on kernel-call return. |
| PM-15 | `Likely` | CR-6, reproduced | IPC error paths can lose a message by mutating or consuming it before a failed count or copyout. |
| PM-16 | `Confirmed, critical` | CR-7, reproduced | `capctl` allows a process to grant capabilities to itself without a privilege check. |
| PM-17 | `Confirmed, critical` | CR-10, reproduced | `mmio_free` drops ownership without revoking page-table entries, leaving a stale mapping. |

The archived Phase 4 novelty searches classified all 16 as new at the reviewed
source revision. No upstream issue or pull-request URL was supplied with the
developer disposition.

The exact disposition table, internal finding mapping, and source screenshot are
preserved in the [2026-07-29 run review](modules/process-management/runs/nanvix-pm-opus48-xhigh-20260729/review/developer-disposition.md).

## Evidence boundary

- [`nanvix-pm-opus48-xhigh-20260729`](modules/process-management/runs/nanvix-pm-opus48-xhigh-20260729/README.md)
  is the primary run behind the developer review.
- [`nanvix-pm-opus48-xhigh-20260803`](modules/process-management/runs/nanvix-pm-opus48-xhigh-20260803/README.md)
  is a later complete pipeline run against a different Nanvix revision. It
  provides overlapping follow-up evidence and is not counted as another set of
  developer confirmations.
- Generated Specula dispositions and severity labels are internal validation
  evidence. The developer disposition determines the 16-entry public count.
