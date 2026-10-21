# Investigation — MC-6

## Scope and source identity

- Finding source: model-checking counterexample `MCVisibleReadyWinsTerminalRace`.
- Source worktree: `worktree` at `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
- The supplied worktree has pre-existing Specula changes. Neither
  `kernel/core/src/syscall/poll.rs` nor `kernel/core/src/process/signal/pause.rs`
  is modified in that worktree.

## Step 1 — code audit and reachability

- The public `poll` syscall enters `sys_poll`, converts its millisecond timeout,
  and calls `do_sys_poll` at `kernel/core/src/syscall/poll.rs:18-85`.
- `do_poll` builds `PollFiles`, registers a `Poller`, then loops at
  `kernel/core/src/syscall/poll.rs:88-121`. A successful `poller.wait()` is
  followed by `poll_files.count_events()` (`:117-120`), but the `ETIME` arm
  returns `Ok(0)` directly (`:108-114`).
- `Poller::wait` delegates to `Waiter::pause_timeout` at
  `kernel/core/src/process/signal/poll.rs:276-315`. `pause_timeout` creates the
  timeout timer, waits, then returns `ETIME` when the timer has no remaining
  duration at `kernel/core/src/process/signal/pause.rs:171-221`.
- A public `timerfd_create` constructs `TimerfdFile` and installs it in the
  file table at `kernel/core/src/syscall/timerfd_create.rs:13-30`. Its expiration
  callback increments `ticks` and notifies `POLLIN` at
  `kernel/core/src/time/timerfd.rs:92-105`. `TimerfdFile::poll` reports the
  current tick state at `:189-204`; a nonblocking `read` consumes nonzero ticks
  at `:177-186, 207-221`.

### Natural trigger scenario

1. A userspace program calls `timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK)`.
2. It arms one expiration with `timerfd_settime`.
3. It calls `poll([{ timerfd, POLLIN }], 1, 1)` while the timer and the poll
   timeout are due at the same boundary.
4. The poller has registered the timerfd observer. The timerfd callback can set
   `ticks` and notify while the timeout path is becoming terminal.
5. If `Poller::wait` returns `ETIME`, `do_poll` returns zero without the final
   `count_events()` used after a normal wake. A following nonblocking `read`
   observes whether the timerfd tick is already visible.

This uses only public timerfd, poll, read, and close operations. The initial
registration scan and the post-successful-wake rescan are relevant safeguards;
there is no analogous rescan in the terminal `ETIME` branch. Timerfd readiness
persists in `ticks` until a successful read consumes it.

## Step 2 — developer-knowledge evidence

- The nearby source comment at `kernel/core/src/syscall/poll.rs:111-113` says
  zero is appropriate when the timeout expires before any descriptor is ready.
  It does not describe a terminal rescan or arbitration rule.
- Blame attributes the direct `ETIME -> Ok(0)` arm to `8187fa2f1b` (Ruihan Li,
  2025-02-13). The subsequent successful-wake `count_events` logic is present
  separately at `:117-120`.
- Merged PR [#1831](https://github.com/asterinas/asterinas/pull/1831), “Fix
  timeout mechanism in `wait_events`”, changed `Poller::wait` and this timeout
  arm in 2025. Its stated scope is timeout accounting and signal interruption;
  its `kernel/src/syscall/poll.rs` patch still makes the `ETIME` arm return zero
  directly. It contains no timerfd readiness-at-timeout report.
- No upstream in-tree regression was found that asserts that a zero `poll`
  result is not followed by an immediately successful timerfd read at the
  deadline. The pre-existing isolated Specula test in this worktree is not an
  upstream developer test and is not treated as developer-intent evidence.

## Challenger addendum — model mapping and consequence

The six-state counterexample is not accepted verbatim as a source-level
schedule. It places `TimerfdExpired` in state 3 and leaves `notified = {}`
through the terminal state, while the implementation executes
`ticks.fetch_add` followed immediately by `pollee.notify` in one timer
callback at `kernel/core/src/time/timerfd.rs:102-105`. The delayed-model-notify
transition therefore cannot by itself establish reachability.

The concrete implementation still admits the relevant arbitration:

- `Pollee::notify` wakes the registered poller at
  `kernel/core/src/process/signal/poll.rs:167-178,318-321`.
- `Waker::wake_up` retains one `has_woken` bit and unparks the task at
  `ostd/src/sync/wait.rs:262-268`. A ready wake can make the task runnable
  without requiring it to execute before the timeout callback.
- After `self.wait()`, `pause_timeout` chooses `ETIME` solely from the
  timeout timer at `kernel/core/src/process/signal/pause.rs:202-208`.
  `do_poll` then returns zero at
  `kernel/core/src/syscall/poll.rs:108-114`, rather than using its normal
  post-wake `count_events()` scan at `:117-120`.

The initial scan is an effective ordering guard: `register_poller` calls
`file.poll(..., Some(...))` and immediately returns `FoundEvents` when it
sees readiness at `kernel/core/src/syscall/poll.rs:165-185`. Thus a
non-consuming helper can arm the timer only after the target has entered its
registered sleep; it cannot manufacture a tick that was already present at
initial registration.

The target's `/proc/<pid>/task/<tid>/status` reports `S (sleeping)` only
when the signalled waker is installed and the task has no CPU:
`kernel/core/src/fs/fs_impls/procfs/pid/task/status.rs:104-115` and
`kernel/core/src/process/posix_thread/mod.rs:235-245`. `pause_timeout`
clears that waker immediately after `self.wait()` at
`kernel/core/src/process/signal/pause.rs:195-197`. A ready observation
coincident with this state is therefore before the caller can receive the
terminal `poll` result.

There is no downstream mask. The terminal zero has already selected the
caller's timeout path; the timerfd tick remains level-readable until a caller
consumes it, as shown by `TimerfdFile::try_read` and
`check_io_events` at `kernel/core/src/time/timerfd.rs:177-204`. The local
comment on the zero-return branch also says zero is appropriate only when the
timeout precedes descriptor readiness. This is a caller-visible contract
violation, not a transient internal state.

## Step 3 — known-status and precedent

The issue-tracker search covered both open and closed issues and PRs, including
recently merged PRs:

- `timerfd` — open and closed, with PRs included;
- `"poll timeout"` — open and closed, with PRs included;
- `"poller.wait"` — open and closed, with PRs included;
- `ETIME poll` — open and closed, with PRs included;
- `"do_poll"` and `"PollFiles"` — open and closed, with PRs included.

The closest result was merged PR [#1831](https://github.com/asterinas/asterinas/pull/1831), above. It is not a report of timerfd readiness becoming visible while `do_poll` returns zero, and it did not add a terminal event rescan. The other `timerfd` and `poll` hits concerned syscall support, invalid FDs, `EINTR` writeback, or unrelated ownership. No open, closed, or merged tracker item reported this mechanism at this site. The Phase-1 novelty record is therefore `NEW` unless Phase 2 uncovers contrary evidence.
