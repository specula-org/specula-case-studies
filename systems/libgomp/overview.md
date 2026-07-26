# libgomp

## Scope

Specula analyzed and tested libgomp's core concurrency runtime, including team barriers, task scheduling, detached-task completion, cancellation, related work-sharing paths, and NVIDIA's proposed flat-barrier implementation.

## Bugs

- In stock libgomp, fulfilling the last detached task from an external thread can wake a barrier waiter without setting `BAR_TASK_PENDING`, causing the team to wait forever. This was reported upstream as GCC PR 124620.
- In the proposed flat-barrier implementation, task-assisted barrier completion can overwrite the barrier's cancellation state, causing an assertion failure in checking builds and leaving inconsistent internal state otherwise.
