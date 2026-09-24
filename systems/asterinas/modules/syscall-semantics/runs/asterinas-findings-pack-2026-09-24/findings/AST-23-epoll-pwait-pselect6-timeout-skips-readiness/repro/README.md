# AST-23 reproducer

The programs use only public APIs: `pipe`, `fork`, `write`, `kill`,
`sched_setaffinity`, `sched_setscheduler`, `epoll_wait`, `epoll_pwait`,
`ppoll`, `pselect`, and signal-mask calls. None of them needs a kernel change.
The recorded runs used Asterinas pin
`4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.

## Files and their sources

All files come from
`/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/`.

| File | Role |
|---|---|
| `test_bugCR-5_wait_mask.c` | Final reproducer (SHA-256 `74f33dab...`). Level-0 timeout, readiness, and signal controls for all four APIs, then the Level-1 `SCHED_FIFO` priority case. |
| `test_bugCR-5_challenge.c` | Challenger control with the same blocked-waiter/FIFO-writer structure. |
| `run_bugCR-5_asterinas.sh` | Two-line init helper that execs `/test_bugCR5.bin`. |
| `cr5-grub.cfg` | GRUB entry used for the ISO: `multiboot2 /boot/asterinas-osdk-bin init=/init loglevel=error earlycon console=ttyS0 -- /test_bugCR5` with `module2 /boot/initramfs.cpio`. |

No initramfs plumbing patch is needed. The test was built as one static
binary and placed at the initramfs root.

## Where the files go

Build the test statically, for example
`gcc -O2 -Wall -Wextra -Werror -static test_bugCR-5_wait_mask.c -o test_bugCR5`
(the preliminary run recorded `gcc -O2 -Wall -Wextra -Werror`, and the final
binary was static). Put it at `/test_bugCR5` in an initramfs cpio for a kernel
built from the pin with `cargo osdk build`, then boot that kernel and cpio from
a GRUB ISO that uses `cr5-grub.cfg`.

## How to run

The final SMP=2 run booted the ISO under QEMU/KVM with `-smp 2`. Its exact
command line is not recorded in the retained artifacts.

The challenger's one-vCPU command is recorded in
`confirmation/CR-5/investigation.md` (the ISO is the run's
`.specula-output/repro/test_bugCR-5_wait_mask.iso`, not copied here):

```sh
timeout 45s qemu-system-x86_64 \
  -enable-kvm -machine q35,kernel-irqchip=split -cpu Icelake-Server,+x2apic \
  -m 1G -smp 1 -bios <asterinas OVMF.fd> \
  -cdrom test_bugCR-5_wait_mask.iso -nographic -no-reboot
```

The Linux control booted the identical static binary as PID 1 on a disposable
Linux 7.1.8 one-vCPU QEMU/KVM guest.

## Reading the output

Look at the `CR5_PRIORITY` lines and the final `CR5_RESULT` line.

| Outcome | Asterinas (bug present) | Linux |
|---|---|---|
| Priority case per API | `CR5_PRIORITY api=<api> ret=0 errno=0 ready=0 post_ret=1 post_errno=0 post_ready=1 before_deadline=1 returned_after_deadline=1 elapsed_ms=~381 mask_blocked=1` followed by `CR5_ANOMALY api=<api> timeout_bypassed_priority_deferred_readiness` | `CR5_PRIORITY api=<api> ret=1 ... ready=1 ... before_deadline=1 returned_after_deadline=1 elapsed_ms=380 mask_blocked=1` |
| Summary | `CR5_RESULT FAIL failures=N` (recorded N=2 at SMP=2, N=4 at one vCPU) | `CR5_RESULT PASS failures=0` |

A priority line with `ret=1` and `returned_after_deadline=0` (about 30 ms)
means the waiter was not delayed past the deadline in that attempt, so it does
not test the bug. `mask_blocked=1` on every line shows the original signal mask
was restored. `ret=-1 errno=4` in the signal controls is the expected `EINTR`.

## SMP setting

Recorded runs: `-smp 2` (final Asterinas trace, 2 of 4 APIs failed) and
`-smp 1` (challenger, 4 of 4 failed). Prefer one vCPU. This checkout's
`sched_setaffinity` does not migrate threads, so on SMP=2 the parent is not
guaranteed to share the FIFO child's CPU.
