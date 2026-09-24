# AST-05 extra: GLM MC-2 (ramfs and exFAT cached reads copy beyond logical EOF)

GLM run `asterinas-glm53-eval-20260826T035049Z`, finding MC-2, native verdict
REPRODUCED at pin `604948581512d83734377974d4c34adb4530f2d7`. The id-map maps
GLM MC-2 to AST-05 ("Same tracked mechanism"). The GLM final report records it
as "= AST-05 + exFAT extension": the 01a AST-05 evidence covered ramfs, and this
run added the same effect on exFAT.

## Files and origin

| File | Copied from |
|---|---|
| `test_bugMC-2_read_past_eof_clobber.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugMC-2_read_past_eof_clobber.c` |
| `run_mc2_repro.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-2/run_mc2_repro.sh` (driver that uses `AUTO_TEST=mc2repro` in a confirmation worktree that no longer exists) |
| `glm-autotest-targets.patch` | `git diff Makefile` in the GLM MC-4 confirmation worktree (pattern for `AUTO_TEST` repro targets, with no `mc2repro` branch) |

## What it tests

Single thread, deterministic (Level 0). A 3072-byte file on `/tmp` (ramfs),
`/exfat`, and `/ext2`, read into a sentinel-filled buffer:

- `short_read`: a read crossing EOF must return 3072 and leave the buffer tail
  untouched.
- `eof_pread`: `pread` at offset 3072 must return 0 and touch nothing.

Backends that are not mounted are skipped.

## How to run

Asterinas: place the file under `test/initramfs/src/regression/io/file_io/`
(the regression initramfs picks it up) and run it after the default init has
mounted `/ext2` and `/exfat`. The `mc2repro` Makefile target from the GLM
worktree was not retained. `glm-autotest-targets.patch` shows the pattern for
`mc1repro` and `mc4repro`: add an `AUTO_TEST` branch whose `--init-args` points
at a wrapper script that execs the binary, and whose completion check greps
`^MC2_REPRO_DONE`. Linux: `gcc -O2` and run it. Only `/tmp` exists on a typical
host.

## Output

- FAIL on Asterinas at the pin:
  `MC2_TAIL ramfs short_read region=3072..4096 clobbered=1024 ...`, `MC2_VERDICT ramfs short_read BUG`,
  `MC2_TAIL exfat eof_pread region=0..2048 clobbered=1024 ...`, `MC2_VERDICT exfat eof_pread BUG`.
- PASS: `clobbered=0` and `CLEAN` for every backend. ext2 printed `CLEAN` in the
  same guest, and the Linux control printed `CLEAN` for ramfs (tmpfs) with
  exFAT and ext2 skipped.

## SMP

Sequential. The GLM guest used SMP=2.
