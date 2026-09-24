# AST-27: Scalar positional I/O allegedly changes shared offset

| Field | Value |
|---|---|
| Evidence status | FALSE POSITIVE |
| Origin | GLM `asterinas-glm53-eval-20260826T035049Z`, finding CR-1, Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z` analysis-report F3 ("Positional I/O exposes the vector split without moving the OFD offset"), a static negative with no confirmation verdict. The GLM final report says CR-1 "matches baseline F3 negative". |
| Syscalls | `pread64`, `pwrite64`, `preadv`, `pwritev` |
| Upstream | none for this candidate (NON_ACTIONABLE_RECORD). Related, not matching: #2471 (merged, fixes `preadv`/`pwritev` parameter passing) |
| Fix | not applicable |
| Reproducer | repro/ (negative probe, ran at 604948581 with SMP=2, 19 of 19 checks pass on Asterinas and Linux) |

## Summary

The candidate asked whether `pread64`/`pwrite64` on descriptors that share one
open file description could move the shared file offset, for example through
an adapter path. They cannot: the positional paths take the offset by value and
never touch `InodeHandle::offset`. A 19-check probe, including faulting
buffers, `O_APPEND`, file extension, and concurrent hammer threads, passed on
Asterinas and on Linux.

## Linux contract

pread(2): "The file offset is not changed." pwrite(2) likewise leaves the file
offset unchanged. On Linux, `pwrite` to an `O_APPEND` descriptor appends at the
end of the file regardless of the offset argument (pwrite(2) BUGS), and the
file offset still does not move. The same probe binary passed 19 of 19 checks
on Linux.

## Asterinas behavior

At the pin the only mutators of `InodeHandle::offset` in
`kernel/core/src/fs/file/inode_handle.rs` are `InodeHandle::read`,
`InodeHandle::write`, the getdents path, and `lseek`, all under the offset mutex.
`kernel/core/src/syscall/pread64.rs::sys_pread64` and
`kernel/core/src/syscall/pwrite64.rs::sys_pwrite64` call
`InodeHandle::read_at`/`InodeHandle::write_at` with the offset by value. The
`O_APPEND` branch in `write_at` reassigns only its local parameter. For regular
files `file_ops_for_positional_io()` returns the inode itself. The one
`open_file`-based implementation (virtiofs `VirtioFsFile`) also receives the
offset by value. `FileTable::duplicate_entry` shares one `Arc<InodeHandle>`
between duplicated descriptors, which matches Linux.

Observed at the pin (GLM CR-1, excerpt):

```
CR1   3 pwrite64 leaves shared offset             : PASS (ret=6 cur(fd)=5000)
CR1   8 pread64 fault-prefix, offset kept         : PASS (ret=-1 errno=14 cur=5000)
CR1  15 O_APPEND pwrite64, offset kept            : PASS (ret=1 cur=1000)
CR1  16 control: read() moves shared offset       : PASS (ret=10 cur=5010)
CR1  17 concurrent pread64 never moves offset     : PASS (cur=7410 expected=7410 pread_bytes=79104)
CR1_RESULT: PASS (19 checks, 0 failed)
```

Checks 1, 2, and 16 are positive controls that prove the probe can see shared
offset movement.

## Reproduction

`repro/test_bugCR-1_positional_offset_isolation.c` is a Level 0 probe using
public syscalls only. See `repro/README.md`. It can serve as a regression test
for positional-offset isolation, which no existing Asterinas test asserts.

## Fix and upstream status

Register: "Scalar positional isolation holds; vector AST-03 is separate."
matches.json: NON_ACTIONABLE_RECORD, upstream fix status NOT_APPLICABLE, "ABI
parameter fixes and vector interleaving are separate."

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmed-bugs.md (Entry 5)
- /home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/CR-1/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/CR-1/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugCR-1_positional_offset_isolation.guest_output.log
- /home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugCR-1_positional_offset_isolation.guest_qemu_full.log
- /home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/repro/test_bugCR-1_positional_offset_isolation.linux_control.txt
- /home/chin39/Documents/play/specula-profile/reports/glm53-eval-final-report.md

## Caveats

- The rejection covers scalar positional I/O and the per-entry `preadv`/`pwritev`
  offset. Vectored atomicity against a shared-offset competitor is AST-03.
- The GLM MC hunt for this property found no violation (BFS depth 19, 2016
  states, plus a long simulation), so the candidate came from code review.
- Side observation, not this mechanism: on fault-prefix transfers Asterinas
  returned zero-progress `EFAULT` where Linux returned the copied prefix (4096).
  That count behavior belongs to the partial-progress family (AST-01, AST-04).
- The GLM guest harness used `AUTO_TEST=cr1repro`. The Makefile wiring for that
  target was not retained because the CR-1 confirmation worktree was removed.
