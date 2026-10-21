# Reproduction — MC-6

## Level 0 — public API only

- Test: `repro/test_bugMC-6_poll_timeout_race.c`.
- API sequence: `timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK)` →
  `timerfd_settime(1 ms)` → `poll(POLLIN, 1 ms)` → immediate nonblocking
  `read` when `poll` returns zero → `close`.
- No state injection, mock peer, or source patch was used. The 1 ms settings
  only make the timeout/readiness boundary likely.
- The source file was bind-mounted read-only into the initramfs source path.
  Both paths had SHA-256
  `aa222dffca87231aad4e9edf01a104b183957590f1e790da941cc7fb56bcd9a8`.

Exact target command (inside the outer `timeout 2100s docker run --rm
--privileged --network=host --device /dev/kvm` using
`asterinas/asterinas:0.18.0-20260702`, `SMP=2`, and the pinned read-only
`nightly-2026-07-21` Rustup home):

```sh
timeout 1800s make -C /source run_kernel SMP=2 CONSOLE=ttyS0 \
  ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 \
  SPECULA_INIT="/test/io/specula/run_bug.sh test_bug6_poll_timeout_race"
```

## Captured output

```text
MC6_INPUT_SHA256
aa222dffca87231aad4e9edf01a104b183957590f1e790da941cc7fb56bcd9a8  /repro/test_bugMC-6_poll_timeout_race.c
aa222dffca87231aad4e9edf01a104b183957590f1e790da941cc7fb56bcd9a8  /source/test/initramfs/src/regression/io/specula/repro/test_bug6_poll_timeout_race.c
MC6_RUSTUP
nightly-2026-07-21-x86_64-unknown-linux-gnu (default)
MC6_ENV VDSO_LIBRARY_DIR=/root/linux_vdso SMP=2
MC6_REPRODUCED attempt=0 poll_result=0 revents=0x0 ticks=1
MC6_LEVEL0_TARGET_EXIT=0
MC6_LEVEL0_HOST_EXIT=0
```

`MC6_REPRODUCED` is printed only after `poll` returned zero and the immediate
nonblocking `read` returned a complete timerfd tick. The guest runner exits
zero after printing the test output, so that runner status is not the test
oracle.

## Match and consequence

The execution matches the supplied terminal timeout/readiness race:
`do_poll` takes its `ETIME` arm at `kernel/core/src/syscall/poll.rs:108-114`
without `count_events()`, while timerfd readiness is a nonzero `ticks` value
that `TimerfdFile::poll` exposes at `kernel/core/src/time/timerfd.rs:189-204`.
The test's caller observes the wrong terminal result at
`repro/test_bugMC-6_poll_timeout_race.c:42-53`.

Correct Linux behavior is to return a positive readiness count once the
timerfd expiration is visible. Linux's `do_poll` performs a final descriptor
scan after its timed wait before it accepts the timeout result.

## Challenger Level 0 replay — ordered public-interface witness

- Test: `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugMC-6_proc_ordered_timerfd_poll.c`.
- Guest-tested SHA-256:
  `aa86dd2d88dc4a54be08c9f287cd5ed169a40fb83cfa1404e5976793bd88c026`.
- APIs: `timerfd_create`, `timerfd_settime`, `poll`, `read`,
  `/proc/<pid>/task/<tid>/status`, pthreads, and `close`. No kernel
  instrumentation, source behavior injection, mock peer, or modified kernel
  code was used.

The helper first observes the polling thread as `S (sleeping)`. It then arms
the timerfd for the final 0.5 ms of the 5 ms poll timeout. It repeatedly uses
`poll(timerfd, 0)`, which does not consume a tick, and accepts a failing
marker only if the timerfd is readable while a second status read still reports
the main thread as sleeping. The main thread then must receive `poll == 0`
and immediately read one complete tick.

Pinned guest command, run with `SMP=2`:

```sh
make -C /source run_kernel SMP=2 CONSOLE=ttyS0 \
  ENABLE_SPECULA_TRACE=true INITRAMFS_SKIP_GZIP=1 \
  SPECULA_INIT="/test/io/specula/run_bug.sh test_bug6_poll_timeout_race"
```

Captured target marker:

```text
MC6B_PROC_STRICT_REPRO attempt=0 poll_result=0 ticks=1 ready_lead_ns=-67233
```

The printed timestamp is sampled after the helper's status read, so its
negative 67.233 us difference is not the ordering oracle. The structural
oracle is stronger: the helper had already observed `POLLIN` and the target
still met Asterinas's `S (sleeping)` predicate. That predicate requires the
waiter's signalled waker and no assigned CPU, whereas `pause_timeout` clears
the waker before it can return to the caller.

Reproduction-integrity note: OSDK can reuse a bundle when only an initramfs
input changes. Replays whose embedded binary did not match the staged probe
were excluded. The accepted guest bundle was checked directly from its cpio:
it contains the `MC6B_PROC_*` strings and the original probe's
`boundary_only` result layout, matching the recorded SHA-256 source above.
The temporary source staging and bundle-cache diagnostic edits were restored;
the worktree's original test source again has SHA-256
`8700a82bb4106cc21d8773a140dbbe7650ff19e9d3516a3ec59085d9cbae7fc5`.

Linux control, compiled from the identical SHA-256 source:

```text
MC6B_PROC_NO_STRICT_REPRO attempts=1000 timeout_ms=5 confirmed=1000 armed=1000 ready_while_sleeping=190 boundary_only=0
```

The control both exercised the ordering witness and avoided the target's
zero-plus-tick result. The Level 0 target marker therefore establishes that
readiness was externally visible before the Asterinas caller received the
wrong terminal timeout result.
