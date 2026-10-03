# CR-4 Investigation

Source: Code Review

## Finding

Malformed public job metadata accepted by the server-side validator can abort a scheduling pass before later valid submitted jobs are considered. The affected variants are not limited to the modeled numeric-string `min_clients` case:

- `min_clients: null` is accepted by validation, reaches the scheduler after resource reservation, then raises a `TypeError`.
- `min_clients: "2"` is accepted by validation, remains a string, and raises a `TypeError` in the scheduler before resource reservation.
- Legacy nested resource metadata such as `{"site-1": {"process": "x"}}` is accepted by validation and raises a `ValueError` in scheduler resource normalization.

## Phase 1 Investigation

### Code path

The normal job submission path accepts an uploaded job ZIP and validates metadata through `JobMetaValidator` before creating the server job record:

- `nvflare/private/fed/server/job_cmds.py:1568-1587` reads the submitted ZIP and calls `JobMetaValidator().validate(folder_name, zip_file_name)`.
- `nvflare/private/fed/server/job_cmds.py:1648-1666` creates the job via `job_def_manager.create(meta, zip_file_name, fl_ctx)` with the validator-returned metadata.
- `nvflare/private/fed/server/job_runner.py:650-658` obtains submitted candidates and calls `scheduler.schedule_job(...)`.

The validator catches only `ValueError` from the validation helpers, then returns the parsed metadata:

- `nvflare/private/fed/server/job_meta_validator.py:61-86`

`min_clients` validation skips `None` and validates a converted local integer for non-`None` values, but it does not normalize the metadata field itself:

- `nvflare/private/fed/server/job_meta_validator.py:237-249`

`job_from_meta` passes the raw metadata field to `Job.min_sites`:

- `nvflare/apis/job_def.py:227-244`

The scheduler then compares the raw field as an integer:

- `nvflare/app_common/job_schedulers/job_scheduler.py:166`
- `nvflare/app_common/job_schedulers/job_scheduler.py:229`

For `min_clients: null`, the first comparison is skipped because the value is falsey, resource checks succeed, and the later comparison at `job_scheduler.py:229` raises after reservations have been recorded. The exception exits `_do_schedule_job`; `_cancel_resources` is not reached.

For `min_clients: "2"`, the first comparison at `job_scheduler.py:166` raises before resource checks.

Resource metadata validation accepts per-site mapping values but does not type-check the nested legacy `process` value:

- `nvflare/private/fed/server/job_meta_validator.py:276-284`

The scheduler normalizes resource metadata through:

- `nvflare/app_common/job_schedulers/job_scheduler.py:179-182`
- `nvflare/utils/job_launcher_utils.py:244-254`
- `nvflare/utils/job_launcher_utils.py:311-323`

With `{"site-1": {"process": "x"}}`, `get_site_launcher_spec(..., "process")` returns the string `"x"`, and `dict("x")` raises `ValueError`.

The scheduler catches broad exceptions around each scheduling attempt, logs `error scheduling job`, and returns no scheduled job:

- `nvflare/app_common/job_schedulers/job_scheduler.py:287-296`

Because the exception aborts `_do_schedule_job`, the failed candidate is not placed in `failed_jobs` or `blocked_jobs`, and `schedule_count`, job status, and scheduling history are not updated. The outer loop therefore sees the same malformed earlier candidate again on the next pass:

- `nvflare/app_common/job_schedulers/job_scheduler.py:343-376`

### Developer intent

The scheduler tests already encode the intended behavior for malformed metadata: an invalid earlier job must not interrupt scheduling of a later valid job.

- `tests/unit_test/app_common/job_schedulers/job_scheduler_test.py:455-491`

That test covers malformed `mandatory_clients`, expects the bad job to be marked `FINISHED_CANT_SCHEDULE`, and expects the later valid job to be scheduled. The same recovery contract is not enforced for malformed `min_clients` or legacy nested `resource_spec` shapes.

Existing validator tests cover invalid numeric ranges for `min_clients`, but not `null` or normalization of accepted numeric strings:

- `tests/unit_test/private/fed/server/job_meta_validator_test.py:279-297`

Existing utility tests cover legacy nested resource-spec handling but do not reject or normalize a scalar `process` value:

- `tests/unit_test/utils/job_launcher_utils_test.py:296-302`

### Masking and persistence

No automatic scheduler guard, backoff, or status transition masks the issue. The malformed job remains `SUBMITTED`, its schedule count remains unset, and it continues to sort before the later valid submitted job. An operator could manually delete or abort the malformed job, but that is not a downstream self-healing mechanism.

For the `null` variant, resource reservations are made before the exception and no cancel call is issued by the scheduler path. A client-side expiry may later release capacity, but it does not remove the malformed submitted job or unblock admission of the later job.

### Known-status search

I searched the pinned checkout's locally available commit and merge history for the affected files and related terms (`min_clients`, `job_scheduler`, `job_meta_validator`, `resource_spec`, `mandatory clients`). I did not open external upstream issue or PR discussions because the continuation instructions prohibit inspecting upstream discussions or newer external state.

Relevant nearby fixes were not the same mechanism:

- `47684966 Treat duplicate mandatory clients as one required site (#5161)` fixes malformed `mandatory_clients` handling and establishes the non-interruption scheduling contract, but it does not cover `min_clients` or nested legacy `resource_spec`.
- `43034da2 Tighten resource spec validation (#4909)` addresses falsey non-mapping top-level/per-site resource values, but it does not reject the accepted nested `process: "x"` shape reproduced here.
- `docs/release_notes/flare_272.rst:406` mentions omitted `min_clients` in `SwarmServerController`, a different component/path from this scheduler metadata handoff.

I found no exact prior report or local fix for this mechanism in the pinned history, so the finding is not dropped as already reported.

## Phase 2 Reproduction

Executable reproduction:

- `/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugCR-4_malformed_metadata.py`

The reproduction uses hand-written public job ZIPs, the real `JobMetaValidator`, `SimpleJobDefManager`, `FilesystemStorage`, `job_from_meta`, and `DefaultJobScheduler`. The engine shim supplies only the normal scheduler environment: connected clients and resource-check/cancel replies.

It verifies:

- A valid control job schedules normally.
- A malformed earlier job with `min_clients: null`, `min_clients: "2"`, or `resource_spec: {"site-1": {"process": "x"}}` is accepted by the validator, remains `SUBMITTED`, and prevents a later valid job from being scheduled across repeated passes.
- The `null` variant records successful reservations and no cancel calls.

Result: reproduced.
