# CR-1 Investigation

## Finding

Code-review finding: EOF turns a valid frame prefix into different operation content in the `examples/kvstore` peer transport.

## Source revision and worktree

- Source repo: `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-1/worktree`
- `git rev-parse HEAD`: `3ac0104a567092139534c9022205d02281a2da41`
- Worktree was already dirty before this investigation: `Cargo.toml`, `examples/kvstore/main.rs`, `lib.rs`, and Specula harness files were modified/untracked. I did not revert them.

## Code audit

- `examples/kvstore/main.rs:68` documents peer wire format as one message per line, whitespace separated.
- `examples/kvstore/main.rs:79-117` encodes `PUT` operations and `PREPARE` frames as text tokens. A `PREPARE` carrying `PUT cr1key FULLVALUE_...` is therefore byte-prefixed by a shorter, syntactically valid `PREPARE ... PUT cr1key FULLVALUE_ABCDEF`.
- `examples/kvstore/main.rs:237-334` decodes a supplied line by `split_whitespace()`. `Tokens::word()` reports `"truncated message"` only when a required token is absent; it does not know whether the input line was newline-terminated. `Tokens::op()` accepts any nonempty third `PUT` token as the complete value.
- `examples/kvstore/main.rs:383-386` sends peer frames as `write_all(line.as_bytes())` followed by a separate `write_all(b"\n")`.
- `examples/kvstore/main.rs:401-409` receives peer input with `BufReader::new(stream).lines().map_while(Result::ok)` and sends successfully decoded frames to the replica event loop. Rust `BufRead::lines()` returns a final nonempty line on clean EOF even if the line has no delimiter, so clean EOF is not distinguishable from a complete line here.
- `lib.rs:701-710` sends `Prepare` for a client request; `lib.rs:718-747` lets backups append the received operation and acknowledge it.
- `lib.rs:776-785` commits when the primary sees a quorum. In the reproduced path, backup acknowledgements to the old primary are intentionally routed to an unreachable old-primary address, so the old primary does not commit or reply.
- `lib.rs:1059-1108` starts a new view from a quorum of `DoViewChange` logs; `lib.rs:1386-1390` and `lib.rs:1399-1415` commit and execute log entries in order. If both surviving backups logged the same shortened operation, the new primary later commits that shortened operation before a fresh client's `GET`.
- `examples/kvstore/main.rs:594-599` formats the fresh client's `GET` result as a bulk string, making the wrong value directly observable by a real kvstore client.

Reachability: the public path is `kvstore` client `SET` to the old primary, primary `Replica::on_request`, real encoder output to peer TCP streams, clean EOF after a valid nonempty prefix at each surviving backup, old primary stop before commit, normal view change among the two survivors, then a fresh client `GET` through node 1. No internal replica state is pre-populated and no source patch is used.

Safeguards encountered: ordinary complete fragmentation is safe because `lines()` waits for `\n`; read errors/reset are stopped by `map_while(Result::ok)` when they surface as `Err`; retransmission/state transfer can repair missing frames but does not repair this case once both survivors have accepted the same shortened op and carry it into the new view.

## Developer-knowledge search

- Comments/docs near the site say the peer protocol is one-line-per-message (`examples/kvstore/main.rs:68`) and the example uses TCP peer messages (`examples/kvstore/main.rs:3-5`, `README.md:137-145`).
- `README.md:14` says the implementation is work in progress and not known to run in production; this is background only, not a waiver for incorrect committed state.
- `examples/kvstore/README.md:37` documents keys and values as single words, matching the reproduction value shape.
- `git blame` attributes the codec and peer acceptor to `b97ffdd3 Add key-value store example`; no commit message or blame evidence states that clean EOF should complete frames.
- Existing upstream issue/PR evidence checked:
  - `https://github.com/penberg/vsr-rs/issues/9`: reports kvstore reconnect backoff, missing disconnect cleanup, and client-id reuse.
  - `https://github.com/penberg/vsr-rs/pull/10`: merged on 2026-09-06, fixes only #9 items (1) and (2) per PR body.
  - GitHub issue search for `kvstore EOF newline frame`, `run_peer_acceptor decode`, `partial write_all PREPARE`, `"PREPARE" "PUT"`, and `"truncated message"` found no same-mechanism report.
- Local `git log --grep` for frame/newline/EOF/decode/kvstore/partial/truncated/connection and `git log -S` for `BufReader::new(stream).lines` / `split_whitespace` found no later fix or discussion for this mechanism.

Known status: no public issue, PR, CVE, advisory, or local git-history precedent found for this exact unterminated-peer-frame-to-different-operation mechanism at the kvstore peer codec/acceptor site. Treat as `Novelty: NEW`.

## Trigger scenario for reproduction

1. Start three unmodified `kvstore` example processes. Node 0 is the initial primary. Nodes 1 and 2 use a peer address list where node 0's send address is unreachable, preventing their `PrepareOk` replies from committing at the old primary during this test.
2. Start relays for node 0's outbound peer links to nodes 1 and 2.
3. A real client sends `SET cr1key FULLVALUE_...` to node 0.
4. The relays read the complete primary-generated `PREPARE` lines, prove the forwarded bytes are exact prefixes, forward only `PREPARE ... PUT cr1key FULLVALUE_ABCDEF` without a newline to each backup, then cleanly close the backup-side stream.
5. Nodes 1 and 2 accept the final unterminated lines as complete peer messages and append the shortened `PUT`.
6. Stop node 0 before it replies to the original client. Nodes 1 and 2 perform a normal view change; node 1 becomes primary.
7. A fresh client sends `GET cr1key` to node 1. Committing that `GET` also commits the preserved op 1, so the client receives the shortened value.

## Reproduction

- Test path: `/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-1_peer_eof_prefix.py`
- Command: `timeout 90s /home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/repro/test_bugCR-1_peer_eof_prefix.py`
- Result: exit 0 with `BUG_TRIGGERED: fresh client observed committed truncated value from an unterminated PREPARE prefix`.
