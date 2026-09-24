# AST-21: poll times out after timerfd becomes readable

| Field | Value |
|---|---|
| Evidence status | REPRODUCED |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, finding MC-6, Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none. The independent Terra review of the Stage-2 evidence classified the same scenario (`poll_timeout_race`) as "ambiguous / requires investigation" before the final ordered witness existed. |
| Syscalls | `poll` (reproduced with a timerfd). `ppoll`, `select`, and `pselect6` reach the same `do_poll` timeout arm (source only). |
| Upstream | No direct match in searched scope (`NO_DIRECT_MATCH` against upstream main `bc12195df`). Reviewed: merged PR [#1049](https://github.com/asterinas/asterinas/pull/1049) (ignore timeout error in `epoll_wait`) and merged PR [#1831](https://github.com/asterinas/asterinas/pull/1831) (timeout accounting in `wait_events`), which kept the direct `ETIME` return. Upstream fix status: not established. |
| Fix | No fix recorded locally or upstream. Register repair column: "Final ordering evidence retained with earlier independent-review uncertainty". |
| Reproducer | repro/ (runtime REPRODUCED at `4ba4abbe8cb3`, SMP=2) |

## Summary

When a `poll` wait ends by timeout, Asterinas returns 0 immediately and skips
the final readiness scan that it performs after every other wakeup. If a
watched timerfd expired and notified the poller while the waiter was being
woken, `poll` still reports a timeout, and the very next nonblocking `read`
returns a full expiration count. The caller receives an irrevocably wrong
terminal result, although the tick remains for a later retry. The run
classified it as High.

## Linux contract

`poll(2)` says a return value of 0 means the call timed out before any file
descriptor became ready. Linux `do_poll` (`fs/select.c`) performs a final
descriptor scan after its timed wait before it accepts the timeout. The Linux
control never produced a zero `poll` result followed by an immediately readable
tick: 20000 attempts of the boundary test, and 1000 attempts of the ordered
probe that saw 190 ready-while-sleeping cases.

- https://man7.org/linux/man-pages/man2/poll.2.html
- https://man7.org/linux/man-pages/man2/timerfd_create.2.html

## Asterinas behavior

- `kernel/core/src/syscall/poll.rs::do_poll` registers a `Poller`, loops on
  `Poller::wait()`, and on `Err(ETIME)` returns `Ok(0)` directly. Only the
  `Ok(())` arm reaches `PollFiles::count_events`.
- `kernel/core/src/process/signal/poll.rs::Poller::wait` delegates to
  `kernel/core/src/process/signal/pause.rs::Waiter::pause_timeout`, which after
  waking chooses `ETIME` solely because the timeout timer has expired.
- `kernel/core/src/time/timerfd.rs::TimerfdFile::new` increments `ticks` and
  calls `Pollee::notify(IN)` in the same expiry callback, so readiness can be
  published and the waiter woken before the timeout decision is made.
- The nearby source comment says zero is correct only when the timeout expires
  before any descriptor is ready.

## Reproduction

Level 0, public API only, no kernel change. The simple boundary test creates a
nonblocking timerfd, arms it for 1 ms, calls `poll(POLLIN, 1 ms)`, and when
`poll` returns 0 tries an immediate nonblocking `read`. A successful read after
a zero return counts as a failure. The canonical ordered probe adds a helper
thread that watches `/proc/<pid>/task/<tid>/status` and arms the timerfd for
the last 0.5 ms of a 5 ms poll only after the poller is seen in `S (sleeping)`.
It accepts a failure only if the helper observed `POLLIN` while the poller was
still asleep. See `repro/README.md`.

Recorded Asterinas SMP=2 results at the pin:

- Stage-2 boundary test: 1/2000 (round 5), then 5/2000, 2/2000, 2/2000 (round-6 repeats) and 4/2000 (round-6 standalone), each a zero `poll` followed by a readable tick.
- Turn A (20000-attempt variant): `MC6_REPRODUCED attempt=0 poll_result=0 revents=0x0 ticks=1`.
- Challenger timestamp-ordered probe: `MC6B_STRICT_REPRO attempt=1 poll_result=0 ticks=1 ready_lead_ns=1912976`.
- Challenger `/proc`-ordered probe (canonical): `MC6B_PROC_STRICT_REPRO attempt=0 poll_result=0 ticks=1 ready_lead_ns=-67233`. The run treats the sleep-state check, not the timestamp, as the ordering oracle.
- Linux: `MC6_NO_REPRO attempts=20000` and `MC6B_PROC_NO_STRICT_REPRO attempts=1000 ... ready_while_sleeping=190 boundary_only=0`.

## Fix and upstream status

No local fix branch and no upstream fix are recorded. The run recommends that
`do_poll` rescan `poll_files` once on `ETIME` and return the event count if it
is nonzero, returning 0 only if the rescan is empty, while keeping non-timeout
error handling. AST-23 has the same shape on the epoll path and on the
mask-taking waits, so a fix should cover both. During packaging on 2026-09-24 a
static read of upstream main `bc12195df` showed the same direct
`Err(ETIME) => return Ok(0)` arm in `do_poll`. No runtime retest was done
there.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmed-bugs.md (Entry 6)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/investigation.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/reproduction.md
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/verdict.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/turn02_B.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/repro/mc6-level0-smp2-pinned-toolchain.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/repro/mc6b-level0-ordered-smp2-retry.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-6/repro/mc6-linux-control.log
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_poll_timeout_race_smp2_repeat_manifest.txt
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/validation_repro_smp2_round6_manifest.txt
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/harness/logs/repro_test_bug6_poll_timeout_race_smp2_level3_print.log (observation-only Level-3 ordering run, excluded by the Terra review)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s5_arbitration_round2_bfs_cex.json (invariant `MCVisibleReadyWinsTerminalRace`, 6 states)
- /home/chin39/Documents/play/specula-profile/reports/independent-review/terra-asterinas-bug-report-vm-final.md (section "Not promoted: poll_timeout_race")
- /home/chin39/Documents/play/specula-profile/reports/workflow-validation.md (Stage 2 recovery, "MC-6 causality")

## Caveats

- Sources disagree on the strength of the evidence, and the register keeps
  both. The independent Terra review (evidence cutoff 2026-08-13 01:20) held
  this scenario as "ambiguous / requires investigation", because a successful
  read after a zero `poll` proves readiness at the read, not at the timeout
  decision. The main agent's Level-3 observation-only run and the later
  confirmation-phase ordered probes were used to resolve that gap. The Terra
  review explicitly excluded the Level-3 run: it was after the cutoff, used
  temporarily modified `poll.rs`, `timerfd.rs`, and test sources, and kept no
  input hash or source snapshot.
- The canonical `MC6B_PROC_STRICT_REPRO` marker is recorded only in
  `confirmation/MC-6/reproduction.md` and the challenger turn log. The retained
  `mc6b-proc-*` guest logs do not contain it, and one of them ends with the
  unrelated standalone `SPECULA_REGRESSION_PASS poll_timeout_race`, because
  OSDK reused a bundle when only the initramfs input changed. The challenger
  excluded such replays after checking the embedded binary.
- The model counterexample separates expiry and notify, which the source does
  in one callback. The challenger did not accept the trace verbatim and relied
  on the live path instead.
- The failure is a rare timing boundary (a few per 2000 attempts in the boundary
  test). All recorded Asterinas runs used `SMP=2`. `SMP=1` was not tried for
  this entry.
- AST-23 is related (same timeout-arbitration class) but has a distinct wait
  path and witness.
