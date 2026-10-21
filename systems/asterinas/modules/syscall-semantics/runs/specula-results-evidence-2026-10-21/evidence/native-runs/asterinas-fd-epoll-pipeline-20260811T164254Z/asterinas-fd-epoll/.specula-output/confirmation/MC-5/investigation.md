# Investigation — MC-5

## Code audit

- Counterexample: temporal property `MCRegisteredTransitionNotLost`, 8 states, `spec/output/MC_hunt_s4_mask_transition_round2_bfs.out`.
- Normal call chain: `signalfd` update → `update_existing_signalfd` → `SignalFile::update_signal_mask`; epoll registration → `SignalFile::poll` → `PosixThread::register_signalfd_poller`.
- The update syscall invokes only the mask update and nonblocking update at `kernel/core/src/syscall/signalfd.rs:103-119`.
- `update_signal_mask` is a relaxed atomic store at `signalfd.rs:157-163`.
- `SignalFile::poll` registers the poller with signal queues at `signalfd.rs:207-216`; the thread helper registers both thread and process queues at `kernel/core/src/process/posix_thread/mod.rs:266-270`.
- The public trigger blocks `SIGUSR1`, queues it under an empty signalfd mask, adds the signalfd to epoll, then updates the signalfd mask to include `SIGUSR1`.

## Developer-knowledge search

- PR #1837 describes signalfd as suitable for poll/epoll integration and says it supports create/update, but it contains no mask-transition wakeup contract.
- Existing `test/initramfs/src/regression/process/signal/signal_fd.c` covers delivery and polling of preconfigured masks, not a pending signal that becomes eligible through a mask update.

## Known-status and precedent

- Searched all open and closed tracker items with `repo:asterinas/asterinas signalfd epoll`.
- PR #1837 is an implementation feature PR, not a report of a missed readiness notification on update. No issue, PR, advisory, or prior Specula entry found for the same update path.

## Additional Phase-1 evidence (2026-08-13)

### Code audit and reachability

- The x86 syscall table routes public `signalfd4(2)` to `sys_signalfd4` at
  `kernel/core/src/syscall/arch/x86.rs:399`; an existing descriptor selects
  `update_existing_signalfd` at `kernel/core/src/syscall/signalfd.rs:78-82`.
- The update obtains the existing `SignalFile`, calls
  `update_signal_mask(new_mask)`, and changes nonblocking mode at
  `kernel/core/src/syscall/signalfd.rs:103-119`. The mask helper is only a
  relaxed store at `signalfd.rs:161-163`.
- A signalfd epoll entry registers its `PollHandle` with the thread and
  process signal queues at `signalfd.rs:207-217` and
  `kernel/core/src/process/posix_thread/mod.rs:266-271`.
- Signal enqueue is the queue transition that invokes
  `signalfd_pollee.notify(IoEvents::IN)` at
  `kernel/core/src/process/signal/sig_queues.rs:38-45`. There is no analogous
  notification in the mask-update path.
- The epoll entry is removed from the ready list when polling under the empty
  mask finds no events (`kernel/core/src/events/epoll/entry.rs:116-149`). A
  later `EpollFile::wait` waits on that ready list instead of rescanning every
  interest entry (`kernel/core/src/events/epoll/file.rs:225-241`).
- Normal public-API sequence: block `SIGUSR1`; create a nonblocking signalfd
  with an empty mask; add it to epoll; `kill(getpid(), SIGUSR1)`; consume the
  resulting non-ready epoll entry with `epoll_wait(..., 0)`; update the same
  signalfd mask to include `SIGUSR1`; then call blocking `epoll_wait`.
  No injected state, private call, source change, or timing control is needed.

### Developer-knowledge evidence

- [PR #3655](https://github.com/asterinas/asterinas/pull/3655), merged
  2026-07-28, says it is an interface-encapsulation improvement and does not
  change signalfd behavior or atomic ordering.
- [PR #3656](https://github.com/asterinas/asterinas/pull/3656), merged
  2026-07-28, removes an equality check and makes `update_signal_mask`
  infallible. Its patch still performs only the store; it describes cleanups,
  not a readiness-notification defect.
- [PR #2245](https://github.com/asterinas/asterinas/pull/2245), merged
  2025-07-08, fixes an inverted filter in the former signal-observer path.
  It is a different mechanism from a pending signal becoming eligible after a
  mask update.

### Known-status / precedent search

- Queried GitHub's issue tracker, including closed and merged PRs, on
  2026-08-13: `repo:asterinas/asterinas signalfd`,
  `repo:asterinas/asterinas signalfd epoll`,
  `repo:asterinas/asterinas signalfd mask`, and
  `repo:asterinas/asterinas type:pr is:merged signalfd`.
- The relevant results above do not report the same missing publication after
  an existing signalfd's mask changes. This supports recording novelty as
  `NEW` after Phase 2; it is not a Phase-1 verdict.

## Agent B adversarial amendment

- The earlier Level-0 test queued the signal after `epoll_ctl(ADD)`, which
  established live harm but did not literally use the model trace's order.
  The separate `repro/test_bugMC-5_exact_counterexample.c` corrects that
  narrow gap: it queues `SIGUSR1` under the empty mask before `epoll_ctl(ADD)`,
  performs an empty-ready-set `epoll_wait(..., 0)`, then updates that same
  signalfd mask.
- This maps the counterexample's material steps: `SigQueuesEnqueueProcess`
  (state 2), epoll registration and initial empty poll (states 3--6),
  `EpollWaitRegisterConsumer` (state 7), and `SignalfdUpdateMask` (state 8)
  in `spec/output/MC_hunt_s4_mask_transition_round2_bfs.out`. The test uses
  `EPOLLIN | EPOLLET`, matching the hunt configuration's sole `ET` trigger
  mode.
- The hunt configuration enables only the ordinary signal, epoll, and mask
  actions used here; it enables no fault action, and its copy-fault, poll,
  source, timeout, interrupt, exec, and topology budgets are zero. The live
  test therefore does not stand in for an injected fault.
- The queued signal is specifically process-directed in this implementation.
  With `SIGUSR1` blocked, self-`kill` takes `kill_process` rather than the
  thread fast path (`kernel/core/src/process/kill.rs:22-35`), which calls
  `Process::enqueue_signal` (`kill.rs:148-155`) and hence the process
  `SigQueues` (`process/process/mod.rs:636-646`).
- `Entry::update` registers the epoll `PollHandle` with the signal file at
  `kernel/core/src/events/epoll/entry.rs:155-166`, and `SignalFile::poll`
  binds it to the signal queues at `signalfd.rs:207-217`. The relevant
  registration therefore exists before the update; the test does not
  synthesize it.
- The possible masking paths were checked. The existing pending signal is not
  re-enqueued on a mask update, so `SigQueues::enqueue`'s only notification at
  `sig_queues.rs:38-45` cannot fire. `EpollFile::wait` consumes the ready set
  at `events/epoll/file.rs:225-280`; it does not rescan all interests after a
  mask store.
- Linux is a behavioral control, not a substitute for the Asterinas run: its
  `do_signalfd4` updates an existing mask under `siglock` and wakes the
  signalfd wait queue (`fs/signalfd.c:274-279`). The identical public sequence
  returns `EPOLLIN` there.
