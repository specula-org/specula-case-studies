# MC-1 — Investigation (Phase 1, evidence only)

Finding: "A positive read prefix is exposed but returned as EFAULT".
Source: model checking, `MC_hunt_scenario_1_positive_copy_progress.cfg`,
invariant `MCReportedCoversVisibleCopy`.
Counterexample: `spec/output/MC_hunt_scenario_1_positive_copy_progress_bfs.out`.

Tree under audit: `.../confirmation/MC-1/worktree`, single-commit baseline
`2cd6429` = upstream Asterinas `604948581512d83734377974d4c34adb4530f2d7`.
All line numbers below are from the pristine tree (`git show HEAD:<path>`),
not from the Specula trace-harness patch.

## Counterexample, reduced

The violating behavior is 10 states; the decisive step is
`MCFileOpsReadAtCopyFaultPositive(t1)` (State 6). Final state (State 10) for
actor `t1`:

    opKind        = "SharedRead"
    requested     = "Complete"
    copyFault     = TRUE
    copied        = "Positive"     copiedTotal  = 1
    visibleTotal  = 1              <- user buffer already changed
    reported      = "Zero"         reportedTotal = 0
    result        = "Fault"
    ofdOffset     = 0              <- shared offset never moved
    entryResult   = "EntryFault"

`MCReportedCoversVisibleCopy` fails because `reportedTotal (0)` does not cover
`visibleTotal (1)`: the syscall reports zero bytes while a positive prefix is
already visible in the user buffer, and the open-file description offset is
unchanged.

## Step 1 — Code audit

### The call chain (read, shared offset, regular file)

1. `kernel/core/src/syscall/read.rs:29-38`
   `let mut writer = user_space.writer(user_buf_addr, buf_len)?; file.read(&mut writer)`
   then `.map_err(...)?` — a scalar `Err` aborts the syscall and
   `SyscallReturn::Return(read_len)` is never reached.
2. `kernel/core/src/context.rs:113-117` → `ostd/src/mm/vm_space.rs:180-195`
   The writer is created **without** validating that the range is mapped:
   `context.rs:104-106` says so explicitly — *"adding any pointer check here
   would break Asterinas's delayed buffer validation behavior"*. The fault is
   therefore taken during the copy, not before it.
3. `kernel/core/src/fs/file/inode_handle.rs:273-290` (`FileLike::read`)

        let mut offset = self.offset.lock();
        let len = file_ops.read_at(*offset, writer, status_flags)?;   // :287
        *offset += len;

   `?` returns before `*offset += len`, so a faulting attempt leaves the shared
   offset untouched.
4. `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:229-243` (`read_at`)

        self.page_cache().read(offset, writer)?;    // :241
        Ok(read_len)

   `read_len` — the only place the byte count exists — is discarded by `?`.
   `kernel/core/src/fs/fs_impls/ramfs/fs.rs:695-719` has the identical shape
   (`page_cache.lock().read(offset, writer)?;` at :709), so both backends erase
   the count.
5. `kernel/core/src/vm/page_cache/vmo/mod.rs:533-566` (`Vmo::read`)

        page.reader().skip(page_offset).read_fallible(writer)?;   // :557

   `Vmo::read` returns `Result<()>`: progress is communicated only through the
   writer's cursor. `?` here maps `(Error, usize)` to a scalar `Error`.
6. `ostd/src/mm/io/mod.rs:337-364` (`read_fallible`)

        let copied_len = unsafe { memcpy::<...>(writer.cursor, self.cursor, copy_len) };
        self.cursor   = self.cursor.wrapping_add(copied_len);
        writer.cursor = writer.cursor.wrapping_add(copied_len);   // :355
        if copied_len < copy_len { Err((Error::PageFault, copied_len)) } else { Ok(copied_len) }

   **The user buffer is already modified and the cursor already advanced when
   the `Err` is returned.** The count survives only inside the tuple.
7. `kernel/core/src/error.rs:209-214`

        impl From<(ostd::Error, usize)> for Error {
            // Used in fallible memory read/write API
            fn from(ostd_error: (ostd::Error, usize)) -> Self { Error::from(ostd_error.0) }
        }

   This is the erasure. `ostd::Error::PageFault` → `Errno::EFAULT`
   (`error.rs:200`); the `usize` is dropped on the floor.

So `copied` is produced at (6), destroyed at (7), and every layer above (5, 4,
3, 1) has no way to recover it. The three observables the invariant compares —
result, visible copy, OFD progress — are therefore guaranteed to disagree
whenever `0 < copied_len < copy_len`.

### Reachability

`__memcpy_fallible` (`ostd/src/arch/x86/mm/memcpy_fallible.S`) is a plain
`rep movsb` with an `.ex_table` fixup, so it copies byte-by-byte and returns
`size - rcx`, i.e. an exact partial count. Any user buffer that straddles a
mapped/unmapped boundary yields `0 < copied_len < copy_len`.

Trigger, entirely through public syscalls (escalation Level 0):

    m   = mmap(NULL, 3*PAGE, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
    mprotect(m + PAGE, 2*PAGE, PROT_NONE);
    buf = m + PAGE - 128;                  // 128 writable bytes, then a hole
    fd  = open(regular_file, O_RDONLY);    // file >= 1 page
    read(fd, buf, 8192);

`Vmo::read` copies page-cache page 0 into `buf`: `copy_len = 4096`,
`copied_len = 128`, fault. This buffer shape is not contrived — it is what a
buffer at the tail of an mmap arena next to a guard page looks like. The
existing Specula trace harness already builds exactly this buffer
(`alloc_fault_buffer(kind=2)`, `test/initramfs/src/regression/io/specula/specula_io_trace.c:92-119`).

### Safeguards encountered

None on this path. `read.rs:34-38` only rewrites `EINTR`→`ERESTARTSYS`; every
other error is returned to user space verbatim. Nothing downstream re-reads,
re-syncs, or repairs the user buffer or the offset.

Note `read.rs:40` (`if read_len > 0 { on_access(&file) }`) is also skipped, so
even the access notification disagrees with the fact that data was delivered.

## Step 2 — Developer-knowledge search

- **Issue tracker.** `asterinas/asterinas#711`, *"Wrong behavior when `EFAULT`
  occurs in the middle of I/O system calls"*, opened 2024-03-23, **still open**.
  Its PoC is the same shape as the trigger above (a buffer at
  `page + PAGE_SIZE - 1`), and it records the same divergence:
  Linux `read(fd, buf, 2)` → `1` with `buf[0] == 'a'`; Asterinas → `Bad address`
  with `buf[0]` unchanged. The issue attributes the behavior to the *then*
  implementation ("allocating kernel buffers before processing system calls")
  and cites `kernel/aster-nix/src/syscall/read.rs` / `write.rs` at
  `f924eb36`. That bounce-buffer implementation is gone: PR #1156
  ("Refactor all io APIs of vfs based on `VmReader`/`VmWriter`", cross-
  referenced from #711) replaced it with the fallible-cursor design audited
  above. The mechanism cited in #711 no longer exists; the symptom persists
  through the new tuple-to-scalar erasure at `error.rs:209`.
- **Commits / blame.** The worktree is a squashed baseline, so `git log -L` on
  the site yields only `2cd6429`. No in-tree rationale for dropping the count.
- **Comments / docs.** `error.rs:210` carries only `// Used in fallible memory
  read/write API`; no note that the count is intentionally discarded.
  `context.rs:96-107` documents the *opposite* intent — delayed buffer
  validation exists precisely so that a partially valid buffer is copied as far
  as it goes rather than rejected up front. Discarding the resulting count
  defeats that design.
- **Tests.** No test in `test/initramfs/src/regression/io/file_io/` asserts
  EFAULT-after-positive-progress for `read`, so nothing pins the current
  behavior as intended.

## Step 3 — Known status / precedent

`#711` reports this defect as a filed, still-open bug: same syscall, same
observable (EFAULT where Linux returns a positive short count), same
partially-mapped-buffer trigger. The campaign brief also names #711 as
mechanism context that must not be presented as a new finding.

→ **Novelty: KNOWN**
  (cite: https://github.com/asterinas/asterinas/issues/711; fix-status: unfixed).
  Verified unfixed against upstream `main` at confirmation time:
  `kernel/core/src/error.rs:209-214` and `kernel/core/src/fs/file/inode_handle.rs:287`
  are byte-identical to the baseline.

Pre-filter does **not** apply: the pre-filter drops *code-review*-sourced
findings that duplicate an existing report. This finding is MC-sourced with a
real counterexample, so it proceeds to Phase 2 unfiltered.

Not matches (checked, different mechanism): #3181 (`sendfile` drops the tail of
an already-read chunk after a short PTY write), #1554 (pipe `PIPE_BUF`
atomicity), #2835 (ext2 `O_DIRECT` cannot return data from disk).

## Reachability assessment

Reachable at escalation Level 0 through `mmap` + `mprotect` + `read`, with no
fault injection, no timing assistance, and no privileged operation. The
counterexample's decisive step `MCFileOpsReadAtCopyFaultPositive` corresponds
directly to `read_fallible` returning `Err((PageFault, copied))` with
`0 < copied < copy_len`.
