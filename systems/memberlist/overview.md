# HashiCorp memberlist

## Scope

Specula analyzed and tested HashiCorp memberlist's SWIM and Lifeguard membership protocol, including direct and indirect probes, suspicion timers, gossip dissemination, push/pull anti-entropy, incarnation handling, and leave, restart, and tombstone lifecycles.

## Bugs

Specula currently tracks 5 HashiCorp memberlist bugs/findings: 2 new findings from
`memberlist-v030-study`, 2 revalidated known findings from that run, and 1
previously tracked known restart-incarnation issue.

New in `memberlist-v030-study`:

- **New:** `deadNode` returns for an already-dead record before retaining
  a higher terminal incarnation, allowing a delayed `Alive(2)` to resurrect a
  crashed node.
- **New:** Suspicion timers are keyed only by node name, allowing
  higher-incarnation evidence to prematurely expire an older-incarnation timer
  and deliver an incorrect `NotifyLeave`.

Previously known and revalidated:

- **Known, issue #312:** A delayed pre-restart or stale `Alive` can bind a node
  name to a retired address. Specula reproduced the wrong `NotifyJoin` and
  `Members()` exposure; normal probing later removes the stale member in the
  tested configuration, so the run records it as a masked finding.
- **Known, issue #132:** `Join` can report success after the receiver's
  `NotifyMerge` rejects the merge, and rejected state can leak to a third node.
- **Known, issue #311:** Because incarnation state is not persisted, a restarted
  node can announce an equal or lower incarnation that peers reject, prolonging
  a false-Dead view.
