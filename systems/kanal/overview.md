# Kanal

## Scope

Specula analyzed and tested Kanal's synchronous and asynchronous bounded, unbounded, and rendezvous channels, including send/receive and send-many operations, wait-list handoff, wakeups, close/disconnect behavior, and cancellation of pending operations.

## Bugs

Specula found 3 new bugs:

- Cancelling `ReceiveFuture` can push returned data to the front of a bounded queue without checking capacity, growing the queue beyond its declared limit.
- `SendManyFuture` can discard the in-flight element's `SendError` when the channel closes while more elements remain, silently losing data; PR #62 fixed it.
- Calling `wait` after `wait_timeout` can mishandle `LOCKED_STARVATION`, report a live channel as closed, and let data be reclaimed while another thread still accesses it.
