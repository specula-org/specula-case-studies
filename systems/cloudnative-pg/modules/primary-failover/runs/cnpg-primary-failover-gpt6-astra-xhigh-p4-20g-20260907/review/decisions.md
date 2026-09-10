# Reviewed Candidate Dispositions

The reviewed count is **one accepted bug**, CR-4. All five original candidates
were code-review sourced. The model-checking findings index is empty.

| Candidate | Original disposition | Reviewed accounting | Reason |
| --- | --- | --- | --- |
| CR-1 | DROPPED, KNOWN | Excluded | [Issue #11354](https://github.com/cloudnative-pg/cloudnative-pg/issues/11354) already reports starting primary PGDATA before lease acquisition at the same sites. No independent live reproduction was performed after the duplicate pre-filter. |
| CR-2 | DROPPED, KNOWN | Excluded | [Issue #3353](https://github.com/cloudnative-pg/cloudnative-pg/issues/3353) already reports the manager shutdown-timeout mechanism. The additional early-lease-release/data-loss consequence was not reproduced; a provenance test is not a live failure reproduction. |
| CR-3 | REPRODUCED, NEW | Excluded as already reported | [Issue #11114](https://github.com/cloudnative-pg/cloudnative-pg/issues/11114) and [issue #11293](https://github.com/cloudnative-pg/cloudnative-pg/issues/11293) report candidate preselection before the final synchronous acknowledgments. The original brief already cited them. The added PostgreSQL/helper test strengthens evidence but does not establish a new defect or exercise the complete operator/CLI path. |
| CR-4 | REPRODUCED, NEW | Accepted, NEW | A real controller promotes using stale-high quorum data after the live configuration changes, and the writable new primary lacks an acknowledged row. No exact prior report was found in the reviewed search. |
| CR-5 | DROPPED, KNOWN | Excluded | [Issue #11346](https://github.com/cloudnative-pg/cloudnative-pg/issues/11346) already reports the pending-marker reset/transition-guard mechanism. The executed test checks the prior report, not a live failure. |

Excluded does not mean false positive. Known code-review mechanisms do not
contribute new bug discoveries, and untested extensions are not separately
counted.

The original CR-4 Markdown verdict predates the successful final confirmation.
This curated record uses the final JSON, executed test, and matching output;
the older NEEDS MORE INFO verdict and stale error files are not current results.
Original files are retained in the supplied archive without modification.

## Validation Scope

Four final canonical traces pass replay and contain 89 records, including four
bootstrap records. They exercise lease behavior. Operator reconciliation,
promotion, shutdown, WAL acknowledgment, archiving, and synchronous-quorum
publication were not instrumented in those traces.

The archive's action inventory contains 139 distinct model-action names.
Eighteen occur in the canonical traces: 14 installed semantic-hook types plus
four environment/control event types. Thirty semantic-hook types were installed,
of which 18 occur in raw records. These are different denominators; none is a
percentage of implementation branches or business functionality.

The Scenario 4 hunt starts with W=1 and permits one configuration-generation
change. It cannot express the reproduced same-primary W=2 to W=1 transition
after first establishing W=2. More runtime alone cannot fill this scope gap.
Scenario 5 requires at least 401 fairness-cursor advances per round, while its
simulation depth was 100. No liveness proof follows from that search.
