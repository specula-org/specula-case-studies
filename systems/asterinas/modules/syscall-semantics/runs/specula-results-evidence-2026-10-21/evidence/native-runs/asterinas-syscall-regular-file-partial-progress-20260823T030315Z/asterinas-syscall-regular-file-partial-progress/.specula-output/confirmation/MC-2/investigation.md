# MC-2 — Investigation (Phase 1, evidence only)

Finding: "A retained write prefix is returned as EFAULT with no offset progress"
Source: model checking, counterexample
`spec/output/MC_hunt_scenario_1_mixed_page_prefix_bfs.out`
Invariant: `MCMixedPageRetainedPrefixReported`
Config: `MC_hunt_scenario_1_mixed_page_prefix.cfg`

Tree under test: `.specula-output/confirmation/MC-2/worktree`,
baseline commit `2cd6429` ("Asterinas 604948581 pristine baseline"), VERSION 0.18.1.
The worktree carries the Specula trace harness on top of that baseline; all
line references below give BOTH the instrumented line (as cited in the finding)
and the pristine line.

## Step 1 — Code audit

### 1.1 The cited sites

| Cited (instrumented) | Pristine | Code |
|---|---|---|
| `ostd/src/mm/io/mod.rs:354` | same (file unmodified) | `Err((Error::PageFault, copied_len))` in `read_fallible` |
| `kernel/core/src/vm/page_cache/vmo/mod.rs:734` | `:733-745` | partial-write arm of `write_pages_with_backend` |
| `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:353` | `:262-265` | `InodeInner::write_at` error arm |
| `kernel/core/src/error.rs:209` | same (file unmodified) | `impl From<(ostd::Error, usize)> for Error` |
| `kernel/core/src/fs/file/inode_handle.rs:367` | `:317-319` | `InodeHandle::write` error propagation |

### 1.2 The chain, bottom-up

**(a) `ostd` produces a progress-carrying error.** `ostd/src/mm/io/mod.rs:333-364`
(`impl_read_fallible!`) copies as much as it can and, on a short copy, returns
the byte count alongside the error:

```rust
self.cursor  = self.cursor.wrapping_add(copied_len);
writer.cursor = writer.cursor.wrapping_add(copied_len);
if copied_len < copy_len {
    Err((Error::PageFault, copied_len))     // ostd/src/mm/io/mod.rs:354
} else { Ok(copied_len) }
```

Note the cursors are advanced by `copied_len` even on the error path, so the
progress is recoverable by the caller in two independent ways: the returned
`copied_len`, and `reader.remain()`.

**(b) The page cache retains the prefix, then throws the count away.**
`kernel/core/src/vm/page_cache/vmo/mod.rs` (pristine `733-752`):

```rust
let written_size = match locked_page.writer().skip(*page_offset).write_fallible(reader) {
    Ok(written_size) => written_size,
    Err((err, written_size)) => {
        // If the page is not initialized, keep it as it is on a partial write.
        if written_size > 0 && state.is_up_to_date() {
            locked_page.set_dirty();                 // <-- prefix RETAINED
        }
        return Err(Error::from(err));                // <-- count ERASED (pristine :745)
    }
};
if written_size > 0 {
    locked_page.set_dirty();                         // <-- fully copied page RETAINED
}
```

Two distinct ways a positive prefix survives a failing `write()`:
- an earlier page in the same call is copied in full → `Ok` arm → `set_dirty()`;
- the faulting page itself is `UpToDate` and took a positive prefix → `Err` arm
  → `set_dirty()`.
Either way `write_pages_with_backend` returns a bare `Err`, and `Error::from(err)`
goes through `kernel/core/src/error.rs:209`:

```rust
impl From<(ostd::Error, usize)> for Error {
    // Used in fallible memory read/write API
    fn from(ostd_error: (ostd::Error, usize)) -> Self { Error::from(ostd_error.0) }
}
```
The `usize` field — the only carrier of progress — is dropped on the floor.

**(c) How a page ends up `Uninit` in the middle of a write.** `Vmo::write`
(pristine `:594-639`) splits an unaligned range into head / middle / tail and
commits the page-aligned middle with `CommitMode::Overwrite`, which does not read
the page in from the backend, so those pages are `Uninit`. The unaligned head/tail
use `CommitMode::Read` → `UpToDate`. So a single `write()` naturally mixes page
states, which is exactly the counterexample's shape.

**(d) ext2 keeps the dirty prefix on rollback.** `InodeInner::write_at`
(pristine `:245-271`):

```rust
if let Err(err) = self.page_cache().write(offset, reader) {
    self.rollback_write(old_size, end);
    return Err(err.into());
}
self.set_mtime_ctime(utils::now());
if end > old_size { self.set_file_size(end); }
Ok(write_len)
```
`rollback_write` returns immediately when `end <= old_size` (pristine `:205-208`),
i.e. for any in-place overwrite the rollback is a no-op and the dirty prefix stays
in the page cache. It is also never *undone* for the in-file part of an extending
write: rollback only truncates page-cache capacity/blocks above `old_size`.

**(e) VFS drops the whole attempt.** `InodeHandle::write`
(pristine `kernel/core/src/fs/file/inode_handle.rs:317-319`):

```rust
let len = file_ops.write_at(*offset, reader, status_flags)?;   // `?` → offset untouched
*offset += len;
```

**(f) The syscall returns EFAULT.** `kernel/core/src/syscall/write.rs:29-38`
maps the error straight out (only `EINTR → ERESTARTSYS`); there is no
"reader consumed N bytes, report N" salvage anywhere on the path.

**(g) The retained prefix is durable.** `BackedVmo::flush_dirty_pages`
(pristine `vmo/mod.rs:866-...`) collects `state.is_dirty()` pages and writes them
to the backend, so the retained bytes reach the ext2 block device on
`fsync`/`sync`/writeback — this is not a page-cache-only artifact.

### 1.3 Reachability

Reachable from unprivileged userspace with only `mmap`/`mprotect`/`write`:
give `write()` a buffer whose tail is `PROT_NONE`. The kernel copies the readable
prefix into the page cache, dirties it, then faults.

Trigger scenario (constructed, entirely public API):
1. `mount -t ext2 /dev/vda /ext2` (the stock initramfs `init` already does this).
2. Create `/ext2/f`, write 8192 bytes of `'A'`, `fsync`, close.
3. Re-open `O_RDWR`; `pread` the whole file so pages 0 and 1 are `UpToDate`.
4. `mmap` 3 anonymous pages, fill with `'B'`, `mprotect` pages 1-2 `PROT_NONE`;
   take `buf = base + PAGE_SIZE - 128` (128 readable bytes, then a hole).
5. `lseek(fd, 0, SEEK_SET)`; `write(fd, buf, 8192)`.

Predicted (from the code above): the 128 readable bytes land in page 0, the page
is dirtied, the next copy faults, `write()` returns `-1/EFAULT`, and the file
offset stays 0 — while the first 128 bytes of the file are now `'B'`.

Safeguards looked for and NOT found:
- no fault-in / retry loop anywhere on the write path (Linux has
  `fault_in_iov_iter_readable` + a copy loop in `generic_perform_write`);
- no partial-count salvage in `sys_write`, `InodeHandle::write`, or
  `InodeInner::write_at`;
- `rollback_write` does not, and structurally cannot, undo in-place page dirtying;
- the `written_size > 0 && state.is_up_to_date()` guard *only* narrows which
  faulting page keeps its prefix; it does not stop an earlier fully-copied page
  from being dirtied.

### 1.4 Independent live-kernel corroboration (pre-existing harness run)

`.specula-output/traces/ext2_buffered.ndjson`, produced by booting the
instrumented kernel under QEMU/KVM, already contains the state this finding
describes (records 13-17):

```
FileOpsWriteAtCopyFaultPositive  {"retained_prefix": "Positive"}  page_state=Uninit
VmoWritePagesWithBackendFaultRetain
InodeHandleWriteReturnError
SysPwrite64Return  result=Fault  committed_total=1  reported_total=0  ofd=0
```

i.e. a real kernel reached `committed_total=1, reported_total=0, result=Fault`.
This is evidence, not the reproduction — it is the instrumented build and it
observes kernel internals rather than the userspace-visible outcome.

## Step 2 — Developer-knowledge search

The distributed tree has a single squashed baseline commit, so `git log`/`git blame`
carry no upstream history. Searched the upstream tracker instead
(`gh search issues/prs --repo asterinas/asterinas`).

**Issue #711 — "Wrong behavior when `EFAULT` occurs in the middle of I/O system
calls"** (OPEN, filed 2024-03-23, last comment 2026-07-14)
<https://github.com/asterinas/asterinas/issues/711>. Its PoC is this exact
mechanism on `read()` and `write()` with a buffer straddling a mapped/unmapped
page boundary; Linux returns a short count, Asterinas returns `EFAULT`.
Maintainer `lrh2000`, 2026-07-14, verbatim:

> I think this issue still exists today. It seems that we do not allow partial
> reads or writes in our page cache implementation. However, I am not aware of any
> applications that depend on this behaviour. Therefore, perhaps the priority to
> fix this is very low.

with links to `kernel/src/vm/page_cache/vmo/mod.rs` L415 and L547 — the page-cache
read/write entry points, i.e. the same site as this finding.

Earlier design discussion in the same issue (`lrh2000` 2024-03-23,
`StevenJiang1110` 2024-03-26) proposes returning `Result<usize>` from the user-copy
API so a partial copy reports `Ok(n)` — i.e. the maintainers state the intended
behavior is a short count, not `EFAULT`.

**Comment in the code**: `// If the page is not initialized, keep it as it is on a
partial write.` (pristine `vmo/mod.rs:741`) shows the author considered partial-write
*data* retention on the faulting page. Nothing in the tree comments on reporting the
retained prefix to userspace.

**PR #3297 — "Introduce `InodeRollbackGuard` ..."** (OPEN draft, 2026-05-29)
restructures the ext2 write-error rollback but does not touch progress reporting.

**Not relevant**: #3181 (sendfile short write to a PTY, CLOSED — different site),
#1554 (pipe write atomicity, CLOSED — different subsystem).

**Tests**: no test in the tree asserts the current EFAULT-on-partial-copy behavior
for regular files; the only exercise of this path is the Specula harness itself.

Searched for a landed fix (`gh search prs` over merged/closed PRs touching the page
cache: #3713, #3421, #3299, #3509, #2953, #3256): none changes the partial-copy
reporting path. #711 is still open and unfixed at the baseline.

## Step 3 — Known-status / precedent

**KNOWN.** Issue #711 reports THIS mechanism (a user-copy fault mid-syscall
erasing the already-copied prefix, `EFAULT` instead of a short count) at THIS
site (page-cache buffered read/write behind `read`/`write`), and it is still open
and unfixed.

Cite: <https://github.com/asterinas/asterinas/issues/711>; fix-status: unfixed.

The pre-filter drop does **not** apply: it is restricted to *code-review*-sourced
findings. MC-2 is model-checking-sourced with an actual TLC counterexample
(`MC_hunt_scenario_1_mixed_page_prefix_bfs.out`, `MCMixedPageRetainedPrefixReported`
violated at State 10), so per `guide.md` it proceeds to Phase 2 unfiltered —
"MC-found *with an actual counterexample* (new or known)".

What #711 does **not** state, and what the counterexample adds: that the failing
`write()` leaves *committed file data* behind (`committed_total=1`,
`reported_total=0`). #711's PoC only observes the return value. The data-retention
half is an aggravation of the same defect at the same site, not a separate
mechanism — so the novelty verdict stays KNOWN.

## Counterexample summary (what Phase 2 must match)

`MC_hunt_scenario_1_mixed_page_prefix_bfs.out`, final State 10:

```
opKind      = SharedWrite      backendMode = Ext2Buffered   rangeClass = InPlace
requested   = Complete         copied      = Positive       committed  = Positive
pageState   = Uninit           (faulting page)              copyFault  = TRUE
result      = Fault            reportedTotal = 0            committedTotal = 1
ofdOffset   = 0                expectedOffset = 0
```

Actions: `MCSysWriteStart(t1,"Ext2Buffered","Complete",FALSE,FALSE,"UpToDate")`
→ AcquireOffset → AcquireData → PrepareWrite → CopyWrite →
`MCFileOpsWriteAtCopyFaultPositive(t1,"Uninit","Positive")` → BackendFinish →
ReleaseData → InodeReturn → SyscallDispatch → Idle.

Violated invariant (`spec/base.tla:559-567`): at `Idle`, with `Ext2Buffered`, a
faulting `Uninit` page, `copied = Positive` and `committed = Positive`, the result
must be `Success`/`ShortSuccess` with `reportedTotal >= committedTotal`.

Phase 2 must show, through the public API only: `write()` → `-1/EFAULT`, file
offset unchanged, and a positive prefix of the file changed.

---

## Phase 2 artifacts (written after reproduction)

- Payload: `repro/test_bugMC-2_retained_write_prefix_efault.c` (level 0, public syscalls only)
- Driver:  `repro/test_bugMC-2_retained_write_prefix_efault.sh`
- Output:  `confirmation/MC-2/repro-run.log`,
  `confirmation/MC-2/linux-control.log`,
  `confirmation/MC-2/asterinas-run.log`,
  `confirmation/MC-2/asterinas-build.log`
- Kernel under test: `confirmation/MC-2/worktree` with `git status -- kernel ostd`
  empty (instrumentation reverted; only initramfs wiring ships the test binary).
