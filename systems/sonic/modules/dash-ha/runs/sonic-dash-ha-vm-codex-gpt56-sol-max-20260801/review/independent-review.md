# Independent review

The original pipeline produced seven candidate dispositions. This review controls the case-study and tracker ledger.

## Accepted

| ID | Ledger | Finding | Evidence |
| --- | --- | --- | --- |
| MC-1 | Known, unfixed | A late DPU acknowledgement regresses an Active scope's acknowledged ASIC role and is republished to the peer. | Reproduced; upstream issue #171. |
| MC-2 | New | Logical Active state installs a vDPU route before the matching ASIC acknowledgement. | Reproduced through the actor and APPL_DB bridge. |
| MC-3 | New | A resent term-1 request overwrites an accepted term 2 and reaches DPU_APPL_DB. | Reproduced through the public SWBus resend path. |
| MC-4 | New | A delayed message from the former peer is accepted after re-pairing and drives a vote using foreign state. | Reproduced through the actor runtime and SWBus. |
| MC-5 | New | Restart rehydration creates a second actionable UUID for one pending DPU operation. | Reproduced; both UUIDs can issue activation commands. |
| MC-7 | Known, unfixed | Vote completion resets the shared retry counter during switchover. | Reproduced; matches PR #145 review discussion. |

## Not counted again

| ID | Disposition | Reason |
| --- | --- | --- |
| MC-6 | Duplicate and masked | It is the same parent-deletion / surviving-child mechanism already present in the SONiC case-study ledger. sairedis rejects the dangerous removal with `SAI_STATUS_OBJECT_IN_USE`, so the claimed hardware corruption is masked. |

The original [confirmed-bugs.md](../confirmed-bugs.md) and [bug-severity.md](../bug-severity.md) remain unchanged as run evidence. Their seven-entry classification is not the deduplicated tracker count.
