# CR-3 Investigation

## Scope

- Source: code review finding CR-3.
- Target revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
- Worktree: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-3/worktree`.
- Reproduction backend/config: package-local Temporal Go tests using the HSM test backend and command-handler test scaffolding; `MaxConcurrentOperations` forced to 1 to expose the capacity accounting.

## Step 1: code audit

Relevant sites:

- `service/history/hsm/nexusoperations/executors.go:641-689`: the live timeout executor calls `recordOperationTimeout`, records a `NEXUS_OPERATION_TIMED_OUT` history event, and applies `TransitionTimedOut`. It does not call `DeleteChild`.
- `service/history/hsm/nexusoperations/events.go:262-272`: replay/application of the same timeout event applies `TransitionTimedOut` and then deletes the operation node with `node.Parent.DeleteChild(node.Key)`.
- `service/history/hsm/nexusoperations/workflow/commands.go:185-193`: scheduling counts `nexusoperations.MachineCollection(root).Size()` and rejects the command when that physical child count reaches `MaxConcurrentOperations`.
- `service/history/api/describeworkflow/api.go:700-722`: Describe maps terminal Nexus operation states, including `NEXUS_OPERATION_STATE_TIMED_OUT`, to `nil`, so retained terminal nodes are omitted from `PendingNexusOperations`.
- `service/history/hsm/tree.go:660-682`: `Collection.List()` and `Collection.Size()` operate over physical child entries in the HSM persistence map; there is no pending-state filter in `Size()`.

Reachable trigger scenario:

1. A workflow schedules a Nexus operation through the normal command handler, creating a Nexus operation HSM child.
2. The operation times out through the normal HSM timer executor path.
3. The live timeout path records the timeout event and transitions the operation to `TIMED_OUT`, but leaves the child in the HSM collection.
4. A later workflow task tries to schedule another Nexus operation while namespace dynamic config allows only one concurrent Nexus operation.
5. The schedule command sees physical collection size 1 and fails with `WORKFLOW_TASK_FAILED_CAUSE_PENDING_NEXUS_OPERATIONS_LIMIT_EXCEEDED`, even though the only node is terminal.
6. Describe builds pending Nexus operation info from the same HSM collection but hides the terminal `TIMED_OUT` node, returning zero pending operations.

Safeguards/compensation observed:

- Event replay/reconstruction applies terminal timeout events through `TimedOutEventDefinition.Apply` and deletes the node, so a full history rebuild path can reclaim capacity.
- The ordinary live timeout executor path and task regeneration path do not delete a terminal node. `Operation.RegenerateTasks` emits no tasks for terminal states, so no later regenerated task was found that would clean up the retained node.

## Step 2: developer knowledge search

Local git/blame evidence:

- `git blame -L 641,689 service/history/hsm/nexusoperations/executors.go` shows `recordOperationTimeout` predates the later deletion work and still has no deletion call at the target revision.
- `git blame -L 262,272 service/history/hsm/nexusoperations/events.go` attributes the timeout event `DeleteChild` line to `9a0114b346`, `handle state machine deletion for state-based replication (#7177)`.
- `git log --all -S 'DeleteChild(node.Key)' -- service/history/hsm/nexusoperations/events.go components/nexusoperations/events.go plugins/nexusoperations/events.go` found the PR chain `#6984`, `#7024`, `#7128`, `#7163`, and `#7177`.

Upstream PR evidence:

- `https://github.com/temporalio/temporal/pull/6984` / `https://github.com/temporalio/temporal/pull/7128` publicly reported the same terminal-node cleanup mechanism: terminal Nexus operation nodes could linger, causing confusion/resource waste and premature workflow task failures. The PR added terminal-event deletion tests.
- `https://github.com/temporalio/temporal/pull/7024` reverted that first fix because it caused replication-stack issues.
- `https://github.com/temporalio/temporal/pull/7177` later adjusted deletion for state-based replication and is the commit that currently provides timeout-event deletion on replay/application.

Existing tests:

- `service/history/hsm/nexusoperations/executors_test.go:756-797` asserts the live timeout task leaves the operation node in `NEXUS_OPERATION_STATE_TIMED_OUT` and records a timeout event.
- `service/history/hsm/nexusoperations/workflow/commands_test.go:850-1008` asserts terminal event application deletes operation nodes and that cancellation after a terminal event fails because the node no longer exists.

## Step 3: known-status / precedent

Issue/PR searches executed:

- `gh search issues --repo temporalio/temporal "Nexus operation timed out pending limit" --limit 20`
- `gh search issues --repo temporalio/temporal "pending nexus operations limit timed out" --limit 20`
- `gh search issues --repo temporalio/temporal "\"pending nexus operation limit\"" --limit 20`
- `gh search issues --repo temporalio/temporal "\"NEXUS_OPERATION_TIMED_OUT\"" --limit 20`
- `gh search prs --repo temporalio/temporal "Nexus operation timed out pending limit" --limit 20 --state closed`
- `gh search prs --repo temporalio/temporal "pending nexus operations limit timed out" --limit 20 --state closed`
- `gh search prs --repo temporalio/temporal "DeleteChild Nexus operation timed out" --limit 20 --state closed`
- `gh search prs --repo temporalio/temporal "\"workflow has reached the pending nexus operation limit\"" --limit 20 --state closed`

The targeted searches found no newer issue or PR for this residual live-timeout/replay mismatch. However, PR `#6984` / `#7128` already reported the same core defect at the same Nexus operation HSM site: terminal operations linger in the state machine and can cause premature workflow task failures. At the target revision the fix is incomplete for the live timeout executor path, so the known fix status is `unfixed` for this specific target.
