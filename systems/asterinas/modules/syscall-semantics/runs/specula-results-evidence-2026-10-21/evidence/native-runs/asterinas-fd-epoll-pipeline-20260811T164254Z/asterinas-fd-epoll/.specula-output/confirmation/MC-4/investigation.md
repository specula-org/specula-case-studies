# Investigation — MC-4

## Code audit

- Source under test: worktree `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`.
- Public path: `timerfd_create(2)` reaches `sys_timerfd_create` at `kernel/core/src/syscall/timerfd_create.rs:13-30`; `timerfd_settime(2)` reaches `TimerfdFile::set_time` through `sys_timerfd_settime` at `kernel/core/src/syscall/timerfd_settime.rs:18-50`; `poll(2)` reaches `PollFiles::register_poller`, which calls `file.poll` at `kernel/core/src/syscall/poll.rs:167-185`.
- On expiry, `TimerfdFile::new` increments `ticks` and calls `pollee.notify(IoEvents::IN)` at `kernel/core/src/time/timerfd.rs:102-105`. `notify` first invalidates the cache at `kernel/core/src/process/signal/poll.rs:167-188`.
- A `TimerfdFile::poll` delegates to `Pollee::poll_with` at `kernel/core/src/time/timerfd.rs:200-204`. If the cache is nonnegative, `poll_with` returns it without rechecking `ticks` at `kernel/core/src/process/signal/poll.rs:106-110`.
- A successful `read(2)` reaches `TimerfdFile::try_read`, which clears `ticks` with `fetch_and(0)` at `kernel/core/src/time/timerfd.rs:177-186`. That function has no call to `self.pollee.invalidate()`.
- `Pollee`'s documented contract requires `invalidate` when an old event disappears without a new event at `kernel/core/src/process/signal/poll.rs:25-29`.
- Reachable trigger candidate: create a `TFD_NONBLOCK` one-shot timerfd; arm it; call `poll(..., 1000)` until it reports `POLLIN` (which caches `IN`); successfully read the eight-byte expiry count; then call `poll(..., 0)` and attempt another nonblocking read. This uses only public timerfd, poll, and read syscalls.
- The consumer that can observe the returned readiness is `PollFiles::register_poller` at `kernel/core/src/syscall/poll.rs:172`; it maps the `TimerfdFile::poll` result to the application-visible `pollfd.revents` at lines 177-182. No read-side cache clearing or caller-side guard appears on that path.
- No downstream synchronizer, resend, loopback, or guard was found in this path. A later timer expiry would call `notify` and invalidate the cache, but an unarmed one-shot timer has no such later event.

## Developer-knowledge search

- `git blame` attributes the timerfd expiry notification and original `try_read` shape to `1775bb0861` ("Support for timerfd-related syscalls") and the counter reset to `7305d389f0` ("Refactor the timer module to solve race conditions and support fdinfo for timerfd files"). Neither commit message gives an exception to the Pollee invalidation contract.
- The only nearby developer guidance is the Pollee contract above. There is no timerfd-site TODO, FIXME, design note, or test asserting that consumed timerfd readiness remains cached.
- Current upstream `main` was checked at `76dac6f5524fe9477ce0df9535ba837cc853e32e` (2026-08-06). Its `kernel/core/src/time/timerfd.rs:177-186` has the same reset without invalidation, so this source state was not superseded by a later cache-clear change.
- Linux's documented contract says a timerfd is readable when one or more expirations have occurred and that a successful read reports expirations since the last successful read: <https://man7.org/linux/man-pages/man2/timerfd_create.2.html>.

## Known-status and precedent

- Searched the Asterinas tracker in all states, including closed and merged PRs, with `timerfd`, `"timerfd" "poll"`, `"timerfd" "readiness"`, `Pollee`, `"stale readiness"`, closed timerfd PRs, and closed `poll`/`invalidate` PRs. No returned issue or PR reports timerfd readiness cached after a successful read.
- Reviewed the relevant closed precedent, [PR #2177](https://github.com/asterinas/asterinas/pull/2177) ("Fix some missing or redundant pollee invalidation"). It adds invalidations for channel and socket paths only; its file list does not include timerfd.
- Reviewed timerfd-affecting [PR #3577](https://github.com/asterinas/asterinas/pull/3577), [PR #2144](https://github.com/asterinas/asterinas/pull/2144), and [PR #2037](https://github.com/asterinas/asterinas/pull/2037). Their tracker descriptions concern `FileCommon`, invalid flag handling, and timerfd introduction respectively, not post-read readiness caching.
- This record contains no Phase-1 verdict. Phase 2 must execute the public-API sequence and decide the final status.

## Agent B supplement — Phase 1 evidence only

- The challenger checked the cited source paths at worktree commit `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`; `git diff --quiet` for `timerfd.rs`, `poll.rs`, and syscall `poll.rs` returned clean. No source patch was used for the investigation.
- The minimized model trace in `spec/output/MC_hunt_s3_cache_round2_bfs.out` reaches: timer poll registration (state 2), expiration/notification (states 3–5), cache fill (states 6–7), successful timerfd read (state 8), then cached poll return (state 9). `MCCachedReadinessSound` is the violated invariant at line 34.
- The model transition `MCTimerfdTryRead` in `spec/base.tla:2096-2110` resets the timer source state while leaving the cache state unchanged. `PolleePollWithCached` returns that loaded cache without a source check. This is the same ordering as `TimerfdFile::try_read` at `timerfd.rs:177-186` and `Pollee::poll_with` at `process/signal/poll.rs:106-110`.
- The public caller path has no post-poll recheck: `PollFiles::register_poller` converts `file.poll` events directly into `pollfd.revents` in `syscall/poll.rs:165-185`. `Pollable::wait_events` documents a spurious `EAGAIN` only when another thread consumes an event; the candidate sequence has one reader and no later producer.
- The challenger independently checked the upstream main tip `76dac6f5524fe9477ce0df9535ba837cc853e32e`; its timerfd read path still lacks an invalidation. Targeted tracker searches found no prior timerfd stale-readiness report. Closed PR #2177 documents the general missing-invalidation class but changes channel/socket files, not timerfd.
