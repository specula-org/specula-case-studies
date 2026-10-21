# Investigation — MC-1

## Code audit

- Finding input: real model-checking counterexample for `MCDeliveryCommitOnCopyout` in `spec/output/MC_hunt_s2_copyout_round2_bfs.out` (the supplied candidate describes a nine-state trace). The counterexample file itself was not opened, per the task boundary.
- Public call chain: `epoll_wait(2)` reaches `sys_epoll_wait` at `kernel/core/src/syscall/epoll.rs:157-178`, then `do_epoll_pwait2` at `:98-155`, which calls `EpollFile::wait` at `:129`. `EpollFile::wait` calls `pop_multi_ready` at `kernel/core/src/events/epoll/file.rs:225-242`.
- `ReadySetPopIter::next` removes a ready entry and resets its ready bit at `kernel/core/src/events/epoll/entry.rs:372-397`. `pop_multi_ready` obtains that entry at `file.rs:244-257`, appends its event at `:270-273`, and requeues it only when `is_still_ready` is true at `:275-278`.
- `Entry::poll` makes `is_still_ready` false for an edge-triggered entry at `kernel/core/src/events/epoll/entry.rs:136-149`. Thus the selected `EPOLLET` entry is absent from the ready set before `do_epoll_pwait2` attempts its first `user_space.write_val` at `kernel/core/src/syscall/epoll.rs:145-152`.
- A failing `write_val` propagates through `?` at `epoll.rs:150`; there is no recovery path between that copyout and the caller. The ordinary, reachable sequence is: `eventfd(0, EFD_NONBLOCK)`, `epoll_create1`, `epoll_ctl(EPOLL_CTL_ADD, EPOLLIN | EPOLLET)`, `write(eventfd, 1)`, `epoll_wait` with an inaccessible event array, then `epoll_wait` with a valid event array. No state injection or source modification is required.
- The eventfd counter remains unread across both waits. An ET registration has no new transition to repopulate the ready set after the failed copyout, so the second waiter is the real public caller that can observe a zero return instead of the pending `EPOLLIN` event.
- No downstream resend, loopback, synchronization, or caller guard was found in this path. `ReadySet::push` is driven by a later observer notification (`entry.rs:280-331`), which this sequence does not produce.

## Developer-knowledge search

- `git blame` attributes the copyout loop at `kernel/core/src/syscall/epoll.rs:145-151` to `0b471ef370` (`Add sys_epoll_pwait2`) and the dequeue/requeue logic at `kernel/core/src/events/epoll/file.rs:244-279` to `83b6c03bd8` (`Split epoll_file.rs`). Neither commit message nor nearby source commentary describes preserving a selected ET event after an output-copy fault.
- Local history searches for `write_val(write_addr`, `pop_multi_ready`, `EDGE_TRIGGER`, `EFAULT`, `copyout`, and `epoll` found no commit that restores an ET entry on an epoll copyout error. The matching public PRs inspected were [#1519](https://github.com/asterinas/asterinas/pull/1519), which adds `max_events` boundary checks, and [#1049](https://github.com/asterinas/asterinas/pull/1049), which changes timeout handling; neither concerns failed output copyout.
- The current public `main` comparison reports the supplied source is 16 commits ahead of `main`; its only listed changes to the three affected files are the source-layout refactor `819e7a826`, not a copyout-recovery change.

## Known-status and precedent

- On 2026-08-13, the GitHub tracker was searched across issues and merged/closed PRs with `repo:asterinas/asterinas is:issue epoll EFAULT`, `repo:asterinas/asterinas is:pr is:merged epoll EFAULT`, `repo:asterinas/asterinas is:pr is:closed epoll EFAULT`, `repo:asterinas/asterinas is:issue epoll_wait`, `repo:asterinas/asterinas is:pr is:merged epoll_wait`, and `repo:asterinas/asterinas copyout epoll`.
- The EFAULT issue search and the copyout search returned no matching tracker items. The merged/closed PR hits for the broad EFAULT query were [#3146](https://github.com/asterinas/asterinas/pull/3146) and [#2951](https://github.com/asterinas/asterinas/pull/2951), both unrelated. The `epoll_wait` results were inspected as above; no report describes an ET ready entry committed before a failing user-memory copy and then lost.
- No public issue, PR, CVE, advisory, or previously reported tracker entry was found for this mechanism at `syscall/epoll.rs` plus `events/epoll/file.rs`.

## Challenger supplemental audit

- Opened `spec/output/MC_hunt_s2_copyout_round2_bfs.out`. Its nine-state witness records `EpollControlCaptureTarget`, `EpollAddInterest`, `TimerfdExpired`, `EntryUpdatePoll`, `EpollControlPushReady`, `ReadySetPop`, `EntryPollPrepare`, and `DoEpollPwait2CopyoutFault`. In state 9, `triggerMode` is `ET`, `sourceReady` remains true, `readyQ` is empty, `copyoutOk[t1]` is `fault`, and `faultedUndelivered` contains the registered key. This is the same ordering as the public eventfd sequence, with a different pollable source.
- The checked source worktree is `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f`. It has trace instrumentation in `EpollFile::control` and `add_interest`, but the diff does not touch `EpollFile::wait`, `pop_multi_ready`, `Entry::poll`, or syscall copyout. The tested kernel in the isolated image has the same SHA-256 as the supplied artifact's kernel.
- The suspected recovery mechanism is absent: `ReadySetPopIter::next` removes the entry and resets `observer.ready` (`entry.rs:372-397`); an ET `Entry::poll` returns `is_still_ready = false` (`entry.rs:136-142`); and `ReadySet::push` can only occur on a subsequent observer notification (`entry.rs:307-330`). A later source transition or `EPOLL_CTL_MOD` can create a new opportunity, but neither restores the already pending edge automatically.
