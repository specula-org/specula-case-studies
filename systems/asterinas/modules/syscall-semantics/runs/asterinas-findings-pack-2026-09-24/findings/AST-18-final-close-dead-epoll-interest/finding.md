# AST-18: Final close retains dead epoll interest metadata

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding MC-3, Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none |
| Syscalls | `close` (final close of the watched file), `epoll_ctl` (`EPOLL_CTL_ADD`), `openat`/`read` of `/proc/self/fdinfo/<epfd>` |
| Upstream | Related mechanism only (`RELATED_ONLY` against upstream main `bc12195df`): merged PR [#1277](https://github.com/asterinas/asterinas/pull/1277) introduced the `(fd, file)` key and removed the file-table close observer, and open issue [#200](https://github.com/asterinas/asterinas/issues/200) covers epoll notification across fork. Neither reports the dead interest entry. Upstream fix status: not established. |
| Fix | No fix recorded locally or upstream. Register repair column: "No numeric-FD retargeting or stale-event delivery demonstrated". |
| Reproducer | repro/ (runtime REPRODUCED at `4ba4abbe8cb3`, SMP=2) |

## Summary

After the last descriptor of a watched file is closed, Asterinas keeps that
file's entry in the epoll interest set. If the file never became ready, no code
path ever removes the entry, and `/proc/self/fdinfo/<epfd>` keeps listing a
`tfd:` line for a file that no longer exists for the life of the epoll
instance. The observed harm is stale, user-visible lifecycle metadata. The run
classified it as High, and it did not demonstrate delivery of stale events or
retargeting to a reused descriptor number.

## Linux contract

`epoll(7)` (Questions and answers, Q6) says that closing a file descriptor
removes it from all epoll interest lists once all descriptors referring to the
underlying open file description have been closed. `proc(5)` documents one
`tfd:` line per watched target in the fdinfo of an epoll descriptor. The Linux
control prints no `tfd:` line for the closed eventfd.

- https://man7.org/linux/man-pages/man7/epoll.7.html
- https://man7.org/linux/man-pages/man5/proc.5.html

## Asterinas behavior

- `kernel/core/src/events/epoll/file.rs::EpollFile::add_interest` inserts an
  `Entry` whose `kernel/core/src/events/epoll/entry.rs::EntryKey` holds the
  file only as a `KeyableWeak`. The interest set holds the `Entry` strongly.
- `kernel/core/src/syscall/close.rs::sys_close` calls
  `kernel/core/src/fs/file/file_table.rs::FileTable::close_file` and drops the
  returned `ClosedFile`. There is no epoll callback on final release.
- The only automatic removal of a dead entry is in
  `kernel/core/src/events/epoll/file.rs::EpollFile::pop_multi_ready`, when
  `Entry::poll` finds that the weak file cannot be upgraded. That runs only for
  entries on the ready list, and an entry whose file never became ready is
  never there.
- `kernel/core/src/events/epoll/file.rs::EpollFile::dump_proc_fdinfo` prints
  every entry of `interest` without filtering dead ones. The procfs reader in
  `kernel/core/src/fs/fs_impls/procfs/pid/task/fd.rs` serves it for
  `/proc/<pid>/fdinfo/<n>`.
- The weak `(fd, file)` key does prevent a reused descriptor number from
  matching the dead entry, so readiness is not delivered to the wrong file.

## Reproduction

Level 0, public API only, no kernel change: `epoll_create1`, `eventfd(0)`,
`epoll_ctl(ADD, EPOLLIN)`, confirm the `tfd:` record is present in
`/proc/self/fdinfo/<epfd>`, `close(eventfd)`, then read the fdinfo again. On
Asterinas the `tfd:` record for the closed descriptor is still present. See
`repro/README.md`.

Recorded Asterinas SMP=2 results at the pin:

- Round-6 standalone test: `SPECULA_REGRESSION_FAIL dead_interest: closed file remains in epoll interest list`.
- Stage-2 driver, round 5: the same failure at `validation_dead_interest_smp2_round5_attempt2.log`.
- Confirmation turn A ran `test_bugMC-3_dead_interest.c` as guest init. Its syscall trace shows the 58-byte `MC-3: REPRODUCED stale interest remains after final close` write.
- Linux control: `SPECULA_REGRESSION_PASS dead_interest`.

## Fix and upstream status

No local fix branch and no upstream fix are recorded. The run recommends
removing interests synchronously when the final reference of the watched file
is released, or registering a final-close cleanup hook that removes the exact
weak-file entry, while keeping the `(fd, file identity)` key so descriptor
reuse still cannot retarget a watch. The spec-generation bug report adds that
the cleanup must keep the file-table, epoll, subject, and observer lock order
explicit. During packaging on 2026-09-24 a static read of upstream main
`bc12195df` showed `dump_proc_fdinfo` still iterating the whole interest set.
No runtime retest was done there.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 3)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-3/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-3/turn02_B.last-message.txt
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-3/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_test_bug4_epoll_dead_interest_smp2_round6_attempt1.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_dead_interest_smp2_round5_attempt2.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_repro_smp2_round6_manifest.txt
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_host_round6.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s2_epoll_delivery_round2_bfs_cex.json (invariant `MCNoDeadInterest`, 7 states)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/bug-report.md
- /home/chin39/Documents/play/specula-profile/reports/independent-review/terra-asterinas-bug-report-vm-final.md (section `dead_interest`)
- /home/chin39/Documents/play/specula-profile/references/asterinas-syscall-security-audit.md (section "Historical FD/epoll full run")

## Caveats

- The register limits this entry: no numeric-FD retargeting and no stale-event
  delivery were demonstrated. The observable failure is the fdinfo membership
  and the retained `Entry` object, not wrong-object delivery.
- The stage-2 severity table listed this as Medium. The final Stage-3
  classification is High. The Stage-3 value is authoritative for the run.
- Opening the fdinfo file can reuse the closed descriptor number. The tests
  compare the `tfd:` number with the closed descriptor, and the Terra review
  notes that the stale entry prints its own recorded descriptor label, so this
  reuse does not create the observation.
- Historical evidence at pin `4ba4abbe8cb3` only. The tested kernel carried
  Specula trace instrumentation, including hooks in `sys_close` and
  `EpollFile::control`. The Terra review found no added cleanup branch.
