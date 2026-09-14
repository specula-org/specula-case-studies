# vsr-rs

## Scope

Specula analyzed and tested vsr-rs's Viewstamped Replication implementation, including replication, client retries and cached replies, view changes, state transfer, crash recovery, and the TCP key-value store's persistence and transport integration.

## Bugs

Specula found 4 new bugs:

- An invalid or unreadable view file is treated as first initialization, allowing a reused replica identity to start in view 0 and acknowledge conflicting history.
- A one-replica configuration checks quorum only after a peer `PrepareOk`, so client requests never commit despite the primary's self-acknowledgement.
- A connected peer that stops reading can block the shared sender's `write_all`, delaying queued traffic to healthy destinations until that peer resumes.
- Clean EOF after a prefix of a `PREPARE` frame is accepted as a complete peer message, allowing surviving replicas to commit altered operation content.
