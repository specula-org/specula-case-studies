# CR-3 Investigation

## Code Audit

Source is code review, not an MC counterexample: the supplied finding has no
invariant, config, or counterexample.

The reachable path is the shipped `examples/kvstore` binary. `main` creates one
shared `frames` channel and one sender thread for a node at
`examples/kvstore/main.rs:650-655`. The main event loop drains replica output,
remote replies, and client output into that shared channel after every event at
`examples/kvstore/main.rs:545-566` and `examples/kvstore/main.rs:749-750`.

The sender thread processes `frames` as one FIFO stream at
`examples/kvstore/main.rs:342-350`. For every remote destination it keeps or
opens a `TcpStream`, with only connection establishment bounded by
`TcpStream::connect_timeout(..., 200ms)` at
`examples/kvstore/main.rs:361-380`. Once connected, writes use
`stream.write_all(line.as_bytes()).and_then(|_| stream.write_all(b"\n"))` at
`examples/kvstore/main.rs:383-387`; no write timeout or per-destination worker is
configured. While that `write_all` blocks, the same sender thread cannot process
later queued frames for any other destination.

Client commands reach the path through normal public kvstore use. A client TCP
connection sends a Redis-like `SET` line, `run_client_connection` converts it to
an `Event::Command` at `examples/kvstore/main.rs:444-468`, the node event loop
calls `Client::on_request` at `examples/kvstore/main.rs:720-734`, `flush` sends
the resulting request frame at `examples/kvstore/main.rs:562-565`, and the
primary later drains `Prepare` frames to backups through the same shared sender.
The client waits at `examples/kvstore/main.rs:469` and writes the response only
after the replicated store executes the operation at `examples/kvstore/main.rs:472`.

Trigger scenario: run three kvstore nodes, allow the primary's TCP streams to
both backups to become established, then stall one backup process so the kernel
receive buffer for that existing TCP connection stops draining. A public client
`SET` with a single-word 4MiB value causes the primary sender to block writing
the `Prepare` frame to the stalled backup. Because the sender is shared, the
same `Prepare` to the healthy backup remains queued behind the blocked write.
The primary cannot receive the healthy backup's `PrepareOk`, so the real client
connection observes no `+OK` even though one backup remains healthy.

Relevant timers: kvstore uses `TICK = 100ms` at
`examples/kvstore/main.rs:30-31` and `PRIMARY_TIMEOUT = 5` idle periods at
`examples/kvstore/main.rs:34-35`, so a delay above about 500ms is enough to make
healthy backups suspect the primary.

Safeguards found: the code has a 200ms connect timeout and a 500ms reconnect
backoff for destinations that cannot be reached at
`examples/kvstore/main.rs:364-380`, but those only apply before a connected
stream is available or after `write_all` returns an error. The protocol
re-sends important messages, per the comment at `examples/kvstore/main.rs:340-341`,
but those re-sends are also placed on the same blocked sender channel.

## Developer-Knowledge Search

Local history: `git log -- examples/kvstore/main.rs` shows the sender was added
by `b97ffdd Add key-value store example`. `git log -S'run_sender' --
examples/kvstore/main.rs`, `git log -S'set_write_timeout' -- .`, and
`git log -S'write_all(line.as_bytes())' -- examples/kvstore/main.rs` show no
later local commit adding write timeouts or per-destination sender isolation.

Blame for `examples/kvstore/main.rs:337-392` points entirely to `b97ffdd Add
key-value store example`. The adjacent developer comment says a node that
cannot be reached loses the message and the protocol re-sends what matters, but
there is no comment documenting blocking connected writes as intended.

Docs: `README.md` says the library itself does no I/O and callers deliver
messages however they like, while `examples/kvstore/README.md` documents a
three-node TCP kvstore and says stopping node 0 lets the others pick a new
primary and continue. No docs found that accept one connected stalled peer
blocking all other destinations.

Issue/PR search:

- `gh search issues --repo penberg/vsr-rs "kvstore write_all sender timeout blocked stall peer" --state open`
  and the same query with `--state closed` returned no items.
- `gh search issues --repo penberg/vsr-rs "blocked peer OR write timeout OR stalled peer OR run_sender" --state open`
  and the same query with `--state closed` returned no items.
- `gh search prs --repo penberg/vsr-rs "kvstore write_all sender timeout blocked stall peer" --state open`
  and the same query with `--state closed` returned no items.
- `gh search prs --repo penberg/vsr-rs "blocked peer OR write timeout OR stalled peer OR run_sender" --state open`
  and the same query with `--state closed` returned no items.

Issue #9, `https://github.com/penberg/vsr-rs/issues/9`, reports three kvstore
items: reconnect backoff after a reset, missing `Event::Disconnect` on client
connection errors, and client-id reuse on restarts. It cites the same sender
function for the reconnect-backoff problem, but not a connected non-reading peer
blocking `write_all` and starving other destinations.

PR #10, `https://github.com/penberg/vsr-rs/pull/10`, is open and says it fixes
issue #9 items (1) and (2). Its diff changes the reconnect-backoff update after
a dropped live connection and refactors client disconnect cleanup. It leaves the
connected-stream `write_all` path without a write timeout and does not introduce
per-destination sender workers.

Known-status: no issue, PR, or local history entry was found that reports this
exact mechanism at `examples/kvstore/main.rs:342-392`. Novelty is therefore
`NEW` for this mechanism.
