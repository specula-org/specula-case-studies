# CR-1 Investigation

## Step 1: Code audit

Finding CR-1 is code-review sourced; no model-checking counterexample is provided for this finding.

The library-level contract says a crashed replica comes back through `Replica::recover`, and the owner must persist `Replica::view_number` after every step before delivering outputs. It warns that without the persisted view, a replica can forget it asked for a view change and let two views run at once (`lib.rs:14-21`).

The kvstore example documents the same caller obligation: only `kvstore-node-N.view` is stored on disk, and a restarted node recovers the rest from peers (`examples/kvstore/README.md:38-39`). The main README also says the owner stores `view_number()` after each step and passes it to `Replica::recover` on restart (`README.md:69-70`).

The startup path in `examples/kvstore/main.rs:683-701` says that if the view file exists, the node has run before and should recover rather than start as a brand new replica. The actual implementation collapses all `read_to_string` errors and all parse errors into `None`:

```rust
let mut persisted_view = std::fs::read_to_string(&view_path)
    .ok()
    .and_then(|s| s.trim().parse::<usize>().ok());
let mut replica = match persisted_view {
    Some(view) => Replica::recover(..., view, nonce),
    None => Replica::new(...),
};
persist_view(&view_path, &mut persisted_view, replica.view_number());
```

Therefore an existing but invalid, invalid-UTF-8, or unreadable view file takes the same constructor branch as a missing file: `Replica::new(args.id, ...)` at `examples/kvstore/main.rs:699`. The following `persist_view` call at `examples/kvstore/main.rs:701` writes the new replica's view 0 through `persist_view` (`examples/kvstore/main.rs:569-585`), replacing the evidence that this was an old identity whose persisted view could not be recovered.

The library behavior behind the consequence is public API behavior. `Replica::new` creates a normal replica in view 0 with an empty log (`lib.rs:490-511`). `Replica::recover` creates a recovering replica in the persisted view and sends `Recovery`; while recovering it ignores all non-`RecoveryResponse` messages (`lib.rs:519-537`, `lib.rs:542-655`). A recovering replica's `Recovery` message includes its persisted view, and a lower-view peer receiving a higher persisted view starts that view change (`lib.rs:1140-1150`, `lib.rs:1224-1230`). A normal view-0 backup created by `Replica::new` instead accepts a view-0 primary's `Prepare` through `accept_from_primary`, appends the entry, and sends `PrepareOk` (`lib.rs:717-746`, `lib.rs:811-823`). The view-0 primary then commits and replies when it receives a quorum `PrepareOk` (`lib.rs:753-783`, `lib.rs:1365-1397`, `lib.rs:1492-1495`).

Concrete trigger scenario:

1. Replica 0 is still a view-0 primary with an uncommitted slot-1 operation X, but its messages to replicas 1 and 2 are partitioned.
2. Replicas 1 and 2 stop hearing from replica 0 and form view 1; replica 1 is the view-1 primary.
3. Replica 1 commits a different slot-1 operation Y in view 1 with replica 2, and releases a client reply. Its owner should have persisted view 1 before releasing that output.
4. Replica 1 crashes and restarts with the same identity, but its existing `kvstore-node-1.view` file is malformed or unreadable.
5. The kvstore startup path treats that existing bad file as `None`, constructs `Replica::new(1, ...)`, and rewrites the view file to `0`.
6. Replica 0 resends the old view-0 `Prepare` for X. The restarted replica 1 is now a normal view-0 backup, acknowledges X, and replica 0 commits X and releases a conflicting client reply for slot 1.

Safeguards encountered:

- If startup uses `Replica::recover(1, ..., view=1, nonce)`, replica 1 ignores the old view-0 `Prepare` while recovering, and its `Recovery { view_number: 1 }` causes lower-view peers to move toward view 1. This is the intended guard.
- The guard is bypassed only because the example startup code maps a present but invalid view file to `Replica::new`.

## Step 2: Developer-knowledge search

Local history has only the initial commit, the kvstore example commit, and the current view-change vocabulary commit. `git blame` places the kvstore startup code at commit `b97ffdd3` and the library recovery contract at commit `716c5bf`; no later local commit changes the startup parse fallback.

Repository docs state the intended behavior:

- `examples/kvstore/README.md:38-39`: only the view number is stored on disk and a restarted node recovers the rest from peers.
- `README.md:69-70`: store `view_number()` after each step and pass it to `Replica::recover` on restart.
- `lib.rs:14-21`: without persisted view, a replica can forget it asked for a view change and let two views run at once.

Existing tests cover correct library recovery when `Replica::recover` is used. `tests/cluster.rs:570-619` reboots replica 1 through `Replica::recover(1, ..., 0, 42)`, asserts it is recovering, proves it ignores a new operation while recovering, then delivers recovery messages and checks it catches up. The tests do not cover kvstore startup with an existing invalid or unreadable view file.

Issue/PR search:

- `gh issue list --repo penberg/vsr-rs --state all --search "view recover OR recovery OR persisted OR kvstore-node"` found issue #9 and old issue #4.
- `gh issue list --repo penberg/vsr-rs --state all --search "malformed OR parse OR unreadable OR UTF-8 OR invalid"` found issue #9.
- `gh issue list --repo penberg/vsr-rs --state all --search "Replica::new OR Replica::recover OR stable storage OR view file"` found issues #9, #4, and #8.
- Matching PR searches for those terms returned no matching PRs.
- `gh pr list --repo penberg/vsr-rs --state all` showed PR #10 open, PR #6 closed, and older merged PRs #3 and #2.
- Issue #9 ("A couple issues in the kvstore example") reports connection backoff view changes, client disconnect cleanup, and duplicate client IDs after quick restart. It does not report invalid/unreadable persisted-view-file fallback to `Replica::new`.
- PR #10 ("Fix connection-lifecycles bugs in kvstore example") says it fixes issue #9 items (1) and (2), leaving the client ID issue alone. It does not touch or discuss the persisted-view-file fallback.
- PR #6 is an old closed "View change protocol" PR against previous `src/message.rs` and `src/replica.rs` paths, not the kvstore persisted view file.
- Issue #4 is about resending messages after timeout, not startup recovery identity.

## Step 3: Known-status / precedent

No upstream issue or PR found in the tracker search reports this exact defect: an existing kvstore replica identity with an invalid/unreadable `kvstore-node-N.view` file silently restarting through `Replica::new` and overwriting the file as view 0.

Known-status evidence supports `Novelty: NEW` for this mechanism. Issue #9 and PR #10 are not exact duplicates of CR-1.
