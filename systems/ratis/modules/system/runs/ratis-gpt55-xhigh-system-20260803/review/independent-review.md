# Independent review — ratis-system

Review date: `2026-08-04`

This run is useful, but its raw Phase 4 summary should not be copied
unfiltered. The reviewed, externally valuable results are MC-1, MC-3, and MC-4.

| Finding | Raw disposition | Reviewed disposition | Notes |
| --- | --- | --- | --- |
| MC-1 | `REPRODUCED` | `REPRODUCED`, Critical | Strong result. The run shows a stale old-term append success after a higher-term vote, followed by client-visible success for an entry absent from the next leader. |
| MC-2 | `REPRODUCED` | Component-level candidate, not promoted | The component behavior is plausible, but the available evidence is still too close to injected in-flight state and does not establish a strong external-consumer failure. |
| MC-3 | `REPRODUCED` | `REPRODUCED`, High | Strong result. The run shows higher-term metadata persistence failure, later same-term acceptance, restart, and a same-term vote from stale durable metadata. |
| MC-4 | `REPRODUCED` | `REPRODUCED`, High | Strong enough with disclosure. The test uses a timing hook to hold queue processing, then demonstrates type-only `STEP_DOWN` dedup dropping a higher term and a real `requestVote(term=2)` consuming the stale term. |
| CR-3 / CR-6 | `FALSE POSITIVE` | Not reportable | Current code has guards or no reproduced consumer error. |
| CR-4 / CR-5 | `DROPPED` | Not reportable | These were not carried forward as new confirmed issues. |

Important caveat: model checking in this run is not an exhaustive proof of the
full Ratis state space. The final main `MC.cfg` check is a 30-minute convergence
recheck, not a completed full-state search. The run is best used as a source of
confirmed bug reports plus supporting modeling artifacts, not as a claim that no
other Ratis bugs exist.

Recommended outward-facing use:

- Report MC-1, MC-3, and MC-4 as reproduced findings.
- Mention MC-4's timing-hook nature explicitly.
- Do not count MC-2 as a confirmed external bug without a stronger reproduction.
