# CR-1 investigation

## Scope and revision

- Finding: CR-1, code-review source.
- Worktree revision: `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
- The worktree has pre-existing Specula trace instrumentation. The cited
  file-table and process-exec logic below is unchanged by that instrumentation.

## Code audit

### Descriptor replacement and deferred cleanup

- `FileTable::dup_exact` first calls `duplicate_entry`, which clones the source
  `Arc<dyn FileLike>` before it removes the destination entry, then installs
  that cloned source in the exact destination slot
  (`kernel/core/src/fs/file/file_table.rs:169-187`).
- `close_file` removes the `FileTableEntry` and returns a `ClosedFile` holding
  the removed file object, rather than retaining or later resolving its numeric
  descriptor (`kernel/core/src/fs/file/file_table.rs:196-205,274-302`).
- `sys_dup2` and `sys_dup3` call that operation while holding the file-table
  write lock. `sys_dup3` releases the lock before dropping the `ClosedFile`, so
  the cleanup operates on the removed `Arc`, not on `new_fd`
  (`kernel/core/src/syscall/dup.rs:56-102`).

### Captured operations

- On an unshared table, `get_file_fast!` returns a borrow only while the caller
  owns the exclusive thread-local table reference. On a shared table, it holds
  the read lock, clones the `Arc`, and releases the lock before the file
  operation can block (`kernel/core/src/fs/file/file_table.rs:326-366`).
- A normal blocking read is a concrete caller: `sys_read` obtains the file
  through `get_file_fast!` and invokes `file.read` on that captured object
  (`kernel/core/src/syscall/read.rs`). A close/reuse after that lookup therefore
  has to affect the slot only; the in-flight read retains the old object.

### Exec cutover

- `do_execve_no_return` waits for every other thread to exit before it reaches
  file-table cutover (`kernel/core/src/process/execve.rs:161-187`).
- `unshare_and_close_files` first clones the current table with
  `FileTable::fork_from`, installs the clone, then removes CLOEXEC entries from
  that private table. The returned `ClosedFile` objects are dropped by object
  identity (`kernel/core/src/process/namespace/unshare.rs:18-28`,
  `kernel/core/src/process/execve.rs:378-387`).
- The supplied `kernel/core/src/syscall/execve.rs:161` location no longer
  exists at this revision because the cutover lives in
  `kernel/core/src/process/execve.rs`; the relevant current line 161 is the
  thread-exit wait described above.

## Reachable trigger to exercise

1. Create an empty pipe A and start a second thread blocking in `read(A.read)`.
2. Close the numeric descriptor in the first thread, reuse that same number
   with pipe B via `dup2`, then write B.
3. A captured operation must remain blocked until A is written and must return
   A's byte, never B's byte.
4. Independently, replace a destination descriptor with `dup2`, retain another
   duplicate of the displaced object, then verify both the replacement and the
   retained duplicate by pipe data.
5. Set CLOEXEC on one duplicate of a pipe, retain a non-CLOEXEC duplicate, and
   exec the test binary. The CLOEXEC slot must be EBADF after exec while the
   retained duplicate still reads the pipe byte.

These are all normal public syscall sequences. The only intended timing help is
a bounded sleep after the reader has started, to increase the chance that the
blocking read has captured pipe A before close/reuse.

## Developer knowledge and tests

- The macro documentation explicitly states that the shared-table path clones
  the file because file operations can block
  (`kernel/core/src/fs/file/file_table.rs:335-337`).
- Blame associates the deferred-close implementation with merged PR
  [#3654](https://github.com/asterinas/asterinas/pull/3654), which describes
  range-lock ownership and atomic-context cleanup, not numeric-FD/OFD
  redirection. It is relevant implementation history but not a report of this
  mechanism.
- The `dup_exact` shape arrived with merged PR
  [#3027](https://github.com/asterinas/asterinas/pull/3027). Its reported bug
  is invalid-source `dup2`/`dup3` error semantics; it does not report an
  operation redirected after descriptor reuse.
- Merged PR [#2459](https://github.com/asterinas/asterinas/pull/2459) states
  that multithreaded exec sends SIGKILL to other threads and waits before the
  exec transition. This matches the current `wait_other_threads_exit` gate.
- Existing source tests cover invalid-source `dup2` preservation in
  `test/initramfs/src/regression/io/file_io/file_err.c:27-38` and normal
  multi-threaded exec behavior under
  `test/initramfs/src/regression/process/execve/`; neither is this
  close/reuse-of-a-captured-OFD sequence.

## Known-status / precedent search

On 2026-08-13, I searched open and closed issues plus merged PRs through the
GitHub issue tracker for `dup2 file descriptor reuse`, `close-on-exec file
table`, `OFD`, `close_files_on_exec`, `file descriptor reuse`, `file table
atomic`, `open file description`, `duplicate_entry`, `close_file dup`, and
`CLOEXEC race`. I also inspected the recent merged PRs returned by those
searches, including #3027, #3654, and #2459. No issue, PR, CVE, advisory, or
Specula dataset entry accessible in this scoped search reports the same
mechanism at these sites: a captured operation or deferred cleanup resolving a
reused numeric descriptor as a different OFD.

Novelty candidate for Phase 2: `NEW`.

## Phase 2 reproduction

- Test source: `repro/test_bugCR-1_ofd_identity.c`; it was compiled as a static
  guest binary and executed by `/test/run_bugCR-1_ofd_identity.sh` in an
  isolated local Asterinas VM.
- The final guest run used the checked-out local OSDK, the pinned
  `nightly-2026-07-21` toolchain, KVM, and `SMP=2`. The repository QEMU-argument
  generator expands that environment value to `-smp 2`.
- Level 0 ran the public pipe/read/close/dup2 sequence 16 times without a
  delay. Level 1 ran it 16 more times with only a 20 ms scheduling delay after
  the reader-start handshake. Both samples observed the old pipe object.
- Level 2 and Level 3 were not used: a normal-operation result already
  contradicted the claimed redirection mechanism, so state injection or a
  source change would not be a valid escalation.

Guest output (`worktree/qemu-serial.log`):

```text
CR-1 OFD identity regression start\nCAPTURE L0 old=16 raced_ebadf=0 raced_new=0 errors=0\nCAPTURE L1 old=16 raced_ebadf=0 raced_new=0 errors=0\nDUP-REPLACE PASS target=100 retained_b=41\nEXEC-CUTOVER PASS closed=100 kept=101\nCR-1 RESULT: PASS (captured and surviving descriptors kept their OFDs)\n
```

The minimal guest init also attempted mounts of disposable blank ext2/exfat
auxiliary drives and reported `Invalid argument`; it continued to the test.
The test uses only pipes, descriptor operations, threads, and exec, and the
recorded pass lines follow those unrelated mount messages.
