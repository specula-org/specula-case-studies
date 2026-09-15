# 5115: [BUG] Client jobs remain active after an abnormal server job exit

{'state': 'CLOSED', 'createdAt': '2026-08-13T17:12:00Z', 'updatedAt': '2026-08-13T18:52:01Z', 'closedAt': '2026-08-13T18:52:01Z'}

## Body
**Describe the bug**

When a launcher-managed server job process terminates abnormally, a participating client job can remain active even though there is no longer a server job process to drive it.

The client parent continues reporting the client job in its heartbeat. Server-side synchronization treats every job awaiting a client terminal outcome as if it were still running on the server, so the heartbeat response does not request cleanup. With an external scheduler such as Slurm, this can leave the client allocation reserved until delayed terminal-outcome cleanup or external scheduler termination.

**To Reproduce**

1. Configure the server and at least one client to launch job processes through an external job launcher.
2. Submit a job and wait for both the server and client job processes to become active.
3. Externally terminate only the server job process while leaving the root server and client parent processes active.
4. Observe that the client job process remains active instead of being cleaned up by heartbeat reconciliation.

**Expected behavior**

Once the root server records that the server job process has failed, subsequent client heartbeat reconciliation should request cleanup of surviving client jobs.

A normally completed server job that is still waiting for acknowledged client terminal outcomes must remain protected from premature cleanup.

**Environment**

- NVFlare `main`
- Launcher-managed server and client job processes
- Reproducible with an external batch scheduler

**Additional context**

The server tracks active server job processes separately from jobs awaiting client terminal outcomes. Heartbeat reconciliation currently combines both sets without excluding jobs that already have a recorded server-side terminal failure.

Acceptance criteria:

- A client job is selected for heartbeat cleanup after its server job has exited with a recorded failure.
- Active server jobs are not selected for cleanup.
- Normally completed server jobs awaiting client outcomes retain the terminal-outcome barrier.
- Regression tests cover all three lifecycle states.