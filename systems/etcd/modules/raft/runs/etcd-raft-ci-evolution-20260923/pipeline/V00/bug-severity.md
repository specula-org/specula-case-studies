# Severity Classification — etcd-raft

## Summary

- Total entries: 6
- Reproduced bugs: 5
- Severity-bearing findings: 0
- Critical: 1
- High: 4
- Medium: 0
- Low: 0
- No-severity dispositions: 1

## Per-entry classification

| Entry | Finding | Status | Severity | Reasoning |
|-------|---------|--------|----------|-----------|
| 1 | CR-1 | REPRODUCED | Critical | Restarting a public RawNode from empty-log storage containing a persisted term and vote resets that election state, permitting a second durable vote in the same term. Two candidate RawNodes consume the votes and both become leaders in that term, directly demonstrating the rubric's two-leader election safety failure. |
| 2 | CR-2 | REPRODUCED | High | Leadership transfer to a node with a committed but unapplied self-removal bypasses the pending-configuration election guard; after applying removal, it remains leader and drops client proposals. The availability failure persists until another leadership change, with no downstream guard stepping the removed leader down in the reported execution. |
| 3 | CR-3 | REPRODUCED | High | Calling Advance before ApplyConfChange allows a second configuration change to commit under the old membership and reach the application's Ready stream before the intermediate membership becomes effective. This membership-safety violation has a permanent applied effect with no downstream revalidation, although persistent client-data corruption is not demonstrated. |
| 4 | CR-4 | DROPPED | — | Phase 4 dropped this entry as an exact duplicate of an already-reported defect; this disposition is not severity-bearing. |
| 5 | CR-5 | REPRODUCED | High | A ReadIndex heartbeat response delayed across leader self-removal lets the removed leader return an old read basis to the application after the remaining node has applied a newer write. Later CheckQuorum step-down cannot revoke the emitted ReadState, leaving an externally exposed read result. |
| 6 | CR-6 | REPRODUCED | High | Under exhausted proposal quota, the public Node.ProposeConfChange call returns success even though admission rejects the membership proposal and it never appears in Ready. The caller loses the rejection signal, and no downstream mechanism corrects the returned result or automatically retries the dropped request. |
