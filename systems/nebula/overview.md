# Nebula Graph

## Scope

Specula analyzed and tested Nebula Graph's Raft partition consensus, including elections and pre-vote, leader leases, heartbeat and log replication, commit advancement, snapshot installation, learner nodes, and restart and persistence behavior.

## Bugs

Specula found 4 new bugs:

- Volatile term and vote state permits double voting after a crash, which can violate leader completeness and lose committed entries.
- **Open:** A leadership change can leave a snapshot promise unfulfilled, permanently keeping a peer host in snapshot-sending state and blocking replication.
- A higher-actual-term PreVote request can mutate the receiver's term, role, and leader before returning through the nominally state-preserving PreVote path.
- Demotion on a higher-term AppendLog response omits host pausing and the leadership-loss callback, so the business layer may never be notified.

Specula also found 1 previously known bug:

- **Open:** Blind-follower election bypass and lease-unaware voting can elect a new leader while the old leader's lease-read window remains valid, allowing stale reads.
