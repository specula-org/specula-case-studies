# CR-4 Investigation

## Finding

- id: CR-4
- source: Code Review
- pinned revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`
- primary location: `service/history/hsm/nexusoperations/workflow/commands.go:196`

## Step 1: Code Audit

The schedule command handler validates and mutates `ScheduleNexusOperationCommandAttributes` before it appends the `NEXUS_OPERATION_SCHEDULED` event and creates the Nexus operation state machine.

Relevant path:

- `service/history/hsm/nexusoperations/workflow/commands.go:36`: `HandleScheduleCommand` handles `COMMAND_TYPE_SCHEDULE_NEXUS_OPERATION`.
- `service/history/hsm/nexusoperations/workflow/commands.go:196`: the command first trims schedule-to-close to workflow run timeout. If the command omitted schedule-to-close and the workflow run has a timeout, `opTimeout == 0` is replaced with the run timeout.
- `service/history/hsm/nexusoperations/workflow/commands.go:204`: the command then trims schedule-to-close to `MaxOperationScheduleToCloseTimeout`, but only when `opTimeout > maxTimeout`.
- `service/history/hsm/nexusoperations/workflow/commands.go:223`: the event persists the possibly-mutated timeout.
- `service/history/hsm/nexusoperations/statemachine.go:144`: creation emits a schedule-to-close timer only when the persisted timeout duration is non-zero.
- `service/history/hsm/nexusoperations/tasks.go:49`: timeout task validation checks current machine state before timing out.

Concrete trigger scenario:

1. Namespace config sets `component.nexusoperations.limit.scheduleToCloseTimeout` to a positive duration, for example `1m`.
2. A workflow with no workflow run timeout schedules a Nexus operation and omits `ScheduleToCloseTimeout`.
3. `opTimeout` is `0`, so the run-timeout branch does not replace it and the dynamic-config max branch does not fire because the condition is `opTimeout > maxTimeout`.
4. The scheduled event persists a zero/nil schedule-to-close timeout, and the operation state machine regenerates no `nexusoperations.Timeout` task.

Healthy control already in the tree: `service/history/hsm/nexusoperations/workflow/commands_test.go:338` asserts an explicit long schedule-to-close timeout is capped by dynamic config. The missing case is the same normal command path with an omitted timeout and no workflow run timeout.

Safeguards observed:

- If the workflow run timeout is set, `commands.go:199` caps an omitted operation timeout to that run timeout.
- If the command explicitly sets a timeout longer than the configured maximum, `commands.go:205` caps it.
- Those safeguards do not cover the omitted operation timeout when the workflow run timeout is absent.

## Step 2: Developer Knowledge Search

Source comments / docs:

- `service/history/hsm/nexusoperations/config.go:106` defines `MaxOperationScheduleToCloseTimeout`.
- `service/history/hsm/nexusoperations/config.go:109` says commands that specify no schedule-to-close timeout or a longer timeout than permitted will have schedule-to-close capped to the configured value.
- `docs/architecture/nexus.md:287` documents that the maximum allowed schedule-to-close timeout can be enforced with the dynamic config.
- `docs/architecture/nexus.md:284` says Nexus operations are retried until they succeed, permanently fail, or time out.

Git history:

- `git blame -L 196,207 -- service/history/hsm/nexusoperations/workflow/commands.go` attributes the cap branch to `9894e14d94` / PR #6147.
- `git blame -L 106,111 -- service/history/hsm/nexusoperations/config.go` attributes the config text promising omitted-timeout capping to the same PR.
- `gh pr view 6147 --repo temporalio/temporal` shows PR #6147 "Add DC to limit schedule-to-close timeout of a Nexus operation" and describes operational flexibility and limiting callback-token lifetime as the reason.

Tests:

- `commands_test.go:338` tests explicit long timeout capping.
- `commands_test.go:397` tests omitted operation timeout defaulting to workflow run timeout when a run timeout exists.
- No existing test was found for the omitted operation timeout with no workflow run timeout and positive `MaxOperationScheduleToCloseTimeout`.
- `statemachine_test.go:37` asserts that an operation with zero schedule-to-close emits only an invocation task, not a schedule-to-close timeout task.

## Step 3: Known Status / Precedent

Issue and PR searches were run against `temporalio/temporal`:

- `gh search issues MaxOperationScheduleToCloseTimeout --repo temporalio/temporal --limit 20`: no results.
- `gh search issues component.nexusoperations.limit.scheduleToCloseTimeout --repo temporalio/temporal --limit 20`: no results.
- `gh search issues "schedule-to-close timeout" Nexus --repo temporalio/temporal --limit 30`: no results.
- `gh search issues "no schedule-to-close" Nexus --repo temporalio/temporal --limit 30`: no results.
- `gh search issues "ScheduleNexusOperation" "timeout" --repo temporalio/temporal --limit 30`: no exact report found.
- `gh search prs MaxOperationScheduleToCloseTimeout --repo temporalio/temporal --limit 20`: found PR #10192, not this mechanism.
- `gh search prs "schedule-to-close" "Nexus" --repo temporalio/temporal --limit 50`: found timeout/callback-related PRs including #6147, #9010, #10014, and #11974, but no PR reporting or fixing this omitted-timeout bypass.
- `gh search prs "no schedule-to-close" Nexus --repo temporalio/temporal --limit 30`: no results.
- `git log --all -S'MaxOperationScheduleToCloseTimeout' --oneline -- ...`: found only PR #6147 for this symbol.
- `git log --all -G'no schedule-to-close|no schedule to close|omitted|cap.*timeout|limit.*timeout' --oneline -- ...`: found only related timeout feature/history commits, not an exact bug report or fix.

Known-status result: no public issue or merged/closed PR was found that reports this exact omitted schedule-to-close timeout bypass at this site.
