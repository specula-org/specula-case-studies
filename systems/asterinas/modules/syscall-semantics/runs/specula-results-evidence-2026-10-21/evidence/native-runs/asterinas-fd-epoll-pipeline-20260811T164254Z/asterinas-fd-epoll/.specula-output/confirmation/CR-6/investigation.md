# CR-6 investigation

## Scope

This investigation is limited to CR-6: two epoll instances, one eventfd, and
the nested-registration/readiness path. It does not infer behavior for deeper
graphs.

## Code audit

`sys_epoll_ctl` resolves the epoll file and delegates to
`EpollFile::control` (`kernel/core/src/syscall/epoll.rs:51-95`). The add path
looks up the target descriptor and calls `add_interest`; it has no check that
the target is the same epoll instance or that adding it closes a two-node
cycle (`kernel/core/src/events/epoll/file.rs:64-161`). The only structural
check in `add_interest` rejects a duplicate `(fd, file)` pair.

An entry registers itself as an observer of its target through `Pollable::poll`
(`kernel/core/src/events/epoll/entry.rs:152-166`). When an observed target is
ready, `Entry::on_events` calls `ReadySet::push`
(`kernel/core/src/events/epoll/entry.rs:280-284`). `ReadySet::push` holds its
entries lock while it invokes `pollee.notify` (`entry.rs:307-331`).
`SyncSubject::notify_observers` holds the observer-set lock and invokes each
observer synchronously (`kernel/core/src/events/subject.rs:126-153`). Thus a
self-registration can route a readiness notification back into the same ready
set while its entries lock is held. A two-node back-edge has analogous nested
delivery, though this audit alone does not establish a guest-visible deadlock.

## Candidate public trigger

1. Create epoll instances A and B and an eventfd E.
2. Add E to A, then add A to B. This is the acyclic control path.
3. Attempt either `epoll_ctl(A, EPOLL_CTL_ADD, A, ...)` or, after adding B to
   A, `epoll_ctl(B, EPOLL_CTL_ADD, A, ...)`.
4. Write to E and wait through the outer epoll only if the attempted cyclic
   registration was accepted.

The candidate uses only public syscall operations. Linux rejects the self edge
with `EINVAL` and the two-node back-edge with `ELOOP`; the acyclic control is
accepted and delivers the event.

## Developer intent

The comment beside `ReadySet::push` explicitly avoids acquiring `Entry::Inner`
during a callback because the registration and notification paths otherwise
have incompatible lock ordering (`kernel/core/src/events/epoll/entry.rs:308-315`).
That shows an intent to avoid callback-induced lock cycles, but it does not
guard ready-set re-entry or reject a cyclic registration. `SyncSubject` also
documents that observers must not violate its atomic notification mode
(`kernel/core/src/events/subject.rs:62-67`) while implementing synchronous
delivery under its observer lock (`subject.rs:126-153`).

## Known-status search

On 2026-08-13, the upstream issue tracker and both open and recently closed
pull requests were searched for `epoll`, `cycle`, and nested-registration
mechanisms. The open-issue search returned no match; the closed-PR search
returned upstream PR [#3395](https://github.com/asterinas/asterinas/pull/3395).
Local `git log --all` has no corresponding merged cycle-rejection commit.
PR #3395,
`Fix EpollTest.CycleOfOneDisallowed`, is an exact prior report: its patch adds
self-edge rejection and graph-cycle detection in `EpollFile::control`, and it
removes the corresponding gVisor epoll conformance blocklist entries. The PR
was closed without merge on 2026-06-24, so its fix status is unfixed.

This is therefore an already reported code-review mechanism, not a new
finding. The separate reproduction attempt records whether this worktree can
execute the public Level-0 scenario; it does not create a duplicate report.
