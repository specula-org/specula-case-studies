# AST-03 extra: GLM MC-4 (vectored I/O not atomic against a shared-offset competitor)

GLM run `asterinas-glm53-eval-20260826T035049Z`, finding MC-4, native verdict
INCOMPLETE at pin `604948581512d83734377974d4c34adb4530f2d7`. The id-map maps
GLM MC-4 to AST-03 and keeps the INCOMPLETE disposition: "AST-03 has 01a
evidence; this run remains INCOMPLETE." The confirmation failed on tooling
(`MC-4: output has no canonical VERDICT`, see `confirmation/MC-4/error.txt`).
The GLM final report records that turn A had reached REPRODUCED in an earlier
attempt. Do not cite this run as an independent confirmation of AST-03.

## Files and origin

| File | Copied from |
|---|---|
| `test_bugMC-4_vector_shared_offset_race.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugMC-4_vector_shared_offset_race.c` (v4, identical to the worktree's `specula_repro_mc4.c`) |
| `specula_repro_mc4.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-4/worktree/test/initramfs/src/regression/io/file_io/specula_repro_mc4.sh` (wrapper) |
| `run_repro_v4.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-4/run_repro_v4.sh` (driver for the v4 guest run) |
| `glm-autotest-targets.patch` | `git diff Makefile` in `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-4/worktree` (adds `AUTO_TEST=mc1repro` and `mc4repro`, plus a `specula` trace target that needs the removed trace harness) |

## What it tests

Two threads share one open file description (`fd` and `dup(fd)`) on
`/tmp/mc4race.bin`. Thread A runs `readv(fd, {entry1[L], entry2[8]})` or
`writev(fd, {D[L], ZZ[8]})`. Thread B runs `write(fd2, "XYXYXYXY", 8)` after a
delay swept over a grid calibrated against the measured entry-1 duration
(Level 1 timing assistance, no kernel change). Results are classified as
`serialA`, `serialB`, or `BUG` (B committed between the two vector entries).

## How to run

Asterinas: copy the C file to
`test/initramfs/src/regression/io/file_io/specula_repro_mc4.c` with the wrapper
next to it, apply `glm-autotest-targets.patch`, and run
`make run_kernel AUTO_TEST=mc4repro TARGET_ARCH=x86_64 SMP=2 MEM=2G ENABLE_KVM=1 CONSOLE=hvc0 LOG_LEVEL=error INITRAMFS_SKIP_GZIP=1`
inside `asterinas/dev:0.18.1-20260805` (`run_repro_v4.sh` shows the full Docker
command). Linux: `gcc -O2 -pthread` and run it.

## Output

- FAIL on Asterinas (v4 guest run, `confirmation/MC-4/docker-build-run-v4.log`):
  `MC4_TRIGGER case=readv L=65536 round=35 ... XY_at_NW=1 ...`,
  `MC4_TRIGGER case=writev L=65536 round=32 ...`,
  `MC4_SUMMARY readv=1 writev=1 (1=triggered 0=exhausted -1=error)`.
- PASS (Linux control, `confirmation/MC-4/linux-control-v4.txt`, 20000 rounds
  per geometry): `bug=0` everywhere and `MC4_SUMMARY readv=0 writev=0`.
- An earlier fixed-tick version (v3) exhausted 4000 rounds without a trigger on
  Asterinas (`guest-mc4-markers-retry.txt`). A zero means "not triggered", not
  "fixed".

## SMP

Needs two or more CPUs. The GLM guest used SMP=2.
