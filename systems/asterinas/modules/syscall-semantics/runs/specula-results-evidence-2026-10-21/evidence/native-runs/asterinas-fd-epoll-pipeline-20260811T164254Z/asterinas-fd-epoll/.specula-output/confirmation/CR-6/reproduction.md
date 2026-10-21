# CR-6 reproduction record

## Artifact and level

The public-syscall reproduction is
`../../repro/test_bugCR-6_nested_epoll_cycle.c`. It uses `epoll_create1`,
`epoll_ctl`, `eventfd`, `write`, and `epoll_wait` only. No scheduling control,
state injection, mock, or source change was used (Level 0).

The test first verifies an acyclic nested topology, then independently checks
a self edge or a two-epoll back-edge. Each execution is protected by an outer
timeout.

## Executed Linux control

The test was compiled and executed on the host:

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

This is the expected Linux control, not evidence that the Asterinas worktree
has the same behavior.

## Asterinas execution boundary

A static copy of the test was included in
`test_bugCR-6_nested_epoll_cycle.v2.initramfs.cpio`, built using the worktree's
initramfs build with `SMP=2`. The Level-0 guest command was invoked with that
initramfs and the selected test mode, without modifying kernel source.

The worktree did not reach QEMU. With both the pinned July 2026 toolchain and
the image's April 2026 toolchain, kernel compilation stopped in dependencies:

```text
error[E0407]: method `forward_overflowing` is not a member of trait `Step`
  .../x86_64-0.15.5/...
error[E0308]: catch_unwind expected bool, found i32
[Error]: Cargo build failed
CR6_GUEST_MODE=self EXIT=6
CR6_GUEST_MODE=pair EXIT=6
```

One bounded fallback using local `nightly-2025-12-06` reached OSDK dependency
installation but stalled before the kernel build; stopping that disposable
container produced:

```text
CR6_GUEST_WRAPPER_EXIT=137
```

Consequently, no Asterinas syscall result, consumer-visible failure, or
permanent bad state was observed. Levels 1--3 were not attempted: the candidate
is an already-reported code-review mechanism and no injection or source patch
is appropriate for a duplicate report.
