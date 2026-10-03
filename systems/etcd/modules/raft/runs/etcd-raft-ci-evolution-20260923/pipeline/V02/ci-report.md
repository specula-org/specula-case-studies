# Incremental CI report — etcd-raft V02

The source-aligned model, trace harness, and update views were regenerated and
validated. Eleven fresh traces (5,778 events), six complete update witnesses,
three broad BFS campaigns, six update simulations, and clean uninstrumented Go
tests are recorded in the [incremental validation report](incremental-validation.md).

The result contains two reproduced bugs: persistent CR-3 and pre-existing MC-2.
The update fixes prior MC-1 by restoring the complete joint configuration.
Authoritative dispositions and confirmation evidence are in
[confirmed-bugs.md](confirmed-bugs.md); impact classification is in
[bug-severity.md](bug-severity.md).

Model checking is bounded rather than exhaustive. Five dedicated BFS hunts
ended on run-local state-storage exhaustion after partial exploration; exact
tasks and counters are retained in the [validation limits](spec/remaining-validation-work.md).

