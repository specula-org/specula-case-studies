# CR-1 Investigation

## Code Audit

Source: code review candidate. There is no model-checking counterexample for this finding, so this is `Code Review` sourced.

Relevant entry points are public `Replica::on_message`, `Replica::on_idle`, `Replica::recover`, `Client::on_request`, `Client::on_idle`, `drain_messages`, `drain_replies`, and `Client::drain`.

Observed code facts:

- `lib.rs:14-18` and `README.md:69-72` define the persistence contract: only the view number survives a crash, and the owner persists it after each replica step before delivering outputs.
- `lib.rs:32-34` and `lib.rs:283-286` define the client discipline: a client sends one request at a time and a restarted client must not reuse an identity.
- `lib.rs:723-752` accepts in-order `Prepare` messages from the current primary, appends the entry, commits only up to the primary's advertised committed prefix, then sends `PrepareOk`.
- `lib.rs:759-789` commits at the primary only after a distinct-replica quorum for an op number; committing an op commits every earlier op in order.
- `lib.rs:862-915` has two `NewState` install paths. Same-view state transfer appends only the missing suffix beyond the current log; catch-up to a started view truncates to the committed prefix before extending the new view's log.
- `lib.rs:948-990` and `lib.rs:1062-1103` install a view-change log selected from a quorum of `DoViewChange` states, then commit the selected committed prefix.
- `lib.rs:1153-1228` makes a recovering replica ignore normal protocol messages until it has a quorum of `RecoveryResponse`s including the latest view's primary state; recovery installs the primary state and commits it into a fresh state machine.
- `lib.rs:1343-1367` rebuilds the client table during log replacement. It preserves replies only when the prior per-client table still names the same committed request. If the same client has a later uncommitted suffix entry, the older committed request's cached reply can be dropped on retained-state catch-up; under the documented one-outstanding-request discipline, that older request was already replied before the later request could exist.
- `lib.rs:1369-1411` applies committed entries in order and stores a reply only if the committed request is still the client's latest table entry.

Reachable trigger attempts:

- Normal committed-prefix path: public client request -> primary `Prepare` -> backup `PrepareOk` -> primary `commit_up_to`.
- Same-view state transfer: a backup legitimately misses `Prepare` for op 2, receives op 3, sends `GetState`, and installs a `NewState` suffix from the primary.
- Retained-state view catch-up: an old primary has a committed prefix and a same-client uncommitted suffix, misses a view change, then catches up by receiving a later-view `Commit`, sending `GetState` from its committed prefix, and installing `NewState` that replaces the uncommitted suffix.
- Recovery: a backup reboots through `Replica::recover`, loses volatile state, ignores normal messages while recovering, and later installs the latest primary's `RecoveryState`.

Safeguards/constraints encountered:

- Replacement is only allowed at or after `commit_number`: catch-up truncates to `self.commit_number` (`lib.rs:902-908`), and `install_log` asserts the supplied log length is at least the current committed prefix (`lib.rs:1346-1347`).
- A recovering replica is not a quorum participant for normal messages because `on_message` drops non-`RecoveryResponse` messages in recovering status (`lib.rs:552-557`).
- Recovery requires the latest-view primary response before installing state (`lib.rs:1205-1215`).
- Client-visible harm from dropping an old cached reply after a later uncommitted request would require the same client to have issued the later request while still waiting for the earlier reply, which contradicts `lib.rs:283-286`.

## Developer Knowledge Search

Local git:

- `git log --oneline --decorate --all -- lib.rs tests/cluster.rs simulator/properties.rs README.md` shows the current mainline head `3ac0104 Drop Raft's "vote" vocabulary from the view change`, prior simulator/protocol commits, and no mainline commit describing a fix for historical committed-prefix replacement or recovery loss.
- `git log --all --grep='recover\|recovery\|view change\|StartView\|NewState\|state transfer\|committed\|commit\|log'` shows Lean/proof work on preservation and quorum intersection, but no issue-fix commit for this exact mechanism.
- `git blame -L 1328,1378 -- lib.rs` and `git blame -L 1174,1228 -- lib.rs` attribute `append_to_log`, `install_log`, `commit_up_to`, and recovery installation to the initial implementation commit `716c5bf`, not to a recent bug-fix commit.

Docs/tests:

- `README.md:80-87` explicitly says normal operation, client table/retransmission, view changes, recovery, and state transfer are implemented; state transfer is described as done without the known truncation defect.
- `README.md:173-186` says the deterministic simulator checks committed-prefix agreement, committed-operation durability, reply consistency, duplicate execution, and convergence under message loss/replay/delay and crash/reboot.
- `tests/cluster.rs:226-242` asserts a `PrepareOk` for op n commits the whole prefix in order.
- `tests/cluster.rs:245-295` exercises overlapping same-view `NewState`.
- `tests/cluster.rs:460-531` exercises view change after primary crash and client retry in the new view.
- `tests/cluster.rs:570-620` exercises recovery after reboot.
- `simulator/properties.rs:51-104`, `207-247`, and `291-360` check durability, committed-prefix agreement, and reply consistency.

Issue/PR tracker:

- `gh issue list -R penberg/vsr-rs --state all --limit 100` found issue #9, issue #8, issue #7, issue #5, issue #4, and issue #1. Issue #9 reports kvstore example connection-backoff, disconnect cleanup, and example client identity reuse; it says the protocol itself looks good. Issue #4 is resend-progress for lost `GetState`.
- `gh pr list -R penberg/vsr-rs --state all --limit 100` found PR #10, PR #6, PR #3, and PR #2. PR #10 addresses issue #9's example connection lifecycle items. PR #6 is the old view-change implementation PR. PR #2 is duplicate-message handling.
- `gh issue view 9 --comments` and `gh pr view 10 --comments` found no maintainer or contributor report of the CR-1 mechanism. The PR #10 maintainer comment concerns connection backoff only.
- Narrow GitHub searches for `recovery` and `"StartView"` in `repo:penberg/vsr-rs` did not find an already-filed issue/PR for the same state-replacement/recovery-prefix mechanism.

Known-status conclusion for Phase 1: not an already-reported same-site defect in the public tracker or local git history. Novelty record for verdict body: `NEW`.

