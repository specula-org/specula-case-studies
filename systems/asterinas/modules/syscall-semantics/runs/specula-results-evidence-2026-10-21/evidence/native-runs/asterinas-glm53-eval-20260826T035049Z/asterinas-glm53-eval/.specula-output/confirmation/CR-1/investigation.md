# CR-1 Investigation (Phase 1 — evidence only)

Finding: "Positional Offset Isolation for pread64/pwrite64 on a Shared Open Description"
Source: code review (MC hunt `MC_hunt_s4_positional_isolation.cfg` completed with NO
violation at depth 19; 30-min simulation also clean — so this is a code-review
candidate, not an MC-found counterexample).

## Step 1: Code audit

### Facts verified (all in the CR-1 worktree, pristine baseline d0139a1 + harness instrumentation)

1. **Dup shares one open description (matches Linux).**
   `FileTable::duplicate_entry` (kernel/core/src/fs/file/file_table.rs:182-191)
   clones `entry.file` — an `Arc<dyn FileLike>` — so `dup`/`dup2`/`fork` give two
   fds backed by the SAME `InodeHandle`, i.e. one `offset: Mutex<usize>`
   (kernel/core/src/fs/file/inode_handle.rs:47). This mirrors Linux's shared
   `struct file` after dup and is itself correct behavior, not a defect.

2. **Every mutator of `InodeHandle::offset`.** grep of `self.offset` in
   inode_handle.rs exhaustively lists:
   - `read()` scalar shared-offset read: locks, `read_at(*offset)`, `*offset += len` (lines 292-307)
   - `write()` scalar shared-offset write: locks, O_APPEND `*offset = size()`, `write_at(*offset)`, `*offset += len` (lines 346-378)
   - `readdir_at` getdents path (lines 141-143)
   - `lseek` (lines 515, 529 via `do_seek_util` 689-712)

3. **The positional paths never touch the offset.**
   `InodeHandle::read_at` (lines 389-410) and `InodeHandle::write_at`
   (lines 412-439) — the targets of pread64/pwrite64 (syscall/pread64.rs:33,
   syscall/pwrite64.rs:33) and of the preadv/pwritev per-entry loop
   (syscall/preadv.rs:120, syscall/pwritev.rs) — do NOT lock, read, or write
   `self.offset` at any point, including on error. The O_APPEND branch in
   `write_at` (line ~425) reassigns only the local parameter
   `mut offset: usize`, never the field. The underlying `file_ops`
   (`file_ops_for_positional_io()` line 115: the inode itself for regular
   files — `SysTreeNode::open` default returns None, so `open_file` is None for
   regular files; virtiofs is the exception and out of scope) has no reference
   back to the handle's offset field, so it cannot mutate it either.

4. **Fault/partial-progress paths.** In sys_pread64/sys_pwrite64 the
   `user_space.writer/reader` is built before I/O; a bad range fails with
   EFAULT before `read_at`/`write_at` runs; a mid-copy page fault surfaces as a
   fallible-writer short count or EFAULT *inside* `file_ops.read_at/write_at`,
   which are still offset-free. The syscall then returns; nothing in the
   success or error path of the positional syscalls references the offset.

### Call chain (pread64, regular file)

sys_pread64 (syscall/pread64.rs) → get_file_fast → `FileRef::read_at` →
`InodeHandle::read_at` (inode_handle.rs:389) → `file_ops_for_positional_io()`
(inode, no side effect) → inode-level `read_at(offset, writer, flags)` (page
cache). No edge reaches `self.offset`.

### Trigger scenario construction (attempt)

The hypothesized trigger needs *some* edge from the positional syscall path to
`InodeHandle::offset`. The audit above finds none — the field is private and
its only mutators are read/write/getdents/lseek, none reachable from
pread64/pwrite64/preadv/pwritev. No caller-side safeguard is even needed; the
mechanism the finding hypothesizes has no code path. Phase 2 must nevertheless
test it empirically on the real kernel (faulting buffers, partial writes,
O_APPEND, EOF straddling, dup'd fds, vectored variants) per the skill.

## Step 2: Developer knowledge

- FIXME comments near `write()`/`write_at()` concern **O_APPEND append-range
  atomicity** — a different, documented sensitivity (excluded by the campaign
  scope), not offset attribution.
- TODO comments in preadv.rs/pwritev.rs concern **readv/writev atomicity vs
  competing I/O** — different aspect, documented upstream as a known limitation.
- Existing regression tests (`access_err.c:220-232`) assert only errno behavior
  of pread/pwrite/preadv/pwritev (EBADF). No test asserts offset isolation.
- Upstream PR #3086 / commit d7cbd0f introduced `file_ops_for_positional_io`
  to fix **errno semantics** (ESPIPE on pipes, EBADF on O_PATH); its
  description says nothing about the shared offset. de52fd1 (empty iov errno)
  and 513532f (partial readv/writev return values) are also different
  mechanisms.
- No "we accept this" or "known limitation" statement about pread/pwrite
  moving the shared offset exists anywhere near the code.

## Step 3: Known status / precedent

Searched the upstream tracker (github.com/asterinas/asterinas) and recent
merged/closed PRs for pread64/pwrite64 offset movement: no issue, PR, or CVE
reports THIS mechanism (positional I/O observably moving the shared
open-description offset). Closest reports are different mechanisms: PR #3086
(errno semantics), #1554 (pipe write atomicity), #2835 (ext2 O_DIRECT data),
#2937/#2953 (page-cache refactor races). → Novelty: NEW (if the finding
survives Phase 2).

## Phase 1 outcome

Proceed to Phase 2. Not dropped: no prior report of this mechanism.

## Phase 2 record (added at reproduction)

Escalation ladder:

- **Level 0 (executed)**: `repro/test_bugCR-1_positional_offset_isolation.c` —
  19 black-box checks via public syscalls only (open/dup/dup2/lseek/read/write/
  pread64/pwrite64/preadv/pwritev/mmap/mprotect/pthreads), covering: shared-offset
  controls (checks 1-2, 16), positional offset isolation on success/EOF-straddle/
  past-EOF/EFAULT/fault-prefix/O_APPEND/file-extension paths (3-15), concurrent
  hammer (4 threads pread64 or pwrite64 vs scalar shared-offset ops with
  per-iteration exact offset verification, 79104/56096 bytes positional traffic;
  checks 17-18), and 500x interleaving (19). Ran on Linux host (control:
  PASS 19/19, saved as `.linux_control.txt`) and inside the Asterinas guest
  (booted via Docker `asterinas/dev:0.18.1-20260805`, KVM, `AUTO_TEST=cr1repro`,
  pristine-baseline kernel with trace instrumentation INACTIVE for the test
  filename — `cr1_pos_isolation.bin` matches no `.specula_*` trace gate, so
  `tla_trace_file` is None and semantics are baseline). Guest result: PASS 19/19
  (`CR1_RESULT: PASS (19 checks, 0 failed)`), `docker_exit=0`, Makefile
  completion grep `^CR1_REPRO_DONE` satisfied. Output saved as
  `.guest_output.log` / `.guest_qemu_full.log`.
- **Level 1**: the concurrency checks already race positional hammering against
  scalar ops with exact per-iteration offset arithmetic — the natural widening
  for this contract. No further timing hook exists that could create an
  offset-attributing edge: the audit shows the positional path never touches
  `self.offset`, so there is no window to widen.
- **Level 2**: the needed pre-condition (positional I/O advancing the shared
  offset) is produced by NO real-API call sequence (no code edge exists; grep of
  `self.offset` mutators is exhaustive: read/write/getdents/lseek) and there is
  NO MC counterexample step to instantiate (the MC hunt returned no violation).
  Injecting it would fabricate an unreachable state — unsound.
- **Level 3**: no crash window exists; a source patch adding offset advancement
  would CREATE the symptom, which is prohibited.

Adapter-path hypothesis closed: for regular files `SysTreeNode::open` default
returns None (systree_inode.rs:599-605), so `file_ops_for_positional_io()`
returns the inode itself; the one `open_file`-based regular-file implementation
(virtiofs `VirtioFsFile`, fs_impls/virtiofs/file.rs:100-137) receives the
offset BY VALUE (`WriteOffset::Absolute(offset)` / `Append`) and holds no
reference to `InodeHandle::offset` — it cannot attribute positional progress
to the shared offset either.

Observation (not this finding's mechanism, not a contract violation): on
fault-prefix transfers the guest returned zero-progress EFAULT where Linux
returned the copied prefix (4096). Zero/positive/complete progress classes are
the contractual classes per the modeling brief; both outcomes leave the offset
unchanged. Different mechanism (copy granularity), different site.

Novelty re-check this turn: web search over the upstream tracker + merged/closed
PRs (PR #3086/d7cbd0f errno semantics, 899db77 preadv parameter passing, de52fd1
empty-iov errno, 513532f partial readv/writev returns, #3211 fsck.exfat block
gaps) — none reports positional I/O moving the shared open-description offset.
Novelty: NEW.

Phase-2 outcome: contract HOLDS on the live kernel, matching the exhaustive
audit (no defect exists) and the clean MC hunt (BFS depth 19 / 2016 states +
464M-state simulation). Finding is not a defect -> FALSE POSITIVE.
