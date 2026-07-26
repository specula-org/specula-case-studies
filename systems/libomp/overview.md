# libomp

## Scope

Specula analyzed and tested libomp's OpenMP runtime, including team barrier algorithms, task-team lifecycle, task scheduling and stealing, detached-task completion, hidden helper tasks, and cancellation.

## Bugs

Specula found 1 new bug:

- A proxy task can be re-enqueued before its incomplete-child count is decremented, allowing all threads to finish and deactivate the task team while the proxy remains queued.
