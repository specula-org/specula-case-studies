# left-right

## Scope

Specula analyzed and tested left-right's reader/writer separation runtime, including dual-copy mutation and publication, reader registration and epoch-based quiescence, blocking and nonblocking publish, handle lifetime, and take-inner/destruction paths.

## Bugs

Specula found 2 new bugs:

- `change_drop` copies the value into a new alias without forgetting the consumed alias, so dropping the original can free data still referenced by the returned alias.
- **Open:** Reentrant `ReadHandle::enter` does not handle the null pointer installed by `take_inner`, so a nested read can reach an `unreachable!` panic (PR #150).

Specula also found 1 previously known bug:

- **Open:** `take_inner` can reuse a stale epoch snapshot and miss a reader that enters before the null-pointer swap, allowing the writer to free data still being read (PR #144).
