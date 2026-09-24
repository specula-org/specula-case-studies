# AST-32: SCM_RIGHTS installs an FD before publishing its number

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | Recon `asterinas-syscall-user-memory-baseline-20260822T172958Z`, finding analysis-report MC-4/T-4/CR-5 (brief MC-4/T-4), Asterinas pin `604948581512d83734377974d4c34adb4530f2d7` |
| Also seen in | none |
| Syscalls | recvmsg |
| Upstream | none: no direct match in the 2026-09-14 search at upstream main `bc12195`. Reviewed non-matches: [#2176](https://github.com/asterinas/asterinas/pull/2176), [#3028](https://github.com/asterinas/asterinas/pull/3028) |
| Fix | unfixed, no fix located |
| Reproducer | NOT_RUN |

## Summary

When a Unix socket delivers SCM_RIGHTS, Asterinas inserts each passed file
into the receiver's file table and only then writes the new descriptor
number into the user control buffer. If that write faults, the table entry
stays, the error becomes `MSG_CTRUNC`, and `recvmsg` returns success. The
process then holds a descriptor whose number it was never told.

## Linux contract

Linux reserves a descriptor number, copies it to user memory, and calls
`fd_install` only after the copy succeeds. On a copy fault it releases the
reservation and installs nothing (Recon cites Linux `fs/file.c:1325-1364`
and `net/core/scm.c:330-379`). Earlier descriptors that were fully published
may stay installed, so the invariant is "installed implies number
published", not rollback of the whole control buffer. recv(2) also documents
`MSG_CMSG_CLOEXEC`, which sets close-on-exec on descriptors received through
SCM_RIGHTS.

## Asterinas behavior

- `kernel/core/src/net/socket/unix/ctrl_msg.rs::FileMessage::write_to`
  writes the `cmsghdr`, then for each file calls
  `file_table.write().insert(file.clone(), FdFlags::empty())` and only
  afterwards `writer.write_val::<i32>(&fd)`. A source comment notes that the
  inserted files are not removed if the number cannot be written and argues
  that Linux does not handle every corner case either. A
  `TODO: Deal with the O_CLOEXEC flag` sits on the insert, so
  `MSG_CMSG_CLOEXEC` is not applied.
- `kernel/core/src/net/socket/util/message_header.rs::ControlMessage::write_all_to`
  catches any `write_to` error, sets `MSG_CTRUNC`, and stops.
- `kernel/core/src/syscall/recvmsg.rs::sys_recvmsg` then writes the header
  and returns the payload length.

Recon rejected a kernel-memory-leak claim. Files that were never installed
are released when their `Arc`s drop. The lead is the installed but
unpublished table entry.

## Reproduction

No runtime reproducer exists. Recon T-4 proposes placing the descriptor slot
across a protection boundary and inspecting the descriptor table after
`recvmsg`.

1. Create an `AF_UNIX` `SOCK_DGRAM` socketpair and open a marker file such as
   `/dev/null`.
2. Send one byte with SCM_RIGHTS carrying the marker descriptor.
3. On the receiver, use a 24-byte control buffer (`CMSG_SPACE(sizeof(int))`)
   placed so the 16-byte `cmsghdr` ends a writable page and the 4-byte
   descriptor slot starts the next page, which is `PROT_NONE` or
   `PROT_READ`.
4. Record the open descriptors (probe `fcntl(fd, F_GETFD)` over 0 to 1023, or
   list `/proc/self/fd`), then call `recvmsg`.

Linux returns 1 with `MSG_CTRUNC` and the descriptor set is unchanged. The
defect is a return of 1 with `MSG_CTRUNC` and one new descriptor in the set.

A secondary check for CR-5 repeats the receive with a valid control buffer
and `MSG_CMSG_CLOEXEC`. Linux sets `FD_CLOEXEC` on the received descriptor.
The source predicts that Asterinas leaves it clear. Under the campaign rules
an unsupported flag alone is not a confirmed bug, so record it next to the
ownership result rather than as a separate finding. SMP=1 is enough.

The existing `test/initramfs/src/regression/network/unix_stream_err.c`
(lines 22-114 at the pin) exercises normal SCM_RIGHTS transfer but not a
faulting descriptor slot.

## Fix and upstream status

The 2026-09-14 dedup recorded NO_DIRECT_MATCH with upstream fix status
NOT_ESTABLISHED. #2176 introduced SCM_RIGHTS and #3028 changed `FileDesc` to
`u32`. Neither addresses install-before-publication. A fix would mirror
Linux: reserve the number, write it, then install.

## Evidence

- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/analysis-report.md` (sections 4, 6.5, 7, 9.1 MC-4, 9.2 T-4, 9.3 CR-5, 10)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/modeling-brief.md` (Scenario 3, section 6)
- `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-user-memory-baseline-20260822T172958Z/asterinas-syscall-user-memory/.specula-output/review-analysis.md`
- `/home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md` (section "Historical user-memory source analysis")
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`

## Caveats

- The register says installed/unpublished ownership and control flags need
  runtime verification.
- The source comment shows the ordering was a known choice upstream. A
  report should explain why Linux's ordering avoids this case rather than
  present it as unknown.
- The review of the Recon run notes that report CR-5 was folded out of the
  modeling brief. Cite the analysis report for CR-5.
- `ctrl_msg.rs`, `message_header.rs` and `recvmsg.rs` are unchanged between
  the pin and upstream main `bc12195` (package-builder `git diff`,
  2026-09-24).
