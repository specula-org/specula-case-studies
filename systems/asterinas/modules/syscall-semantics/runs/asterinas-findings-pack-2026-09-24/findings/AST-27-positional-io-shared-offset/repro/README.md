# AST-27 negative probe

This entry is a FALSE POSITIVE. The probe is kept for deduplication and as a
candidate regression test for positional-offset isolation.

## Files and origin

| File | Copied from | Role |
|---|---|---|
| `test_bugCR-1_positional_offset_isolation.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugCR-1_positional_offset_isolation.c` | Probe, same binary on Linux and Asterinas |

## How to run

The probe creates `/tmp/cr1_pos_isolation.bin` (ramfs on Asterinas), duplicates
the descriptor with `dup` and `dup2`, and runs 19 checks: positional I/O on
success, at and past EOF, with `EFAULT` and fault-prefix buffers, with
`O_APPEND`, with file extension, and with four hammer threads racing scalar
`read`/`write`. Every check compares `lseek(fd, 0, SEEK_CUR)` on each descriptor
against the exact expected offset.

- Linux: `gcc -O2 -pthread test_bugCR-1_positional_offset_isolation.c -o cr1 && ./cr1`.
- Asterinas: build it statically with `-pthread` and run it from the guest. The
  GLM run placed it under `test/initramfs/src/regression/io/file_io/`, where
  the regression initramfs build picks it up, and booted it with a custom
  `AUTO_TEST=cr1repro` Makefile target (`make run_kernel AUTO_TEST=cr1repro
  TARGET_ARCH=x86_64 SMP=2 MEM=2G ENABLE_KVM=1` inside
  `asterinas/dev:0.18.1-20260805`). That target was not retained. Running the
  binary from any init script, or adding it to the regular regression suite,
  works the same way.

## Reading the output

- Expected on Asterinas at the pin and on Linux: 19 `PASS` lines,
  `CR1_RESULT: PASS (19 checks, 0 failed)`, `CR1_REPRO_DONE`, exit status 0.
- A real regression would show a `FAIL` on checks 3 to 15 or 17 to 19 and exit
  status 1. A `FAIL` on checks 1, 2, or 16 means the probe itself cannot see
  shared-offset movement.
- Exit status 2 means setup failed (for example, the file could not be created).

## SMP

The GLM guest used SMP=2. Checks 17 to 19 use threads. One CPU still runs them.
