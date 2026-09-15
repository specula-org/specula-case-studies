# Source fidelity review during validation

Pinned source is retained under `validation/source/`. This note distinguishes fixes from execution evidence; final coverage is in `bug-report.md`.

- Expiry zero is a documented observer projection from `tokens_to_remove`, not a claim that the stored reservation tuple contains zero. All dequeue snapshots remain under the existing RM lock. Phase 2.5 already implemented this projection; validation retains it.
- Stop send precedes blocking stop return (`job_runner.py:374-413`). Round 1 splits both admin and startup-failure sends and moves client ownership capture under the existing executor lock (`client_executor.py:497-504`).
- Explicit/strict start failures preserve `active_client_sites = all_client_sites` before the helper/policy raises (`job_runner.py:313-358`). Round 1 retains that local value.
- The pending-client gate (`fed_server.py:938-940`) must guard accepted failure state changes. Late outcomes from excluded participants must be consumed without changing job state.
- Missing outcome resolution (`fed_server.py:1045-1094`) is distinct from an outcome report; it may set infrastructure failure only while an active job remains, and keeps the actual pending-site guard.
- An ABORTED outcome is distinct from generic failure; `fail_run` preserves existing stronger failures, and completion preserves the explicit admin-aborted branch (`job_runner.py:482-490,548-572,813-843`).
- Server abort cleanup uses either normal grace, zero grace after a command exception, or early exit when the registry entry disappears (`server_engine.py:354-409`). Unconditional map pop permits a no-op.
- Normal heartbeat response is reactive protocol behavior, not an injected fault to exhaust. All hunt configurations require `MCTypeOK` alongside their scenario properties.

PR #5191 refreshed on 2026-09-14: open, unmerged, head `27ecde2ab85b38734072b90128dc5dc2e8390882`. Full discussion and current metadata are saved in this directory. Cancellation acknowledgement loss alone leaves expiring reservations; it does not establish a permanent allocation leak. Proposed PR changes and the requested verify-and-log adjustment are separate from the pinned code.

## Applied result

The source-backed repairs above are implemented and all four final traces pass. The accepted ABORTED outcome receiver branch, delayed heartbeat snapshots and TV-2/TV-3 service-death paths retain the explicit coverage boundaries in priority-coverage.md. The original generation review is preserved as a historical review of the pre-validation model, not rewritten as an independent approval of these repairs.
