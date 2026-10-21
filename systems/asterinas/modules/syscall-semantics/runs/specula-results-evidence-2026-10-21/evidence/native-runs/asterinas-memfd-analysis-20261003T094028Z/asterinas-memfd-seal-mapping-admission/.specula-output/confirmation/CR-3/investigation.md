# CR-3 Investigation Record (Phase 1 — evidence only)

Finding: "Failed mprotect prefix and busy seal addition may leave inconsistent
observable effects" (code-review sourced; scenario 4 arms: protection-prefix and
busy-seal; the rejected-fixed-replacement arm is MC-2's, not covered here).

## Step 1: Code audit

### Cited code, read in full

- `kernel/core/src/fs/fs_impls/ramfs/memfd.rs:49-116` — `MemfdInode::add_seals`.
  Order of operations under `self.seals.lock()`:
  1. F_SEAL_SEAL already set → EPERM (no state change).
  2. F_SEAL_EXEC expansion (exec-bit mode check) — out of scope per target
     instructions (exec sealing excluded).
  3. If the request contains F_SEAL_WRITE: `page_cache.writable_mapping_status().deny()?`
     (vmo/mod.rs:1193-1258). `deny()` is a conditional atomic update: it sets the
     counter to -1 only when the current value is <= 0; when writable mappings
     exist (> 0) it returns EBUSY **without modifying any state**.
  4. `*seals |= new_seals` — publication happens strictly AFTER the deny check.
  → A busy combined WRITE|FUTURE|SEAL addition returns EBUSY and publishes NO
  bits; the deny counter is left untouched. Syscall-wide rollback.
- `kernel/core/src/vm/vmar/vmar_impls/protect.rs:21-160` — `Vmar::protect`.
  Iterates intersecting mappings in address order and applies each segment
  immediately (remove → split → protect → reinsert) before evaluating the next:
  - EACCES arm: `new_perms = perms | (vm_mapping_perms & ALL_MAY_PERMS)` then
    `new_perms.check()?` (perms.rs:39-52) rejects any requested real perm not
    covered by a MAY bit → EACCES, AFTER earlier segments were already applied.
  - ENOMEM arms: hole before first mapping → immediate ENOMEM, no prefix
    (lines 41-48); trailing hole → ENOMEM after the loop, prefix applied
    (lines 146-156).
  - Doc comment states Linux contract explicitly: "Note that pages before the
    unmapped hole are still protected."
  → Successful prefix is NOT discarded on later failure; no permission is
  granted beyond MAY bits (check() enforces subset).
- `kernel/core/src/vm/perms.rs:39-52` — `VmPerms::check()` maps MAY_READ/WRITE/EXEC
  (bits 3-5) onto READ/WRITE/EXEC and returns EACCES when requested ⊄ allowed.
- `kernel/core/src/syscall/mmap.rs:133-149` — MAP_SHARED on a non-writable fd
  removes MAY_WRITE from the mapping's may_perms (O_RDONLY handle = admission
  control; exactly the Linux VM_MAYWRITE rule). This makes the EACCES segment
  constructible through the real API.
- `kernel/core/src/vm/page_cache/vmo/mod.rs:1193-1258` — `WritableMappingStatus`:
  map() (inc when >= 0, else EPERM), deny() (set -1 when <= 0, else EBUSY —
  no state change on failure), increment/decrement on split/merge/drop.

### Linux contract (primary sources)

- Linux v6.16.5 `mm/memfd.c` `memfd_add_seals` (fetched from
  git.kernel.org, tag v6.16.5): the F_SEAL_WRITE branch does
  `error = mapping_deny_writable(...); if (error) goto unlock;` — and
  `*file_seals |= seals;` is only reached after ALL checks pass. On EBUSY no
  seal bit is published and (in the wait_for_pins EBUSY path) Linux explicitly
  calls `mapping_allow_writable` to undo the deny. Linux is also all-or-nothing
  for seal publication.
- Linux `mm/mprotect.c` `do_mprotect_pkey` applies per-VMA fixes walking the
  range in order; on EACCES/ENOMEM it returns mid-walk without rolling back
  already-fixed VMAs (the prefix stays). Same contract that protect.rs's doc
  comment states. (Cited for the comparison; reproduced below empirically on
  host Linux 7.2.8 with the same binary.)
- `mprotect(2)`/`F_ADD_SEALS(2const)` man pages: EACCES "the memory cannot be
  given the specified access"; EBUSY for F_ADD_SEALS+F_SEAL_WRITE "if any
  writable, shared mapping exists"; ENOMEM "addresses in the range ... are
  unmapped". Neither documents syscall-wide rollback.

### Call chain / reachability

- Busy-seal arm: `sys_fcntl` → `MemfdInodeHandle::add_seals` (memfd.rs:315-327)
  → `MemfdInode::add_seals`. Trigger: `memfd_create(MFD_ALLOW_SEALING)`,
  `mmap(PROT_READ|PROT_WRITE, MAP_SHARED)`, then
  `fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE|F_SEAL_FUTURE_WRITE|F_SEAL_SEAL)`.
  Plain syscalls, single process — fully reachable (Level 0).
- Prefix arm: `sys_mprotect` (mprotect.rs:15) → `Vmar::protect`. Trigger:
  adjacent mappings with different MAY bits, or a hole in the middle of the
  range. Plain syscalls — fully reachable (Level 0).

### Safeguards encountered

None that mask these effects; the observed states ARE the syscall results
(read back via F_GET_SEALS, actual memory writes, and later mmap/mprotect
results). No downstream "fix-up" mechanism exists for seal bits or mapping
perms — they are terminal kernel state.

## Step 2: Developer-knowledge search

- Git history at the sites:
  - `ea142155f` "Fix permission validation in mprotect and mmap" (+ test commit
    `66ac28c4c`) — added `VmPerms::check()` MAY-bit enforcement, i.e. the
    "grant permissions beyond MAY bits" concern was deliberately implemented
    and regression-tested (single-segment case:
    `test/initramfs/src/apps/mmap/mmap_and_mprotect.c`,
    `mprotect_shared_writable_mapping_on_read_only_file` asserts EACCES).
    Upstream PR #2926.
  - `c7b633e9b` "Fix panic in mprotect when merging adjacent mappings" (fixes
    upstream issue #2917, a *different* mechanism — an unwrap panic when a
    previously-protected mapping merges with the next; the tree now has the
    `let Some(...) else { continue }` skip branch).
  - `6ba1a84ae` / `291c42c9f` "Support sealing memfd files" / "Enable some
    gvisor tests of memfd_test" (PR #2408, issue #2214) — the seal mechanism;
    PR #2408's description explicitly discusses the F_SEAL_WRITE EBUSY
    contract, showing the all-or-nothing failure contract is intended.
  - F_SEAL_GROW comment in memfd.rs references PR #2555's discussion — grow
    semantics, different aspect.
- No TODO/FIXME at either site about partial effects or seal publication.
- Existing tests do NOT cover the multi-segment prefix behavior or the
  busy-combined-seal no-publication observable; single-segment EACCES is tested.

## Step 3: Known-status / precedent

Searches over the Asterinas issue tracker and recently merged/closed PRs
(queries: mprotect partial/prefix/ENOMEM effects, F_ADD_SEALS EBUSY partial
publication, F_GET_SEALS inconsistency, MAY_WRITE segments):
- Upstream issue #2917 (panic when mprotect merges adjacent mappings) — same
  function, DIFFERENT mechanism (unwrap panic; fixed in-tree by c7b633e9b).
  Not a report of partial-effect inconsistency.
- PR #2408 / #2926 / #2766 — implementation and validation of the intended
  contracts, not reports of the deviation this finding hypothesizes.
- No issue, PR, or advisory reports the busy-seal partial-publication or the
  mprotect prefix-discard mechanism. → Novelty: NEW (searched; nothing found
  for THIS mechanism at THIS site).

Pre-filter (code-review × known): no match → proceed to Phase 2.

## Trigger scenario (concrete, Level 0)

Busy-seal arm:
1. fd = memfd_create("cr3", MFD_CLOEXEC|MFD_ALLOW_SEALING); ftruncate(fd, 8192).
2. p = mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0) — active
   writable mapping (WritableMappingStatus > 0).
3. fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE|F_SEAL_FUTURE_WRITE|F_SEAL_SEAL)
   → EBUSY expected.
4. fcntl(fd, F_GET_SEALS) → 0 expected (nothing published).
5. A new writable shared mmap must still succeed (deny flag not leaked).
6. munmap; retry the combined add → success; F_GET_SEALS → combined bits;
   new writable shared mmap → EPERM.

Prefix arm (EACCES):
1. Same memfd; fd_ro = open("/proc/self/fd/<fd>", O_RDONLY).
2. A = MAP_FIXED_NOREPLACE 2 pages RW MAP_SHARED via fd_w at base.
   B = MAP_FIXED_NOREPLACE 1 page PROT_READ MAP_SHARED via fd_ro at base+2p
   (no MAY_WRITE).
3. mprotect(A, 2p, PROT_READ) → OK.
4. mprotect(base, 3p, PROT_READ|PROT_WRITE) → EACCES expected.
5. Prefix check: writing A[0] must succeed; writing B[0] must SIGSEGV.
6. mprotect(A, 2p, PROT_READ|PROT_WRITE) alone must still succeed (A's MAY
   bits intact); mprotect(B, 1p, PROT_READ|PROT_WRITE) alone → EACCES.

Prefix arm (ENOMEM):
1. C = MAP_FIXED_NOREPLACE 3 pages RW MAP_SHARED via fd_w.
2. munmap middle page.
3. mprotect(C, 3p, PROT_READ) → ENOMEM expected.
4. Prefix check: C[0] write → SIGSEGV (protected); C[2] write → succeeds.

## Phase 2 record (this turn)

### Prior-turn artifact preflight (reuse rules)

The previous confirmation turn (turn01_A) crashed after the adapter (rc=1)
while its container steps had already run: the compiled binary, initramfs and
both logs existed under guest/, but the test SOURCE
(`repro/test_bugCR-3_rejected_op_effects.c`) was missing from .specula-output/repro.
Verified before reuse:
- Container `specula-memfd-harness-20261003` (image asterinas/dev:0.18.1-20260926,
  /dev/kvm, run_dir bind-mounted at /work) still up; harness/raw/run.json pins
  source_commit 0c6053709 + instrumentation patch.
- CR-3 worktree is bit-identical to /work/source (diff -r excluding target/.git
  rc=0; `git diff HEAD` hashes equal), so /work/source/target/osdk/asterinas/
  asterinas-osdk-bin.elf (built 2026-10-03T21:19Z) is the kernel for this tree.
- Prior Asterinas log preserved as guest/logs/cr3-asterinas.turn01-crash-fragment.log.
Action: recreated the test source faithfully from the prior run's binary
strings + logged PASS lines + the Step-1 scenarios (semantics identical), then
RE-EXECUTED both steps from scratch in this turn.

### Execution (commands)

- Linux reference:
  docker exec specula-memfd-harness-20261003 bash \
    /work/.specula-output/confirmation/CR-3/guest/step1_build_and_linux_ref.sh
  (gcc -O2 -static repro/test_bugCR-3_rejected_op_effects.c; run on container
  host kernel 7.2.8; repacks initramfs.cpio)
- Asterinas guest:
  docker exec specula-memfd-harness-20261003 bash \
    /work/.specula-output/confirmation/CR-3/guest/step2_asterinas_run.sh
  (cargo osdk run --scheme specula_memfd --boot-method=vmm-direct, prebuilt
  kernel, CR-3 initramfs, PID1=/init mounts /proc and execs /test_cr3)

### Escalation ladder

- Level 0 (pure black-box): reached and completed. All three arms trigger
  through plain public syscalls (memfd_create/open/mmap/mprotect/munmap/
  fcntl/write) in a single sequential process — deterministic, no race
  window, no failpoints. Result on BOTH Linux reference and Asterinas:
  22/22 checks pass; every observable effect matches the Linux contract.
  The hypothesized deviations (prefix discarded, over-grant beyond MAY
  bits, partial seal publication, deny-flag leak) do NOT occur.
- Levels 1-3: not escalated. Nothing timing-dependent to widen (Level 1),
  the hypothesized bad state cannot be injected because the code orders the
  deny check strictly before seal publication and applies each mprotect
  segment (remove->split->protect->reinsert) individually before checking
  the next (Level 2 has no admissible "bad" pre-state), and a source patch
  would only create the symptom (Level 3 prohibited). Level 0 alone fully
  exercised the finding's mechanisms and they behave correctly.

### Verdict rationale (decided after reproduction, per decision table)

Reachability of the hypothesized DEVIATION fails: the mechanism the finding
posits does not exist in the code. Code audit (checks ordered before
publication; per-segment application with VmPerms::check MAY-bit subset
enforcement), bounded MC (scenario-4 configs: no violation), and live Level-0
reproduction on Linux and Asterinas all agree: rejected operations leave
exactly the Linux-contract operation-specific effects (prefix retained on
EACCES/ENOMEM, no over-grant, all-or-nothing seal publication, no deny leak).
No real consumer can observe a wrong outcome because the wrong outcome is not
producible. Not a defect -> FALSE POSITIVE (code-review row). The single
pre-filter (code-review x known) does not apply: no prior report of this
mechanism exists (Step-3 search re-run this turn: web/GitHub — #2917 is the
merge-panic mechanism, #2408/#2926 implement the intended contracts) ->
Novelty: NEW.
