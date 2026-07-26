# Crossbeam

## Scope

Specula analyzed and tested Crossbeam's bounded and rendezvous channels, work-stealing deque and injector, epoch reclamation, and skip list, including send/receive and selection, stealing and resizing, reclamation, concurrent updates, iteration, and range resumption under mutation.

## Bugs

Specula found 7 new bugs:

- After returning `None`, `Iter::next`, `Iter::next_back`, `Range::next`, and `Range::next_back` can reset their exhausted cursor and yield already visited elements; Issue #1142 and PR #1252 cover only part of this behavior.
- The `Injector` debug implementation prints `Worker { .. }` instead of `Injector { .. }`; PR #1259 remains open.
- The LIFO first CAS in `steal_batch_with_limit_and_pop` lacks one buffer-identity recheck added elsewhere for CVE-2021-32810; the tracker classifies this as a non-exploitable defense-in-depth gap.
- `insert_internal` publishes a same-key replacement before marking the old node, temporarily exposing both nodes as live and enabling duplicate observations.
- If a comparator panics after a failed level-zero insertion CAS, the optimistic length increment is not reverted, permanently corrupting `len` and `is_empty`.
- `compare_insert` disarms the unpublished-node guard before calling the replacement predicate, so a predicate panic leaks the node and its payload.
- `remove` holds a non-dropping acquired entry across a comparator call, so a comparator panic can permanently pin the removed node and payload.

The bug tracker also records 4 known bugs examined by Specula:

- `Range::next` can rewind after exhaustion because `None` represents both an unstarted and an exhausted cursor; Issue #1142 and PR #1252 remain open.
- The historical MSQueue pop path could leave `tail` pointing to a collected node when `head == tail`, causing a use-after-free on the next push; Issue #238 records the fix.
- A historical nested pin could advance and replace the local epoch while an outer guard still held old references, enabling use-after-free; Issue #105 records the merged fix.
- Bounded-array `Receiver::try_recv` can spin behind an unpublished send reservation instead of returning immediately; Issue #997 and PR #1105 remain open.
