# CR-30 Investigation

## Finding

CR-30 is code-review sourced. It asks whether `JobRunner.abort_client_run`
catches only `RuntimeError` around `_send_to_clients`, allowing an ordinary
non-`RuntimeError` cleanup exception to escape the completion path.

Affected site:

- `nvflare/private/fed/server/job_runner.py:408-413` wraps `_send_to_clients`
  in `try` and catches only `RuntimeError`.
- `_stop_run` calls `abort_client_run` from `job_runner.py:389`.
- `_job_complete_process` calls `_get_finished_job_status` at
  `job_runner.py:489`; `_get_finished_job_status` calls `abort_client_run` at
  `job_runner.py:584` when `engine.exception_run_processes[job_id]` exists.

## Code audit

`_send_to_clients` validates targets before fanout:

- `job_runner.py:63-66`: `engine.validate_targets(client_sites)` and
  `raise RuntimeError(f"unknown clients: {invalid_inputs}.")` for invalid
  targets.
- `job_runner.py:67-75`: build `{client.token: message}`, create a new admin
  context, then call `admin_server.send_requests(...)`.

Default target validation does not introduce a non-`RuntimeError`:

- `client_manager.py:445-459` loops through requested names/tokens and returns
  `(clients, invalid_inputs)`.
- `client_manager.py:461-474` resolves client names or returns an admin-client
  placeholder; ordinary unknown clients are reported in `invalid_inputs`, then
  converted to `RuntimeError` by `_send_to_clients`.

Default admin fanout also did not yield a concrete non-`RuntimeError` producer:

- `admin.py:326-339` fires `BEFORE_SEND_ADMIN_COMMAND`, attaches peer context,
  and delegates to `message_send.send_requests`.
- `apis/utils/event.py:54-82` catches `Exception` from event handlers, logs it,
  and stores it under `FLContextKey.EXCEPTIONS`; handler `ValueError` does not
  propagate through `send_requests`.
- `message_send.py:62-66` has a `TypeError` for non-dict requests, but
  `_send_to_clients` always passes a dict it just built.
- `message_send.py:93-99` returns normally for no target messages or
  fire-and-forget.
- `message_send.py:102-110` asserts replies are CellNet `Message` objects.
  A non-CellMessage reply requires a fake/corrupt cell implementation; the
  normal `CoreCell.broadcast_multi_requests` returns message replies or raises
  its own guarded errors.
- `core_cell.py:1513-1515` raises `RuntimeError("waiter not unique!")` for the
  explicit local waiter collision guard.
- `core_cell.py:1777-1795` catches remote callback exceptions and turns them
  into `make_reply(ReturnCode.PROCESS_EXCEPTION)`, so a client-side ordinary
  exception is a reply, not a Python exception escaping the server fanout.

The nearby live-dict alias edge was checked separately:

- `server_engine.py:318-326` stores `job_clients` or, if empty, aliases
  `self.client_manager.clients` as `RunProcessKey.PARTICIPANTS`.
- If a non-empty scheduled client set disconnects before `_start_run`, then
  `get_job_clients` can be empty, but `start_client_job` produces no matching
  replies and `admin.check_client_replies` raises `RuntimeError` at
  `admin.py:102-105`.
- Concurrent mutation while `_get_active_job_participants` iterates
  `participants.items()` can raise Python's dictionary-size
  `RuntimeError`, which is a separate live-collection issue, not CR-30's
  ordinary non-`RuntimeError` fanout source.

## Reachability and safeguards

Reachable normal operations that reach this cleanup site:

- Server/client job failure records `engine.exception_run_processes[job_id]`.
- Completion sees the server run process removed from `engine.run_processes`,
  calls `_get_finished_job_status`, filters active participants, and invokes
  `abort_client_run`.
- `_stop_run` also invokes `abort_client_run` while stopping a live server run.

Safeguards and conversions found:

- Invalid/disconnected targets are converted to `RuntimeError` and caught by
  `abort_client_run`.
- Empty optional abort fanout returns normally.
- Remote client handler exceptions are converted to return-code replies by
  CellNet.
- Server-side event handler exceptions are recorded in `FLContext`, not raised
  through the admin send.

No concrete default local-process launch path was found that emits an ordinary
non-`RuntimeError` from `_send_to_clients` at the cited completion cleanup site.
The only demonstrated non-`RuntimeError` escape requires substituting a
non-default admin sender that raises `ValueError` directly.

## Developer knowledge and known status

Searches performed:

- Read the cited source and adjacent call chain in `job_runner.py`,
  `server_engine.py`, `admin.py`, `message_send.py`, `client_manager.py`,
  `apis/utils/event.py`, and `core_cell.py`.
- Searched HEAD-reachable git history for the cited functions and nearby
  behavior with `git log -p -G 'abort_client_run|_send_to_clients|Failed to abort run|RuntimeError as e|BEFORE_SEND_ADMIN_COMMAND'`.
- Searched in-tree tests/docs/source with `rg` for `abort_client_run`,
  `_send_to_clients`, `Failed to abort run`, `ordinary exception`, `cleanup
  exception`, and `RuntimeError`.
- Searched the supplied handoff conversations for `CR-30`, `Scenario 30`,
  `ordinary cleanup`, `_send_to_clients`, `abort-client`, `Failed to abort
  run`, and `RS-11`.

Relevant developer/history evidence:

- Commit `597b29d5` ("silent abort message logging") made abort client cleanup
  optional and left only `RuntimeError` catch at the abort site, but the
  mechanism concerned ignoring abort replies/timeouts, not a filed
  non-`RuntimeError` escape.
- Commit `1571296f` ("Fix abort job with only connected clients") introduced
  active-participant filtering so disconnected clients are not targeted during
  abort; that path still produces/catches `RuntimeError` for invalid targets.
- Commit `9b5dddfd` ("Harden Client API and Swarm abort cleanup") and later
  lifecycle commits harden related cleanup/accounting paths, but do not report
  this same non-`RuntimeError` cleanup fanout mechanism at this site.
- Existing tests around `_get_finished_job_status` mock `abort_client_run` and
  assert status classification. No test was found asserting that an ordinary
  non-`RuntimeError` from default abort fanout is reachable.
- Handoff conversation evidence records this lead as `RS-11 PLAUSIBLE / not
  triggered` with "No concrete trigger found" at
  `handoff/conversations/02-specification.md:3113`.

Known-status assessment:

- No same-mechanism, same-site filed report was found in the local
  HEAD-reachable history, tests/docs/source, or supplied prior Specula
  conversation records.
- External issue/PR discussion browsing and newer commits were not consulted
  because the continuation instructions prohibit external answers and newer
  upstream inspection. Within the allowed evidence, record as `NEW`, not a
  code-review-known duplicate.

## Reproduction artifact

Wrote and executed:

- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-30_cleanup_exception.py`

The probe exercises Level 0, Level 1, and Level 2:

- Level 0: default optional abort fanout with no clients returns normally.
- Level 1: timing-like disconnected target becomes `RuntimeError` and is
  caught.
- Event path: a non-`RuntimeError` handler failure is recorded in FLContext.
- Level 2: injected non-default `admin_server.send_requests` raises
  `ValueError`, and that escapes `_get_finished_job_status`.
- Level 3 source patch was not used; there is no admissible reachable
  precondition to make deterministic without creating the symptom.
