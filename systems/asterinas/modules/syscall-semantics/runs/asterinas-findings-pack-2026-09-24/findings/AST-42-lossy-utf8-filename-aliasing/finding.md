# AST-42: Lossy UTF-8 conversion aliases distinct filename byte strings

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 attachment `asterinas_tlpi_audit_v2.zip` (archive SHA-256 `0c70d01cb9b8120e...`, no native run ID), finding F01, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `openat`, `open`, `creat` |
| Upstream | direct (dedup `EXACT_MATCH`, upstream main `bc12195df`): [#1097](https://github.com/asterinas/asterinas/issues/1097) |
| Fix | unfixed |
| Reproducer | NOT_RUN (`repro/` holds the TLPI-v2 probe, cases `path_bytes`, Linux evidence only) |

## Summary

`openat` converts the user pathname with `to_string_lossy`, so every invalid UTF-8 byte becomes U+FFFD before path lookup. Two names that differ only in invalid bytes, such as `f\x80` and `f\x81`, are predicted to name the same file. Any process that creates or opens files with non-UTF-8 names can observe the aliasing.

## Linux contract

[pathname(7)](https://man7.org/linux/man-pages/man7/pathname.7.html) describes a filename as a sequence of bytes. Every byte except `/` and NUL is allowed, and the kernel does not require or enforce an encoding. Linux therefore creates `f\x80` and `f\x81` as two files.

## Asterinas behavior

Source sites are at pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.

`kernel/core/src/syscall/open.rs::sys_openat` reads the path with `read_cstring`, calls `path.to_string_lossy()`, and passes the result to `FsPath::from_fd_at`. `sys_open` and `sys_creat` delegate to `sys_openat`, so they share the conversion. At the pin, 29 files under `kernel/core/src/syscall/` call `to_string_lossy` (a grep count made for this package). The attachment asserts only the openat path, and the other files were not reviewed.

## Reproduction

`repro/` holds the attachment's probe harness, copied without changes. It has not run on Asterinas. Only Linux evidence was saved, from the attachment's earlier static ELF, which is not in the archive.

Case `path_bytes` creates `f\x80` and `f\x81` with `O_WRONLY|O_CREAT|O_EXCL` in a fresh directory under `$TMPDIR`. It passes when both `openat` calls return a descriptor. All five saved Linux executions report PASS, for example `distinct byte names: first=4 errno=0 second=5 errno=0`. Source prediction for Asterinas at `a5449e62b`, not observed: the second `openat` fails because both names convert to the same string, so the case prints a negative `second` value and reports FAIL.

See `repro/README.md` for build and guest instructions.

## Fix and upstream status

No local or upstream fix is recorded. The register says: "Direct open issue #1097 already reports lossy filename aliasing; imported test remains NOT_RUN." The attachment's repair direction is to resolve paths and store inode names as byte strings and to use lossy conversion only for logging.

Direct: [#1097](https://github.com/asterinas/asterinas/issues/1097) (OPEN), "File and directory names shouldn't be assumed as valid UTF-8 strings". [#3335](https://github.com/asterinas/asterinas/issues/3335) was checked and excluded because it is a netlink interface-name panic.

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
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-path_bytes.log`

The other four saved Linux logs per case (overlayfs 002 and 003, tmpfs 001, shell-import 001) are listed in `meta.json`.

## Caveats

The finding is static. The attachment records it as "source_supported; runtime confirmation on Asterinas outstanding". It asserts only the reviewed openat path and does not claim that every filesystem or string interface was traversed. The upstream issue #1097 covers the broader byte-string naming problem.
