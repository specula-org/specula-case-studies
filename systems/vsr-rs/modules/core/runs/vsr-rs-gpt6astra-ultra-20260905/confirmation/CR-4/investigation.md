# CR-4 Investigation

## Finding

- Source: Code Review. The finding has no model-checking counterexample or violated invariant.
- Scope: the shipped `examples/kvstore/main.rs` integration boundary for library obligations.
- Primary concrete mechanism found during investigation: client identity reuse across node restarts.

## Step 1: Code Audit

Library obligations:

- `lib.rs:14-18` says a crashed replica must return through `Replica::recover`, and the owner must persist `Replica::view_number()` after every step before delivering outputs.
- `lib.rs:32-35` says every client must have its own `ClientID`, and a restarted client must not reuse one.
- `lib.rs:527-532` says `Replica::recover` requires a recovery nonce that differs from any earlier recovery of that replica.
- `README.md:67-70` repeats that owners must call `on_idle` at a fixed period and persist `view_number()` before delivering produced messages/replies.

Relevant kvstore implementation facts:

- `examples/kvstore/main.rs:340-391` sends frames over TCP, reconnecting on demand. Unreachable destinations lose the current frame; the comment says the protocol resends what matters.
- `examples/kvstore/main.rs:444-475` handles one client command at a time over a TCP connection and sends `Event::Disconnect(connection)` only after the loop reaches its normal tail.
- `examples/kvstore/main.rs:478-491` constructs each client connection id from `(node_id << 56) | (started << 32) | next`, where `started` is `SystemTime::now().as_secs() & 0xFF_FFFF` and `next` is the per-process accept counter.
- `examples/kvstore/main.rs:569-585` persists the current view by writing a temporary file, syncing that file, and renaming it into place.
- `examples/kvstore/main.rs:673-680` starts a tick thread that sends `Event::Tick` to the main event queue every 100ms.
- `examples/kvstore/main.rs:683-701` reads `kvstore-node-{id}.view`; if it exists, the node uses `Replica::recover(..., view, nonce)` with a nonce derived from `SystemTime::now().duration_since(UNIX_EPOCH).as_nanos() as u64`.
- `examples/kvstore/main.rs:716-750` runs all replica/client events through one event loop; after each event it calls `persist_view(...)` and only then calls `flush(...)`.
- `examples/kvstore/main.rs:725-734` creates `Client::new(id as ClientID, config.clone())` for each connection and stores one pending request for the connection.
- `examples/kvstore/main.rs:526-538` delivers a reply only to the currently live connection whose key equals the reply's client id and whose `Client` accepts the request number.

Call chain and reachability for the client-identity mechanism:

1. Public entry point: run `examples/kvstore` and connect as a normal TCP client.
2. `run_client_acceptor` accepts the first connection in one process and assigns `next = 0`.
3. `main` creates `Client::new(id as ClientID, ...)`; `Client::on_request` sends request number 0.
4. The primary records and caches the latest client request/reply in `lib.rs:680-695` and `lib.rs:1400-1403`.
5. If the same kvstore node process restarts within the same wall-clock second, `started` and the first accept counter can repeat, so the new first connection can reuse the same `ClientID` and request number 0.
6. A primary that still has the old client-table entry treats the new first request as a resend and may answer from the old cached reply instead of appending/executing the new command.

Safeguards observed:

- Normal reconnects within the same process are guarded by the monotonically increasing `enumerate()` accept counter.
- Normal replies are routed by the high byte of `client_id` via `node_of()` and delivered only to a currently tracked connection.
- These safeguards do not make the restart-within-same-second identity unique; the accept counter restarts from zero and `started` has one-second granularity.

Concrete trigger scenario:

1. Start a three-node kvstore cluster.
2. Connect the first client to node 0 and issue `SET k old`; this uses node 0's first connection id and request number 0.
3. Restart node 0 within the same wall-clock second as its original start, while other replicas preserve the committed log and client table.
4. Connect the first client to the restarted node 0 and issue `GET k`; the restarted gateway can assign the same connection/client id and request number 0.
5. The current primary can treat this as a duplicate of the old request and return the cached result for the previous `SET`, so `run_client_connection` formats the new `GET` using the wrong result.

## Step 2: Developer-Knowledge Search

Issue tracker and PR search performed with:

- `gh issue list -R penberg/vsr-rs --state all --limit 100 --json number,title,state,updatedAt,closedAt,url,body`
- `gh pr list -R penberg/vsr-rs --state all --limit 100 --json number,title,state,updatedAt,closedAt,mergedAt,url,body`
- `gh issue view 9 -R penberg/vsr-rs --comments --json number,title,state,url,body,comments`
- `gh pr view 10 -R penberg/vsr-rs --comments --json number,title,state,url,body,comments,commits,mergedAt,closedAt,headRefOid,baseRefOid`

Results:

- Upstream issue https://github.com/penberg/vsr-rs/issues/9 is open and reports three kvstore example issues.
- Issue #9 item 3 reports the exact client-id reuse mechanism: a node may issue the same id if it starts twice in under a second because both `started` and `next` repeat; the report says the two clients use the same client-table entry and this breaks VSR.
- Upstream PR https://github.com/penberg/vsr-rs/pull/10 is open. Its body says it fixes issue #9 items (1) and (2), and left the client ID issue alone because it seemed out of scope.
- PR #10 has no `mergedAt` value and therefore has not landed. Its two commits address connection backoff and disconnect cleanup, not the client-id restart issue.
- Maintainer comment https://github.com/penberg/vsr-rs/pull/10#issuecomment-5549729674 discusses the connection-backoff part of issue #9, not a fix for the client-id issue.

Git history and blame:

- `git log --oneline --decorate --all -- examples/kvstore/main.rs lib.rs README.md` shows the kvstore example was added in `b97ffdd Add key-value store example`; the current head is `3ac0104`.
- `git blame -L 478,492 -- examples/kvstore/main.rs` attributes the client-id generation and warning comment to `b97ffdd`.
- No later local commit in the checked-out history changes `run_client_acceptor` or the client-id generation.

Developer intent evidence:

- The code comment at `examples/kvstore/main.rs:479-484` explicitly states client ids must never repeat and explains that repeats make the primary answer a new connection's first request from the cache.
- The library comment at `lib.rs:32-35` documents the same obligation for all callers.

## Step 3: Known Status / Precedent

Known-status determination:

- This is code-review sourced: there is no real model-checking counterexample for CR-4.
- Upstream issue #9 has already filed the same mechanism at the same site: `examples/kvstore/main.rs:485-491` can reuse a client id after a node restart within one second because `started` and `next` repeat.
- Upstream PR #10 is open and explicitly leaves that client-id issue unfixed.

Pre-filter result:

- Status: DROPPED (code-review x known, cite: https://github.com/penberg/vsr-rs/issues/9)
- Fix status: unfixed at current head `3ac0104a567092139534c9022205d02281a2da41`.

