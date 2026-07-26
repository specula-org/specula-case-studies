# DPDK

## Scope

Specula analyzed and tested DPDK's `rte_ring` module across MP/MC, SP/SC, HTS, and RTS modes, including head reservation, tail publication, concurrent enqueue/dequeue, stalled participants, capacity boundaries, and counter wraparound.

## Bugs

Specula found 1 new bug:

- `rte_soring_release` only logs a mismatched release count in non-debug builds and then advances the stage tail by that count, so under-release leaks slots and over-release exposes unreleased elements.
