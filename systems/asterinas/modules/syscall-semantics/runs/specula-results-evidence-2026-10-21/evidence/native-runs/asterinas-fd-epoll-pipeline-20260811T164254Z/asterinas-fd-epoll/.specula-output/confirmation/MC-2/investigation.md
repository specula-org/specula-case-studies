# Investigation — MC-2

## Scope

- Source worktree HEAD: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
- The cited `entry.rs` and `syscall/epoll.rs` paths have no local diff. Other worktree changes are pre-existing trace/test instrumentation and were not changed for this investigation.
- Dispatcher metadata identifies this as an MC finding with an actual counterexample at `spec/output/MC_hunt_s2_oneshot_round2_bfs.out`. The counterexample artifact was not opened.

## Code audit

- Public call chain: `eventfd` → `epoll_create1` → `epoll_ctl(EPOLL_CTL_ADD, EPOLLIN | EPOLLONESHOT)` → `write(eventfd)` → `epoll_wait`.
- `EpollFile::wait` collects events into a kernel `Vec` via `pop_multi_ready` before the syscall performs user-memory copyout: `kernel/core/src/events/epoll/file.rs:225-279`, then `kernel/core/src/syscall/epoll.rs:129-150`.
- `Entry::poll` observes readiness, constructs `EpollEvent`, and calls `reset_enabled` for an `EPOLLONESHOT` entry at `kernel/core/src/events/epoll/entry.rs:126-147`.
- The later `user_space.write_val` can fail while copying that already-collected event to `events_addr` at `kernel/core/src/syscall/epoll.rs:145-151`.
- The eventfd remains the same live open file object throughout this sequence; no close, descriptor reuse, duplication, or file-table identity transition is involved. The lost state is the entry observer's enabled bit, not FD-slot identity.
- A subsequent subject notification calls `Observer::on_events` and `ReadySet::push`, but `ReadySet::push` returns immediately when the observer is disabled: `kernel/core/src/events/epoll/entry.rs:280-283`, `307-318`. `Entry::update` is the re-enable path, invoked from `EPOLL_CTL_MOD`: `kernel/core/src/events/epoll/entry.rs:152-165`, `kernel/core/src/events/epoll/file.rs:181-212`.

### Trigger sequence

1. Create a nonblocking eventfd and an epoll instance.
2. Add the eventfd with `EPOLLIN | EPOLLONESHOT` and write a token to make it readable.
3. Call `epoll_wait` with an inaccessible output address. The public syscall must return `EFAULT`.
4. Retry `epoll_wait` with valid writable memory without an `EPOLL_CTL_MOD` rearm.

The reproduction source is `test/initramfs/src/regression/io/specula/specula_validation.c:36-73`: it asserts the first `EFAULT` at lines 61-64 and requires the retry to return the original token at lines 66-70. This is Level 0: no timing aid, state injection, source patch, or unsupported interface.

### Safeguards and downstream behavior

- The ordinary one-shot path deliberately disables after an event is returned and re-enables through `EPOLL_CTL_MOD`; the existing regression test records that contract at `test/initramfs/src/regression/io/epoll/epoll_err.c:145-165`.
- There is no automatic requeue/re-enable after a failed output copyout. A new readiness notification is rejected while `is_enabled` remains false. A caller can recover only by explicitly rearming with `EPOLL_CTL_MOD`.

## Developer-knowledge search

- `git blame` attributes the one-shot disable comment and branch at `entry.rs:136-146` to commits `7a13c0dff6` ("Fix behavior related to EPOLLONESHOT") and `60440d1062` ("Avoid deadlocks due to drops"). The adjacent comment names `EpollCtl::Mod` as the re-enable operation; it does not discuss copyout failure.
- The `write_val` loop at `syscall/epoll.rs:145-151` was introduced by `0b471ef370` ("Add sys_epoll_pwait2"). Its history and nearby comments do not discuss restoring collected events after `EFAULT`.
- Existing `epoll_flags_oneshot` coverage verifies normal first delivery, suppression after a delivered event, and explicit rearm. It has no invalid-output-address path: `test/initramfs/src/regression/io/epoll/epoll_err.c:145-165`.
- The historical one-shot PR [#1277](https://github.com/asterinas/asterinas/pull/1277) addressed epoll keying/open-file-description identity and ordinary one-shot behavior. Its description and changed files do not report an event being disabled before a failed `epoll_wait` copyout.

## Known status and precedent

- **Novelty: NEW.** GitHub tracker searches covered open and closed records, including recently merged PRs: `is:issue epoll` (23 results), `is:pr epoll` (62 results), `is:issue EPOLLONESHOT` (0), and `is:pr EPOLLONESHOT` (only #1277 above).
- Exact mechanism searches found `is:issue epoll_wait EFAULT` (0), `is:issue copyout` (0), and no issue or PR that reports `Entry::poll` disabling an `EPOLLONESHOT` interest before `do_epoll_pwait2` has successfully copied the event to user memory.
- The only search hits adjacent to the terms were [#3146](https://github.com/asterinas/asterinas/pull/3146), a TCP receive-ring short-read fix, and [#3382](https://github.com/asterinas/asterinas/pull/3382), a `gettimeofday` invalid-timezone-pointer fix. Neither concerns epoll or this state transition.

## Agent B adversarial audit

### Counterexample and code mapping

- The minimized trace's relevant projection is: one-shot interest capture/add, source readiness, entry update, ready-set push, `ReadySetPop`, `EntryPollPrepare`, then `DoEpollPwait2CopyoutFault` (states 2, 4-10 in `spec/output/MC_hunt_s2_oneshot_round2_bfs.out`). State 3 contains a second, uncompleted control capture; it is not needed by the public-syscall projection.
- `EntryPollPrepare` matches `Entry::poll`: it calls `file.poll`, constructs the event, and clears `is_enabled` for `ONE_SHOT` at `kernel/core/src/events/epoll/entry.rs:116-149`. `EpollFile::wait` has already removed the ready token before returning the event vector at `kernel/core/src/events/epoll/file.rs:225-280`; the subsequent `user_space.write_val` may return `EFAULT` at `kernel/core/src/syscall/epoll.rs:145-152`.
- The trace uses timerfd, while the guest test uses eventfd. Both reach the same generic `Entry::poll` path through `FileLike::poll`; neither requires a fabricated observer state or a fault injection outside the syscall interface.

### Reachability and consumer-visible state

- `test/initramfs/src/regression/io/specula/specula_validation.c:36-73` uses only `eventfd`, `epoll_create1`, `epoll_ctl`, `write`, and `epoll_wait`. It checks that the inaccessible-buffer call returns `-1/EFAULT` before it performs the valid-buffer retry.
- The persisted SMP=2 Level-0 guest output in `repro/test_bugMC-2_oneshot_efault.final.log` is:

  ```text
  SPECULA_REGRESSION_FAIL copyout_oneshot: ready event was not retained after EFAULT (errno=0)
  ```

- This failure occurs after the test resets `errno` before the retry. The ready event was never read from eventfd. `EventFile::check_io_events` treats a nonzero counter as `IN` (`kernel/core/src/syscall/eventfd.rs:104-122`), while `try_read` is the only shown path that resets it (`:124-152`).
- There is no automatic recovery path: disabled observers cause `ReadySet::push` to return before queueing (`kernel/core/src/events/epoll/entry.rs:307-318`). `Entry::update`, reached through `EPOLL_CTL_MOD`, explicitly enables and repolls the entry (`:152-165`; `kernel/core/src/events/epoll/file.rs:181-212`).

### Linux compatibility control

- Linux's `ep_deliver_event` puts the event into user memory first. On a user-copy fault it puts the item back on the scan batch and returns `-EFAULT`; it clears one-shot interest only after that succeeds ([Linux `fs/eventpoll.c:1976-2000`](https://github.com/torvalds/linux/blob/master/fs/eventpoll.c#L1976-L2000)).
- The standalone public-API control `repro/test_bugMC-2_challenge.c` compiled with `cc -std=c11 -Wall -Wextra -Werror` and ran under `timeout 30s` on the host Linux control. Its output was:

  ```text
  MC2_CONTROL_PASS first=-1/EFAULT retry=1 token=4d43325f45464155
  ```

- The control also contains a counterfactual rearm branch: if a system returns an empty retry after `EFAULT`, it issues `EPOLL_CTL_MOD` and requires the still-readable eventfd to be reported. This separates loss of epoll interest from consumption of the eventfd value.

### Re-run status

- I reran the supplied SMP=2 wrapper with an outer `timeout 25m`. Its build stopped before QEMU because Cargo could not fetch the pinned `inherit-methods-macro` revision after TLS and connection failures. This is an environment failure, not a result used for the finding; the existing final guest log above is the executed Asterinas evidence.
