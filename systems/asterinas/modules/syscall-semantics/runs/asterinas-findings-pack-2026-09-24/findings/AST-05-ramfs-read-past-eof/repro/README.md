# AST-05 reproducers

## Files and where they came from

| File | Source |
|---|---|
| `repro.c` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-05-ramfs-read-past-eof/repro.c`, byte-identical to the 01a run's `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-3_ramfs_read_past_eof.c` |
| `run.sh` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-05-ramfs-read-past-eof/run.sh` |
| `min_ast05.c` | `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/minimal/min_ast05.c` |
| `read_eof-regression-pr3778.patch` | `git diff 042ff520c 17234066b -- test/` in `/home/chin39/Documents/asterinas-dev`, the test commit of PR #3778 |
| `variants/GLM-MC-2/` | The GLM run's variant, see its own README |

## Where they go in an Asterinas tree

The guest has no compiler. Copy `repro.c` (for example as `ast05.c`) and
`min_ast05.c` into a regression test directory such as
`test/initramfs/src/regression/io/specula/`, register it, and boot with a
custom init script, as `docs/running-reproducers.md` describes. The init
script must create the target directory first (`mkdir -p /mc3`).

`read_eof-regression-pr3778.patch` is an in-tree fs regression test from the
PR, whose base is `a5449e62b`. `git apply --check` also passes on `604948581`
and `bc12195df` (checked 2026-09-24, not built there). It adds `test/initramfs/src/regression/fs/read_eof/` and
one line to `fs/run_test.sh`, and runs in the normal fs suite
(`make run_kernel AUTO_TEST=regression`). Its concurrent `preadv` case needs
`SMP=2` or more and skips on one CPU.

No kernel hooks are needed.

## Build and run

Linux control:

```sh
cc -Wall -O2 -o /tmp/ast05 repro.c && mkdir -p /dev/shm/ast05 && /tmp/ast05 /dev/shm/ast05
cc -Wall -O2 -o /tmp/min_ast05 min_ast05.c && /tmp/min_ast05 /dev/shm/min_ast05.bin
```

Asterinas guest, `SMP=2`:

```sh
mkdir -p /mc3 && /test/io/specula/ast05 /mc3      # ramfs
/test/io/specula/ast05 /exfat                     # exFAT, if mounted
/test/io/specula/min_ast05 /min_ast05.bin
```

## Reading the output

`repro.c` prints one line per check, ending in `-> OK` or `-> VIOLATION`, then
a summary.

| Line | Unfixed Asterinas (`604948581`, ramfs) | Linux tmpfs |
|---|---|---|
| `[case1 pread(off=1,len=64,size=2)]` | `ret=1 ... clobbered=63 -> VIOLATION` | `clobbered=0 -> OK` |
| `[case2 pread(off=EOF=2,len=64)]` | `ret=0 ... clobbered=64 -> VIOLATION` | `-> OK` |
| `[case3 read(off=1,len=64,size=2)]` | `clobbered=63 -> VIOLATION` | `-> OK` |
| `[case4 preadv ...]` entries | `-> VIOLATION` | `-> OK` |
| `[case5 pread(off=4096,len=4096,size=4100)]` | `ret=4 ... clobbered=4092 -> VIOLATION` | `-> OK` |
| `MC3_SUMMARY` / `MC3_RESULT` | `wrong_return_values=0 buffers_modified_past_return=6`, `DIVERGES_FROM_LINUX` | `0` and `0`, `MATCHES_LINUX` |

The return values are correct on both kernels. The bug is the clobbered
sentinel bytes past the return value. Both programs exit 0 whether or not the
bug is present. `min_ast05` ends with `MIN_AST05 BUG` or `MIN_AST05 OK`.

The PR #3778 test prints `test_<name> summary: N tests passed, M tests failed`
per function and exits nonzero on any failure. An earlier revision of this
test (without the concurrent case) was run against the unfixed pin:
`pread_across_eof_leaves_tail_untouched`, `pread_at_eof_leaves_buffer_untouched`,
and `read_across_eof_leaves_tail_untouched` failed on `/tmp` and `/exfat` and
passed on `/ext2`
(`/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/ast05-fix-read_eof-baseline-604948581.txt`).
The fourth function, `preadv_fills_iovecs_in_order`, passes on the unfixed
kernel. It fails only if a fix limits the caller's writer in place.
