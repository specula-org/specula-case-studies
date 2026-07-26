# ConcurrentQueue

## Scope

Specula analyzed and tested moodycamel::ConcurrentQueue's lock-free MPMC core, including explicit and implicit producer subqueues, enqueue/dequeue and batch operations, block allocation and recycling, producer discovery, per-producer FIFO ordering, and exactly-once delivery.

## Bugs

The bug tracker currently records no bugs for this system.
