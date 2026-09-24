# AST-02 extra: GLM MC-3 (zero-progress ramfs write publishes the requested EOF)

GLM run `asterinas-glm53-eval-20260826T035049Z`, finding MC-3, native verdict
REPRODUCED at pin `604948581512d83734377974d4c34adb4530f2d7`. The id-map maps
GLM MC-3 to AST-02 ("Same tracked mechanism").

## Files and origin

| File | Copied from |
|---|---|
| `test_bugMC-3_prepublished_write_eof.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugMC-3_prepublished_write_eof.c` |
| `run_mc3_repro.sh` | `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-3/run_mc3_repro.sh` (driver that uses `AUTO_TEST=mc3repro` in a confirmation worktree that no longer exists) |
| `glm-autotest-targets.patch` | `git diff Makefile` in the GLM MC-4 confirmation worktree (pattern for `AUTO_TEST` repro targets, with no `mc3repro` branch) |

## What it tests

Single thread, deterministic (Level 0). The optional argument is the ramfs
directory (default `/tmp`). Phases:

- `ramfs_zero_pwrite`: `pwrite64(fd, buf, 2, 6)` on a 6-byte file with a
  `PROT_NONE` buffer (exact counterexample shape).
- `ramfs_zero_write`: the same fault through `write` on the shared offset.
- `ramfs_prefix_pwrite`: two-page buffer, second page `PROT_NONE`. EOF must
  equal the committed prefix.
- `memfd_zero_pwrite`: memfd files are ramfs too.
- `ext2_zero_pwrite_ctrl`: the same operation on `/ext2` (control).

## How to run

Asterinas: place the file under `test/initramfs/src/regression/io/file_io/`
and run it after the default init has mounted `/ext2`. The `mc3repro` Makefile
target was not retained. `glm-autotest-targets.patch` shows the pattern for
`mc1repro` and `mc4repro`. Add an analogous `mc3repro` branch with a completion
grep for `^MC3_REPRO_DONE`. Linux: `gcc -O2` and run
it.

## Output

- FAIL on Asterinas at the pin: `MC3_VERDICT ramfs_zero_pwrite BUG (size grew on zero-progress fault)`
  (`st_size=8`), `ramfs_zero_write BUG`, `ramfs_prefix_pwrite BUG (EOF != committed prefix)`
  (`ret=-1`, `st_size=8192`, `committed_prefix=4096`), `memfd_zero_pwrite BUG`,
  `ext2_zero_pwrite_ctrl CLEAN`, `bug_phases=4`.
- PASS (Linux control): every ramfs and memfd phase `CLEAN`, `st_size=6`, and
  the prefix write returns 4096 with `st_size=4096`. The Linux run skipped the
  ext2 control for lack of `/ext2`.

The prefix phase also exercises AST-02's nonempty-fault path, which the
current empty-write fix batch does not cover.

## SMP

Sequential. The GLM guest used SMP=2.
