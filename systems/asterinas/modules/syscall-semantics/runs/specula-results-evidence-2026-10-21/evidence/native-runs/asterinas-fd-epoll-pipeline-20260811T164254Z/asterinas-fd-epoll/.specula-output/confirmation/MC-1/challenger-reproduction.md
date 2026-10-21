# Challenger reproduction — MC-1

Violated invariant: `MCDeliveryCommitOnCopyout`.

The minimized model witness is `spec/output/MC_hunt_s2_copyout_round2_bfs.out`: its ninth state has an ET registration with `sourceReady = TRUE`, an empty `readyQ`, a copyout fault, and the key in `faultedUndelivered`.

## Phase 2 level

Level 0. The test uses only `eventfd`, `epoll_create1`, `epoll_ctl`, `write`, `epoll_wait`, and `read`. It does not inject kernel state, modify source behavior, or rely on a race. The inaccessible output pointer is deliberately passed through the documented `epoll_wait` error interface and Asterinas returns `EFAULT` for it.

## Test and target

- Test: `../../repro/test_bugMC-1_challenger.c`
- Source worktree: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`
- Target: isolated Asterinas ISO, SMP=2
- Test source SHA-256: `7cb6fcf6d961239ae93c8d7cb41ea753b5736e72994ea9e2a080955932e86664`
- Injected static test binary SHA-256: `12981b59284812dd42ae37d0ce2aaeeea33ba8d4699a19b66ed90d2b1e8b9a64`
- ISO SHA-256: `a4d34d94e1e41fc7af36a5c08b2464735ebbaaf90784bf6a48890077f744f2cf`

The image changes only the initramfs test binary. The Asterinas kernel SHA-256 is `1481841a3be39e01d32ba3655b2487118c5216de1cbc492450197fc044fbc45d` in both the supplied and challenger artifacts.

## Expected result

After a ready `EPOLLIN | EPOLLET` eventfd is exposed through an invalid event-array pointer, `epoll_wait` must return `-1/EFAULT` without committing delivery. A subsequent valid `epoll_wait` must return the pending event. The LT case establishes that the test itself and ordinary recovery remain valid; the successful-ET control establishes ordinary ET one-time consumption.

## Observed result

The host Linux control passed:

```
MC1_CASE name=edge_after_efault first=-1 first_errno=14 second=1 second_errno=0 events=0x1 data=0x4d43312d43484c4c eventfd_read=8 unread=1
MC1_CASE name=level_after_efault first=-1 first_errno=14 second=1 second_errno=0 events=0x1 data=0x4d43312d43484c4c eventfd_read=8 unread=1
MC1_CONTROL name=successful_et first=1 second=0
MC1_CHALLENGER_PASS
```

The sealed Asterinas SMP=2 run produced the same result twice:

```
MC1_CASE name=edge_after_efault first=-1 first_errno=14 second=0 second_errno=0 events=0x0 data=0x0 eventfd_read=8 unread=1
MC1_CASE name=level_after_efault first=-1 first_errno=14 second=1 second_errno=0 events=0x1 data=0x4d43312d43484c4c eventfd_read=8 unread=1
MC1_CONTROL name=successful_et first=1 second=0
MC1_CHALLENGER_FAIL
```

The first call is a genuine public `EFAULT`; the second is a valid user-memory call. The unread eventfd counter proves the source event was not consumed. The LT control redelivers it, so the failure is specific to edge-triggered ready-set handling, not eventfd readiness or the test's output buffer.

## Consequence and masking check

The caller receives `0` from a valid `epoll_wait` while the eventfd remains readable. No automatic recovery runs before that second call. A later write or `EPOLL_CTL_MOD` can create a new notification, but does not make this lost pending edge observable to the caller that issued the valid retry. This is a wrong consumer-visible result, not merely an internal state discrepancy.

## Identity, supported scope, and Linux comparison

No FD close, duplication, or number reuse occurs. The epoll instance and eventfd retain their original slots, and the unread value `1` comes from the same eventfd file object registered with epoll. The failure is therefore a ready-delivery state loss, not FD-slot/object confusion.

`eventfd`, `EPOLL_CTL_ADD`, `EPOLLIN | EPOLLET`, and the `EFAULT` return from an inaccessible `epoll_wait` output array are all exercised through supported public interfaces. Linux's `fs/eventpoll.c` explicitly puts the selected item back when user copyout faults, before its ET/LT completion handling. Asterinas lacks that rollback after `EpollFile::wait` returns its vector.
