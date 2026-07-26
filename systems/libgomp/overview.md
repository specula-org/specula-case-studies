# libgomp

## Scope

Specula analyzed and tested libgomp's core concurrency runtime, including team barriers, task scheduling, detached-task completion, cancellation, related work-sharing paths, and NVIDIA's proposed flat-barrier implementation.

## Bugs

Specula found 3 new bugs:

- **Fixed:** In NVIDIA's flat-barrier path, cancellation can race with task-assisted completion so that some threads observe cancellation while others pass the barrier normally.
- **Approved:** Fulfilling the last detached task from an external thread can wake barrier waiters without setting `BAR_TASK_PENDING`, leaving them asleep indefinitely.
- The POSIX flat barrier's `gomp_team_barrier_done` clears `BAR_CANCELLED` when advancing the generation, losing cancellation during task completion.
