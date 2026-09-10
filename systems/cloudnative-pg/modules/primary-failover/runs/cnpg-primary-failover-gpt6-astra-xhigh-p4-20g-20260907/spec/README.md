# Model and Trace Evidence

These are the archived specifications, not a repaired model for CR-4.

- [Base model](base.tla), [MC wrapper](MC.tla), and [Trace wrapper](Trace.tla)
- [Model-checking findings](findings.json): empty
- [Broad BFS summary](output/MC_round1_summary.json)
- [Focused BFS summaries](output/hunt-bfs-summary.json)
- [Simulation summaries](output/hunt-simulation-summary.json)
- [Action inventory](action-map.json) and [observed action counts](output/implementation-trace-action-counts.json)

The six BFS runs stopped with unexplored queues, at depths 6 to 11. Five
simulations used depth 100 and 30-minute budgets. These are incomplete searches,
not safety or liveness proofs.

The four [canonical traces](../traces/) contain 89 records and validate the
exercised lease transitions only. They do not demonstrate conformance of the
CR-4 quorum/configuration/failover path. See the [review ledger](../review/decisions.md)
for the action-count denominators and missing configuration transition.

## Replay Existing Traces

Requirements: Java, GNU timeout, tla2tools.jar, and CommunityModules-deps.jar.
Set both jar variables to absolute paths. From this directory:

```sh
export TLC_JAR=/absolute/path/to/tla2tools.jar
export COMMUNITY_JAR=/absolute/path/to/CommunityModules-deps.jar
(
  for trace in ../traces/*.ndjson; do
    JSON="$(realpath "$trace")" timeout 60s java -Xmx512m -XX:+UseParallelGC \
      -cp "$COMMUNITY_JAR:$TLC_JAR" tlc2.TLC \
      -config Trace.cfg -workers 1 Trace.tla || exit "$?"
  done
)
```

Keep TraceMatched and the exact post-state checks enabled. Replaying archived
traces does not recollect implementation traces or reproduce CR-4.
