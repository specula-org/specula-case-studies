# Generation decisions

Source: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`, verified locally on 2026-09-14.
Category A: asynchronous server/site commands with explicit local thread boundaries.
Method: user-selected spec-generation/SKILL.md and its full guide/references; single agent, sequential phases.

Selected implementation: ListResourceManager with gpu IDs [0,1], 30 cleanup ticks,
ListResourceConsumer and default local process launchers; cooperative connected
sites, valid one-unit requests, server resources treated as sufficient.
Default policy: max_jobs=2, min_sites=1, required site-1, non-strict start replies.
The suite also supplies max_jobs=1 and strict/min_sites=2 variants.

Keep resource-manager critical sections atomic; split consumption, environment
copy, spawn, handle attachment, dispatch, waiter installation and rollback.
Keep stored status reads/writes separate from runner and scheduler map mutations.
Use explicit command/reply identity (job, attempt, site, operation). A timeout
closes its waiter; it does not retract an executing command. No fabricated START
retries for a running job and no fabricated cross-job lifecycle events.

Model time with explicit reservation cleanup scan ticks plus untimed deadline
crossings. Reservation TTL is decremented by the RM scan; allocation removes
its token from the reservation map. Trace wrappers check measured elapsed time
at deadline boundaries. Relative timing remains an overapproximation requiring
feasibility review; outcome/archival deadlines are separate from physical exit. Scenario 5's admission-exception
baseline is known #5191 context; service-death extensions remain TV-2/TV-3 first.

#5191 was freshly retrieved via GitHub REST on 2026-09-14: open, unmerged,
head 27ecde2ab85b38734072b90128dc5dc2e8390882. The PR body, all 3 issue comments,
9 review comments and 7 reviews are saved in pr5191-*.json. The expiry/tradeoff
comment distinguishes bounded reservation retention from running allocations.
Proposed cleanup/cancel-ack/retry changes are not imported into the pinned model.
