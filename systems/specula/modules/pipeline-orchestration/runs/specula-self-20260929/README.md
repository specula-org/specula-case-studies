# Specula pipeline orchestration self-check

The September 29, 2026 self-check examined Specula at `0dc869cfa217e63e7745db1b4f7ff412d55f6848`. This record summarizes 12 reproduced findings from the original report. One false positive is excluded.

| Finding | Status | Reference |
|---|---|---|
| Confirmation verdict can claim a source revision the worker never inspected | Fixed | [PR #172](https://github.com/specula-org/Specula/pull/172) |
| Older confirmation files override a newer legacy report during repair | Confirmed |  |
| A resumed repair loop can exceed the global round cap | Fixed | [PR #173](https://github.com/specula-org/Specula/pull/173) |
| A phase can succeed using an empty or stale artifact | Confirmed |  |
| A scheduler launch exception can produce exit zero with unfinished work | Confirmed |  |
| One finding can invalidate another finding's published repro proof | Confirmed |  |
| A TLC timeout can leave the owner and resource lease live indefinitely | Confirmed |  |
| A detached agent child can outlive phase success and mutate output | Confirmed |  |
| A target name can escape its selected run directory | Confirmed |  |
| Two targets sharing a workspace can claim one another's phase output | Confirmed |  |
| Candidate validation permits an empty list despite model-checking findings | Confirmed |  |
| Later phase checks can accept incomplete outputs | Confirmed |  |

The two linked fixes have merged. The remaining findings are recorded as Confirmed by the project. Status was checked on 2026-10-05.

This is a findings summary. The original run reports and reproduction artifacts remain in the source archive; their hashes are recorded in [provenance.json](provenance.json).
