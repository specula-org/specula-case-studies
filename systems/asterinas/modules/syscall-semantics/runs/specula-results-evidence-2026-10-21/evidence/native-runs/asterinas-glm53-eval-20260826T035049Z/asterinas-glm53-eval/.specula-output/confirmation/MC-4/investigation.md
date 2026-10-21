# MC-4 Investigation — Vectored I/O Is Not Atomic Against a Shared-Offset Competitor

Worktree: `.specula-output/confirmation/MC-4/worktree` (baseline d0139a1 = upstream
604948581 + uncommitted trace instrumentation; `kernel/` verified identical to the
harness-built `source/` tree via `diff -rq`).

## Step 1: Code audit

### Cited code and call chain (readv side)

1. `sys_readv` → `do_sys_readv` — `kernel/core/src/syscall/preadv.rs`. The loop at
   ~line 145-190 iterates `writer_array.writers_mut()` and calls the **scalar**
   `file.read(writer)` once per iovec entry (the call at the finding's cited line
   159 region). In-tree TODO (verbatim, both preadv.rs and pwritev.rs):
   > `// TODO: According to the man page at <https://man7.org/linux/man-pages/man2/readv.2.html>,`
   > `// readv must be atomic, but the current implementation does not ensure atomicity.`
   > `// A suitable fix would be to add a `readv` method for the `FileLike` trait,`
   > `// allowing each subsystem to implement atomicity.`
2. `FileHandle::read` → `InodeHandle::read` — `kernel/core/src/fs/file/inode_handle.rs`
   (~line 282). For an offset-aware regular file it does, per call:
   `let mut offset = self.offset.lock();` (line 292) → `file_ops.read_at(*offset, ..)`
   → `*offset += len` → `drop(offset)`. One full lock acquire/release cycle per scalar op.
3. `sys_writev` → `do_sys_writev` — `kernel/core/src/syscall/pwritev.rs` (~line 130-190),
   identical per-entry loop calling scalar `file.write(reader)`.
4. `InodeHandle::write` — `inode_handle.rs` (~line 332), `self.offset.lock()` at line 346,
   same per-call acquire/commit/release shape.

So a readv/writev with N iovecs takes and drops the shared open-description offset
lock N times; between entries the description is unlocked and a competing shared-offset
operation can acquire, commit, and advance the offset.

### MC counterexample (spec/output/MC_hunt_s3_vector_linearization_bfs.out)

21 states, invariant `MCVectorSingleLinearization` violated. Two threads share one
open description (t1 scalar Write 2 units, t2 Readv 2 iovecs × 2 units). Final
`commitLog`:

```
[ kind="Readv", start=0, amount=2, tid=t2, iov=1 ],
[ kind="Write", start=2, amount=2, tid=t1, iov=1 ],
[ kind="Readv", start=4, amount=2, tid=t2, iov=2 ]
```

Readv entry 1 commits at offset 0, the scalar write commits at 2, readv entry 2
reads at 4 (offset moved by the competitor). In any serial order of the two
syscalls the readv reads a contiguous 4-byte block: A-first ⇒ (0,2)+write@4;
B-first ⇒ write@0+read@(2,4). Observed (0,4) with write@2 is realizable by no
serial ordering — no single linearization point for the vector op. The harness
INSTRUMENTATION.md additionally reports a deterministic guest witness for the
writev side (`ramfs_fault_vector` trace contains the exact vector-iovec-1,
scalar-commit, vector-iovec-2 order).

### Linux contract

readv(2) man page: "The data transfers performed by readv() and writev() are
atomic … readv() is guaranteed to read a contiguous block of data from the file,
regardless of read operations performed in other threads or processes that have
file descriptors referring to the same open file description." On Linux, shared-f_pos
operations are serialized by `fdget_pos` (f_pos_lock) around the **whole** vector
operation, so the CE interleaving is impossible there.

### Reachability

Real-API path, no preconditions beyond "two threads sharing one open description":
`open("/tmp/f", O_RDWR)` + `dup(fd)` (or CLONE_FILES threads), thread A
`readv(fd, {2×2B})`, thread B `write(fd2, 2B)`. All regular-file syscalls on the
guest /tmp (ramfs, page-cache, offset-aware — the same RamFs profile the CE models).
The boundary window is reachable whenever B's lock acquire lands between A's
entries — including B blocking on the mutex during A's entry-1 critical section
(mutex handoff lands B exactly in the boundary).

### Safeguards encountered

None between vector entries: the file-table borrow in `do_sys_readv` is
thread-local (does not exclude other threads); the offset mutex is dropped at the
end of every scalar entry; no inode-level I/O lock spans the vector loop
(Asterinas has no i_rwsem equivalent here). The page cache serializes individual
VMO ops, not vector-op extents.

### Trigger scenario (Phase 2 target)

Round: restore 8 two-byte markers (aa..hh) via `pwrite`, `lseek(fd,0,SEEK_SET)`,
then simultaneously (spin-release) A=`readv(fd, {buf0[2], buf1[2]})` and
B=`write(fd2, "XY", 2)`. Classification of A's returned pair:
- (aa,bb) ⇒ serializable A-first (X lands @4);
- (XY,bb) ⇒ serializable B-first (X @0);
- (aa,cc) ⇒ **BUG** — entry 2 read at offset 4 because B committed @2 between
  the entries (matches the CE exactly; only the interleave produces this pair).
writev variant: A=`writev(fd, {"AA","CC"})`, B=`write(fd2,"XY",2)`; file layout
AA@0,XY@2,CC@4 ⇒ BUG (serial orders give AA,CC,XY or XY,AA,CC).

## Step 2: Developer knowledge

- In-tree TODO comments in `preadv.rs` / `pwritev.rs` (quoted above): developers
  know readv/writev "must be atomic" and that the implementation "does not ensure
  atomicity"; suggested fix = per-subsystem `readv`/`writev` FileLike methods.
  Awareness, not a filed report — per the skill this is evidence, not KNOWN status.
- `git log` on the cited files: only the campaign baseline commit exists in this
  worktree (squashed); upstream history via web: commits 513532f (partial
  writev/readv short-count), de52fd1 (errno probe for empty iovec lists), d7cbd0f /
  PR #3086 (pread/pwrite positional-io semantics) — all different aspects; none
  touch vector atomicity.
- `inode_handle.rs` FIXME near line 354 re O_APPEND concurrent append — separate
  documented exclusion in the target scope.

## Step 3: Known-status / precedent

Tracker searches (GitHub asterinas/asterinas, open + recently merged/closed):
- #1554 — PIPE_BUF atomicity for **pipes** (different file type/site; the target
  brief lists it as mechanism context only).
- #3142 — xfstests gap tracker; mentions RWF_NOWAIT ignored, no vector-atomicity
  entry for regular files.
- #1542 — sendfile truncation (pipes again). #2937/#2953 — page-cache refactoring.
- No issue/PR/CVE reports regular-file readv/writev non-atomicity against a
  shared-offset competitor at preadv.rs/pwritev.rs; no merged or open PR adds a
  FileLike::readv/writev or otherwise holds the offset lock across vector entries.

Conclusion: **Novelty: NEW** (searched; nothing reports this mechanism at this
site). Source is MC with a real counterexample ⇒ no pre-filter drop; proceed to
Phase 2.

## Phase 2 plan

Level 0 first: the race test above (public syscalls, real threads, /tmp ramfs).
Escalation Level 1 if needed (timing assistance only, e.g., entry-size tuning to
lengthen the entry-1 critical section so the competitor's blocking acquire lands
in the boundary; still stock logic). Level 3 (sleep at the exact boundary in
`do_sys_readv`) only if 0-1 fail. Build/run: docker `asterinas/dev:0.18.1-20260805`,
`make run_kernel AUTO_TEST=mc4repro …` with warm `target/` cache reuse, mirroring
the harness `run.sh` invocation.

## Phase 2 execution and result

Test: `repro/test_bugMC-4_vector_shared_offset_race.c` (v2; identical copy at
`worktree/test/initramfs/src/regression/io/file_io/specula_repro_mc4.c`, guest
path `/test/io/file_io/specula_repro_mc4`, run as init via `AUTO_TEST=mc4repro`).
File named `mc4_*` so the campaign instrumentation (`trace_file_for_path`) stays
off — stock kernel behavior.

- **Level 0 (v1, 2-byte entries, no barrier, spin handshake): 150,000 rounds,
  no trigger.** Guest round pacing ~ms-scale with 3 spinning threads on 2
  vCPUs; the scalar competitor almost always ran after the whole vector op.
  Two rounds classified (bb,cc) — actually the serial-B-first signature
  (B-first moves the offset; A then reads at 2..6), which corrected the
  classifier in v2. No false bug signatures observed.
- **Level 1 (v2): 64 KiB iovec entry 1 (lengthens the real lock-held section —
  one page-cache copy under the offset mutex), pthread_barrier rendezvous
  between the two competitors, rotating pause-delay before the scalar write,
  main polls with usleep. No system logic changed; public syscalls only.**
- **Guest result (Asterinas d0139a1+instrumentation-off, SMP=2, KVM, ramfs
  /tmp): BOTH cases triggered.** readv: round 62 — entry1 = full 64 KiB from
  offset 0 (e1[0..2]=pat(0..2), e1 tail = pat(L-2..L)), competitor XY
  physically at [L,L+2) (pread-corroborated, XY_at_L=1), entry2 bytes =
  pat(L+2..L+4) ⇒ entry 2 started at offset L+2. Expected-if-serial entry2 =
  pat(L..L+2). readv returned 65538, write returned 2. writev: round 38 —
  durable layout D·64K, XY, ZZ (serial orders give D·64K,ZZ,XY or XY,D·64K,ZZ).
- **Linux control (same binary, host kernel): 60,000 rounds, bug=0 in both
cases, serial_b ≈ 6.5%** — the competitor races concurrently on Linux too,
  and the detector never fires: Linux holds f_pos_lock across the whole
  vector operation, so the CE interleaving is impossible there.

Raw output archived in `guest-run.txt` (copied from `worktree/qemu.log`) and
`linux-control.txt`; docker log `docker-build-run.log` (DOCKER_EXIT=0).

Escalation level reached: **1** (Level 0 attempted first and documented).
Right-bug verification: actions, order (vector-entry1 commit, scalar commit
between entries, vector-entry2 commit), violated invariant
(MCVectorSingleLinearization — no single linearization point), and root cause
(per-entry scalar dispatch at preadv.rs:159 / pwritev.rs:155 through the
per-call offset lock cycle at inode_handle.rs:292/346) all match the MC
counterexample `MC_hunt_s3_vector_linearization_bfs.out`.

## Retry session (2026-08-28): re-verification and re-execution

Context: the prior session completed Phase 1+2 (both cases triggered, Level
1) but the pipeline crashed in turn 2 (Agent B adapter error) before the
final structured output; the dispatcher recreated the worktree fresh, losing
the prior repro source. This session re-verified all Phase 1 evidence and
re-executed everything from scratch.

Phase 1 re-verification (this session):

- Cited code re-read in the recreated worktree: per-entry scalar dispatch
  confirmed (`file.read(writer)` in do_sys_readv, `file.write(reader)` in
  do_sys_writev, incl. the verbatim atomicity TODO comments), and the per-call
  offset-mutex cycle in InodeHandle::read/write (lock -> read_at/write_at ->
  advance -> drop) confirmed at the cited lines.
- Counterexample re-read: final commitLog is exactly Readv@0 (t2 iov1),
  Write@2 (t1 scalar), Readv@4 (t2 iov2), invariant MCVectorSingleLinearization
  violated under adapterProfile "Correct".
- Instrumentation inertness re-verified: tla_trace hooks are keyed on
  `.specula_*` file-name prefixes (tla_trace.rs:268 trace_file_for_path);
  the mc4_-named test file gets tla_trace_file = None, and the unconditional
  loop hooks only act on an active per-thread trace op.
- Novelty re-check (web: GitHub asterinas/asterinas issues + recently
  merged/closed PRs, 3 queries): still nothing on regular-file vector
  atomicity vs shared-offset competitors (513532f short-count, de52fd1
  empty-iovec errno, d7cbd0f/#3086 positional-io, #1554 pipe PIPE_BUF, #2937
  page-cache refactor — all different mechanisms/sites). Novelty stays NEW.

Phase 2 re-execution (escalation Level 0 already documented last session;
this session re-ran Level 1):

- v3 (L=64 KiB entry 1, delay grid 50..6350 ticks, 4000 rounds/case):
  guest built+booted clean (docker asterinas/dev:0.18.1-20260805, SMP=2,
  KVM, ramfs /tmp, DOCKER_EXIT=0). NO trigger: readv serialA=1143 serialB=2857
  other=0; writev serialA=1364 serialB=2636 other=0. Interpretation: the
  detector sees heavy concurrency (71%/66% B-first) but the delay grid never
  put the competitor's write in flight during entry 1's lock-held copy on
  this guest scheduler; every round serialized B-before-entry-1 or
  B-after-whole-vector.
- v4 (same design, timing assistance widened): entry 1 enlarged to 512 KiB
  (ms-scale page-cache copy under the offset mutex) and delay grid widened to
  50..25550 ticks (round%256 step 100). Host Linux control of v4: 4000
  rounds/case, bug=0, other=0 — classifier clean, Linux stays atomic.
  Full-strength Linux control (60k rounds/case, -DROUNDS_MAX=60000):
  readv serialA=59968 serialB=32 other=0; writev serialA=59909 serialB=91
  other=0; bug=0 — the competitor genuinely interleaves on Linux (123
  B-first rounds) and the BUG signature never fires in 120k rounds.
  Archived in linux-control-retry.txt.
- v4 guest run: outcome appended below after completion.

## Session 3 (2026-08-28, current): re-verification and v4 re-execution

Context: the retry session (above) hit its adapter timeout (error.txt: turn 1 A
exited 124) after the v3 no-trigger run and the v4 host control, before the v4
guest run; the dispatcher recreated the worktree fresh again (file_io checkout
timestamps Aug 28 20:25; no specula_repro_mc4, no target/ cache) and re-invoked
turn 1 A. This session redid Phase 1 spot-verification and Phase 2 from
scratch.

Phase 1 re-verification (this session, recreated worktree):

- preadv.rs do_sys_readv: per-entry `file.read(writer)` loop with the verbatim
  atomicity TODO re-read (loop body at the cited :159 region).
- pwritev.rs do_sys_writev: per-entry `file.write(reader)` loop, same TODO
  (cited :155 region).
- inode_handle.rs: `let mut offset = self.offset.lock();` at :292 (read) and
  :346 (write); guard dropped at each scalar call's end.
- tla_trace.rs trace_file_for_path (:268): instrumentation only activates for
  dot-prefixed `.specula_*` file names; the mc4 test uses `/tmp/mc4race.bin`
  → stock kernel behavior.
- Counterexample re-read: 21 states, final commitLog Readv@0 (t2 iov1),
  Write@2 (t1), Readv@4 (t2 iov2), sharedOffset=6, invariant
  MCVectorSingleLinearization violated, adapterProfile "Correct".
- Novelty re-check (web: GitHub asterinas/asterinas, issues + commits/PRs,
  3 queries): #1554 (pipe PIPE_BUF — different file type), 513532f (vector
  short-count), de52fd1 (empty-iov errno), 899db77 (preadv/pwritev parameter
  passing), d7cbd0f/#3086 (positional-io semantics) — none is vector
  atomicity vs a shared-offset competitor at this site. Novelty stays NEW.

Phase 2 v4 (this session): test rewritten as
`repro/test_bugMC-4_vector_shared_offset_race.c` (guest copy
`worktree/test/initramfsfs/.../file_io/specula_repro_mc4.c` — actually
`test/initramfs/src/regression/io/file_io/specula_repro_mc4.c`, AUTO_TEST
branch `mc4repro` added to the worktree Makefile). Differences from v3:
entry-1 geometries 64 KiB then 512 KiB (stop per case at first trigger), and
B's delay grid is auto-calibrated against the MEASURED entry-1 duration
(clock_gettime around a serial vector op; sweep [0, 1.25*t_e1] over 256
steps) instead of fixed tick units — the v3 miss is attributed to fixed
ticks not tracking actual copy duration. Still Level 1: public syscalls
(open/dup/readv/writev/write/pread/pwrite/lseek/ftruncate), real threads,
timing assistance only, no kernel logic change.

- Host compile + quick control (2000 rounds/geometry, both cases): sanity
  ok=1 everywhere, classifier clean (other=0), serialB present (1-8 per
  2000 — the competitor genuinely races), bug=0. Archived host-v4b-quick.log.
- Full host Linux control (20000 rounds/geometry): running, archived to
  linux-control-v4.txt.
- Guest run (docker cold build, AUTO_TEST=mc4repro, SMP=2, KVM): running,
  archived to docker-build-run-v4.log / guest-run-v4.txt /
  guest-mc4-markers-v4.txt. Outcome appended below.
