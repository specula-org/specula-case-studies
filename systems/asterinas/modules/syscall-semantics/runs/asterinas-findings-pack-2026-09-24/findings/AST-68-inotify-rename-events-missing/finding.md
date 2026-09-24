# AST-68: inotify accepts move subscriptions without matching rename notifications

| Field | Value |
|---|---|
| Evidence status | SOURCE LEAD |
| Origin | TLPI-v2 `asterinas_tlpi_audit_v2.zip` (no native run ID), finding F24, Asterinas pin `a5449e62b0a5a0affccb6087ea3543a2fdf66052` |
| Also seen in | none |
| Syscalls | `inotify_add_watch`, `rename`, `renameat`, `renameat2`, `read` on the inotify FD |
| Upstream | No direct match in the searched scope (search of 2026-09-14 against upstream main `bc12195df`). Reviewed related items: [#2083](https://github.com/asterinas/asterinas/pull/2083), [#2654](https://github.com/asterinas/asterinas/pull/2654), [#2838](https://github.com/asterinas/asterinas/pull/2838), [#2859](https://github.com/asterinas/asterinas/pull/2859) (inotify framework, SCML, improvements, ONESHOT, all merged) and [#2844](https://github.com/asterinas/asterinas/issues/2844) (closed). None adds rename events or cookies. |
| Fix | Unfixed. No local or upstream fix recorded. |
| Reproducer | `repro/` (case `inotify_rename_cookie`, control `inotify_control_only`, NOT_RUN on Asterinas, saved Linux PASS, planned SMP=2) |

## Summary

`inotify_add_watch` accepts IN_MOVED_FROM and IN_MOVED_TO, but a rename
inside the watched directory produces no event, and the event queue has no
way to carry a nonzero cookie. File watchers such as build tools, editors
and sync daemons miss renames entirely while their watch registration
appears to succeed.

## Linux contract

[inotify(7)](https://man7.org/linux/man-pages/man7/inotify.7.html): a rename
generates IN_MOVED_FROM for the directory holding the old name and
IN_MOVED_TO for the directory holding the new name. The `cookie` field links
the pair and is currently used only for rename events. All five saved
Linux 6.18 executions saw one event of each kind with equal nonzero cookies.
The cookie value differed per run (196, 200, 198, 201 and 203).

## Asterinas behavior

At the pin, `kernel/core/src/syscall/inotify.rs::parse_inotify_watch_request`
accepts the move bits as part of `InotifyEvents`. The rename path,
`kernel/core/src/syscall/rename.rs::sys_renameat2` to `Path::rename` to
`kernel/core/src/fs/vfs/path/dentry.rs::DirDentry::rename`, never calls into
`fs::vfs::notify`, so no fsnotify event is emitted.
`kernel/core/src/fs/vfs/notify/inotify.rs::InotifyFile::receive_event` builds
every event with `InotifyEvent::new(wd, event, 0, name)`, so even a future
move event would carry cookie 0. The project's syscall-flag-coverage page at
the pin (`book/src/kernel/linux-compatibility/syscall-flag-coverage/file-systems-and-mount-control/README.md`)
lists IN_MOVED_FROM, IN_MOVED_TO and IN_MOVE_SELF as not generated.

## Reproduction

`repro/` holds the TLPI-v2 harness and its README. Case
`inotify_rename_cookie` creates a file in a fresh directory, watches the
directory for IN_MOVED_FROM | IN_MOVED_TO, renames the file inside it, polls
for 300 ms and parses the events. The saved Linux output is
`DETAIL cookie_from=196 cookie_to=196` and
`OBS {"ready":1,"from_count":1,"to_count":1,"cookies_nonzero_equal":true,"errno":0}`
(PASS). The negative control `inotify_control_only` checks that a mask of
IN_ONLYDIR alone is accepted, and Linux printed
`OBS {"accepted":true,"errno":0}`. By source reading, Asterinas at the pin
would report no ready event and zero counts and FAIL. The cases have not run
on Asterinas.

## Fix and upstream status

No fix exists. The repair direction recorded by TLPI-v2 is to emit rename
notifications with a shared cookie, then cover cross-directory moves, moves
of the watched object itself and overwritten targets. The cited files are
byte-identical at upstream `bc12195df` (the pin's direct child), checked on
2026-09-24 with a read-only `git diff`. Later upstream commits were not
checked.

## Evidence

- `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/README.md` (register row AST-68)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/finding-map.md` (F24)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` (batches `files_abi` and `controls`)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/findings.json` (F24)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/REPORT.md` (section F24)
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/001-inotify_rename_cookie.log`
- `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/oracle-development/README.md` (earlier wrong IN_ONLYDIR oracle, now the control)
- `/home/chin39/Documents/play/specula-profile/reports/upstream-dedup-2026-09-14/matches.json` (AST-68)

## Caveats

- This is a source-level prediction. No TLPI-v2 case has run on Asterinas,
  and the Linux logs come from the attachment author's build.
- The project documents move events as unsupported, so upstream may treat
  this as a known capability gap rather than an implementation bug. The
  register keeps SOURCE LEAD because the watch request is accepted silently.
- The most direct prediction is missing events. Do not record a measured
  cookie of 0, because no Asterinas cookie value has been observed.
- The IN_ONLYDIR control records a withdrawn hypothesis. It is not a finding.
