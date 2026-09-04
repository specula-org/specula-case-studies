# CR-2 Investigation

## Finding
`reset_for_exec` zeroes the process pending-signal bitset during `execv()` image
replacement. POSIX requires pending signals to remain pending across `execve`;
only handler dispositions are reset to default. Clearing the pending set silently
drops a signal posted (and possibly blocked) before the exec.

- Source: **Code Review** (code-review TV-2).
- Cited site: `src/kernel/src/pm/process/state/signal.rs:490` (`reset_for_exec`, body 490-498; the offending line is `self.pending = 0;` at 496).

## Step 1 — Code audit (facts)

`SignalControl::reset_for_exec` (signal.rs:490-498):
```rust
pub fn reset_for_exec(&mut self) {
    for slot in self.dispositions.iter_mut() {
        if matches!(slot, SignalDisposition::Handler(_)) {
            *slot = SignalDisposition::Default;      // correct: caught -> default
        }
    }
    self.pending = 0;                                 // BUG: discards pending set
    self.restorer = None;
}
```

Doc comment (signal.rs:485-488) cites POSIX only for the disposition rule
("SIG_IGN and SIG_DFL dispositions are preserved, as POSIX requires"); the
"pending set is cleared" clause carries no POSIX citation.

### Call chain (reachable through a real kcall)
- `execv` kcall handler: `src/kernel/src/pm/kcall/execv.rs:56` (`pub fn execv`) validates
  the `ExecvArgs` and calls `ProcessManager::exec`.
- `ProcessManager::exec` -> `do_execv` (`manager/mod.rs:1973`) builds the new image, then
  in the infallible commit block calls `self.get_running_mut().replace_image(vmem, thread)`
  (`manager/mod.rs:2062`).
- `RunningProcess::replace_image` (`state/running.rs:160`) swaps vmem/thread and calls
  `self.state.signals_mut().reset_for_exec();` (`running.rs:189`).

So `execv` (a real, externally reachable kernel call) unconditionally reaches the
`self.pending = 0` line on every successful image replacement. Reachability: YES.

### How `pending` is populated and consumed (the consumer/consequence)
- Populated by `kill()`: `manager/mod.rs:855` calls `signals.post(signum)` — but ONLY for a
  **caught (Handler)** disposition when delivery must be deferred (line 852-857). A
  default-terminate signal is not posted; it terminates immediately.
- Consumed by:
  - `sigpending()` kcall: `manager/mod.rs:685-696` returns `pending & blocked` to userspace.
  - `sigsuspend` deliverability: `manager/mod.rs:739` (`signals.pending() & !installed`).
  - async delivery: `manager/signal.rs:242` (`(signals.pending() | thread_pending) & !blocked`).

Therefore the realistic pending-across-exec scenario (matching the finding's suggested
"post+block a signal") is: install a handler for signal S (so kill posts it to `pending`),
block S in the thread mask (so delivery is deferred and S stays pending rather than being
delivered at the return-to-user checkpoint), have a peer `kill()` S (posts to `pending`),
then `execv`. POSIX: S stays pending; its disposition becomes default (Terminate); once the
new image unblocks S it is terminated. Nanvix: `pending = 0` drops S permanently — a
real consumer (`sigpending()` and the delivery checkpoint) now sees nothing.

### Safeguards / masks
None. Nothing restores `pending`. `inherited_for_fork` (signal.rs:472-478) deliberately
starts a fork child with `pending: 0` (POSIX-correct for fork), showing the author knew
fork must clear pending but wrongly applied the same clearing to exec. No downstream
sync/resend/loopback re-posts the dropped signal. The loss is permanent.

## Step 2 — Developer knowledge
- Introduced by commit `c7cb73b66` ("[kernel] F: Deliver Caught Signals", Closes #2694,
  Part of #2690). Commit message: "Reset caught dispositions and drop the restorer on
  execv()" — mentions dispositions + restorer, NOT pending. The doc comment adds "the
  pending set is cleared" with no POSIX justification.
- Issue #2694 body: "Because caught handlers reset across execv, the kernel re-resolves the
  restorer" — again only dispositions/restorer, no mention of preserving pending.
- Umbrella #2690 describes per-thread masks and pending sets but does not state the
  pending-across-exec rule.
- No comment / TODO / test asserts that clearing pending on exec is intended. Existing
  tests (`signal_test.rs`) cover `post`/`pending` but have NO exec test.

Developer-intent conclusion: no evidence the implementation intends to violate POSIX here;
it is an oversight (fork's clear-pending copied onto exec). Falls back to the POSIX
engineering principle (execve preserves pending signals; man 7 signal: "the pending signal
set is preserved across an execve(2)").

## Step 3 — Known status / precedent
- Upstream `nanvix/nanvix` (repo id 11183126, ref b495fc7) still has the identical
  `reset_for_exec` clearing pending — **unfixed upstream**.
- `git log -S "self.pending = 0" -- signal.rs`: only the introducing commit `c7cb73b66`;
  no later commit touched the line. No fix landed in any branch.
- Issue-tracker search (`pending+exec`, `signal+exec`, `pending+signal`, `sigpending`,
  `signals+preserved+exec`): only the signals feature issues (#2690 umbrella, #2691-#2697
  sub-tasks). NONE report the pending-discarded-on-exec defect; #2694 discusses only
  disposition/restorer reset. No PR/CVE/advisory reports this mechanism.

=> **Novelty: NEW** (searched open issues, sub-issues, and git history; nothing reports
this mechanism at this site).

Code-review × known pre-filter: NOT known -> do NOT drop. Proceed to Phase 2.
