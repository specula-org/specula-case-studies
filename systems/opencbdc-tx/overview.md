# OpenCBDC 2PC

## Scope

Specula analyzed OpenCBDC's two-phase transaction-processing path, including coordinator, sentinel, and locking-shard interactions, leader transitions, asynchronous RPC response liveness, and Raft snapshot and log-compaction behavior.

## Bugs

After an independent second review, Specula recorded 1 new bug:

- An accepted asynchronous coordinator RPC can remain unresolved after a post-send disconnect because the pending request is neither failed nor replayed and the typed RPC wrapper suppresses the terminal no-response notification.

Specula also confirmed 1 previously known open bug:

- The coordinator and locking-shard Raft services disable automatic snapshots, so their persistent logs grow without automatic compaction. See upstream [Issue #12](https://github.com/mit-dci/opencbdc-tx/issues/12).

The archived run's original conclusion was revised during the second review. See the [reviewed run](modules/twophase/runs/20260722-174240-2125/README.md) for the evidence and full adjudication.
