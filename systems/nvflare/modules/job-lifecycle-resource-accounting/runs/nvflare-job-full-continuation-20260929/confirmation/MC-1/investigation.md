# MC-1 Investigation

## Scope

Confirmed the model-checking finding that a queued abort can be acknowledged as
`FINISHED:ABORTED` and then overwritten by concurrent runner lifecycle writes.
The investigation was limited to MC-1 and did not inspect other findings,
`bug-report.md`, `confirmed-bugs.md`, or the shared repair queue.

## Code Evidence

`nvflare/private/fed/server/job_cmds.py:1058-1065` handles `abort_job` by reading
the job meta status. If the job is `SUBMITTED` or `DISPATCHED`, it writes
`RunStatus.FINISHED_ABORTED`, appends the user-visible message
`Aborted the job ... before running it.`, appends OK success metadata, and
returns without coordinating with the runner.

`nvflare/private/fed/server/job_runner.py:661-711` checks that a scheduled job is
`SUBMITTED`, deploys it, then unconditionally writes `DISPATCHED`; later it
checks for `DISPATCHED`, starts the run, records `running_jobs`, and
unconditionally writes `RUNNING`. Those writes are not compare-and-swap
transitions, and they can occur after `abort_job` has already acknowledged
`FINISHED:ABORTED`.

`nvflare/fuel/flare_api/flare_api.py:560-581` documents the public API contract:
if a job has not started, `abort_job` "will be cancelled and won't be scheduled";
if the server returns OK, the API returns the server message to the caller.

## Developer Intent

The intended queued-abort behavior is cancellation before scheduling/start.
That intent is explicit in the public `flare_api.abort_job` docstring and in the
server response string emitted by the queued-abort branch. The pre-schedule
control in the reproduction shows this intended behavior: after the abort
acknowledgement, `get_jobs_to_schedule` no longer returns the job.

## Novelty Search

The continuation instructions prohibit external issue/PR discussion lookup and
newer upstream inspection. Within the permitted pinned local git history and
local repository materials, I searched commit history, tests, docs, and release
notes for this mechanism.

Searches covered queued aborts, `FINISHED:ABORTED`, `DISPATCHED`, `RUNNING`,
the abort acknowledgement text, and status overwrite/race wording. Local git
history surfaced older abort/status work including `#1637`, `#1613`, `#1650`,
`#1657`, `#3656`, `#4604`, `#5051`, and `#5221`, but no commit/test/doc entry
matched the queued-abort acknowledgement being overwritten by the runner's
subsequent `DISPATCHED`/`RUNNING` writes. I therefore classify the mechanism as
NEW from the permitted evidence.

## Reproduction

Wrote and executed:

`/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-1_queued_abort.py`

Command:

```bash
timeout 90s python3 /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/repro/test_bugMC-1_queued_abort.py 2>&1 | tee /home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/MC-1/repro-output.log
```

The reproduction is Level 1: timing-controlled harness using the real
`JobCommandModule.abort_job` handler and real `JobRunner.run` lifecycle path.
It stubs deployment/start transport edges to place the abort at admissible timing
points but does not inject unreachable state and does not patch product source.

Result:

```text
CONTROL abort-before-schedule
  abort_reply=['Aborted the job mc1-control before running it.']
  status_history=FINISHED:ABORTED
  final_status=FINISHED:ABORTED
  jobs_to_schedule_after_abort=0
  control_ok=True
SCENARIO abort-during-deploy
  abort_reply=['Aborted the job mc1-deploy before running it.']
  abort_errors=[]
  status_history=FINISHED:ABORTED -> DISPATCHED -> RUNNING
  final_status=RUNNING
  started_after_ack=True
  run_aborted=False
  bug_triggered=True
SCENARIO abort-during-start
  abort_reply=['Aborted the job mc1-start before running it.']
  abort_errors=[]
  status_history=DISPATCHED -> FINISHED:ABORTED -> RUNNING
  final_status=RUNNING
  started_after_ack=True
  run_aborted=False
  bug_triggered=True
RESULT: BUG REPRODUCED - acknowledged queued abort was overwritten and the job started RUNNING
```

## Verdict Rationale

The wrong outcome is live and observable. A real caller through
`nvflare/fuel/flare_api/flare_api.py:575` can receive the OK abort response,
while the same job subsequently becomes `RUNNING` through
`nvflare/private/fed/server/job_runner.py:703-711`. In the reproduction the job
remains in `engine.run_processes`, `run_aborted` is false, and no downstream
loop immediately resolves the acknowledged abort. A later natural completion
would still mean the already-acknowledged queued abort was not honored.

Verdict: REPRODUCED.
