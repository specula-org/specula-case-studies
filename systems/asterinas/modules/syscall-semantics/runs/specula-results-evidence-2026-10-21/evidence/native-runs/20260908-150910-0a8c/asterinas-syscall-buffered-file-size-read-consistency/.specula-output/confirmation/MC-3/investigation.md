# MC-3 Investigation — ExFAT stale write preparation permits false success and inconsistent extents

Source: MC (counterexample `spec/output/MC_hunt_s2_exfat_extent_bfs1.out`, config `MC_hunt_s2_exfat_extent.cfg`, invariant `SettledReadableExtent`).

## Step 1 — Code audit

### Cited code (worktree line numbers; instrumented tree == `/work/source`, verified `diff -rq` identical)

`kernel/core/src/fs/fs_impls/exfat/inode.rs`, `ExfatInode::write_at` (body starts l. 729):

```rust
fn write_at(&self, offset: usize, reader: &mut VmReader) -> Result<usize> {
    let write_len = reader.remain();
    let new_size = {
        let mut inner = self.inner.write();              // (P1) exclusive guard
        ...
        if new_size > file_size {
            if new_size > file_allocated_size {
                inner.resize(new_size, &fs_guard)?;      // exFAT cluster allocation
            }
            inner.page_cache.resize(new_size, file_size)?; // sets VMO capacity C = align_up(new_size)
        }
        new_size.max(file_size)                          // saved for later publication
    };                                                    // (P2) write guard RELEASED here
    // Locks released here, so that file write can be parallelized.
    let inner = self.inner.upread();                     // (P3) fresh upgradeable guard; no revalidation
    inner.page_cache.write(offset, reader)?;             // (P4) copy; VMO clamps to CURRENT capacity
    {
        let mut inner = inner.upgrade();
        inner.update_atime_mtime_and_ctime()?;
        inner.size = new_size;                           // (P5) publishes STALE saved new_size
    }
    ...
    Ok(write_len)                                        // (P6) returns FULL requested count
}
```

Supporting lines:

- `kernel/core/src/vm/page_cache/mod.rs:271` — `PageCache::resize`: `vmo.size.store(new_cache_size, Ordering::Release)`; a *smaller* `new_file_size` lowers C and decommits pages above it. There is no guard against lowering C below another prepared extender's target. `deep-shared-protocol.md:56` independently notes the decommit branch keys on `new_file_size < old_file_size`.
- `kernel/core/src/vm/page_cache/vmo/mod.rs:571` — `Vmo::write`: `let write_len = reader.remain().min(self.size().saturating_sub(offset));` — silently clamps the copy to the *current* capacity; `write_len == 0` returns `Ok(())` immediately. Zero bytes copied is a success.
- `kernel/core/src/vm/page_cache/mod.rs:355-366` — `impl VmIo for PageCache`: `read`/`write` return `Result<()>`; the backend therefore cannot learn how many bytes were actually transferred. The TODO at 359-361: *"This should require `&mut` to ensure that the caller holds the inode lock. However, we need to fix the exfat code first, since it does not hold the write lock when handling `write()`."*
- `exfat/inode.rs:652-675` `read_at`: computes `read_len` from the **logical** `inner.size`, calls `page_cache.read` (returns `()`), returns `Ok(read_len)` — the count is derived from logical size regardless of delivered bytes.
- `kernel/core/src/vm/page_cache/vmo/mod.rs:538-546` — `Vmo::read`: `read_len = writer.avail().min(self.size().saturating_sub(offset))` — clamps to capacity C, not logical size L.
- `kernel/core/src/fs/file/inode_handle.rs:327-341,343-369` — returns backend counts unmodified.
- `kernel/core/src/syscall/pread64.rs:33-41` — `sys_pread64` returns `file.read_at(...)` count directly to userspace; the VmWriter is not consulted for progress. (pwrite64 symmetric.)

### Counterexample trace (28 states, from `MC_hunt_s2_exfat_extent_bfs1.json`; 1 cell = 2048 B, file starts L=C=A=2)

| States | Action |
|---|---|
| 2-3 | t0 enters `pwrite64(O=2,N=2)`; t1 enters `pwrite64(O=4,N=2)` |
| 4-7 | **t1 (higher) prepares first**: exFAT alloc to 6, `PageCacheResizeCapacity` C=6, releases write guard |
| 8-11 | t1 sits before `ExfatAcquireCopy`; **t0 (lower) prepares**: `PageCacheResizeCapacity` C=4 (**lowers C from 6 to 4**) |
| 12-21 | t0 copies D=2 (fits C=4), publishes L=4, returns Ok(2) |
| 22-27 | t1 copies at O=4: C=4 → `ioLen = min(2, 4-4) = 0`, **D=0, accepted=[]**; publishes **L=6**; returns **Ok(2)** |
| 28 | settled: **L=6 > C=4**; t1's completed write has `view=[...,Unreachable,Unreachable]` — `SettledReadableExtent` violated |

Real-byte instantiation (PAGE_SIZE=4096, seed file 4096 B): t1 = `pwrite64(fd, buf, 4096, 8192)`, t0 = `pwrite64(fd, buf, 4096, 4096)`. t1 prepares C→12288; t0 prepares C→8192; t0 copies+returns; t1 copies 0 bytes, publishes L=12288, returns 4096. Settled: L=12288, C=8192.

### Reachability / trigger scenario

Pure userspace, no faults, no special privileges: two threads `pwrite64` disjoint extending ranges of one exFAT file. The required interleaving is a legal schedule of the real lock protocol (verified against `deep-shared-protocol.md:84`: exFAT write releases preparation's write guard before taking an upreader; only one upreader may exist, so copies exclude each other, but another preparation can execute between release and reacquisition).

Consequence chain (real consumer): after settle, L=12288 > C=8192 persists (no later operation restores C: reads never resize; a write inside [0,12288] takes the `new_size <= file_size` branch and skips resize; verified in code). Therefore:

1. **Write-side false success**: t1's `pwrite64` returns 4096 having delivered 0 bytes (POSIX: a return of N means N bytes were written; subsequent reads must see them or zeros).
2. **Read-side over-report**: `pread64(fd, buf, 4096, 8192)` → `read_at` computes read_len=4096 from L=12288; `Vmo::read` clamps to C=8192 → delivers 0 bytes; syscall returns 4096 with the user buffer untouched (stale user memory reported as file content; a correct kernel returns zeros for the in-EOF hole).
3. **Permanence**: a *third*, non-racing `pwrite64(fd, buf, 4096, 8192)` after settle again returns 4096 while delivering 0 bytes (L=12288 already, so no resize ever happens).
4. **Other completion order** (t1 publishes L=12288 before t0 publishes L=8192): the file size regresses to 8192 below t0's... below t1's already-successful extent 12288 — a completed write ends up beyond EOF.

Safeguards checked (none fire): no count reconciliation anywhere on the write or read return path (`PageCache` `VmIo` returns `()`); `sys_pread64`/`pwrite64` return the backend count verbatim; the only related guard is the single-upreader rule, which serializes copies but not prepare-versus-copy.

### Existing native evidence (from harness scenario exfat-4, `traces/exfat-4-14.ndjson`)

The prior harness run exercised exactly this two-extender race on exFAT (t0 `pwrite(4096,4096)`, t1 `pwrite(4096,8192)`, 4096-B seed). Observed native schedule: t1 ran prepare+copy+publish **completely before** t0 entered (t0's prepare observed `S=6`, so it skipped resize). Benign order; no anomaly. Confirms the dangerous window (higher extender's ReleasePreparation → its copy) was not hit by the single collected native trial.

## Step 2 — Developer knowledge

- `kernel/core/src/vm/page_cache/mod.rs:359-361` (TODO, verbatim): *"This should require `&mut` to ensure that the caller holds the inode lock. However, we need to fix the exfat code first, since it does not hold the write lock when handling `write()`."* — direct in-tree acknowledgement that exFAT's write path lacks write-lock coverage. A TODO is awareness, not a filed report (skill Step 3): does not make the finding known.
- `exfat/inode.rs:758` comment: *"Locks released here, so that file write can be parallelized."* — the release is deliberate (parallelism intent); the stale-revalidation gap is not discussed anywhere.
- `PageCache::resize` doc comment (`page_cache/mod.rs:201-214`): *"The filesystem must keep that capacity synchronized with its own file size under the same inode- or file-level lock that excludes conflicting buffered I/O and resizing."* — exFAT violates this documented contract across its prepare/copy gap.
- Issue tracker (evidence/issue-inventory.json, 420 issues, plus live web search 2026-09-08): #2937 "Refactor the page cache system" (closed, design proposal; "incomplete locking mechanism ... race conditions" in general), PR #2953 (page-cache refactor, merged; states PageCache cannot guarantee concurrent data-page access, Linux i_rwsem analogy), #3142/#3604 xfstests gap trackers (ext2/ext4-style hole zero-fill, mmap-during-sync — different aspects), #2269 (exFAT eviction duplicate DMA map — different mechanism), #3609 (exFAT POSIX-semantics false success for chmod/chown/socket — different operations), #440 (rwlock upgrade atomicity — adjacent but different), PR #3256 (merged 2026-05-25; uninit-memory leak via partial-page CommitMode — different mechanism, already fixed). **No report describes the exFAT prepare/release/reacquire publication defect or its size-regression / zero-copy-false-success consequence.**
- Pipeline archaeology (`evidence/deep-shared-protocol.md:44,56,84`) analyzed this exact protocol and records the TODO as "a lead, not a substitute" — treated as unreported.

## Step 3 — Known-status

Novelty: **NEW**. Searched: 420-issue inventory (incl. closed), open-PR inventory, live web search over asterinas/asterinas issues/PRs (queries: "exfat write_at page_cache resize concurrent writers race", "exfat write lock released parallelized write", "PageCache write TODO exfat hold write lock"), and recently merged PRs (#3256, #2953, #3171, 7f3a096). No issue/PR/CVE reports this mechanism at this site. This is MC-sourced with a real counterexample, so even a known match would proceed to Phase 2; the code-review × known pre-filter does not apply.

## Step 2/3 re-check (resumed turn, 2026-09-09)

Independently re-ran the prior-report search before writing NEW:

- Live web search (3 query angles over asterinas issues/PRs): only adjacent reports — #2937/#2953 (general page-cache locking refactor), #3256 (merged fix for uninit-memory leak via partial-page CommitMode, different mechanism), #2817 (ftruncate decommit hang, different). No report describes the exFAT prepare/release/reacquire publication defect.
- GitHub issue search `exfat in:title created:>2026-06-01` (14 results): #3803 (`cluster_to_off` underflow panic via crafted image) and #3802 (bitmap OOB via crafted mount) are malformed-image crashers — different mechanism, different site. No match for this finding.
- Recent commits touching `kernel/core/src/fs/fs_impls/exfat/inode.rs` (864b9138 2026-09-02, da46023b, 0a9a1106, 36ae7fe1, d921f38d, b9cfb5cc): none touch `write_at`'s prepare/release/reacquire protocol.
- Current upstream `main` (fetched raw, 2026-09-09): `write_at` still has the exact structure — write-guard block computes `new_size`, guard released at block end ("Locks released here, so that file write can be parallelized."), `upread()`, `page_cache.write`, then `inner.size = new_size` with NO revalidation. Defect still present upstream; fix-status: unfixed.

Novelty stands: **NEW**.

## kernel-src vs worktree (Level 3 patch audit)

`diff -r`: exactly three files differ (`tla_trace.rs`, `syscall/prctl.rs`, `fs_impls/exfat/inode.rs`), and only by the timing hook (repro/mc3-kernel-hook.patch): one busy-wait call at the release→reacquire window, one armed-counter field, one prctl option gate. Default disarmed ⇒ behavior identical to the worktree kernel. No logic is altered anywhere.

## Phase 2 artifact status at resume

- L1 (unpatched harness kernel, 500 trials, entry-delay sweep, -smp 2, pinned vCPUs): completed by previous turn — `build/guest-L1.log`, `MC3_VERDICT L1 not_triggered trials=500`. Window never hit natively.
- L3/L3R guest initramfs + exfat image built; patched kernel build was in progress (build/osdk-target, 630M) when the previous turn crashed (adapter exit 241); resumed this turn.

## Phase 2 — reproduction record (completed 2026-09-09, resumed turn)

Escalation ladder:

- **L0/L1 (unpatched harness kernel, timing-only)**: 500 trials, CPU-pinned threads, TSC-rendezvous, swept userspace entry delay (0..12.5k pause iterations), `-smp 2`. `build/guest-L1.log`: every trial benign (t1 completed fully before t0 entered, or t0 prepared first). `MC3_VERDICT L1 not_triggered trials=500`. The native window — write-guard release to upread reacquire, a handful of instructions — was never hit. Prior harness native trace (`traces/exfat-4-14.ndjson`) likewise captured only the benign order.
- **L2 (state injection)**: not used. The defect is a lock-protocol race window; injecting a pre-shrunk VMO would test `write_at`'s handling of a state, not the race itself, and L3 (below) instantiates the CE's exact schedule through real syscalls, which is strictly stronger evidence.
- **L3 (minimal code modification — timing-only hook)**: `repro/mc3-kernel-hook.patch` adds a prctl(0x53504551)-armed busy-wait inside `ExfatInode::write_at` immediately after `ExfatWriteAtReleasePreparation` and before the upread reacquire — the exact CE window (states 8-11). No locks held while spinning; no logic altered; default disarmed (no-op). Patch audited: `diff -r` vs the worktree shows exactly 3 files differing, hook only. Guest: `repro/guest_mc3.c`; runner: `repro/test_bugMC-3_exfat_stale_prepare.sh`; kernel: `build/kernel-l3` (build log `build/kernel-build-l3.log`; patched tree renamed `kernel-src` -> `kernelhook` because the comp-sys component path heuristic panics on directory names containing `src/` — runtime `NotIncludeAllComponent("/work/.../kernel-")`).

L3 result (CE order: t0 copies+publishes first) — `build/guest-L3.log`, verbatim:

```
MC3_BEGIN mode=L3 kernel-delay hook (CE order: t0 completes first)
MC3_RESULT {"level":3,"trial":0,"t0_ret":4096,"t0_errno":0,"t1_ret":4096,"t1_errno":0,"size_after":12288,"read_ret":4096,"read_errno":0,"read_bytes_changed":0,"w3_ret":4096,"w3_errno":0,"r3_ret":4096,"r3_errno":0,"r3_changed":0,"size_final":12288,"CHECK1_size_regressed_below_completed_write":0,"CHECK3_read_overreport_sentinel_survives":1,"CHECK4_persistent_false_success":1}
MC3_VERDICT L3 BUG_TRIGGERED
```

Reading: t1's `pwrite64(fd,'B',4096,8192)` returned **4096** while `Vmo::write` clamped its copy to **0 bytes** (C had been lowered to 8192 by t0's prepare). Settled st_size=12288 > C=8192. Post-settle `pread64(fd,buf,4096,8192)` returned **4096** with **0 bytes delivered** (all 4096 sentinel bytes 0x55 survived) — read over-report of an in-EOF hole that a correct kernel returns as zeros (CHECK3). A third, non-racing `pwrite64` at 8192 again returned 4096 delivering 0 bytes and the range still reads back as untouched sentinel — the bad state is **permanent** (CHECK4).

L3R result (regression order: t1 publishes 12288, then t0 publishes its stale 8192) — `build/guest-L3R.log`, verbatim:

```
MC3_BEGIN mode=L3R kernel-delay hook (regression order)
MC3_RESULT {"level":3,"trial":0,"t0_ret":4096,"t0_errno":0,"t1_ret":4096,"t1_errno":0,"size_after":8192,"read_ret":0,"read_errno":0,"read_bytes_changed":0,"w3_ret":4096,"w3_errno":0,"r3_ret":4096,"r3_errno":0,"r3_changed":4096,"size_final":12288,"CHECK1_size_regressed_below_completed_write":1,"CHECK3_read_overreport_sentinel_survives":0,"CHECK4_persistent_false_success":0}
MC3_VERDICT L3R BUG_TRIGGERED
```

Reading: t1's pwrite of extent [8192,12288) already returned success (4096), then the settled st_size regressed to **8192** — the acknowledged write ended up entirely beyond EOF (CHECK1). (`read_ret`=0 is consistent: EOF was 8192 at inspection. The later third write re-extends cleanly, hence `r3_changed`=4096.)

Both runs match the counterexample: same actions (two extending `pwrite64`s), same order (higher extender prepares and releases; lower extender's prepare lowers C), same violated invariant (`SettledReadableExtent`: settled L exceeds the cache's readable bound), same code path (exFAT `write_at` prepare/release/reacquire + `Vmo::write` clamp + stale `new_size` publish).

Environment notes for reruns: docker image `asterinas/dev:0.18.1-20260901`, container `specula-mc3`, run dir mounted at `/work`, `/dev/kvm`; QEMU `-enable-kvm -smp 2`, guest initramfs `build/initramfs-L3{,R}.cpio`, subject image `build/exfat.img` (128 MiB exFAT, cluster 4096, mounted at /exfat).
