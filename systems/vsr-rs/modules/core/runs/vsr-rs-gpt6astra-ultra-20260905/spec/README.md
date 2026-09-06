# vsr-rs specification handoff

Generated for source revision `3ac0104a567092139534c9022205d02281a2da41`, following the installed Specula `spec-generation` guide. Category A; fixed membership; whole synchronous handlers, separate durable-view publication and individual output release.

- `base.tla` / `base.cfg`: implementation state machines, authentic transport, client discipline, crash/recovery and independent historical/application observations.
- `MC.tla` / `MC.cfg`: finite fault wrappers, core/structural convergence checks. Cfg operator overrides select each wrapper; `B!Action` preserves access to the original base transition.
- Six `MC_hunt_*.cfg` files: S1 preservation (3 and 5 replicas), S2 logical service, S3 client progress and quiescent recovery (3 and 5 replicas). S4's conforming boundary is explicitly merged into S1; concrete example candidates are outside this core model as the brief requests.
- `brief-coverage.md`: actual cfg-to-brief audit, bounds, temporal premises and limitations.
- `Trace.tla` / `Trace.cfg`: complete captured post-state validation, ordered application events, no silent actions, and required `TraceMatched`.
- `instrumentation-spec.md`: executable schema mapping and precise hooks for the subsequent harness phase.
- `checks/validation.md`: generation checks and their limits; machine-readable commands/results in `checks/validation-results.json`.

Run from this directory. Supply a TLC jar and CommunityModules with `IOUtils`/NDJSON support:

```sh
java -cp "$TLA_JAR:$COMMUNITY_JAR" tla2sany.SANY MC.tla
java -cp "$TLA_JAR:$COMMUNITY_JAR" tlc2.TLC -noGenerateSpecTE -config MC.cfg MC
java -cp "$TLA_JAR:$COMMUNITY_JAR" tlc2.TLC -noGenerateSpecTE -config MC_hunt_scenario1.cfg MC
JSON=../traces/run.ndjson java -cp "$TLA_JAR:$COMMUNITY_JAR" tlc2.TLC -noGenerateSpecTE -config Trace.cfg Trace
```

`python3 checks/run_checks.py` reruns the bounded generation checks. It uses `TLA_JAR` / `COMMUNITY_JAR` when provided, otherwise the pinned local tool paths recorded by the generation run. It does not launch a full exhaustive hunt.

Do not interpret smoke tests as spec convergence against the Rust implementation. The synthetic fixture tests checker wiring and rejection of bad observations; actual Rust traces are the next verification input. Liveness passes at a `BoundHit` boundary are inconclusive; the temporal cfgs do not establish unbounded service progress.

Reference context remains subordinate to pinned source behavior: [VSR Revisited](https://www.cs.princeton.edu/courses/archive/fall19/cos418/papers/vr-revisited.pdf), [recovery correction](https://drkp.net/papers/recovery-tr17.pdf), and [state-transfer analysis](https://jack-vanlightly.com/analyses/2022/12/28/paper-vr-revisited-state-transfer-part-3). The DVC tie choice follows [`Iterator::max_by_key`](https://doc.rust-lang.org/std/iter/trait.Iterator.html#method.max_by_key): the last equal maximum in the ascending BTreeMap traversal.
