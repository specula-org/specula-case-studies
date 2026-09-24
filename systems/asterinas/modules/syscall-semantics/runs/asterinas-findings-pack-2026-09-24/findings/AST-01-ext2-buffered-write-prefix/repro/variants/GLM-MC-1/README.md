# AST-01 extra: GLM MC-1 (a later readv/writev fault hides a positive copy prefix)

GLM run `asterinas-glm53-eval-20260826T035049Z`, finding MC-1, native verdict
REPRODUCED at pin `604948581512d83734377974d4c34adb4530f2d7`. The id-map maps
GLM MC-1 to both AST-01 and AST-04: "Existing shared count-erasure mapping;
readv observation overlaps both historical entries." The `writev_later` case
below is AST-01's shape (a committed write prefix hidden by the returned count
or EFAULT). The read cases are AST-04's shape. The same files are packaged
under both entries. The GLM confirmation labeled the finding KNOWN, citing
https://github.com/asterinas/asterinas/issues/711 (open).

## Files and origin

| File | Copied from |
|---|---|
| `test_bugMC-1_readv_prefix_fault.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugMC-1_readv_prefix_fault.c` (the guest copy `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/source/test/initramfs/src/regression/io/file_io/specula_repro_mc1.c` has the same body without the five-line header) |
| `specula_repro_mc1.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/source/test/initramfs/src/regression/io/file_io/specula_repro_mc1.sh` (wrapper that execs the binary) |
| `glm-autotest-targets.patch` | `git diff Makefile` in `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-4/worktree` (adds `AUTO_TEST=mc1repro` and `mc4repro` targets, plus a `specula` trace target that needs the removed trace harness) |

## What it tests

Single thread, deterministic (Level 0). A two-page buffer has its second page
`PROT_NONE`. On `/tmp` (ramfs) and `/ext2`:

- `read_scalar`: `read` that faults after copying 2048 bytes.
- `readv_later`: `readv` whose second iovec faults after a positive prefix.
- `readv_first`: `readv` whose first iovec faults after a positive prefix.
- `writev_later`: `writev` whose second iovec faults after a positive prefix
  (AST-01 shape).

Each phase runs in a forked child.

## How to run

Asterinas: copy the C file to
`test/initramfs/src/regression/io/file_io/specula_repro_mc1.c` and the wrapper
next to it, apply `glm-autotest-targets.patch`, and run
`make run_kernel AUTO_TEST=mc1repro TARGET_ARCH=x86_64 SMP=2 MEM=2G ENABLE_KVM=1 CONSOLE=hvc0 LOG_LEVEL=error INITRAMFS_SKIP_GZIP=1`
inside `asterinas/dev:0.18.1-20260805`. The default init mounts `/ext2` and
`/exfat` before running the wrapper. Linux:
`gcc -Wall -O2 -o mc1 test_bugMC-1_readv_prefix_fault.c && ./mc1`.

## Output

- FAIL on Asterinas at the pin (ext2 behaves the same as ramfs):
  - `MC1_CASE name=read_scalar tag=ramfs ret=-1` with `prefix_copied=1`
  - `MC1_CASE name=readv_later tag=ramfs ret=16` with
    `prefix_copied_beyond_ret=1` and `redelivers_prefix_bytes=1`
  - `readv_first ... ret=-1 ... prefix_copied_despite_efault=1`
  - `writev_later ... ret=16 ... committed_prefix_bytes=2048`
- PASS (Linux control): `read_scalar ret=2048`, `readv_later ret=2064`,
  `redelivers_prefix_bytes=0`. Each return covers the copied prefix and the
  offset advances by it.

## SMP

Sequential. The GLM guest used SMP=2.
