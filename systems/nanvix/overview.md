# Nanvix

## Scope

Specula analyzed and tested Nanvix's process and thread lifecycle management, including sleep and wakeup, join and detach, signal delivery and masks, mutexes and condition variables, IPC error paths, capability updates, and MMIO ownership.

## Bugs

Specula found 16 new bugs: 11 marked Confirmed and 5 marked Likely by the developers:

- **Confirmed:** A condvar or join notification can be consumed without waking a sleeper embedded in an interrupted process.
- **Confirmed:** A caught signal can starve when its only eligible recipient sleeps in a non-suspended process.
- **Confirmed:** A terminated process can resume user code on a carried-forward interrupted thread.
- **Confirmed:** `do_exit` can panic while waking an orphaned rendezvous peer after clearing the running slot.
- **Likely:** `cond_wait` can return after interruption without reacquiring the caller's mutex.
- **Likely:** An interrupted `cond_wait` reacquire can leave an orphaned mutex-map entry.
- **Confirmed:** A masked default-action signal can be acted on immediately instead of remaining pending.
- **Confirmed:** Changing a pending signal's disposition can strand it permanently.
- **Likely:** Nested `sigsuspend` handling can overwrite the saved signal mask.
- **Confirmed:** `join_thread` reaps an exit status before a failed user copyout, preventing a retry.
- **Confirmed:** `execv` clears process-pending signals instead of preserving them.
- **Likely:** A caught signal without a restorer can be dropped while the temporary `sigsuspend` mask remains installed.
- **Confirmed:** A CPU-bound thread can starve a caught signal when delivery occurs only on kernel-call return.
- **Likely:** IPC error paths can lose a message by mutating or consuming it before a failed count or copyout.
- **Confirmed:** `capctl` allows a process to grant capabilities to itself without a privilege check.
- **Confirmed:** `mmio_free` drops ownership without revoking page-table entries, leaving a stale mapping.
