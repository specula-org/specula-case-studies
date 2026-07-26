# Tokio

## Scope

Specula analyzed and tested Tokio's broadcast and watch channels, including concurrent send and receive, subscription and lag handling, drop and close races, slot reuse and wraparound, value-version observation, change notification, cancellation, predicates, and silent updates.

## Bugs

Specula found 2 new bugs:

- At `u64` position wraparound, `Receiver::drop` can skip its cleanup loop and leave slot reference counts undecremented, leaking memory.
- At `u64` position wraparound, `Receiver::len()` can subtract a wrapped tail position from a larger receiver position and panic on arithmetic overflow.
