# Regular-file partial-progress trace harness

This Category B harness instruments the archived Asterinas source directly. `apply.sh` accepts baseline tree `3893ebda0ec3c6f2ef075109c6cb620073b855ef`, whose recorded upstream source commit is `604948581512d83734377974d4c34adb4530f2d7`.

From `.specula-output/`, run:

```sh
bash harness/run.sh
```

The script applies the patch, builds the SMP=2 kernel in `asterinas/dev:0.18.1-20260805`, boots every scenario under KVM, writes console logs under `harness/logs/`, postprocesses per-actor raw records, and checks the final files under `traces/`. Set `SPECULA_SCENARIOS=overlap_prefix` only for an incremental rerun after a complete trace set already exists.

## Trace path

- `kernel/core/src/tla_trace.rs:369-966` owns syscall-actor registration, fixed 256-slot actor buffers, event stamping, reference `FileOps`, PR_SET_NAME control, and console flush.
- `kernel/core/comps/block/src/tla_trace.rs:1-209` owns fixed per-CPU completion buffers, shared semantic order, and data epochs.
- Hot hooks write integer fields into preallocated atomic slots. They do not allocate, format JSON, or print.
- `src/postprocess_trace.py:53-1095` maps event IDs, validates raw intervals, reconstructs all model state in `shadow_order`, preserves execution-actor stream order, and rank-compresses real TSC boundaries.
- `src/check_traces.py:31-199` enforces schema, the 59-event coverage set, pinned/reference separation, the 200-event cap, and Category B overlap.
- `traces/raw/<scenario>-<actor>.ndjson` retains the uncompressed producer observations. `traces/<scenario>.ndjson` is the input for `Trace.tla`.

The `overlap_prefix` scenario uses a one-shot two-actor barrier inside the syscall-start timeboxes. Both commuting `SysReadStart` actions remain unordered; tracing stops before either actor mutates shared OFD state. This avoids inventing an alternate order for causally serialized lock actions.

## Applied hook locations

Line numbers below are after `apply.sh`.

| Area | Location | Events or observation |
|---|---|---|
| Scalar syscall boundary | `kernel/core/src/syscall/read.rs:31-78`; `write.rs:31-80` | scalar start, return, and EINTR translation |
| Positional syscall boundary | `kernel/core/src/syscall/pread64.rs:35-61`; `pwrite64.rs:35-61` | positional start and return |
| Vectored dispatch | `kernel/core/src/syscall/preadv.rs:161-203`; `pwritev.rs:157-199` | vector start and per-iovec continue/return/fault |
| Shared and positional OFD path | `kernel/core/src/fs/file/inode_handle.rs:280-488` | offset acquisition, append selection, positional begin, and nested return |
| ramfs backend | `kernel/core/src/fs/fs_impls/ramfs/fs.rs:709-884` | size snapshot, data guard, copy outcome, metadata publication, backend finish, and release |
| ext2 backend | `kernel/core/src/fs/fs_impls/ext2/inode/file.rs:31-670` | zero writes, buffered/direct read and write outcomes, rollback/commit, BIO submit, and batch wait |
| Partial backed-page observation | `kernel/core/src/vm/page_cache/vmo/mod.rs:741-756` | faulting page state and retained positive prefix |
| BIO identity transport | `kernel/core/src/fs/fs_impls/ext2/fs.rs:504-519`; `kernel/core/comps/block/src/impl_block_device.rs:77-95`; `kernel/core/comps/block/src/bio.rs:38-93,216-311` | submit identity and completion timebox |
| Signal and restart | `kernel/core/src/process/signal/mod.rs:59-62,167-174`; `kernel/core/src/thread/task.rs:84` | classification, restart/no-restart delivery, and syscall rewind |
| Actor control | `kernel/core/src/syscall/prctl.rs:69`; `kernel/core/src/process/posix_thread/thread_local.rs:57,195-200` | trace mode selection and cached actor ID |
| Build wiring | `Makefile:66,118-120`; `test/initramfs/Makefile:10,60`; `test/initramfs/nix/default.nix:36,43`; `test/initramfs/nix/initramfs.nix:25,53-54` | isolated package and scenario init |

`instrumented-events.txt` is the canonical list of the 59 exact TLA+ action names. Numeric IDs and raw layouts are defined together in `src/tla_trace.rs`, `src/block_tla_trace.rs`, and `EVENT_NAMES` in `src/postprocess_trace.py`.

## Small adjustments

To add a field:

1. Add the raw integer to `event_fields(...)` at the source hook. Core actor slots have 16 fields; completion slots have 8.
2. Decode the index in the matching branch of `reconstruct()` in `src/postprocess_trace.py`.
3. Add the final field to `snapshot()` and `STATE_FIELDS` only if it is new model state.
4. Add the matching `event.state.<field>` check to `ValidatePostState` before relying on it. Do not retain unvalidated fields.

To add an event:

1. Reserve one ID and constant in the appropriate trace module.
2. Add the exact action name to `EVENT_NAMES` and `instrumented-events.txt`.
3. Add a `reconstruct()` transition with precondition checks and observed deltas.
4. Add a real scenario that reaches the source hook, then rerun the coverage checker.

To move a capture point, keep `begin_*()` immediately before the modeled operation and call `record()` after it. If a guard must be dropped before recording, call `stamp()` first, drop the guard, then call the specialized recorder. BIO completion identity must remain attached at submission and emitted by the completion CPU actor.

After changing tracked source hooks, regenerate `patches/source-hooks.patch` against `refs/specula/baseline`. After changing an owned file under `harness/src/`, make the same edit in its applied source copy or run `clean.sh` before applying again; `apply.sh` refuses to overwrite divergent files.

## Current verification

- `bash harness/run.sh`: passed all seven real guest scenarios.
- Coverage: all 59 event types; all 52 pinned ext2/ramfs-producible events occur outside the reference trace; all seven reference-only events occur in `reference_restart`.
- Category B quality: `overlap_prefix` has 1/1 cross-actor event pairs overlapping (100%).
- L2: all 44 emitted state fields are referenced by non-stub `ValidatePostState` checks.
- TLC syntax: `Trace.cfg` and `Trace-reference.cfg` both pass SANY.
- Quick trace validation: `overlap_prefix.ndjson` passes `Trace.tla`/`Trace.cfg` with 6 generated states.

The broader traces are retained even when validation stops, because rewriting an observed trace would hide the behavior Phase 3 must classify. The current first stops are:

| Trace | TLC result |
|---|---|
| `ramfs_normal.ndjson` | `TraceMatched` stops at the second readv entry's zero-byte EOF copy; the model's ramfs complete-copy action expects positive progress. |
| `ramfs_faults.ndjson` | `ReportedCoversVisibleCopy` |
| `ramfs_zero_append.ndjson` | `FileSizeMatchesProgress` |
| `ext2_buffered.ndjson` | `ReportedCoversCommittedWrite` |
| `ext2_direct.ndjson` | `ReportedCoversVisibleCopy` |
| `reference_restart.ndjson` with `Trace-reference.cfg` | `ReportedCoversVisibleCopy` at the reference-only post-copy EINTR path |

These names are validation observations, not classified findings. Phase 3 should decide whether each stop is a model mismatch, instrumentation adjustment, or implementation behavior before changing any capture point.
