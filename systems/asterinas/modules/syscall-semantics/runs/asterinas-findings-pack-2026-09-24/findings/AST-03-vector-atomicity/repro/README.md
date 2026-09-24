# AST-03 reproducer

## Files and where they came from

| File | Source |
|---|---|
| `repro.c` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-03-vector-atomicity/repro.c`, byte-identical to the 01a run's `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-5_vector_atomicity.c` |
| `run.sh` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-03-vector-atomicity/run.sh` |
| `variants/GLM-MC-4/` | The GLM run's timing-assisted variant, see its own README |

## Where it goes in an Asterinas tree

The guest has no compiler. Copy `repro.c` (for example as `ast03.c`) into a
regression test directory such as `test/initramfs/src/regression/io/specula/`
whose Makefile links with `-lpthread` (the 01a harness used
`EXTRA_C_FLAGS := -static -lpthread`), register it, and boot with a custom
init script. `docs/running-reproducers.md` gives the full procedure. No kernel
hooks are needed.

## Build and run

Linux control:

```sh
cc -Wall -O2 -pthread -o /tmp/ast03 repro.c && /tmp/ast03 /dev/shm
```

Asterinas guest, `SMP=2` or more (the race needs two CPUs):

```sh
/test/io/specula/ast03 /
```

The argument is a writable directory (default `/`, which is ramfs in the stock
initramfs). A run takes a few seconds per case.

## Reading the output

| Line | Unfixed Asterinas (`604948581`, 2026-09-02) | Linux 7.1.9 tmpfs |
|---|---|---|
| `CASE A readv_vs_read ... noncontiguous_rounds=` | 87 of 100, `VERDICT=VECTOR_TORN` | 0, `VERDICT=ATOMIC` |
| `CASE B readv_vs_write ... noncontiguous_rounds=` | 87 of 100, `VECTOR_TORN` | 0, `ATOMIC` |
| `CASE C writev_vs_write ... split_rounds=` | 98 of 100, `total_foreign_bytes_inside=191168`, `VECTOR_TORN` | 0, `ATOMIC` |
| `CASE D per_entry_read_loop_vs_read` (detector control) | `VECTOR_TORN` | `VECTOR_TORN` (100 of 100) |
| `CASE E later_iovec_fault` | `ret=4096 ... deposited_total=8192 VERDICT=RESULT_UNDERREPORTS_EFFECT` | `ret=8192 VERDICT=RESULT_MATCHES_EFFECT` |

The bug is present when CASE A, B, or C reports `VECTOR_TORN`. CASE D must tear
on both kernels. If CASE D reports `ATOMIC`, the competitor never ran
concurrently and the run proves nothing. The program ends with `MC5_DONE` and
exits 0 either way.
