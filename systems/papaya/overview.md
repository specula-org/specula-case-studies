# Papaya

## Scope

Specula analyzed and tested Papaya's lock-free concurrent hash map, including insertion, removal, guarded reads and iteration, blocking and incremental resize, waiter coordination, entry migration, memory ordering, and epoch-based reclamation.

## Bugs

Specula found 6 new bugs:

- Aborting a blocking resize unparks the source table's parker instead of the next table's parker, leaving waiting threads permanently blocked; this was fixed in PR #92.
- Under sustained hash-collision pressure, concurrent resize attempts can repeatedly abort and restart without making progress.
- A delayed phase-two metadata store can overwrite a concurrent removal's tombstone, leaving an empty slot marked non-reusable; PR #95 closed this as wontfix.
- Removing and reinserting a key while an iterator advances can make one iteration return that key twice with different values.
- `ResizeMode::Incremental(0)` permits a resize that performs no copying, causing public `reserve` to livelock indefinitely.
- After a failed compare-and-swap retry, a panic in the user callback can leak the key allocation owned by `HashMap::compute`.
