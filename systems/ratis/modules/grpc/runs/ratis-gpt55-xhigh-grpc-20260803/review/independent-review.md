# Independent review — ratis-grpc

Review date: `2026-08-04`

This run is valuable for spec repair and candidate generation, but it does not
produce a reviewed, externally confirmed Ratis bug.

| Finding | Raw disposition | Reviewed disposition | Notes |
| --- | --- | --- | --- |
| MC-1 | `MASKED` | Masked risk/candidate, not a reproduced external bug | The source-level concern is plausible: a stale `INCONSISTENCY` reply can lower `nextIndex` below a snapshot boundary. The observed run also shows the downstream snapshot retry path restoring progress, so it should not be described as an unmasked reproduced bug. |
| MC-2 | `FALSE POSITIVE` / `PENDING REPAIR` during repair loop | Spec artifact repaired | The original model allowed staging-only restart to recreate `FollowerInfoImpl` and reset progress. The real code removes staging appenders but does not recreate replacement follower info for a staging-only peer. The repair constrained the spec accordingly. |
| CR-1 | `FALSE POSITIVE` | Not reportable | Late gRPC success reply did not produce the modeled bad outcome in the current implementation. |
| CR-4 | `DROPPED` | Not reportable | Not carried forward as a new issue. |

The final repair-loop status is still useful:

- Raw TLC trace validation passed 3/3.
- `MC_hunt_rg4_staging_restart.cfg` completed after the repair with no errors.
- Final hunt output left only the snapshot-race MC-1 as a current violation.

Recommended outward-facing use:

- Do not present this run as finding a confirmed gRPC bug.
- Use it as evidence that the resume/repair workflow can identify and repair an
  over-permissive model transition.
- If MC-1 is mentioned, describe it as a masked candidate and name the snapshot
  retry mask.
