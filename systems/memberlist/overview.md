# memberlist

## Scope

Specula analyzed and tested memberlist's SWIM and Lifeguard membership protocol, including direct and indirect probes, suspicion timers, gossip dissemination, push/pull anti-entropy, incarnation handling, and leave, restart, and tombstone lifecycles.

## Bugs

Specula found 3 previously known bugs:

- **Open:** Reaping a Left or Dead tombstone erases its incarnation floor, allowing stale push/pull Alive state to resurrect the node and delay membership convergence.
- **Open:** Because incarnation state is not persisted, a restarted node can announce an equal or lower incarnation that peers reject, prolonging a false-Dead view.
- **Open:** `Join` can report success after the receiver's `NotifyMerge` rejects the merge, leaving the two nodes with asymmetric membership views.
