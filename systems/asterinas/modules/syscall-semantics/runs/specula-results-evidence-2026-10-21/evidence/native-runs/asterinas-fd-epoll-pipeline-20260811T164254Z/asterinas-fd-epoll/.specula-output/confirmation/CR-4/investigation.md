# CR-4 investigation

## Scope and provenance

- Finding: `CR-4`, code-review source, Scenario 4.
- Checked worktree: `worktree` at `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
- The worktree has pre-existing Specula instrumentation. Its only diff in
  `kernel/core/src/syscall/signalfd.rs` is trace recording in
  `update_existing_signalfd` (lines 112-114); the cited poll/read path is
  unchanged from `HEAD`.
- This investigation did not open `bug-report.md`, a Specula finding, a
  counterexample, or the shared repair-request queue.

## Step 1: code audit

### Cited sites

- `kernel/core/src/syscall/signalfd.rs:207-216` obtains `current_thread()`,
  registers the supplied poller through that thread's
  `register_signalfd_poller`, then tests that same thread's pending set.
- `kernel/core/src/syscall/signalfd.rs:221-245` obtains `current_thread()`
  again for `read`; `try_read` dequeues from the caller's signal context at
  lines 183-204.
- `kernel/core/src/process/posix_thread/mod.rs:266-271` registers a signalfd
  poller with the selected thread's `sig_queues` and the selected thread's
  process-wide `sig_queues`.
- `kernel/core/src/process/signal/sig_queues.rs:38-45` notifies the
  `signalfd_pollee` belonging to the queue into which a signal was enqueued.
- `kernel/core/src/process/signal/pending.rs:103-127` makes a reader see and
  dequeue its own thread queue first, then the process queue.

### Public call chain and reachability

1. A process blocks `SIGUSR1`, creates `signalfd(-1, &mask, SFD_NONBLOCK)`,
   creates an epoll FD, and calls `epoll_ctl(EPOLL_CTL_ADD, signalfd)`.
   `sys_epoll_ctl` dispatches to `EpollFile::control` at
   `kernel/core/src/syscall/epoll.rs:51-95`.
2. `EpollFile::add_interest` creates and updates an entry at
   `kernel/core/src/events/epoll/file.rs:116-161`. `Entry::update` enables
   its observer and invokes `file.poll(..., Some(&mut poller))` at
   `kernel/core/src/events/epoll/entry.rs:152-166`. For a `SignalFile`, this
   is the registration thread identified above.
3. A second pthread invokes `epoll_wait` and later `read(signalfd)`. The
   epoll wait path calls `entry.poll()` only after it pops a ready observer
   (`events/epoll/file.rs:244-279`); `Entry::poll` then checks the file with
   the thread executing that wait (`events/epoll/entry.rs:116-149`).
4. `pthread_kill` is a normal libc interface for a thread-directed signal.
   At the kernel boundary, Asterinas's `sys_tgkill` reaches
   `process::tgkill` (`kernel/core/src/syscall/tgkill.rs:20-48` and
   `kernel/core/src/process/kill.rs:83-119`), which calls
   `target_posix_thread.enqueue_signal`. The target's own `SigQueues` is
   therefore the queue that emits the notification.

### Concrete Level-0 trigger scenario

1. Registration thread A creates the nonblocking signalfd and adds it to an
   epoll instance while no `SIGUSR1` is pending.
2. Waiter thread B exists, inherits the blocked mask, and blocks on a pipe
   used only to order the test.
3. A calls `pthread_kill(B, SIGUSR1)` while B is blocked. The test does not
   release B until this call returns, so the signal is pending before B calls
   `epoll_wait`.
4. B calls `epoll_wait` and then directly reads the shared signalfd.

This sequence uses ordinary pthread, signal, signalfd, epoll, pipe, and read
interfaces. It contains no injected kernel state, mock peer, failpoint, sleep,
or source modification.

### Safeguards to test

- The registration thread's process queue observer covers process-directed
  signals. The level-0 test instead directs the signal to B specifically.
- When an observer has already made an entry ready, the `epoll_wait` path
  re-polls from B and can therefore check B's pending set. The test checks
  whether the directed signal causes that observer wakeup in the first place.
- A direct `read` from B independently checks whether the pending signal is
  visible to the intended thread.

### Linux-visible contract used for comparison

- The Linux `signalfd(2)` manual says that a multithreaded reader receives
  signals directed to itself and process-directed signals, and that the FD is
  usable with epoll. It also states that an FD is readable when a matching
  signal is pending. See <https://man7.org/linux/man-pages/man2/signalfd.2.html>.
- Linux's `signalfd_poll` registers against the calling thread group's
  `sighand->signalfd_wqh` and checks the current thread's pending plus shared
  pending queues. See <https://github.com/torvalds/linux/blob/master/fs/signalfd.c>.

## Step 2: developer-knowledge search

- `git blame -L 207,215 kernel/core/src/syscall/signalfd.rs` attributes the
  current-thread lookup to commit `166d56d8ed` and poller registration to
  `6e8dac0c36`; it contains no rationale for cross-thread epoll delivery.
- `git log --all -- kernel/core/src/syscall/signalfd.rs` found the site’s
  original implementation, the assembler refactor, and no thread/epoll fix.
- `git log --all -i --grep='signalfd\\|epoll.*signal\\|signal.*epoll'` found
  signalfd feature, mask, coverage, and signature-cleanup commits. Symbol
  history for `register_signalfd_poller` found only the assembler refactor.
- Upstream PR #1837 describes signalfd integration with poll/epoll event loops
  and dynamically registered thread observers:
  <https://github.com/asterinas/asterinas/pull/1837>.
- PR #2245 changes the signalfd mask, and PR #3656 only changes mask method
  signatures/comments: <https://github.com/asterinas/asterinas/pull/2245> and
  <https://github.com/asterinas/asterinas/pull/3656>.

## Step 3: known-status and precedent search

The following upstream issue/PR searches were run on 2026-08-13, including
closed and recently merged pull requests:

- `repo:asterinas/asterinas signalfd`
- `repo:asterinas/asterinas "register_signalfd_poller"`
- `repo:asterinas/asterinas signalfd thread epoll`

The first returned the feature/mask/cleanup PRs above; the latter two returned
no report describing registration by one thread, a directed signal to another
thread, and a missed signalfd epoll wakeup at this site. Local all-history
searches likewise found no such report. No prior Specula dataset was consulted,
per scope restriction. This completes the tracker/history pre-filter; Phase 2
continues with a `NEW` candidate unless reproduction changes the final route.
