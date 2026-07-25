# requestPreVote metrics label copy-paste error

**PR**: https://github.com/hashicorp/raft/pull/665

`requestPreVote` (`raft.go:1738`) uses metrics key `"requestVote"` instead of `"requestPreVote"`. Copied from `requestVote` in PR #530 without updating the label. PreVote latency gets mixed into the requestVote metric.
