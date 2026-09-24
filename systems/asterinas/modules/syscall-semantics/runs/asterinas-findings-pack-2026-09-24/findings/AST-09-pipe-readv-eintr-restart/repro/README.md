# AST-09 reproducers

## Files and where they came from

| File | Source |
|---|---|
| `repro.c` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-09-pipe-readv-eintr-restart/repro.c`, byte-identical to the GLM run's `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugCR-2_eintr_restart_divergence.c` |
| `repro-min.c` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-09-pipe-readv-eintr-restart/repro-min.c` |
| `run.sh` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-09-pipe-readv-eintr-restart/run.sh` |
| `vectored_io_restart-regression.patch` | `git diff f80ee60c2^ f80ee60c2` in `/home/chin39/Documents/asterinas-dev` (test commit of the local branch `fix/vectored-io-restart`). The same diff is in `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/upstream-issues/AST-09-patches/0002-*.patch`. |
| `syscall_restart-cases-for-pr3576.patch` | `git diff a57ded014^ a57ded014` in `/home/chin39/Documents/asterinas-dev` (branch `scratch/3576-on-main`). The upstream-issues copy is `AST-09-patches/for-pr-3576/0001-*.patch`. |

## Where they go in an Asterinas tree

The guest has no compiler. For `repro.c` and `repro-min.c`, copy them (for
example as `ast09.c` and `ast09_min.c`) into a regression test directory such
as `test/initramfs/src/regression/io/specula/`, register it, and boot with a
custom init script, as `docs/running-reproducers.md` describes.

`vectored_io_restart-regression.patch` adds
`test/initramfs/src/regression/process/signal/vectored_io_restart.c` and one
line to `process/run_test.sh`, and runs in the normal process suite
(`make run_kernel AUTO_TEST=regression`). It was written on `e60087be1`.
`git apply --check` also passes on `604948581` and `bc12195df` (checked
2026-09-24, not built there).

`syscall_restart-cases-for-pr3576.patch` edits
`test/initramfs/src/regression/process/signal/syscall_restart.c`, which exists
only on a tree that contains PR #3576. It was checked with `git apply --check`
against the PR head `8e02d0e94`.

No kernel hooks are needed.

## Build and run

Linux control:

```sh
cc -Wall -O2 -o /tmp/ast09 repro.c && /tmp/ast09
cc -Wall -O2 -o /tmp/ast09_min repro-min.c && /tmp/ast09_min
```

Asterinas guest, `SMP=2`:

```sh
/test/io/specula/ast09
/test/io/specula/ast09_min
```

Neither program takes arguments. Each check waits about 2 s (the child sleeps
1 s before the signal and 1 s before making the pipe ready), so a full run
takes about 10 s. `repro.c` also creates and removes
`/tmp/cr2_pread_sanity.bin`.

## Reading the output

`repro.c` prints one `CR2 <n> <description>: PASS|FAIL (...)` line per check
and a summary.

| Check | Unfixed Asterinas (`604948581`) | Linux |
|---|---|---|
| 1 `read()` empty pipe (control) | `PASS (ret=1 signals=1)` | PASS |
| 2 `readv()` empty pipe | `FAIL (ret=-1 errno=4 (Interrupted system call) signals=1)` | PASS |
| 3 `write()` full pipe (control) | `PASS` | PASS |
| 4 `writev()` full pipe | `FAIL (ret=-1 errno=4 ...)` | PASS |
| 5 `pread64()` sanity | `PASS (ret=7)` | PASS |
| `CR2_RESULT` | `FAIL (5 checks, 2 failed)` | `PASS (5 checks, 0 failed)` |

Checks 1 and 3 must pass on both kernels, because they show that the signal
and restart machinery works for the translated scalar calls. If they fail, the
harness is broken. `signals=1` confirms the handler ran. The program prints
`CR2_REPRO_DONE` and exits 0 either way.

`repro-min.c` prints one line per call, ending in `restarted` or
`NOT restarted`. On the unfixed kernel `readv` and `writev` print
`ret=-1 errno=4 Interrupted system call signals=1: NOT restarted`. On Linux all
four print `restarted`.

The regression test prints `test_<name> summary: N tests passed, M tests failed`
and exits nonzero on failure. Without a fix, `readv_on_empty_pipe_restarts` and
`writev_on_full_pipe_restarts` fail, and `readv_on_empty_pipe_fails_without_sa_restart`
passes on both kernels.
