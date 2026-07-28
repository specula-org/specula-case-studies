# Independent bug review

## Final adjudication

The second review records **1 new bug and 1 known open bug**.

| Candidate | Final classification | Severity | Recorded? |
|---|---|---:|---:|
| MC-1 | Intentional transient activation gap, masked by reconnect and retry | — | No |
| MC-2, narrowed | Post-send disconnect can leave an accepted asynchronous RPC unresolved | Medium | New |
| CR-1 | Invalid reproduction bypassed the real coordinator, Raft, and recovery path | — | No |
| CR-2 | Automatic Raft snapshots are disabled | Minor | Known, open |
| CR-3 | Claimed batch race is protected by `m_batch_mut` | — | No |
| CR-4 | Ordinary restart replays the persistent Raft log | — | No |
| CR-5 | No functional failure established | — | No |

The archived [confirmation report](../confirmed-bugs.md) is retained for provenance but is not the final adjudication.

## New bug: unresolved asynchronous RPC after disconnect

### Mechanism

The generic TCP client inserts an asynchronous response callback into `m_responses` before sending the request. If the send succeeds and the connection then disappears before a response arrives, the request remains in that map: there is no disconnect path that fails it or replays it. See [`tcp_client.hpp` lines 104-114 and 175-188](https://github.com/mit-dci/opencbdc-tx/blob/8444ef8b4297c85109b4681071a8c43c5fea329b/src/util/rpc/tcp_client.hpp#L104-L188).

Client destruction attempts to complete every pending action with `std::nullopt`, but the typed asynchronous wrapper returns without invoking the application callback when it receives that value. See [`tcp_client.hpp` lines 40-51](https://github.com/mit-dci/opencbdc-tx/blob/8444ef8b4297c85109b4681071a8c43c5fea329b/src/util/rpc/tcp_client.hpp#L40-L51) and [`client.hpp` lines 67-87](https://github.com/mit-dci/opencbdc-tx/blob/8444ef8b4297c85109b4681071a8c43c5fea329b/src/util/rpc/client.hpp#L67-L87).

The coordinator RPC client forwards `execute_transaction` directly through this asynchronous generic client. See [`coordinator/client.cpp` lines 19-22](https://github.com/mit-dci/opencbdc-tx/blob/8444ef8b4297c85109b4681071a8c43c5fea329b/src/uhs/twophase/coordinator/client.cpp#L19-L22). A coordinator stepdown closes its RPC server before joining existing transaction execution, making a post-send disconnect a reachable lifecycle event. See [`coordinator/controller.cpp` lines 182-210](https://github.com/mit-dci/opencbdc-tx/blob/8444ef8b4297c85109b4681071a8c43c5fea329b/src/uhs/twophase/coordinator/controller.cpp#L182-L210).

The focused product-code reproduction in [test_disconnect.cpp](test_disconnect.cpp) sent an asynchronous request, waited for the server to accept it, then closed the server before it replied. The observed [output](test_disconnect.out) was:

```text
pending_after_disconnect=true
callback_after_client_destroy=false
```

This demonstrates an indefinitely unresolved or indeterminate transaction response on the affected path. It does not demonstrate data corruption, duplicate execution, or a cluster-wide outage.

### Novelty boundary

Upstream [Issue #145](https://github.com/mit-dci/opencbdc-tx/issues/145) discusses initial forwarding failure, infinite retry, and the top-level sentinel return value. It does not describe a successfully sent request remaining in `m_responses` after disconnect or the terminal `std::nullopt` being suppressed. The finding is therefore recorded as new, subject to upstream deduplication.

## Known open bug: snapshots disabled

Both Raft-backed 2PC services explicitly set `snapshot_distance_ = 0`:

- [`coordinator/controller.cpp` line 37](https://github.com/mit-dci/opencbdc-tx/blob/8444ef8b4297c85109b4681071a8c43c5fea329b/src/uhs/twophase/coordinator/controller.cpp#L37)
- [`locking_shard/controller.cpp` line 46](https://github.com/mit-dci/opencbdc-tx/blob/8444ef8b4297c85109b4681071a8c43c5fea329b/src/uhs/twophase/locking_shard/controller.cpp#L46)

Their state-machine snapshot methods are stubs. The direct consequence is no automatic snapshot-based log compaction, so persistent Raft logs grow with continued operation and recovery work increases over time. This is already tracked by upstream [Issue #12, “Add Coordinator State Machine snapshots”](https://github.com/mit-dci/opencbdc-tx/issues/12), which was open at the time of review.

## Why the archived CR-1 was rejected

The archived CR-1 reproducer directly executes `lock → apply → discard → apply` against a shard. It does not generate the claimed sequence through the real coordinator, NuRaft leadership transition, or recovery logic. Product recovery first replicates the coordinator state-machine command and reconstructs incomplete transactions from the persistent log. The harness therefore proves only that an invalid direct shard call is fatal, not that normal failover emits that call sequence.

## Review provenance and limits

- Review date: 2026-07-27
- Public upstream revision reviewed: [`8444ef8b4297c85109b4681071a8c43c5fea329b`](https://github.com/mit-dci/opencbdc-tx/tree/8444ef8b4297c85109b4681071a8c43c5fea329b)
- Archived source revision: unknown; the archive contains only instrumented source fragments, not a complete Git checkout
- New-bug reproduction level: focused runtime reproduction using the unmodified generic RPC implementation
- Known-bug confirmation: source review plus open upstream issue

The archive's original source revision could not be replayed exactly. Final claims are limited to mechanisms confirmed on the public revision above.
