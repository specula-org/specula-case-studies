# AST-05: ramfs/exFAT reads copy beyond the reported EOF prefix

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z`, finding MC-3 (former catalog alias RF-05), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | GLM `asterinas-glm53-eval-20260826T035049Z` MC-2, REPRODUCED (added exFAT). 01b `20260908-150910-0a8c` MC-2 ("ExFAT reads copy beyond their reported prefix during write preparation"), REPRODUCED. 01b CR-1, REPRODUCED: its syscall effect maps here and its contract remainder is AST-25. |
| Syscalls | `read`, `pread64`, `readv`, `preadv` |
| Upstream | Open PR covers it: [#3778](https://github.com/asterinas/asterinas/pull/3778) "Limit page-cache reads to the file size in ramfs and exfat", head `d007cbb62`, open on 2026-09-24. |
| Fix | PR #3778 (filed by the workspace owner on 2026-09-02). Not merged. The register notes it was not retested in the catalog pass. |
| Reproducer | repro/ (runtime REPRODUCED at `604948581`, SMP=2) |

## Summary

A `read()`, `pread64()`, or `preadv()` on a ramfs or exFAT file that reaches
the logical EOF copies page-cache bytes past EOF into the caller's buffer. The
page cache is page-aligned, so bytes beyond the returned count are overwritten
with zeros, even when the call returns 0 at EOF. If the caller's buffer faults
after the logical EOF, the call returns `EFAULT` instead of the short read.
Any unprivileged process reading a ramfs or exFAT file can observe that its
buffer is clobbered beyond the reported length.

## Linux contract

read(2) returns the number of bytes read into the buffer. Linux copies only
those bytes and leaves the rest of the caller's buffer untouched. The Linux
7.1.9 tmpfs control (2026-09-02) left every sentinel byte past the return
value intact (`wrong_return_values=0 buffers_modified_past_return=0`,
`MC3_RESULT MATCHES_LINUX`).

## Asterinas behavior

At pin `604948581`:

- `kernel/core/src/fs/fs_impls/ramfs/fs.rs::RamInode::read_at` (the `FileOps`
  impl, lines 701-710) computes the correct logical `read_len` but hands the
  caller's unlimited writer to the page cache.
- `kernel/core/src/fs/fs_impls/exfat/inode.rs::ExfatInode::read_at` (line 643
  onward) has the same shape. The GLM run and the 2026-09-02 `/exfat` check
  showed the same effect.
- `kernel/core/src/vm/page_cache/mod.rs::PageCache` (lines 181-186) documents
  that capacity is page-aligned and may exceed EOF ("The filesystem remains
  responsible for tracking EOF").
- `kernel/core/src/vm/page_cache/vmo/mod.rs::Vmo::read` (lines 534-566) clips
  the copy against capacity, not file size.
- For contrast, `kernel/core/src/fs/fs_impls/ext2/inode/file.rs::InodeInner::read_at`
  calls `writer.limit(read_len)` (line 240), so ext2 is not affected.

## Reproduction

- `repro/repro.c`: the 01a program (MC-3), byte-identical to
  `test_bugMC-3_ramfs_read_past_eof.c`. It fills buffers with a sentinel, reads
  across and at EOF with `pread`, `read`, and `preadv`, and prints
  `MC3_SUMMARY wrong_return_values=<a> buffers_modified_past_return=<b>` and
  `MC3_RESULT`. The directory argument must exist.
- `repro/min_ast05.c`: a 37-line version from the 2026-09-02 validation that
  prints `MIN_AST05 BUG` or `MIN_AST05 OK`.
- `repro/read_eof-regression-pr3778.patch`: the in-tree regression test from PR
  #3778 (commit `17234066b`, `fs/read_eof`). It runs on `/tmp`, `/ext2`, and
  `/exfat` and includes a concurrent `preadv` case that protects the clone form
  of the fix.
- `repro/variants/GLM-MC-2/`: the GLM variant with ramfs, exFAT, and an ext2
  control in one run.

Recorded on 2026-09-02 at the pin (SMP=2), on `/mc3` (ramfs): 6 of 6 checked
buffers were modified past the return value (for example `pread` at EOF
returned 0 and clobbered all 64 bytes), and the return values were correct.
The same regression test on `/exfat` at the pin failed the same way while
`/ext2` passed.

## Fix and upstream status

- PR #3778 is open with head `d007cbb623bde58c6692feb6e3257ca1490438fd` on base
  `a5449e62b`. Commits: `042ff520c` (copy through a clone of the writer limited
  to `read_len`, then advance the caller's writer, in ramfs and exFAT),
  `17234066b` (`fs/read_eof` tests), `16e1bcaa6` (take the page-cache lock
  before sizing ramfs reads, which fixes AST-10), and `d007cbb62`
  (`fs/read_truncate_race` test for AST-10). `matches.json` records the PR head
  as equal to the local development HEAD on 2026-09-14.
- The clone matters. A reviewer suggested limiting the caller's writer in
  place, as ext2 does. That form breaks `do_sys_readv`/`do_sys_preadv`, which
  decide whether to continue to the next iovec from the writer's remaining
  space: a guest test measured 294 of 20000 `preadv` calls split across iovecs
  with the in-place form, and 0 with the clone form. ext2 has the same latent
  problem upstream.
- Earlier history: the 01a v5 `fixes.patch` added an in-place
  `writer.limit(read_len)` and a cursor-derived return, and passed the A/B at
  the pin (6/6 clobbered before, 0/0 after). The same patch was later found
  unsafe for `readv` for the reason above.
- Review state and local branch history are in
  `/home/chin39/Documents/play/specula-profile/references/pr-3778-handoff.md`.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-05-ramfs-read-past-eof/description.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-3/`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-3_ramfs_read_past_eof.c` and `test_bugMC-3_eof_consumer_harm.c`
- `/home/chin39/Documents/play/specula-profile/reports/patch-validation-report.md`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/README.md` (sections "AST-05 fix validation" and "AST-05 review round 1")
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/asterinas-604948581-guest-transcript.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/linux-7.1.9-AST-05-tmpfs.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/ast05-fix-read_eof-baseline-604948581.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/ast05-review/`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/upstream-issues/AST-05-pr-draft.md` and `AST-05-patches/`
- `/home/chin39/Documents/play/specula-profile/references/pr-3778-handoff.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-2/`
- `/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency/.specula-output/confirmed-bugs.md` (entries MC-2 and CR-1)
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (entry `AST-05`)

## Caveats

- AST-10 (ramfs snapshots the read length before serializing with resize) is a
  separate tracked defect with a different fix and test, even though PR #3778
  fixes both.
- AST-25 keeps the unverified PageCache/VmIo contract question that 01b CR-1
  raised. Its reproduced syscall effect is this entry.
- The PR was not re-run during the catalog or deduplication passes. The last
  guest validation found in the workspace is from 2026-09-11, on an uncommitted
  snapshot (`scratch/wip-check` `d1c027870`) of the eight-writer test form: fs
  suite at SMP=4 passed, 0 of 20000 split reads, and the in-place-limit counter
  tree failed 1767 of 20000. No log ties that run to the pushed head
  `d007cbb62` (`/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/wip-2026-09-11/`).
- `repro/run.sh` compiles inside the guest with `cc` and expects `/mc3` to
  exist. The stock initramfs has no compiler, and the guest driver must
  `mkdir -p /mc3` first. See `docs/running-reproducers.md`.
