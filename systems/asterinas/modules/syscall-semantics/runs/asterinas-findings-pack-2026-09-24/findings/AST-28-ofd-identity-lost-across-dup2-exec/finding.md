# AST-28: OFD identity allegedly lost across dup2/exec

| Field | Value |
|---|---|
| Evidence status | FALSE POSITIVE |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding CR-1 (code review), Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none |
| Syscalls | `read` (blocking, in flight), `close`, `dup2`/`dup3`, `fcntl(F_SETFD, FD_CLOEXEC)`, `execve`, `pipe`, `write` |
| Upstream | Non-actionable record (`NON_ACTIONABLE_RECORD` against upstream main `bc12195df`): keep the FALSE POSITIVE at its tested pin. Reviewed for context only: merged PR [#1277](https://github.com/asterinas/asterinas/pull/1277) and open issue [#200](https://github.com/asterinas/asterinas/issues/200), which concern epoll and fork identity, not this claim. Upstream fix status: not applicable. |
| Fix | Not applicable. The run recommends no product change and keeping the test as identity coverage. |
| Reproducer | repro/ (negative result: the test PASSED on Asterinas at `4ba4abbe8cb3`, SMP=2) |

## Summary

The code-review candidate claimed that an operation that had already looked up
a descriptor, or a deferred cleanup, could end up acting on a different open
file description (OFD) after the descriptor number was closed and reused with
`dup2`, and that the exec-time close-on-exec cutover could close the wrong
object. Source review and a public-API test on Asterinas showed that identity
is preserved in all three cases. Do not re-report this claim without new
evidence of a different mechanism.

## Linux contract

`dup2(2)` makes the new descriptor refer to the same OFD as the old one.
`close(2)` (section on multithreaded processes) says that on Linux a blocking
I/O call holds a reference to the underlying OFD, which keeps it open until the
call completes, so closing and reusing the number does not redirect the
in-flight call. `execve(2)` closes
only descriptors marked close-on-exec, and `fcntl(2)` says `FD_CLOEXEC` is a
per-descriptor flag, so a non-CLOEXEC duplicate of the same OFD survives.

- https://man7.org/linux/man-pages/man2/dup.2.html
- https://man7.org/linux/man-pages/man2/close.2.html
- https://man7.org/linux/man-pages/man2/execve.2.html

## Asterinas behavior

What the source does at the pin, which is why the claim fails:

- `kernel/core/src/fs/file/file_table.rs::FileTable::dup_exact` clones the
  source `Arc<dyn FileLike>` through `FileTable::duplicate_entry` before it
  removes the destination entry, then installs the clone in the exact slot.
- `kernel/core/src/fs/file/file_table.rs::FileTable::close_file` returns a
  `ClosedFile` that holds the removed file object. `sys_dup3` drops it after
  releasing the table lock, so cleanup acts on the removed object, not on the
  descriptor number.
- The `get_file_fast!` macro in `kernel/core/src/fs/file/file_table.rs` clones
  the `Arc` and releases the lock on a shared table because file operations can
  block, so a blocking `read` keeps its captured object.
- `kernel/core/src/process/execve.rs::do_execve_no_return` waits for all other
  threads to exit before the cutover, and
  `kernel/core/src/process/execve.rs::unshare_and_close_files` installs a
  private copy of the table and then removes only CLOEXEC entries from it.

## Reproduction

The negative result is reproducible with `repro/test_bugCR-1_ofd_identity.c`.
Level 0 runs 16 samples of: a second thread blocks in `read` on pipe A, the
main thread closes that descriptor number, reuses it for pipe B with `dup2`,
writes both pipes, and checks that the blocked read returns pipe A's byte.
Level 1 repeats this 16 times with a 20 ms delay after the reader starts. The
test then checks `dup2` replacement with a retained duplicate, and a self-exec
where the CLOEXEC slot must be `EBADF` while a retained duplicate still reads
the pipe byte.

Recorded Asterinas SMP=2 output at the pin (the program prints literal `\n`
sequences):

```text
CR-1 OFD identity regression start\nCAPTURE L0 old=16 raced_ebadf=0 raced_new=0 errors=0\nCAPTURE L1 old=16 raced_ebadf=0 raced_new=0 errors=0\nDUP-REPLACE PASS target=100 retained_b=41\nEXEC-CUTOVER PASS closed=100 kept=101\nCR-1 RESULT: PASS (captured and surviving descriptors kept their OFDs)\n
```

The model hunts that cover descriptor replacement and exec
(`MC_hunt_s1_replacement`, `MC_hunt_s1_fd_exec`, `MC_hunt_s1_exec`) also found
no violation.

## Fix and upstream status

No fix is needed. The dedup pass classified this as a non-actionable record
and noted that historical fork identity issues do not override the tested
disposition.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 7)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-1/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-1/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-1/turn01_A.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/build-cr1/ (build byproducts and early failed launch logs)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/bug-report.md ("Not Reproduced" table)
- /home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md (section "Historical FD/epoll full run")

## Caveats

- The guest serial log (`confirmation/CR-1/worktree/qemu-serial.log`) was
  removed with the worktree. The PASS output survives only in
  `investigation.md` and `turn01_A.log`. The retained
  `repro/build-cr1/guest-run-local-osdk.log` records an earlier failed launch
  (`no such command: osdk`), not the passing run.
- The sample is small (16 plus 16 captured-read attempts) and uses pipes only.
  Other file types were not tested.
- The test's exit status does not fail when a read returns pipe B's byte
  (`raced_new`), because that can be legitimate if the reader had not yet
  looked up the descriptor. The evidence is the recorded counts
  (`old=16 raced_new=0` at both levels), not the exit status alone.
- The debate did not run (0 rounds). Turn A alone reached FALSE POSITIVE.
- The original candidate cited `kernel/core/src/syscall/execve.rs:161`, which
  does not exist at the pin. The cutover lives in
  `kernel/core/src/process/execve.rs`.
- The disposition is tied to pin `4ba4abbe8cb3`.
