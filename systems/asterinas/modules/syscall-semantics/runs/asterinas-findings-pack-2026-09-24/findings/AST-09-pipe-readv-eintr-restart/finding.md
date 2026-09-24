# AST-09: Pipe readv/writev return EINTR despite SA_RESTART

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | GLM `asterinas-glm53-eval-20260826T035049Z`, finding CR-2, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none. The 01a run's CR-1 (AST-26, FALSE POSITIVE) checked the same code asymmetry but only for regular files, which have no `EINTR` producer. |
| Syscalls | `readv`, `writev`, and `preadv2`/`pwritev2` with offset `-1` (live on pipes). `pread64`, `pwrite64`, `preadv`, and `pwritev` lack the same translation but have no reachable `EINTR` producer today. |
| Upstream | Open PR covers it by inspection: [#3576](https://github.com/asterinas/asterinas/pull/3576) "Refactor the syscall restart machnism", head `8e02d0e94`, open on 2026-09-24. Also reviewed: closed issue [#1578](https://github.com/asterinas/asterinas/issues/1578) (origin of the restart machinery) and closed unmerged PR [#3607](https://github.com/asterinas/asterinas/pull/3607) (socket timeouts). |
| Fix | PR #3576 (third-party, not merged). Local branch `fix/vectored-io-restart` in `/home/chin39/Documents/asterinas-dev` (`10b2439cd` fix, `f80ee60c2` test, on `e60087be1`), validated, not pushed. The issue draft offering test cases to #3576 is not filed. |
| Reproducer | repro/ (runtime REPRODUCED at `604948581`, SMP=2) |

## Summary

A blocking `readv()` on an empty pipe, or `writev()` on a full pipe, returns
`-1`/`EINTR` when a signal arrives, even though the handler was installed with
`SA_RESTART`. Scalar `read()` and `write()` on the same pipe restart correctly.
Any unprivileged program that uses vectored I/O on pipes together with
`SA_RESTART` handlers sees spurious `EINTR` failures that Linux never
produces.

## Linux contract

signal(7), "Interruption of system calls and library functions by signal
handlers": if a blocked call to `read(2)`, `readv(2)`, `write(2)`, `writev(2)`,
or `ioctl(2)` on a "slow" device (a pipe counts) is interrupted by a handler
installed with `SA_RESTART`, the call is automatically restarted after the
handler returns. The Linux host control of `repro.c` passed 5 of 5 checks in
every run (4 runs in the GLM confirmation, plus Linux 7.1.9 on 2026-09-02).

## Asterinas behavior

At pin `604948581`:

- `kernel/core/src/syscall/read.rs::sys_read` (lines 37-39) and
  `kernel/core/src/syscall/write.rs::sys_write` (lines 36-39) map `EINTR` to
  the internal `ERESTARTSYS`.
- `kernel/core/src/syscall/preadv.rs::do_sys_readv` and
  `kernel/core/src/syscall/pwritev.rs::do_sys_writev` return the error raw.
  `pread64.rs` and `pwrite64.rs` also have no translation.
- The `EINTR` comes from the pipe wait:
  `kernel/core/src/fs/pipe/common.rs::PipeHandle::read_at` (and `write_at`)
  calls `wait_events`, which goes through `Poller::wait` to
  `kernel/core/src/process/signal/pause.rs::Pause::pause_timeout` and returns
  `Err(EINTR)` when a signal is pending.
- `kernel/core/src/process/signal/mod.rs::handle_pending_signal` rewinds a
  syscall for `SA_RESTART` only when its return value is `-ERESTARTSYS`, so the
  raw `EINTR` reaches userspace.

Issue #1578, which introduced the restart machinery, listed read, write, ioctl,
open, wait, waitpid, fcntl locks, and futex. The vectored and positional
wrappers were left out.

## Reproduction

- `repro/repro.c`: the GLM confirmation program, byte-identical to
  `test_bugCR-2_eintr_restart_divergence.c` in the GLM run. It installs a
  `SIGUSR1` handler with `SA_RESTART`, forks a child that signals the parent
  after 1 s and makes the pipe ready 1 s later, and runs five checks: scalar
  `read` (control), `readv` (bug), scalar `write` (control), `writev` (bug),
  and a `pread64` sanity check.
- `repro/repro-min.c`: a 100-line version used in the #3576 validation and in
  the issue draft.
- `repro/vectored_io_restart-regression.patch`: the in-tree regression test
  from the local fix branch (`process/signal/vectored_io_restart`, three cases).
- `repro/syscall_restart-cases-for-pr3576.patch`: `readv` and `writev` cases
  for #3576's own `process/signal/syscall_restart.c`. It applies only on a tree
  that already contains #3576.

Recorded results:

| Tree | Result |
|---|---|
| `604948581`, GLM confirmation, 2026-08-28 (Docker `asterinas/dev:0.18.1-20260805`, KVM, SMP=2, 2G) | checks 2 and 4 `FAIL (ret=-1 errno=4 ...)`, checks 1 and 3 PASS in the same boot, `CR2_RESULT: FAIL (5 checks, 2 failed)`. The challenger reproduced it in an independent boot. |
| `604948581`, 2026-09-02 (QEMU/KVM, SMP=2) | checks 2 and 4 FAIL, controls PASS |
| `e60087be1` with the test but without the fix (Run B) | `readv_on_empty_pipe_restarts` and `writev_on_full_pipe_restarts` fail, `readv_on_empty_pipe_fails_without_sa_restart` passes |
| `d76b4dcc0` (main, unpatched, Run D) | `repro-min`: `readv`/`writev` `ret=-1 errno=4 ... NOT restarted`, `read`/`write` restarted |
| `d76b4dcc0` plus #3576 plus the two cases (Run C) | `syscall_restart` 8 of 8 cases, 55 of 55 checks pass |
| Linux 7.1.9 and 7.1.12 | 5/5 PASS (`repro.c`), all four restarted (`repro-min.c`), 22/22 (`vectored_io_restart`), 8/8 cases (`syscall_restart`) |

## Fix and upstream status

- Upstream dedup (2026-09-14): `OPEN_PR_COVERS`. PR #3576 makes the `pause`
  family return `ERESTARTSYS` directly and removes the per-syscall `EINTR`
  mapping, which fixes pipe `readv`/`writev` as a side effect. It never touches
  `preadv.rs` or `pwritev.rs`, and its `syscall_restart.c` had no
  `readv`/`writev` case. It had no human review as of 2026-09-03 and was still
  open on 2026-09-24, last updated 2026-07-23.
- Decision recorded on 2026-09-03: file an issue that references #3576 and
  offer the two test cases as a patch to that PR. Keep the standalone fix as a
  fallback. Neither the issue nor the fallback PR has been filed.
- Local fix branch `fix/vectored-io-restart`: `10b2439cd` maps `EINTR` to
  `ERESTARTSYS` in `do_sys_readv`/`do_sys_writev` (zero-progress arm only), and
  `f80ee60c2` adds the regression test. Validation on 2026-09-02: format and
  clippy passed, the full regression suite passed with the network suite and
  NVMe test skipped (pre-existing failures), and `vectored_io_restart` passed
  22/22.
- Drafts and patches:
  `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/upstream-issues/AST-09-issue-draft.md`,
  `AST-09-pr-draft.md`, and `AST-09-patches/` in the same directory.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-09-pipe-readv-eintr-restart/description.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/CR-2/` (`investigation.md`, `debate.md`, `verdict.json`)
- `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugCR-2_eintr_restart_divergence.c`, `.guest_output.log`, `.guest_qemu_full.log`, `.challenger_rerun.log`, `.linux_control.txt`
- `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmed-bugs.md` (entry 6)
- `/home/chin39/Documents/play/specula-profile/reports/glm53-eval-final-report.md`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/README.md` ("AST-09 fix validation" and "AST-09 via #3576")
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/ast09/` and `logs/ast09-3576/`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/linux-7.1.9-AST-09.txt`, `linux-7.1.9-ast09-vectored_io_restart.txt`, `linux-7.1.12-ast09-repro-min.txt`, `linux-7.1.12-3576-syscall_restart.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scripts/ast09-validate.sh`, `ast09-3576-validate.sh`, `ast09-3576-unpatched.sh`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (entry `AST-09`)

## Caveats

- The `pread64`/`pwrite64` half of the original finding is latent: local
  regular-file backends have no interruptible wait, and pipes and sockets are
  not seekable (`ESPIPE`). Only vectored I/O on pipes is a live trigger.
- The "restart replays committed bytes" hazard would need an `EINTR` after
  progress. No current path produces one, and `do_sys_readv` returns a short
  count once some bytes have been transferred.
- The GLM confirmation worktree for CR-2 no longer exists (the directory has
  no `worktree/`), so the guest wiring it used (`AUTO_TEST=cr2repro` in a
  patched Makefile) is not preserved. The reproducer source and its logs are
  in the run's `.specula-output/repro/`.
- Linux and Asterinas ran separately compiled builds of the same source.
- AST-39 (socket timeout and restart progress) and AST-44 (pipe `readv`
  blocking after a positive prefix) are separate source leads near this path.
