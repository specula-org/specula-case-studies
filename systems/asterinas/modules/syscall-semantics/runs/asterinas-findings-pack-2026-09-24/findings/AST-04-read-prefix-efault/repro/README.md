# AST-04 reproducer

## Files and where they came from

| File | Source |
|---|---|
| `repro.c` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-04-read-prefix-efault/repro.c`, byte-identical to the 01a run's `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-1_partial_read_efault.c` |
| `run.sh` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-04-read-prefix-efault/run.sh` |
| `variants/GLM-MC-1/` | The GLM run's readv/writev variant, see its own README |

## Where it goes in an Asterinas tree

The guest has no compiler. Copy `repro.c` (for example as `ast04.c`) into a
regression test directory such as `test/initramfs/src/regression/io/specula/`,
register it, and boot with a custom init script, as
`docs/running-reproducers.md` describes. No kernel hooks are needed.

## Build and run

Linux control (pass one tmpfs path and one disk path):

```sh
cc -Wall -O2 -o /tmp/ast04 repro.c
/tmp/ast04 /dev/shm/mc1-regular-file /var/tmp/mc1-regular-file
```

Asterinas guest, `SMP=2`:

```sh
/test/io/specula/ast04                                     # defaults: /mc1-regular-file (ramfs) and /ext2/mc1-regular-file
/test/io/specula/ast04 /mc1-regular-file /ext2/mc1-regular-file   # same, explicit
```

Each argument is a file path that the program creates and removes.

## Reading the output

For each path the program prints a `read`, `next read`, `pread`, and
`zero-prefix control` line, plus an `ANOMALY` line for every divergence. It
ends with `MC1_ANOMALIES <n>` and `MC1_RESULT`.

| Line | Unfixed Asterinas (`604948581`) | Linux |
|---|---|---|
| `<path> read` | `ret=-1 errno=14(Bad address) offset_after=0 visible_prefix=128` | `ret=128 offset_after=128 visible_prefix=128` |
| `<path> next read` | `first_byte='A'` (the prefix is replayed) | `first_byte='Y'` |
| `<path> zero-prefix control` | `ret=-1 errno=14` | `ret=-1 errno=14` (both kernels must fail here) |
| `MC1_RESULT` | `DIVERGES_FROM_LINUX` (6 anomalies over ramfs and ext2 on 2026-09-02) | `MATCHES_LINUX`, `MC1_ANOMALIES 0` |

The program exits 0 in both cases. Read the marker lines. If the zero-prefix
control does not fail on either kernel, the fault setup is broken and the run
proves nothing.
