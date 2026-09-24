# AST-02 reproducers

## Files and where they came from

| File | Source |
|---|---|
| `repro.c` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-02-ramfs-size-publication/repro.c`. It is the 01a run's `test_bugMC-4_ramfs_size_publication.c` with a three-line header comment reworded. The code is identical. |
| `run.sh` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-02-ramfs-size-publication/run.sh` |
| `min_ast02.c` | `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/minimal/min_ast02.c` |
| `empty_write-regression-pr3875.patch` | `git diff bc12195df 37b18435c -- test/` in `/home/chin39/Documents/asterinas-dev`, the test part of PR #3875 |
| `variants/GLM-MC-3/` | The GLM run's variant, see its own README |

## Where they go in an Asterinas tree

The guest has no compiler. Copy `repro.c` (for example as `ast02.c`) and
`min_ast02.c` into a regression test directory such as
`test/initramfs/src/regression/io/specula/`, register it, and boot with a
custom init script, as `docs/running-reproducers.md` describes.

`empty_write-regression-pr3875.patch` is an ordinary in-tree test. It was
written on `bc12195df`. `git apply --check` also passes on `604948581`
(checked 2026-09-24, not built there). It adds
`test/initramfs/src/regression/fs/empty_write/` and five lines to
`fs/run_test.sh`, and it runs in the normal fs regression suite
(`make run_kernel AUTO_TEST=regression`).

No kernel hooks are needed.

## Build and run

Linux control:

```sh
cc -Wall -O2 -o /tmp/ast02 repro.c && /tmp/ast02 /dev/shm      # tmpfs is the reference filesystem
cc -Wall -O2 -o /tmp/min_ast02 min_ast02.c && /tmp/min_ast02 /dev/shm/min_ast02.bin
```

Asterinas guest, `SMP=2`:

```sh
/test/io/specula/ast02 /                      # / is ramfs in the stock initramfs
/test/io/specula/min_ast02 /min_ast02.bin
```

## Reading the output

`repro.c` prints one `CASE <X> ... VERDICT=<v>` line per case and a summary.

| Line | Unfixed Asterinas (`604948581`) | Linux tmpfs |
|---|---|---|
| `CASE A pwrite64_extending_zero_copy_fault` | `size_after=16384 ... VERDICT=SIZE_GREW` | `size_after=8192 ... VERDICT=OK` |
| `CASE B pwrite64_zero_length_past_eof` | `size_after=16384 ... VERDICT=SIZE_GREW` | `VERDICT=OK` |
| `CASE C write_o_append_zero_copy_fault` | `size_after=16384 ... VERDICT=SIZE_GREW` | `VERDICT=OK` |
| `CASE D write_at_seeked_offset_zero_copy_fault` | `size_after=24576 linux_expected=16384 VERDICT=SIZE_GREW` | `size_after=16384 VERDICT=OK` |
| `CASE E pwrite64_overlapping_eof_zero_copy_fault` | `size_after=12288 ... VERDICT=SIZE_GREW` | `VERDICT=OK` |
| `MC4_SUMMARY` | `deviations=5 failures=0` | `deviations=0 failures=0` |

`failures` counts setup or expectation errors in the harness itself. A nonzero
`failures` means the run is not valid.

`min_ast02` ends with `MIN_AST02 BUG` on the unfixed kernel (for example
`zero-length pwrite past EOF: ret=0 ... size=8192 (expected 4096)`) and
`MIN_AST02 OK` on Linux.

Both programs exit 0 whether or not the bug is present. Read the marker lines.

The PR #3875 test uses the harness in `test/initramfs/src/regression/common/test.h`.
Each test function prints `<name> summary: N tests passed, M tests failed`,
and a failing assertion makes the binary exit nonzero, which stops
`fs/run_test.sh`. It covers only zero-length writes, so it passes on a kernel
that still has the zero-progress fault defect.
