# MC-4 challenger record — Agent B

## Phase 2: reproduction

Source tested: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.

Reproducer: `../../repro/test_bugMC-4_challenge.c`. It uses only the public
`timerfd_create(2)`, `timerfd_settime(2)`, `poll(2)`, and `read(2)` interfaces:

1. Create a nonblocking, close-on-exec timerfd.
2. Arm a one-shot 100 ms timer.
3. Poll until it reports `POLLIN`, then consume its eight-byte counter.
4. Poll for 75 ms, then attempt a second nonblocking read and a zero-timeout poll.

There is one thread, no source mutation, mock, fault injection, or timing
extension. The timer is one-shot, so no later producer can repair the state.
No descriptor is closed, duplicated, or reused: every syscall addresses the
same live timerfd and its same `TimerfdFile`/`Pollee`. FD-slot identity is
therefore not a confounder in this finding.

Concrete Rust sequence:

1. The expiration closure increments `ticks` and calls `Pollee::notify(IN)`
   (`time/timerfd.rs:102-105`), invalidating any prior cache.
2. The initial syscall poll invokes `TimerfdFile::poll`, whose `poll_with`
   check observes nonzero ticks and caches `IN` (`timerfd.rs:189-204`,
   `process/signal/poll.rs:125-151`).
3. The successful nonblocking file read calls `try_read`, which atomically
   clears ticks but does not invalidate the `Pollee` (`timerfd.rs:177-186`).
4. The following poll takes the nonnegative cache branch without checking
   ticks (`process/signal/poll.rs:106-110`) and syscall poll returns that event
   directly in `pollfd.revents` (`syscall/poll.rs:165-185`).

### Escalation ladder

Level 0 passed in the isolated Asterinas VM with `SMP=2`; Levels 1–3 were not
needed. The host run is a control, not a substitute for the guest result.

Commands executed (with `REPRO` set to
`/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro`):

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror "$REPRO/test_bugMC-4_challenge.c" \
  -o "$REPRO/test_bugMC-4_challenge.host"
timeout 10s "$REPRO/test_bugMC-4_challenge.host"

timeout 3m docker run --rm --privileged --network=none --device /dev/kvm \
  -v "$REPRO:/root/repro:ro" asterinas/asterinas:0.18.0-20260702 \
  /usr/local/qemu/bin/qemu-system-x86_64 \
  -cpu Icelake-Server,+x2apic -machine q35,kernel-irqchip=split \
  -smp 2 -m 8G -bios /root/ovmf/release/OVMF.fd -accel kvm \
  -boot order=d -cdrom /root/repro/test_bugMC-4_challenge-smp2.iso \
  -nographic -display none -monitor none -serial stdio -nic none -no-reboot \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
```

Host control:

```text
MC4B_LEVEL=0 public-api one-shot timerfd/poll/read
MC4B_INITIAL poll=1 revents=0x1
MC4B_CONSUME bytes=8 ticks=1 errno=0
MC4B_POST_READ_TIMED_POLL poll=0 revents=0x0
MC4B_POST_READ bytes=-1 errno=11 (Resource temporarily unavailable)
MC4B_POST_READ_ZERO_POLL poll=0 revents=0x0
MC4B_NO_STALE_READINESS timed_poll=0 zero_poll=0
MC4B_HOST_EXIT=1
```

Fresh Asterinas guest, booted with `-smp 2`:

```text
MC4B_GUEST_BOOT smp=2
MC4B_LEVEL=0 public-api one-shot timerfd/poll/read
MC4B_INITIAL poll=1 revents=0x1
MC4B_CONSUME bytes=8 ticks=1 errno=0
MC4B_POST_READ_TIMED_POLL poll=1 revents=0x1
MC4B_POST_READ bytes=-1 errno=11 (Resource temporarily unavailable)
MC4B_POST_READ_ZERO_POLL poll=1 revents=0x1
MC4B_BUG_TRIGGERED timed_poll_reported_readiness_then_read_eagain
MC4B_GUEST_EXIT status=0
```

The QEMU process exited 33 after the guest's debug-exit shutdown; the guest
test itself reported status 0. The initramfs and ISO used for this run are
`../../repro/test_bugMC-4_challenge-smp2.cpio` and
`../../repro/test_bugMC-4_challenge-smp2.iso` (SHA-256
`cf07737f115975a81af74f8a989c55a548b561cd36d0c68a4d6b1e4f2b33237b` and
`c7df157d674cb361b9b61456cb3766532e49928065fc099add94be72e2c1d042`,
respectively).

Both command results above were repeated on 2026-08-13. The host control again
exited 1 after `MC4B_NO_STALE_READINESS`; the fresh guest boot again printed
`MC4B_BUG_TRIGGERED` and `MC4B_GUEST_EXIT status=0`.

### Consequence and contract comparison

The timed 75 ms poll should wait or time out after the successful read. Instead
it immediately gives the caller `POLLIN`; the immediately following read then
returns `EAGAIN`. This is an observable wrong outcome, not merely an internal
cache state. Linux defines a timerfd as readable when expirations are pending,
and a successful read consumes the count; `poll(2)` readiness means the
requested operation would not block. See
<https://man7.org/linux/man-pages/man2/timerfd_create.2.html> and
<https://man7.org/linux/man-pages/man2/poll.2.html>.

There is no downstream guard: the poll syscall maps the cached file event to
the caller's `pollfd.revents` directly. The documented spurious-`EAGAIN`
exception requires another thread to consume an event, which does not occur in
this single-threaded sequence. The stale state persists through both a timed
and zero-timeout poll; it would be cleared only by a future notification, which
the disarmed one-shot timer cannot produce.

## Challenger conclusion

The counterexample maps to a reachable public syscall sequence, and the
single-threaded SMP=2 run demonstrates unmasked caller-visible harm. This is a
confirmed live defect, not a model artifact. No repair request was created:
repair-request format applies when the counterexample requires model/spec
repair, whereas this Level-0 reproduction establishes the implementation bug.

VERDICT: REPRODUCED
