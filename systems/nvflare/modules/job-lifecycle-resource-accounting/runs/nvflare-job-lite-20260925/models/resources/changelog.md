# Resource-ownership model changelog (models/resources)

## Model versions
- v1: base.tla as checked. One fidelity edit before the first TLC run: removed an extra `okc = {}` clause from
  the NO_RESOURCE / deploy-abort conditions and added `ASSUME MinSites >= 1` (the implementation's conditions are
  `num_sites_ok < job.min_sites` and `job.min_sites and num_ok_sites < job.min_sites`; with min_sites >= 1 the two
  forms coincide).

## Fault assumptions
- Faults bounded in MC.tla: CHECK reply timeouts (late CHECK processing allowed), runner `continue` after admin
  abort (not SUBMITTED / not DISPATCHED), partial client deploy / server deploy failure, SJ launch failure, START
  reply timeouts (late START allowed), reservation expiry while still in use (slow deploy), client launcher failure.
- Not modeled as reachable: removal of a deployed app directory between deploy and START (only via the disabled
  delete_workspace command or the uncalled JobRunner._delete_run) and a second START for an already started job
  (the runner only schedules SUBMITTED jobs). ClientStartAppEarlyReturn is modeled with its real guards; TLC shows it
  is never enabled under the modeled operations.

## Results
- mc_1: Jobs {j1,j2}, Clients {c1,c2}, K=1, MinSites 1, MaxAttempts 2, MaxJobs 2, all faults <= 1.
  12,467,043 distinct states, depth 49, complete, no violation of ResourceConservation, NoOverAllocation,
  AllocationOwned.
- Diagnostics (by-design, expiry-bounded):
  - hunt_ReservationTracked_1: a CHECK reply times out -> NO_RESOURCE -> the late CHECK reserves a unit nobody
    cancels (expires after expiration_period).
  - hunt_NoRejectionByLeftoverReservation_1 / hunt_leftover_noCT_1 / _noSkip_1 / _noSkip_noDF_1: a later job's
    CHECK is rejected while a leftover reservation from (a) a timed-out CHECK, (b) the runner's `continue` after an
    abort, (c) the except path after a deploy failure, or (d) a timed-out START holds the unit.
