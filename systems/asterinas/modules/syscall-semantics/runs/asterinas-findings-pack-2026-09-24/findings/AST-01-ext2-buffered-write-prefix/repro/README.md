# AST-01 reproducer

## Files and where they came from

| File | Source |
|---|---|
| `repro.c` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-01-ext2-buffered-write-prefix/repro.c`, byte-identical to the 01a run's `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-2_retained_write_prefix_efault.c` |
| `run.sh` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-01-ext2-buffered-write-prefix/run.sh` |
| `variants/GLM-MC-1/` | The GLM run's readv/writev variant, see its own README |

## Where it goes in an Asterinas tree

The Asterinas initramfs has no C compiler, so `run.sh` (which calls `cc`)
works only on a Linux host. For the guest, copy `repro.c` into a regression
test directory, for example
`test/initramfs/src/regression/io/specula/ast01.c`, register the directory,
and boot with a custom init script. `docs/running-reproducers.md` gives the
full procedure. The program then runs as `/test/io/specula/ast01`.

The program uses only public syscalls. It needs no kernel hooks.

## Build and run

Linux control (host):

```sh
cc -Wall -O2 -o /tmp/ast01 repro.c
mkdir -p /tmp/ast01-dir && /tmp/ast01 /tmp/ast01-dir   # use a disk filesystem, not tmpfs
```

Asterinas guest (after building it into the initramfs):

```sh
/test/io/specula/ast01 /ext2
```

Run the guest with `SMP=2`. The bug is single-threaded, but every recorded run
used two CPUs.

## Reading the output

Each case prints `MC2_WRITE`, `MC2_OFFSET`, `MC2_FILE`, `MC2_DIRECT`, and a
`MC2_VERDICT` line, and the run ends with `MC2_RESULT`.

| Result | Meaning |
|---|---|
| `MC2_VERDICT <case> RETAINED_PREFIX_UNREPORTED reported=0 committed=<n>` and `MC2_RESULT DIVERGES_FROM_LINUX` | Bug present: the call returned `-1`/`EFAULT` (`errno=14`) but `<n>` bytes changed in the file |
| `MC2_VERDICT <case> CONSISTENT_SHORT_WRITE reported=<n> committed=<n> offset_delta=<n>` and `MC2_RESULT MATCHES_LINUX` | Linux behavior: short count, file change, and offset agree |

Recorded values at `604948581` (2026-09-02, SMP=2): `mixed_page` committed
4096, `partial_page` committed 128, `uninit_tail` (`O_DIRECT`) committed 128,
all with `ret=-1 errno=14` and `offset_delta=0`. Linux 7.1.9 on ext4 returned
4096/128/128 with matching offset deltas.

The program exits 0 in both cases. Judge the result from the marker lines, not
the exit status.
