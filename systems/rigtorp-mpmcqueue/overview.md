# Rigtorp MPMCQueue

## Scope

Specula analyzed and tested Rigtorp MPMCQueue's bounded multi-producer and multi-consumer queue, including blocking and nonblocking push and pop, ticket and slot reuse, wraparound, publication ordering, full and empty observations, blocked readers and writers, and object lifetime.

## Bugs

Specula found 1 new bug:

- `Queue<T>` accepts nothrow copy-assignable types, but `pop` and `try_pop` unconditionally require move assignment, rejecting types allowed by the class constraint.
