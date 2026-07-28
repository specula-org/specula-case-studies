## Bug Hunting
- [fix-inv] NoConflictingActiveCompactions: exclude `Submitted` from live conflict accounting so the invariant matches the coordinator's validation chokepoint and only flags conflicts after promotion beyond backlog state.
- [fix-spec] WriteOutputSst: require modeled output SST timestamps to be at least the durable submission time so GC cannot delete outputs earlier than the implementation's ULID-based watermark permits.
- [fix-inv] OnlyCurrentOwnerPublishes: narrow the property to the publishing worker's local execution state; another worker may still be asynchronously stopping after reclaim without violating ownership safety.
- [bug] MaybeValidateSubmittedSchedule: after refreshing a remote conflicting `Submitted` entry, the coordinator can promote both the local and remote jobs to `Scheduled` because `validate_compaction()` does not re-run `add_compaction()` overlap checks.

## Result
Converged in 1 rounds. Bug hunting: 1 bug found.

## Repair Round 1
- [fix-spec] `MC_hunt_family1.cfg` / `MC_hunt_family5.cfg`: swap in hunt-specific job presets so family 1 models the confirmed duplicate-L0 scenario and family 5 explores non-conflicting backlog for the capacity hunt.
- [bug] `BoundedRunningClaims`: after the RR-001 reruns, both `MC_hunt_family1.cfg` and `MC_hunt_family5.cfg` now violate the running-compaction bound instead of `NoConflictingActiveCompactions`.
