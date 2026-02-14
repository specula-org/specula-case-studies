# Missing resp.Term check in heartbeat causes phantom contact

**Issue**: https://github.com/hashicorp/raft/issues/666

`heartbeat()` (`replication.go:423`) calls `setLastContact()` unconditionally when the transport succeeds, without checking `resp.Term`. Both `replicateTo()` (line 239) and `pipelineDecode()` (line 548) check `resp.Term > req.Term` before calling `setLastContact()`.

When `replicate()` is blocked on disk IO (its raison d'etre — see comment at `replication.go:385`), only `heartbeat()` sends RPCs. A follower that has moved to a higher term rejects the heartbeat (`resp.Term > req.Term`, `Success=false`, transport `err=nil`), but `heartbeat()` still records it as a successful contact. `checkLeaderLease()` counts these phantom contacts toward quorum, keeping the stale leader alive indefinitely.
