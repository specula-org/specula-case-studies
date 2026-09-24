# AST-12: Successful exFAT ftruncate retains the old logical size

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01b `20260908-150910-0a8c` (target `asterinas-syscall-buffered-file-size-read-consistency`), finding MC-4, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | `ftruncate` (trigger); `fstat`, `pread64` (observers) |
| Upstream | none (NO_DIRECT_MATCH). Reviewed, not matching: #3603 (closed unmerged exFAT refactor), #3604 (open exFAT xfstests tracking issue), #787 and #788 (closed old exFAT fixes) |
| Fix | unfixed. Repair and size/EOF/remount verification pending. |
| Reproducer | repro/ (runtime REPRODUCED at 604948581, SMP=2, single-threaded) |

## Summary

On exFAT, `ftruncate` returns 0 but the file's logical size stays at its old
value for every extension and for a shrink that does not free a cluster, because
the resize path updates only the allocation bookkeeping. Extending an empty file
leaves `st_size` at 0, and shrinking a 4096-byte file to 2048 leaves `st_size`
at 4096 with the truncated bytes still readable. Any process that can
`ftruncate` an exFAT file observes it with a single thread.

## Linux contract

ftruncate(2): "If the file previously was larger than this size, the extra data
is lost. If the file previously was shorter, it is extended, and the extended
part reads as null bytes ('\0')." On success it returns 0 and `fstat` reports
the new length. The 01b guest ran ext2 as the in-kernel control, which reported
the requested sizes (8192 and 2048). No separate Linux run was recorded for
this finding.

## Asterinas behavior

`kernel/core/src/fs/fs_impls/exfat/inode.rs::ExfatInode::resize` (the `Inode`
impl reached from `sys_ftruncate` through `InodeHandle::resize`) shrinks the
page cache only when `new_size < file_size`, then calls
`kernel/core/src/fs/fs_impls/exfat/inode.rs::ExfatInodeInner::resize`. That
helper is documented as "The `size_allocated` field in inode can be enlarged,
while the `size` field will not." It allocates or frees clusters, sets
`size_allocated = new_size`, and assigns `size = new_size` only in the branch
where the cluster count decreases and `new_size < self.size`. The helper's
contract suits `ExfatInode::write_at`, which publishes `size` itself, but the
public `resize` never publishes it. `ExfatInode::metadata` and
`ExfatInode::read_at` then use the stale `inner.size`.

Observed at the pin (01b MC-4):

```
MC4CASE /exfat/mc4a  before=0    ftruncate(1)=0    errno=0 st_size=0    pread=0
MC4CASE /exfat/mc4a2 before=0    ftruncate(8192)=0 errno=0 st_size=0    pread=0
MC4CASE /exfat/mc4b  before=4096 ftruncate(8192)=0 errno=0 st_size=4096 pread=4096
MC4CASE /exfat/mc4c  before=4096 ftruncate(2048)=0 errno=0 st_size=4096 pread=4096
MC4CASE /ext2/mc4a   before=0    ftruncate(8192)=0 errno=0 st_size=8192 pread=8192
MC4CASE /ext2/mc4c   before=4096 ftruncate(2048)=0 errno=0 st_size=2048 pread=2048
MC4VERDICT BUG bugs=8
```

In-kernel trace receipts (`ExfatResizeAllocation`, post-helper
`[size, size_allocated, clusters]`) showed `[0,1,1]`, `[0,8192,2]`,
`[4096,8192,2]`, `[4096,2048,1]`.

## Reproduction

`repro/test_bugMC-4_exfat_resize.sh` writes a static guest `/init` from an
embedded heredoc, builds fresh ext2 and exFAT images, and boots a kernel under
QEMU/KVM with `-smp 2`. The test is single-threaded and deterministic
(Level 0). See `repro/README.md`.

## Fix and upstream status

Register: "Repair and size/EOF/remount verification pending." The 01b handoff
worklist asks to cover extension, shrink within one cluster, shrink across
clusters, zero size, and repeated same-size calls, checking `fstat`, reads,
allocation, and persistence after remount. The 01b confirmation suggested
publishing `inner.size = new_size` after `inner.resize` in the public `resize`
and growing the page-cache bound on extension, while keeping the helper's
allocation-only semantics for `write_at`. No patch exists. matches.json:
NO_DIRECT_MATCH, upstream fix status NOT_ESTABLISHED.

## Evidence

- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md (Entry 4)
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/investigation.md
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/verdict.json
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmation/MC-4/repro-output.txt
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/spec/output/MC_hunt_s3_extend_zero_exfat_bfs1.out
- /home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/traces/exfat-0-10.ndjson
- /home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-buffered-file-size-read-consistency-20260907T161100Z.prep/handoff-01b.md

## Caveats

- The MC-4 run reused the harness kernel ELF under host QEMU/KVM because a
  registry TLS failure prevented pulling the Docker image. That ELF is the pin
  plus passive trace hooks. The test arms the hooks only to collect receipts.
- The runner hardcodes Nix store paths for QEMU, `mkfs.exfat`, and a static
  glibc on the original host. Override `QEMU`, `MKFS_EXFAT`, and
  `GLIBC_STATIC`, or use any static toolchain.
- The confirmation's cited line numbers (`inode.rs:293`, `:1469`) belong to the
  instrumented tree. At the pristine pin `ExfatInodeInner::resize` starts at
  line 286 and `ExfatInode::resize` at line 1436.
- A later write can republish the size as a side effect, which hides the state
  but does not repair `ftruncate`.
