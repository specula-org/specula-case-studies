# AST-03: Vectored I/O releases the offset lock between iovecs

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | 01a `asterinas-syscall-regular-file-partial-progress-20260823T030315Z`, finding MC-5 (former catalog alias RF-03), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | GLM `asterinas-glm53-eval-20260826T035049Z` MC-4, INCOMPLETE (tooling failure: the turn produced no canonical VERDICT; the final report records an earlier attempt's A-verdict as REPRODUCED). Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z` analysis-report MC-1 and modeling-brief MC-1, analysis-only candidates. |
| Syscalls | `readv`, `writev`, `preadv2` and `pwritev2` with offset `-1` |
| Upstream | Related only: merged PR [#2230](https://github.com/asterinas/asterinas/pull/2230) keeps an earlier iovec count after a later error but still calls the scalar path per iovec. Closed issue [#1554](https://github.com/asterinas/asterinas/issues/1554) is about pipe `PIPE_BUF` atomicity. Neither fixes shared-offset vector atomicity. |
| Fix | Local only: the historical 01a v5 `fixes.patch` (A/B validated at the pin). Not rebased and not submitted. No upstream fix. |
| Reproducer | repro/ (runtime REPRODUCED at `604948581`, SMP=2) |

## Summary

`readv()` and `writev()` on a regular file loop over the iovecs and call the
scalar `file.read()` or `file.write()` once per entry. Each scalar call takes
and releases the open file description's offset lock, so another thread using
a duplicated descriptor can read or write between two iovecs of a single
vector call. A concurrent `write()` can land inside the range one `writev()`
writes, and a concurrent `read()` can consume bytes between two entries of one
`readv()`. Any unprivileged multithreaded process sharing a descriptor can
observe it.

## Linux contract

readv(2): "The data transfers performed by readv() and writev() are atomic:
the data written by writev() is written as a single block that is not
intermingled with output from writes in other processes; analogously, readv()
is guaranteed to read a contiguous block of data from the file, regardless of
read operations performed in other threads or processes that have file
descriptors referring to the same open file description." Linux holds
`f_pos_lock` for the whole vector call (`fdget_pos` in `fs/read_write.c`,
cited as lines 1068-1106 in the catalog description).

## Asterinas behavior

At pin `604948581`:

- `kernel/core/src/syscall/preadv.rs::do_sys_readv` (lines 134-174) calls
  `file.read(writer)` once per iovec. The in-source TODO says: "readv must be
  atomic, but the current implementation does not ensure atomicity."
- `kernel/core/src/syscall/pwritev.rs::do_sys_writev` (lines 148-170) does the
  same with `file.write(reader)`.
- `kernel/core/src/fs/file/inode_handle.rs::InodeHandle::read` and
  `::write` (the `FileLike` impl, lines 273-320) hold the offset mutex only
  around one backend call.
- `sys_preadv2`/`sys_pwritev2` with offset `-1` dispatch to the same
  `do_sys_readv`/`do_sys_writev`.

A related effect shows in CASE E of the reproducer: when a later iovec faults
after depositing bytes, the return counts only the earlier entries (ret=4096
while 8192 bytes were deposited). That is the AST-04 count-erasure mechanism
applied per iovec.

## Reproduction

`repro/repro.c` (01a MC-5, byte-identical to the run's
`test_bugMC-5_vector_atomicity.c`) creates a 64-entry, 4096-byte-per-entry
vector and races it against a competitor thread on a `dup`ed descriptor for
100 rounds per case. It needs `-pthread` and `SMP=2` or more.

- CASE A `readv_vs_read`, CASE B `readv_vs_write`, CASE C `writev_vs_write`:
  the atomicity checks.
- CASE D `per_entry_read_loop_vs_read`: a detector control that reproduces the
  per-entry loop shape in userspace. It must tear on both kernels, which shows
  the detector is not blind.
- CASE E `later_iovec_fault`: return count versus deposited bytes.

Recorded on 2026-09-02 at the pin (SMP=2): A 87/100, B 87/100, and C 98/100
rounds torn (191168 foreign bytes inside `writev` spans), D 99/100, and E
`ret=4096` with 8192 deposited. The 01a run recorded 79, 92, and 97 torn rounds
and 234,560 foreign bytes. Linux 7.1.9 tmpfs: A/B/C 0 torn, D 100/100, E
`ret=8192`.

`repro/variants/GLM-MC-4/` holds the GLM run's timing-assisted variant. Its
retained source did not trigger in the retained guest runs. See its README.

## Fix and upstream status

- Upstream dedup (2026-09-14): `RELATED_ONLY`, no fix established. The
  2026-09-02 search also noted merged PR #3720 (iovec validation, 2026-08-27),
  which adds no per-call offset locking.
- Local fix in the 01a v5 `fixes.patch`: new `FileLike::readv`/`writev` trait
  methods, an `InodeHandle` override that holds the offset lock across all
  iovecs, and `preadv.rs`/`pwritev.rs` dispatching to them. A/B at the pin:
  0/100 torn in A, B, and C (`ATOMIC`), CASE E `RESULT_MATCHES_EFFECT`
  (`ret=8192`), and CASE D still torn. Patch path:
  `/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z.fixes.patch`.
  Pipes, sockets, and other `FileLike` types keep the old per-entry loop through
  the trait default.
- `preadv.rs` and `pwritev.rs` were byte-identical on main `29b0f4bcf` on
  2026-09-02 (static check).

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-03-vector-atomicity/description.md`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/confirmation/MC-5/`
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-5_vector_atomicity.c`
- `/home/chin39/Documents/play/specula-profile/reports/patch-validation-report.md`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/asterinas-604948581-guest-transcript.txt`
- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/linux-7.1.9-AST-03-tmpfs.txt`
- `/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-4/`
- `/home/chin39/Documents/play/specula-profile/reports/glm53-eval-final-report.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (entry `AST-03`)

## Caveats

- The race is schedule-dependent. Torn-round counts differ between runs (79 to
  98 of 100), and a single-CPU guest is not expected to show it. Use `SMP=2` or
  more.
- The GLM run's own confirmation of this mechanism stayed INCOMPLETE. The
  catalog's REPRODUCED status rests on the 01a run and the 2026-09-02
  re-run.
- The v5 fix only covers `InodeHandle` (regular files). Vector atomicity for
  other file types was not examined.
- Linux and Asterinas ran separately compiled builds of the same source.
- AST-43 (datagram record boundaries) and AST-44 (pipe `readv` prefix
  blocking) are separate source leads about the same per-iovec loop.
