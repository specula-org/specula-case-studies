# AST-43: Scalar decomposition of vectored datagram I/O breaks record boundaries

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F02, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `writev`, `readv`, `pwritev2`, `preadv2` |
| Upstream | none (dedup `NO_DIRECT_MATCH`, upstream main `bc12195df`) |
| Fix | unfixed |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `datagram_writev`, `datagram_readv`, Linux evidence only) |

## Summary

`readv` and `writev` loop over the iovecs and issue one scalar `read`/`write` per iovec. On a socket each scalar call is one `recvmsg`/`sendmsg`, so a two-iovec `writev` on an `AF_UNIX` `SOCK_DGRAM` socket is predicted to send two datagrams, and a two-iovec `readv` cannot receive one 8-byte datagram as 4+4 bytes. Any program that uses vectored I/O on message sockets can observe it.

## Linux contract

[readv(2)](https://man7.org/linux/man-pages/man2/readv.2.html) says the data transfers performed by `readv()` and `writev()` are atomic and that the buffers are processed in array order. For a datagram socket this makes one `writev` one message and one `readv` one message scattered across the buffers. The saved Linux runs show `writev=8`, one 8-byte datagram, then `EAGAIN`, and `readv=8` split as `ABCD`/`EFGH`.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/pwritev.rs::do_sys_writev` iterates `reader_array.readers_mut()` and calls `file.write(reader)` per iovec. `kernel/core/src/syscall/preadv.rs::do_sys_readv` iterates `writer_array.writers_mut()` and calls `file.read(writer)` per iovec. The blanket `impl<T: Socket> FileLike for T` in `kernel/core/src/net/socket/mod.rs` implements `read` as one `recvmsg(writer, RecvFlags::empty())` and `write` as one `sendmsg(reader, ..., SendFlags::empty())`. `sys_preadv2` and `sys_pwritev2` route `offset == -1` to the same loops. `Socket::sendmsg` and `Socket::recvmsg` take multi-segment readers and writers, so `sendmsg(2)` and `recvmsg(2)` with several iovecs do not go through this loop (signature check only).

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `datagram_writev` `writev` of `ABCD` and `EFGH` on a nonblocking `AF_UNIX` `SOCK_DGRAM` socketpair, then two `recv` calls. It passes when `writev` returns 8, the first `recv` returns the 8 bytes `ABCDEFGH`, and the second `recv` fails with `EAGAIN`. All five saved Linux executions report PASS, for example `writev=8 first datagram=8 second=-1 errno=11 first-data=4142434445464748`. Source prediction for Asterinas at `a5449e62b`, not observed: the first `recv` returns 4 bytes and the second returns the second datagram, so the case reports FAIL.

Case `datagram_readv` `send` of one 8-byte datagram, then `readv` into two 4-byte iovecs. It passes when `readv` returns 8 with `ABCD` and `EFGH` in the two iovecs. All five saved Linux executions report PASS, for example `readv=8 first=41424344 second=45464748`. Source prediction for Asterinas at `a5449e62b`, not observed: the first iovec's `recvmsg` consumes the whole datagram, so `readv` cannot return 8 bytes split across both iovecs and the case reports FAIL.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

No fix is recorded. The register notes: "Related to AST-03 splitting family; separate datagram contract, no target run". The attachment's repair direction is to hand the whole vector to the object in one operation. The source's own TODO in the vector loops proposes adding `readv`/`writev` methods to the `FileLike` trait.

No direct match in the searched scope. Reviewed and not matching: [#2230](https://github.com/asterinas/asterinas/pull/2230) (MERGED, partial writes and reads in writev/readv), [#1294](https://github.com/asterinas/asterinas/pull/1294) (MERGED, IoVec-based network API refactor), [#3347](https://github.com/asterinas/asterinas/pull/3347) (MERGED, MSG_PEEK), and [#3600](https://github.com/asterinas/asterinas/pull/3600) (MERGED, MSG_TRUNC).

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/id-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/source-check.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/inputs/asterinas_tlpi_audit_v2.zip`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json`
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/README.md`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/metadata.json`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-datagram_writev.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-datagram_readv.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The finding is static and NOT_RUN. It is related to AST-03 through the same per-iovec loop, but AST-03 concerns the shared file offset on regular files, and its reproduction does not confirm datagram behavior. The attachment does not claim that every syscall is an uninterruptible transaction. Concurrent atomicity needs a separate stress test. Stream sockets were not assessed.
