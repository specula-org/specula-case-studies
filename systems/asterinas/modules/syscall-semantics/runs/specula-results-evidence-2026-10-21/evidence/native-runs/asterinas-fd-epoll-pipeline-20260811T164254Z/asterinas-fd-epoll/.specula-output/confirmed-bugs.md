# Confirmation Report — asterinas-fd-epoll

## Final Result

Reproduced bugs: 8 = 8 NEW + 0 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 0
Env-limited findings: 0
False positives: 1
Dropped: 1
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 10
Dispositions: 10 total = 8 reproduced + 0 env-limited + 0 masked + 1 false-positive + 0 needs-more-info + 1 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | MC-5 | REPRODUCED | yes |
| 6 | MC-6 | REPRODUCED | yes |
| 7 | CR-1 | FALSE POSITIVE | no |
| 8 | CR-4 | REPRODUCED | yes |
| 9 | CR-5 | REPRODUCED | yes |
| 10 | CR-6 | DROPPED | no |

## Entry 1: epoll EFAULT loses edge-triggered readiness

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: kernel/core/src/syscall/epoll.rs:129; kernel/core/src/events/epoll/file.rs:244

## Description

`MCDeliveryCommitOnCopyout` is violated: an edge-triggered entry is removed from the ready set before `sys_epoll_wait` completes user-memory copyout. A resulting `EFAULT` returns without restoring that ready epoch, so a later valid `epoll_wait` receives no event.

Upstream issue and merged/closed-PR searches found no prior report or landed fix for this pre-copyout edge-triggered delivery mechanism. The nearest epoll changes, [#1519](https://github.com/asterinas/asterinas/pull/1519) and [#1049](https://github.com/asterinas/asterinas/pull/1049), address bounds and timeout behavior, not rollback after copyout failure.

## Trigger scenario

1. Create an `eventfd`, register it with `EPOLLIN | EPOLLET`, then write `1`.
2. Call `epoll_wait` with an invalid event-buffer pointer; it returns `EFAULT`.
3. Call `epoll_wait` again with valid storage while the eventfd remains unread.
4. The expected ready event is absent.

The ready entry is dequeued in `pop_multi_ready` before the syscall copyout loop. Edge-triggered polling does not requeue it as still-ready.

## Developer intent

The implementation’s structure implies delivery should become externally observable only through successful copyout. `EpollFile::wait` returns selected events to `do_epoll_pwait2`, which then writes them to user memory. No rollback path exists for entries already removed when `user_space.write_val` fails.

## Reproduction result

The required test was written and executed: [test_bugMC-1_epoll_efault_et.c](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-1_epoll_efault_et.c:1). Its source exactly matched the staged guest test. A Linux host control retained the event:

```text
SOURCE_MATCH=yes
SPECULA_REGRESSION_PASS copyout_et
HOST_EXIT=0
```

An SMP=2 Asterinas VM booted the same public-API test and produced:

```text
mount: mounting /dev/vda on /ext2 failed: No such file or directory
mount: mounting /dev/vdb on /exfat failed: No such file or directory
SPECULA_REGRESSION_FAIL copyout_et: ready event was not retained after EFAULT
[     1.005] ERROR : Failed to power off the system because the poweroff handler fails
[     1.006] ERROR : Halting the machine...
```

The unrelated optional mount messages preceded the test result. Full captured output is in [repro_smp2_rebuilt_artifact.log](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-1/repro_smp2_rebuilt_artifact.log:1).

1. Did Level 0 or Level 1 alone trigger it? **yes**. Level 0, using only `eventfd`, `epoll_ctl`, `write`, and `epoll_wait`, triggered it on SMP=2.
2. Did Level 2 or Level 3 contribute? **No; not applicable.** No state injection or source patch was used.
3. Which real caller observes the wrong outcome? The userspace caller at [test_bugMC-1_epoll_efault_et.c:34](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-1_epoll_efault_et.c:34), whose valid second `epoll_wait` does not receive the pending event.
4. Is the bad state permanent or masked? **Permanent for the affected readiness epoch.** No downstream retry, loopback, or requeue restores it; a future independent notification may create a new edge but does not redeliver the lost one.

## Recommendation

Defer committing removal of edge-triggered ready entries until all selected events copy successfully, or restore every selected entry before returning a copyout error. Add this regression with a valid-copy control and define rollback behavior for partially copied multi-event waits.

## Debate addendum

I cannot defeat MC-1; I agree with A.

A Level-0 public-API test on SMP=2 reproduces it: the first ET `epoll_wait` returns `EFAULT`; the valid retry returns `0` while the same eventfd remains unread (`1`). LT redelivers, and normal ET delivery passes. [Challenger test](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-1_challenger.c:1) and [results](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-1/challenger-reproduction.md:1).

The model’s nine-state ET/copyout-fault trace matches the implementation: Asterinas dequeues the ready entry before `write_val`, and ET prevents requeue; there is no rollback on copyout error. [epoll.rs](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-1/worktree/kernel/core/src/syscall/epoll.rs:129) [file.rs](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-1/worktree/kernel/core/src/events/epoll/file.rs:244). Linux explicitly reinserts a selected event when copyout faults, before ET completion handling. [Linux eventpoll.c](https://github.com/torvalds/linux/blob/master/fs/eventpoll.c)

No FD reuse or unsupported interface is involved, and no automatic recovery masks the failed valid retry. No repair request is appropriate.

---

## Entry 2: epoll EFAULT disables one-shot interest before delivery

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: [entry.rs:145](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-2/worktree/kernel/core/src/events/epoll/entry.rs:145); [epoll.rs:150](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-2/worktree/kernel/core/src/syscall/epoll.rs:150)

## Description

`Entry::poll` disables a ready `EPOLLONESHOT` entry before the later fallible user-memory copyout. An `EFAULT` therefore returns without delivery, while the still-readable eventfd is disabled. This violates `MCOneShotDisabledIffDelivered`.

## Trigger scenario

Create an eventfd, register `EPOLLIN | EPOLLONESHOT`, write to it, call `epoll_wait` with an inaccessible output pointer, then retry with valid memory. The retry receives no event.

The eventfd object remains live throughout; this is not FD reuse. Linux disables one-shot interest after an event is received by `epoll_wait`, with explicit `EPOLL_CTL_MOD` rearm thereafter. [epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html)

## Developer intent

Existing coverage checks normal one-shot delivery and rearm, but not failed copyout. The adjacent source comment similarly describes rearm via `EPOLL_CTL_MOD`. Tracker and history searches found no prior report of this exact pre-copyout disable mechanism; [#1277](https://github.com/asterinas/asterinas/pull/1277) concerns different ordinary one-shot/open-file-description behavior.

## Reproduction result

Executed [test_bugMC-2_oneshot_efault.sh](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-2_oneshot_efault.sh:1) on the documented Asterinas guest recipe with `SMP=2`:

```text
SPECULA_REGRESSION_FAIL copyout_oneshot: ready event was not retained after EFAULT (errno=0)
test_exit=1
```

The test asserts the first call returned `-1/EFAULT`; the displayed failure is from the valid-buffer retry at `specula_validation.c:67`. The same public-API control on Linux produced:

```text
SPECULA_REGRESSION_PASS copyout_oneshot
```

1. Did Level 0 or Level 1 alone trigger it? **yes** — Level 0 only.
2. Level 2/3 reachability: **not applicable**; neither was used.
3. Real consumer/caller: `test/initramfs/src/regression/io/specula/specula_validation.c:67` observes the missing ready event through the public `epoll_wait` API.
4. Bad state: **permanent until `EPOLL_CTL_MOD`**. Disabled observers reject later readiness notifications; there is no automatic resend or guard that restores the event.

## Recommendation

Defer each one-shot disable until its corresponding copyout succeeds. Preserve or requeue entries not copied after `EFAULT`; handle partial multi-event copyout per event, not as one whole-vector commit.

## Debate addendum

MC-2 survives the challenge: the public Level-0 sequence reaches the claimed state and produces a persistent missing event.

- `Entry::poll` disables one-shot interest before fallible copyout; no automatic requeue exists. `EPOLL_CTL_MOD` is the only recovery path. [Investigation](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-2/investigation.md:49)
- The executed SMP=2 guest test first verified `-1/EFAULT`, then failed on the valid retry: `ready event was not retained after EFAULT`. [Guest log](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-2_oneshot_efault.final.log:425)
- My independent public-API Linux control redelivered the event after EFAULT. Linux requeues on copyout failure and disables one-shot only after successful copyout. [Control test](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-2_challenge.c:44), [Linux source](https://github.com/torvalds/linux/blob/master/fs/eventpoll.c#L1976-L2000)
- A fresh guest rerun was blocked before QEMU by TLS failures fetching `inherit-methods-macro`; it is not used as evidence. The claimed kernel paths remain unmodified.

No repair request applies: this is not a model artifact or masked condition.

---

## Entry 3: final close leaves a dead epoll interest entry

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: `kernel/core/src/events/epoll/file.rs:259`

## Description

Final close drops the watched eventfd, but its weak epoll entry remains in `interest`. Because the unread eventfd never enters the ready list, the lazy cleanup in `pop_multi_ready` never scans or removes it. `/proc/self/fdinfo/<epfd>` still reports the dead watch.

## Trigger scenario

Level 0 public API sequence:

`epoll_create1` → `eventfd(0)` → `epoll_ctl(ADD, EPOLLIN)` → final `close(watched_fd)` → read `/proc/self/fdinfo/<epfd>`.

Executed [test_bugMC-3_dead_interest.c](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-3_dead_interest.c) in the Asterinas VM with `SMP=2`; QEMU exited 0.

## Developer intent

`EntryKey` includes both FD and weak file identity to prevent FD-number reuse from retargeting a watch. That matches the intent of [Asterinas PR #1277](https://github.com/asterinas/asterinas/pull/1277) and Linux’s final-close cleanup rule documented in [epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html). Tracker search, including closed issues and merged PRs, found no report or fix for this residual stale-interest/fdinfo behavior.

## Reproduction result

Actual guest trace:

```text
[pid=1][tid=1][id=291][SYS_EPOLL_CREATE1]
[pid=1][tid=1][id=290][SYS_EVENTFD2]
[pid=1][tid=1][id=233][SYS_EPOLL_CTL]
epfd = 3, op = 1, fd = 4
[pid=1][tid=1][id=3][SYS_CLOSE]
raw_fd = 4
[pid=1][tid=1][id=257][SYS_OPENAT]
path = "/proc/self/fdinfo/3"
[pid=1][tid=1][id=0][SYS_READ]
[pid=1][tid=1][id=1][SYS_WRITE] user_buf_len = 0x2c
[pid=1][tid=1][id=1][SYS_WRITE] user_buf_len = 0x66
[pid=1][tid=1][id=1][SYS_WRITE] user_buf_len = 0x3a
[pid=1][tid=1][id=169][SYS_REBOOT]
```

The final 58-byte write is the test’s `MC-3: REPRODUCED stale interest remains after final close` branch. It is reachable solely through normal syscalls.

Checklist:

1. Level 0 alone triggered it: **yes**.
2. Level 2/3 precondition: **not applicable**.
3. Real consumer: `kernel/core/src/fs/fs_impls/procfs/pid/task/fd.rs:313`, which serves `/proc/self/fdinfo/<epfd>`.
4. Bad state: **permanent for the epoll instance** on this no-ready path. `pop_multi_ready` is the only lazy cleanup path, and no ready entry exists to invoke it.

## Recommendation

Remove interests synchronously when the final watched file reference closes, or register a final-close cleanup hook that removes the exact weak-file entry. Preserve the `(fd, file identity)` key so FD reuse remains non-retargeting.

## Debate addendum

MC-3 survives the challenge. I agree with A: it is a reproduced `/proc`-visible epoll lifecycle defect, not a stale-event or FD-reuse delivery bug.

- Reachable at Level 0: complete `EPOLL_CTL_ADD` of `eventfd(0)` for `EPOLLIN`, close its only descriptor, then read `/proc/self/fdinfo/<epfd>`. The seven-state model reaches the same dead-interest state, and the simpler sequential schedule is also real. [model config](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/MC_hunt_s2_epoll_delivery.cfg:1) [counterexample](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s2_epoll_delivery_round2_bfs.out:2599)

- There is no hidden epoll-held strong reference: the entry key, `PollHandle`, and registered observers are weak. [entry](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-3/worktree/kernel/core/src/events/epoll/entry.rs:103) [poll handle](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-3/worktree/kernel/core/src/process/signal/poll.rs:199)

- The observable wrong outcome is unmasked: `fdinfo` enumerates `interest` without filtering dead entries. The SMP=2 VM emitted `SPECULA_REGRESSION_FAIL dead_interest: closed file remains in epoll interest list`; host Linux emitted the expected pass. [dump path](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-3/worktree/kernel/core/src/events/epoll/file.rs:310) [VM manifest](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_repro_smp2_round6_manifest.txt:4) [VM output](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_test_bug4_epoll_dead_interest_smp2_round6_attempt1.log:117) [Linux control](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_host_round6.log:4)

I did not rely solely on A’s inferred console-write length. The equivalent VM test parses the exact `tfd` record, and the recorded run used `timeout 600 make run_kernel SMP=2 ... SPECULA_INIT="/test/io/specula/run_bug.sh test_bug4_epoll_dead_interest"`. [test](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/source/test/initramfs/src/regression/io/specula/repro/test_bug4_epoll_dead_interest.c:11) [command record](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec-validation.activity.attempt-2.jsonl:208)

The FD-identity guard prevents retargeting and stale readiness delivery, but it does not correct the stale `fdinfo` output. Linux removes the watch after the final descriptor for its open file description closes. [epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html) No repair request is appropriate.

---

## Entry 4: consumed timerfd remains ready through the poll cache

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/debate.md

# MC-4 — consumed timerfd remains ready through the poll cache

- **Source**: MC
- **Novelty**: NEW
- **Severity**: High
- **Location**: `kernel/core/src/time/timerfd.rs:177`

## Description

A successful `TimerfdFile::try_read` clears `ticks` but does not invalidate its `Pollee`. `Pollee::poll_with` then returns the cached `POLLIN` state without rechecking readiness. A caller observes `POLLIN`, then immediately receives `EAGAIN` from `read`.

## Trigger scenario

1. Create a nonblocking timerfd and arm a one-shot 100 ms timer.
2. Wait for `POLLIN`, then poll once more to populate the readiness cache.
3. Read the expiration count successfully.
4. Poll the same FD with timeout zero, then read again.

This is Level 0: public `timerfd_create`, `timerfd_settime`, `poll`, and `read` only.

## Developer intent

`Pollee` documents that consumers must invalidate cached readiness when an old event disappears. Timer expiration correctly notifies the Pollee, while consumed ticks do not invalidate it. Linux requires a consumed nonblocking timerfd to cease being readable; the host control test follows that behavior. [timerfd_create(2)](https://man7.org/linux/man-pages/man2/timerfd_create.2.html)

I searched upstream issues and closed/merged PRs, including the related [PR #2177](https://github.com/asterinas/asterinas/pull/2177). It does not cover timerfd consumption, and current upstream retains this missing invalidation. No prior report or landed fix for this mechanism was found.

## Reproduction result

Executed [test_bugMC-4_timerfd_cache.c](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/repro/test_bugMC-4_timerfd_cache.c) in the isolated Asterinas VM with `SMP=2`; the full guest log is [qemu.log](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/repro/qemu.log).

```text
MC4_GUEST_BOOT smp=2
MC4_LEVEL=0 public-api timerfd->poll->read->poll
MC4_INITIAL_POLL ret=1 revents=0x1
MC4_CACHE_PRIME ret=1 revents=0x1
MC4_CONSUME bytes=8 ticks=1 errno=0
MC4_POST_CONSUME_POLL index=0 ret=1 revents=0x1
MC4_POST_CONSUME_POLL index=1 ret=1 revents=0x1
MC4_POST_CONSUME_POLL index=2 ret=1 revents=0x1
MC4_POST_CONSUME_READ bytes=-1 errno=11 (Resource temporarily unavailable)
MC4_BUG_TRIGGERED stale_polls=3 while_read_is_EAGAIN
MC4_GUEST_EXIT status=0
```

## Reproduced-bug checklist

1. Did Level 0 or Level 1 alone trigger it? **yes** — Level 0 alone triggered it.
2. Level 2/3 reachability: **not applicable**; neither was used.
3. Real consumer/caller: `kernel/core/src/syscall/poll.rs:172` calls the file poll path and returns the stale `POLLIN` to the application.
4. Permanent or later masked? **Persistent for the consumed one-shot timer.** Three later polls remained stale; no guard or synchronizer repairs it. A future timer expiry could invalidate the cache, but none occurs while the one-shot timer remains unarmed.

## Recommendation

Invalidate the timerfd `Pollee` on the successful tick-consumption path, preserving existing read/copyout semantics. Keep this Level 0 regression test to require post-read `poll(0) == 0` and a subsequent nonblocking `read == EAGAIN`.

## Debate addendum

I agree with Agent A: MC-4 is a real, unmasked implementation bug.

- Independent Level-0 repro: a one-shot `timerfd` expires, is consumed, then a 75 ms `poll` immediately returns `POLLIN`; the next read returns `EAGAIN`. Linux host control correctly times out. The guest reproduced this on fresh Asterinas `SMP=2`. [reproducer](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-4_challenge.c:33) · [execution record](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/challenge_B.md:70)

- This is reachable without races, mocks, FD reuse, or source changes. The one-shot timer has no future producer to repair the stale state.

- The source mapping is direct: expiration notifies, the initial poll caches `IN`, `try_read` clears ticks without invalidating, and the next poll returns the cached event. [timerfd read](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/worktree/kernel/core/src/time/timerfd.rs:177) · [cache return](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/worktree/kernel/core/src/process/signal/poll.rs:106)

- There is no downstream guard: syscall `poll` exposes the cached event directly. This violates the timerfd/poll readiness contract. [timerfd_create(2)](https://man7.org/linux/man-pages/man2/timerfd_create.2.html) · [poll(2)](https://man7.org/linux/man-pages/man2/poll.2.html)

Phase 1 evidence and the Phase 2 challenge record are in [investigation.md](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/investigation.md:29) and [challenge_B.md](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-4/challenge_B.md:1). Relevant source files remain unmodified.

---

## Entry 5: signalfd mask update does not publish readiness

- **Finding ID**: MC-5
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: kernel/core/src/syscall/signalfd.rs:161

## Description

`MCRegisteredTransitionNotLost` is violated. Updating an existing signalfd only stores its new mask; it does not notify pollers. A previously pending `SIGUSR1` consequently becomes readable under the new mask, but epoll is not re-polled and times out.

I checked upstream issues and merged/closed PRs, including [#3655](https://github.com/asterinas/asterinas/pull/3655) and [#3656](https://github.com/asterinas/asterinas/pull/3656). Neither reports or fixes this pending-signal mask-transition notification mechanism.

## Trigger scenario

Block `SIGUSR1`; create an empty-mask signalfd; register it with level-triggered epoll; queue `SIGUSR1`; update the same signalfd mask to include `SIGUSR1`; then wait on epoll.

1. Did Level 0 or Level 1 alone trigger it — real public API / normal ops, timing help only? **yes**.
2. Level 2/3 precondition: **not applicable**; none was used.
3. Real consumer/caller: user-space `epoll_wait` at [test_bugMC-5_signalfd_mask_transition.c:59](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-5_signalfd_mask_transition.c:59), entering [kernel/core/src/syscall/epoll.rs:129](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree/kernel/core/src/syscall/epoll.rs:129).
4. The state is not automatically resolved or masked. It persists until a direct read consumes the signal or a later enqueue creates a fresh notification; the control shows that the epoll registration itself remains live.

## Developer intent

Existing-descriptor mask updates are supported by `signalfd4`. Linux makes the newly eligible pending signal observable through epoll; this is also documented by [signalfd(2)](https://man7.org/linux/man-pages/man2/signalfd.2.html). Asterinas currently updates the mask at [signalfd.rs:161](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree/kernel/core/src/syscall/signalfd.rs:161), while pollers are registered with signal queues at [posix_thread/mod.rs:266](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree/kernel/core/src/process/posix_thread/mod.rs:266).

## Reproduction result

Executed [test_bugMC-5_signalfd_mask_transition.sh](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-5_signalfd_mask_transition.sh:40) with `SMP=2`; QEMU arguments expand this to `-smp 2`.

```text
MC5_LEVEL=0 public signalfd/epoll/kill sequence
MC5_PREUPDATE_EPOLL_WAIT=0
MC5_POSTUPDATE_EPOLL_WAIT=0 events=0x0
MC5_PENDING_SIGNAL_READ signo=10
MC5_CONTROL_POSTQUEUE_EPOLL_WAIT=1 events=0x1
MC5_REPRODUCED epoll timed out while the updated signalfd was readable
```

The identical public-API test on Linux reports `MC5_POSTUPDATE_EPOLL_WAIT=1 events=0x1`.

## Recommendation

After updating an existing signalfd mask, notify or re-evaluate its registered signal-queue pollers so epoll re-polls the file under the new mask. Add this SMP=2 regression sequence to the signalfd/epoll suite.

## Debate addendum

MC-5 survives the challenge; I concur with A: it is reproduced.

- I replaced the ordering gap with an exact Level-0 public-API test: process signal queued before epoll add, empty-ready `epoll_wait(0)`, then mask update. It uses `EPOLLIN | EPOLLET`, matching the hunt config. Blocked self-`kill` takes Asterinas’s process-queue path. [test](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-5_exact_counterexample.c:30) [signal route](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree/kernel/core/src/process/kill.rs:22)

- Two SMP=2 runs gave: post-update `epoll_wait=0`, direct `poll=1`, direct read received `SIGUSR1`, and a fresh signal woke epoll. That is a caller-visible missed readiness transition, not a dead registration. [run log](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree/qemu.log:30)

- The code has no masking rescan: the mask update only stores the mask, enqueue is the notification path, and epoll waits on its ready set. [update](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree/kernel/core/src/syscall/signalfd.rs:103) [notification](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree/kernel/core/src/process/signal/sig_queues.rs:38) [epoll wait](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree/kernel/core/src/events/epoll/file.rs:225)

Linux returns `EPOLLIN` for the same test; its signalfd update explicitly wakes waiters, consistent with [upstream Linux](https://github.com/torvalds/linux/blob/master/fs/signalfd.c#L274-L279) and [signalfd(2)](https://man7.org/linux/man-pages/man2/signalfd.2.html).

Evidence is recorded in [investigation.md](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/investigation.md) and [reproduction.md](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/reproduction.md). No repair request applies.

---

## Entry 6: poll returns timeout after timerfd becomes readable

- **Finding ID**: MC-6
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: kernel/core/src/syscall/poll.rs:108

## Description

`do_poll` returns `Ok(0)` directly when `Poller::wait()` reports `ETIME`, bypassing its normal `count_events()` rescan. A timerfd expiration increments its readable tick counter, so the same descriptor can be readable immediately after `poll` reports a timeout. This violates `MCVisibleReadyWinsTerminalRace`. [poll.rs](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/worktree/kernel/core/src/syscall/poll.rs:108)

The tracker search covered open/closed issues and merged PRs. The closest result, [PR #1831](https://github.com/asterinas/asterinas/pull/1831), changed timeout accounting but did not report or fix this terminal readiness arbitration.

## Trigger scenario

Level 0 only: `timerfd_create(TFD_NONBLOCK)` → arm for 1 ms → `poll(POLLIN, 1 ms)` → immediate nonblocking `read`.

No injected state, mock, or source patch was used; the timing values only exercise the natural timeout boundary.

## Developer intent

The nearby comment says zero is correct only when timeout expires before any descriptor is ready. Linux performs a final descriptor scan after its timed wait before accepting timeout; Asterinas’s `ETIME` arm does not. [Linux do_poll](https://github.com/torvalds/linux/blob/master/fs/select.c#L902-L968)

## Reproduction result

Executed [test_bugMC-6_poll_timeout_race.c](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/repro/test_bugMC-6_poll_timeout_race.c:42) in Asterinas SMP=2 with pinned nightly-2026-07-21:

```text
MC6_REPRODUCED attempt=0 poll_result=0 revents=0x0 ticks=1
MC6_LEVEL0_TARGET_EXIT=0
MC6_LEVEL0_HOST_EXIT=0
```

The marker is emitted only when `poll` returned zero and the immediate read returned a complete timerfd tick. The caller observing the wrong result is the public-API test at `test_bugMC-6_poll_timeout_race.c:42`.

1. Level 0 or 1 alone triggered it: **yes** — Level 0.
2. Level 2 or 3: **not used**.
3. Real consumer/caller: **`repro/test_bugMC-6_poll_timeout_race.c:42`**.
4. Permanent or masked: the erroneous terminal `poll` result cannot be corrected; the timerfd tick remains until the caller consumes it. There is no automatic downstream guard or retry, so it is **not masked**.

## Recommendation

On `ETIME`, rescan `poll_files` once and return its event count if nonzero; return zero only if that rescan is empty. Add this SMP=2 timerfd deadline regression while preserving non-timeout error handling.

## Debate addendum

MC-6 survives the challenge; I agree with Agent A.

The stronger Level-0 SMP=2 witness observed timerfd `POLLIN` while `/proc` still reported the polling thread asleep, then saw `poll == 0` followed by an immediate timerfd tick read. The status-based ordering is the oracle, not its post-read timestamp. Linux control exercised 190 equivalent ready-while-sleeping cases without the bad outcome.

The model’s separated expiry/notify transition is an abstraction, but the live path is real: `pause_timeout` selects `ETIME`, then [do_poll](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/worktree/kernel/core/src/syscall/poll.rs:108) returns zero without rescanning. The caller-visible result is wrong and unmasked. This conflicts with [poll(2)](https://man7.org/linux/man-pages/man2/poll.2.html) and Linux’s final readiness scan in [fs/select.c](https://raw.githubusercontent.com/torvalds/linux/master/fs/select.c).

Evidence is recorded in [investigation.md](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/investigation.md) and [reproduction.md](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/reproduction.md). The canonical probe is [test_bugMC-6_proc_ordered_timerfd_poll.c](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-6_proc_ordered_timerfd_poll.c:77); temporary worktree staging was restored.

---

## Entry 7: captured FD operations and exec cutover may lose OFD identity

- **Finding ID**: CR-1
- **Status**: FALSE POSITIVE
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-1/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: kernel/core/src/fs/file/file_table.rs:169

## Description

CR-1 is not present. Replacement captures `Arc<FileLike>` before removing the destination slot; deferred cleanup retains the removed object rather than re-resolving its FD. A blocking `sys_read` likewise operates on its captured file object. Exec unshares the table, then removes only CLOEXEC entries.

## Trigger scenario

A second thread blocks reading pipe A. Another thread closes its numeric FD, reuses that number for pipe B with `dup2`, then writes both pipes. The test also verifies retained-duplicate identity across replacement and CLOEXEC cutover across self-exec.

## Developer intent

The shared-table lookup explicitly clones the file because operations can block. `dup_exact` and `ClosedFile` preserve object identity, while exec waits for peer threads before private-table CLOEXEC cleanup. Upstream issue/merged-PR searches found no prior report for this exact mechanism.

## Reproduction result

Executed [test_bugCR-1_ofd_identity.c](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-1_ofd_identity.c) in a local KVM Asterinas guest with `SMP=2`.

```text
CR-1 OFD identity regression start\nCAPTURE L0 old=16 raced_ebadf=0 raced_new=0 errors=0\nCAPTURE L1 old=16 raced_ebadf=0 raced_new=0 errors=0\nDUP-REPLACE PASS target=100 retained_b=41\nEXEC-CUTOVER PASS closed=100 kept=101\nCR-1 RESULT: PASS (captured and surviving descriptors kept their OFDs)\n
```

Level 0 and Level 1 both preserved pipe A for all samples. Levels 2 and 3 were not used. Details are in [investigation.md](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-1/investigation.md).

## Recommendation

No product change. Retain the regression as coverage for the identity contract.

---

## Entry 8: signalfd epoll registration may bind readiness to the wrong thread

- **Finding ID**: CR-4
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: kernel/core/src/syscall/signalfd.rs:207

## Description

CR-4 is reproduced. `SignalFile::poll` registers epoll readiness against the thread executing `epoll_ctl`, while `read` evaluates signals pending for the thread executing the read. A thread-directed signal to the later waiter is therefore directly readable but does not notify the queue registered by the original thread.

The shared FD refers to one `SignalFile`, but readiness registration is bound to thread A’s signal queues. B’s `SIGUSR1` is enqueued in B’s queue, so epoll never receives a notification. Linux exposes this as readable through epoll as well as `read`. [signalfd(2)](https://man7.org/linux/man-pages/man2/signalfd.2.html)

## Trigger scenario

Thread A blocks `SIGUSR1`, creates a nonblocking signalfd, creates epoll, and adds the signalfd. Thread B inherits the blocked mask. A sends `SIGUSR1` to B via `pthread_kill` before releasing B to call `epoll_wait`; B then performs two waits and a direct signalfd read.

The Level-0 test is [test_bugCR-4_thread_registration.c](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-4_thread_registration.c:71), executed via [test_bugCR-4_thread_registration.sh](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-4_thread_registration.sh:1) against Asterinas with `-smp 2`.

## Developer intent

Asterinas’s signalfd feature explicitly integrates with poll/epoll event loops, but the implementation history and searched upstream issues/merged PRs contain no report of this cross-thread registration mechanism. The related feature, mask, and cleanup PRs do not address it. [PR #1837](https://github.com/asterinas/asterinas/pull/1837), [PR #2245](https://github.com/asterinas/asterinas/pull/2245), [PR #3656](https://github.com/asterinas/asterinas/pull/3656)

## Reproduction result

Command:

```sh
cd .../.specula-output/repro
./test_bugCR-4_thread_registration.sh
```

Actual guest output:

```text
CR4 iteration=0 epoll_rc=0 epoll_errno=0 epoll_events=0x0 epoll_retry_rc=0 epoll_retry_errno=0 epoll_retry_events=0x0 read_rc=128 read_errno=0 signo=10 outcome=42
CR4_RESULT=PERSISTENT_MISS: two epoll_wait calls timed out while the same thread directly read its pending SIGUSR1 from signalfd
CR4_ASTERINAS_QEMU_EXIT=33
CR4_ASTERINAS_WRAPPER_EXIT=42
```

Linux control passed all eight iterations with `epoll_rc=1`, `EPOLLIN`, and a 128-byte `SIGUSR1` read.

1. **yes** — Level 0 alone triggered it through public pthread, signal, signalfd, epoll, pipe, and read APIs; no timing aid was used.
2. **Not applicable** — no Level 2 injection or Level 3 source modification was used.
3. Real consumer: thread B’s `epoll_wait` in `test_bugCR-4_thread_registration.c:71`; the kernel ready-list consumer is `kernel/core/src/events/epoll/file.rs:244`.
4. **Persistent** — both bounded waits timed out before B consumed the signal. No downstream rescan or loopback occurs without a notification; the direct read only consumes the still-pending signal to demonstrate the divergence.

## Recommendation

Register signalfd epoll observers against readiness state shared by every thread that may consume the shared signalfd, or notify the shared signalfd observer for each thread-directed queue. Do not rely on re-polling in `epoll_wait`, because that occurs only after an observer was already queued.

## Debate addendum

CR-4 survives the challenge. The public two-thread sequence is reachable, and the waiter sees a real wrong result: two `epoll_wait` timeouts while that same thread successfully reads its pending `SIGUSR1` from the shared signalfd.

The SMP=2 controls isolate registration-thread identity: B-registers/B-waits succeeds; A-registers/B-waits fails even when B already existed. Linux passes the exact cross-thread control. This matches documented signalfd/epoll and thread-directed-signal behavior. [Challenger record](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-4/challenge_B.md:12) [signalfd(2)](https://man7.org/linux/man-pages/man2/signalfd.2.html) [signal(7)](https://man7.org/linux/man-pages/man7/signal.7.html)

---

## Entry 9: epoll and mask-taking waits may bypass terminal readiness arbitration

- **Finding ID**: CR-5
- **Status**: REPRODUCED
- **Debate**: consensus in 1 round(s)
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: `kernel/core/src/process/signal/pause.rs:202`

## Description

A delayed waiter can return `ETIME` after pipe readiness occurred before its deadline. The timeout path bypasses the final readiness scan, so `epoll_pwait` and `pselect6` return `0`; an immediate zero-time retry finds the pipe ready. Temporary signal masks were restored correctly.

## Trigger scenario

A public-API child process pins to CPU 0, writes a pipe before a 200 ms deadline, then holds CPU priority long enough for the waiting parent to resume after expiry. No injected state or source patch was used.

## Developer intent

`epoll_wait`/`poll` should return zero only if no descriptor became ready during the timeout. [epoll_wait(2)](https://man7.org/linux/man-pages/man2/epoll_wait.2.html) and [poll(2)](https://man7.org/linux/man-pages/man2/poll.2.html) define readiness, signal, and timeout as the terminal outcomes. Upstream merged-PR/issue searches, including [#1831](https://github.com/asterinas/asterinas/pull/1831), [#3050](https://github.com/asterinas/asterinas/pull/3050), [#3060](https://github.com/asterinas/asterinas/pull/3060), and [#3384](https://github.com/asterinas/asterinas/pull/3384), found no prior report or fix for this arbitration mechanism.

## Reproduction result

Executed [test_bugCR-5_wait_mask.c](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-5_wait_mask.c:1) against the supplied worktree in QEMU/KVM with `-smp 2`. Full trace: [test_bugCR-5_wait_mask.smp2.log](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-5_wait_mask.smp2.log:1).

```text
CR5_PRIORITY api=epoll_pwait ret=0 errno=0 ready=0 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=382 mask_blocked=1
CR5_ANOMALY api=epoll_pwait timeout_bypassed_priority_deferred_readiness
CR5_PRIORITY api=pselect6 ret=0 errno=0 ready=0 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=381 mask_blocked=1
CR5_ANOMALY api=pselect6 timeout_bypassed_priority_deferred_readiness
CR5_RESULT FAIL failures=2
```

1. **yes** — Level 1 alone triggered it using normal scheduler and pipe APIs.
2. Not applicable: no Level 2 injection or Level 3 source patch was used.
3. The real public caller is the reproducer at [test_bugCR-5_wait_mask.c:441](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-5_wait_mask.c:441); it observes the incorrect zero return.
4. The incorrect return is irrevocable. Readiness remains level-triggered, but only a separate caller-initiated retry observes it; no downstream mechanism repairs the already-returned timeout.

## Recommendation

After a waiter returns with terminal timeout, rescan registered descriptors before converting `ETIME` to zero. Preserve the existing centralized signal-mask restoration path.

## Debate addendum

I agree with A: CR-5 is reproduced, but only as a terminal-readiness arbitration bug.

- The SMP=2 affinity claim was weak because Asterinas does not migrate threads for `sched_setaffinity`; I resolved that with a one-vCPU run. [sched_affinity.rs](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/worktree/kernel/core/src/syscall/sched_affinity.rs:33)
- The identical public-API FIFO test returned `0` on Asterinas for `epoll_wait`, `epoll_pwait`, `ppoll`, and `pselect6`, despite pre-deadline readiness; each immediate zero-time retry returned readiness. Linux returned `1` for all four. [evidence](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/investigation.md:309)
- The causal path is real: expiry is checked after wake, then propagated before the readiness closure reruns. [pause.rs](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/worktree/kernel/core/src/process/signal/pause.rs:202) [poll.rs](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-5/worktree/kernel/core/src/process/signal/poll.rs:375)
- Signal-mask restoration did not fail. The fix should preserve it and address timeout-versus-ready arbitration. I also requested a post-write timestamp in the regression.

---

## Entry 10: nested epoll cycle checks and synchronous callbacks may deadlock

- **Finding ID**: CR-6
- **Status**: DROPPED
- **Debate**: not run
- **Transcript**: /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-6/debate.md

- **Source**: Code Review
- **Novelty**: KNOWN (cite: https://github.com/asterinas/asterinas/pull/3395; fix-status: unfixed)
- **Location**: kernel/core/src/events/epoll/file.rs:65

## Description

`EpollFile::control` accepts epoll targets without self-edge or cycle rejection. Synchronous observer delivery can re-enter a ready set while its lock is held. This is an unsupported cyclic topology; no failure of the supported acyclic path was shown.

## Trigger scenario

The Level-0 test creates two epolls and an eventfd, verifies the acyclic chain, then attempts either a self-edge or two-node back-edge. It uses only normal public syscalls.

## Developer intent

`ReadySet::push` explicitly avoids one callback lock-order cycle, but does not guard ready-set re-entry. Upstream PR #3395 proposes the exact missing self/cycle checks and was closed unmerged.

## Reproduction result

Executed [test_bugCR-6_nested_epoll_cycle.c](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-6_nested_epoll_cycle.c) as a Linux Level-0 control:

```text
HOST_MODE=self
CR6 LEVEL0_START mode=self
CR6 ACYCLIC_CONTROL_OK ready=1 data=a11c events=1
CR6 SELF_EDGE_REJECTED errno=22 (Invalid argument)
HOST_MODE_EXIT=0
HOST_MODE=pair
CR6 LEVEL0_START mode=pair
CR6 ACYCLIC_CONTROL_OK ready=1 data=a11c events=1
CR6 PAIR_BACK_EDGE_REJECTED errno=40 (Too many levels of symbolic links)
HOST_MODE_EXIT=0
```

An SMP=2 Asterinas initramfs was built, but guest execution did not reach QEMU due to toolchain/dependency build failures. No Asterinas consumer-visible outcome was observed. Records: [investigation.md](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-6/investigation.md) and [reproduction.md](/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-6/reproduction.md).

## Recommendation

Do not file a duplicate. Retain CR-6 only as a reference to upstream PR #3395; its closed, unmerged status already records this exact code-review mechanism.

---
