# 5220: [BUG] Failed server job remains RUNNING while waiting for a disconnected client outcome

{'state': 'CLOSED', 'createdAt': '2026-08-26T21:31:41Z', 'updatedAt': '2026-08-27T00:04:24Z', 'closedAt': '2026-08-27T00:04:24Z'}

## Body
## Describe the bug

When a server job process exits with a recorded execution failure while a participating client is unreachable, the parent job can remain `RUNNING` until the client-outcome or heartbeat timeout expires.

The client terminal-outcome barrier is needed when the server process completes normally because a client may still report a late failure. It should not delay publication after the server has already recorded an authoritative execution failure.

This is a generic job-lifecycle problem. A vertical workflow with a required passive client is a reliable reproducer because disconnecting that client both fails the server workflow and prevents the client from reporting its terminal outcome.

## To reproduce

1. Start a job with one server and two required clients.
2. Wait for the job to reach `RUNNING`.
3. Disconnect one client from the server network.
4. Allow the server workflow to time out and its job process to exit with an execution failure.
5. Continue monitoring the parent job.

## Actual behavior

The server job process has stopped and its failure is recorded, but the parent job remains `RUNNING` while waiting for the disconnected client's terminal outcome.

## Expected behavior

Once the server job process has stopped with an authoritative execution failure, the parent job should promptly publish `FINISHED:EXECUTION_EXCEPTION`. A missing client outcome must not hold a known failed job behind the normal outcome grace period.

Normal server completion must continue waiting for client terminal outcomes, and an `ABORTED` launcher outcome must retain its existing precedence behavior.

## Root cause

The completion loop checks the pending-client outcome barrier before it evaluates the already-recorded server-process failure. Explicit failure paths release the barrier, but a failure originating from the server job process does not.

## Acceptance criteria

- A stopped server job with a recorded non-`ABORTED` failure releases the client-outcome barrier and publishes its terminal failure promptly.
- Normal server completion continues waiting for pending client outcomes.
- Existing administrative and launcher `ABORTED` behavior remains unchanged.
- Late or duplicate client outcome reports cannot mutate an already-selected terminal status.
- Focused regression coverage exercises server failure with a pending client outcome.

Related to #5115, which addressed cleanup of surviving client processes after an abnormal server job exit; this issue covers publication of the parent job's terminal status.
