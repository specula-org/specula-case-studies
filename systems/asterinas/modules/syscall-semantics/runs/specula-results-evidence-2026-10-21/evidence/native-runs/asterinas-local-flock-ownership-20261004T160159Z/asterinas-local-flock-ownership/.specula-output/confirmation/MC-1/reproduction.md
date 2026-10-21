# MC-1 Reproduction record (Phase 2)

Test: `repro/test_bugMC-1_flock_conversion_retention.c` (self-contained C, public flock(2)/open(2)/close(2)
+ pthread only; runs as guest init/PID 1 and as a host Linux control).

Escalation level reached: **Level 0** (pure black-box). No state injection, no source patch, no
failpoints, no timing hooks. The guest kernel is the campaign's validated v12 build
(`asterinas-osdk-bin.elf` sha256 `d51c2205...`, source state byte-identical to this finding's
worktree; instrumentation is dormant trace-only and logic-preserving — see investigation.md).

## Execution commands

- Guest (Asterinas, KVM, 2 CPUs, ramfs rootfs), twice for repeatability:
  `qemu-system-x86_64 -bios /root/ovmf/release/OVMF.fd -machine q35 -accel kvm -cpu host -m 2G -smp 2
   -display none -serial stdio -monitor none -no-reboot -device isa-debug-exit,iobase=0xf4,iosize=0x04
   -drive file=/repro/build/mc1.iso,format=raw,index=2,media=cdrom`
  (ISO repacked with `grub-mkrescue` from the campaign iso_root with this test as initramfs — the
  same recipe `cargo osdk run` uses; cargo itself was bypassed because the fresh container lacks the
  imported cargo dependency cache of the removed harness container.)
  Logs: `repro-guest-run2.log`, `repro-guest-run3.log` (identical outcomes).
- Linux control (host kernel Linux 7.2.8, same binary): `timeout 60 ./test_mc1_host`
  Logs: `repro-linux-control.log` (and an earlier identical run).

## Guest output (Asterinas, kernel identity "Linux 5.13.0", smp=2) — verbatim

```
MC1_ENV kernel=Linux 5.13.0 smp=2
P1 opens a=3 b=4 c=5 (independent opens, one OFD each)
P1 flock(a, SH|NB)   = 0 errno=0
P1 flock(b, SH|NB)   = 0 errno=0
P1 flock(a, EX|NB)   = -1 errno=EAGAIN   <- A converts SH->EX, conflicts with B's SH
P1 flock(b, UN)      = 0 errno=0   <- B releases its SH
P1 flock(c, EX|NB)   = -1 errno=EAGAIN   <- DISCRIMINATOR: Linux oracle =0 (A's failed conversion removed A's SH); Asterinas bug =EAGAIN (A's old SH retained)
P1 flock(a, UN)      = 0 errno=0   <- A drops its retained old SH
P1 flock(c, EX|NB)   = 0 errno=0   <- after A's UN, C must succeed on both kernels
P2 opens a2=3 b2=4
P2 flock(a2, SH|NB)  = 0 errno=0
P2 flock(b2, SH|NB)  = 0 errno=0
P2 both converters entered blocking flock(a2/b2, EX)
P2 window(5s)        : t1_done=0 t2_done=0   <- Asterinas bug: 0 0 (both parked, each holding the SH the other waits for); Linux oracle: exactly one completed
P2 drain: flock(a2, UN) = 0 errno=0
P2 drain: t2_done=1 (blocking conversion returned)
P2 drain: flock(b2, UN) = 0 errno=0
P2 drain: t1_done=1 (blocking conversion returned)
P2 results: t1 flock=0 errno=0, t2 flock=0 errno=0
MC1_P1_OBSERVED C_EX_NB_after_B_unlock=EAGAIN(retained SH blocks C)
MC1_P2_OBSERVED completed_during_window=0
MC1_ASSESSMENT BUG_REPRODUCED: Asterinas retains the caller's old SH across a conflicting conversion; C's EX|NB is denied after B's release, and two blocking SH->EX converters deadlock mutually (0 completions in 5s)
MC1_GUEST_DONE status=BUG_REPRODUCED
```

## Linux control output (host Linux 7.2.8) — verbatim

```
MC1_ENV kernel=Linux 7.2.8 smp=24
P1 opens a=3 b=4 c=5 (independent opens, one OFD each)
P1 flock(a, SH|NB)   = 0 errno=0
P1 flock(b, SH|NB)   = 0 errno=0
P1 flock(a, EX|NB)   = -1 errno=EAGAIN   <- A converts SH->EX, conflicts with B's SH
P1 flock(b, UN)      = 0 errno=0   <- B releases its SH
P1 flock(c, EX|NB)   = 0 errno=0   <- DISCRIMINATOR: Linux oracle =0 (A's failed conversion removed A's SH); Asterinas bug =EAGAIN (A's old SH retained)
P1 flock(a, UN)      = 0 errno=0   <- A drops its retained old SH
P1 flock(c, EX|NB)   = 0 errno=0   <- after A's UN, C must succeed on both kernels
P2 opens a2=3 b2=4
P2 flock(a2, SH|NB)  = 0 errno=0
P2 flock(b2, SH|NB)  = 0 errno=0
P2 both converters entered blocking flock(a2/b2, EX)
P2 window(5s)        : t1_done=0 t2_done=1   <- Asterinas bug: 0 0 (both parked, each holding the SH the other waits for); Linux oracle: exactly one completed
P2 drain: flock(a2, UN) = 0 errno=0
P2 drain: t2_done=1 (blocking conversion returned)
P2 drain: flock(b2, UN) = 0 errno=0
P2 drain: t1_done=1 (blocking conversion returned)
P2 results: t1 flock=0 errno=0, t2 flock=0 errno=0
MC1_P1_OBSERVED C_EX_NB_after_B_unlock=SUCCESS(old lock gone)
MC1_P2_OBSERVED completed_during_window=1
MC1_ASSESSMENT LINUX_CONTROL_MATCHED: failed conversion left no lock (C granted), and exactly one blocking converter completed spontaneously
MC1_GUEST_DONE status=LINUX_CONTROL
```

## Right-bug verification against the MC counterexample

- C05 CE (`MC_hunt_2_conversion_oracle-bfs.log`, final state 80): `items` still contains
  `[mode "SH", owner a]` after B's unlock; `linuxMode` = a→"UN", b→"UN", c→"EX"; `observed` t3
  (C's EX|NB) = "EAGAIN" vs `linuxResult` t3 = "OK". My P1 executes the identical action sequence
  (SH a, SH b, EX|NB a → EAGAIN, UN b, EX|NB c) and observes the identical divergence
  (EAGAIN on Asterinas vs 0 on the Linux control). Same violated property (Asterinas list state vs
  the Linux mode oracle), same root-cause site (flock.rs:114/147: conflict search precedes the
  same-owner replacement; the blocking path parks with the old item still in the list).
- C06 CE (ConvertersDrain; campaign runtime prefix `C06.log`: tid2 registered on q1002, tid3
  registered on q1001, both parked, `complete:false`): my P2 observes the same mutual-block state
  live — zero converter completions in a 5 s window — while the Linux control completes exactly one
  converter spontaneously, as the delete-before-conflict order guarantees.
- The campaign's own v10/v12 harness runs corroborate both (C05 asserted EAGAIN on the guest and
  success on the Linux 7.2.8 control; C06 ended as a parked prefix).

## Determinism

Two independent guest boots produced identical results (repro-guest-run2.log, repro-guest-run3.log);
the Linux control run twice, identical (repro-linux-control.log). The P1 outcome is a deterministic
function of the code order; the P2 mutual block has no resolution path absent external unlock/close
or a signal (signals are outside the modeled scope, and EINTR→ERESTARTSYS re-enters the same path).
