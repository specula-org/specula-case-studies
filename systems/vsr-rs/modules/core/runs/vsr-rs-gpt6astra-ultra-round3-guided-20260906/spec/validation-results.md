# Spec generation validation

Source revision: `3ac0104a567092139534c9022205d02281a2da41`. All requested
files and seven scenario hunt cfgs are present. The source checkout was read
only; preexisting untracked local metadata was preserved. No Rust simulator run,
source patch, bug-fix commit, or external write was performed.

| Check | Result and scope |
|---|---|
| SANY: base, MC, Trace | All parse and semantically resolve, including Json/IOUtils. |
| Config assembly | All nine `MC*.cfg` files load and initialize. One-step checks validate wiring only. |
| Brief coverage | All seven brief §5 Safety properties are defined and enabled in one or more actual hunt cfgs; all five scenarios and MC-1 through MC-5 have targeting setups. `validation/coverage.json` contains the parsed cfgs. |
| `MC_smoke.cfg` exhaustive check | Passed: 409 generated, 237 distinct states, depth 18, queue empty. One request, no tick/crash/loss/retry injection; this is only the tiny normal-case assembly model. |
| S3 random execution check | 100 TLC simulation traces, depth limit 250, seed 20260906, 53,354 generated states; no enabled invariant failure or evaluation error. Not exhaustive; it does not establish that every requested mixed-view/rolling combination occurred. |
| S5 minority random execution check | 20 TLC simulation traces, depth limit 250, seed 20260906, 2,448 generated states; no reported failure. This is a finite execution/temporal-wiring check, not a liveness proof. |
| S5 recovery random execution check | 20 TLC simulation traces, depth limit 250, seed 20260906, 5,965 generated states; no reported failure. Same limits apply. |
| Synthetic trace positive | 13 events through Put replication, primary commit and accepted client reply; TraceMatched passes, 13 distinct states. This fixture is hand-constructed engine evidence, not implementation conformance evidence. |
| Synthetic trace negatives | Three variants are rejected with TraceMatched violations: changed post-state log value, changed reply payload, omitted persist event. No checks were removed to accept a fixture. |
| Existing EOF byte evidence | Rechecked stored bytes: the 2,613,675-byte received frame is a strict prefix of the 16,777,242-byte encoder frame, with no newline. Final value is 2,613,649 / 16,777,216 bytes. Hashes and input paths are in input-provenance.json. This rechecks supplied evidence; it does not rerun the socket/process experiment. |

Raw logs are in `validation/`. `validation/assembly-results.json` records parser/config/positive-negative check outcomes. `artifact-manifest.json` binds the final deliverables to SHA-256 hashes.

## Running

Use a TLC jar that includes Json and put CommunityModules-deps.jar on the classpath for IOUtils. The jar paths below were available during generation; substitute matching local paths if relocating these artifacts.

```sh
TLA_JAR=/home/ubuntu/Specula-incremental-skill-canary-20260901/cases/051-nuraft-core-step02/attempt-001/lib/tla2tools.jar
COMMUNITY_JAR=/home/ubuntu/Specula-incremental-skill-canary-20260901/cases/051-nuraft-core-step02/attempt-001/lib/CommunityModules-deps.jar
python3 validation/check_generated.py --tla-jar "$TLA_JAR" --community-jar "$COMMUNITY_JAR"
java -Xmx2g -XX:+UseParallelGC -Djava.io.tmpdir="$PWD/validation/tmp" \
  -cp "$TLA_JAR:$COMMUNITY_JAR" tlc2.TLC -workers 1 \
  -metadir validation/states-smoke -config MC_smoke.cfg MC
JSON=../traces/trace.ndjson java -Xmx2g -XX:+UseParallelGC \
  -Djava.io.tmpdir="$PWD/validation/tmp" -cp "$TLA_JAR:$COMMUNITY_JAR" \
  tlc2.TLC -workers 1 -metadir validation/states-trace -config Trace.cfg Trace
```

Run from `spec/`. Replace MC_smoke.cfg with MC.cfg for convergence or the appropriate MC_hunt cfg after implementation-trace convergence. The base.cfg describes unbounded behavior and is not an exhaustive-search budget. No default implementation trace is fabricated: the next harness-generation phase must write real traces in `../traces/` according to instrumentation-spec.md.

## Interpretation limits

This completes spec generation, not the later trace/model convergence loop or independent confirmation of a new defect. Broad scenario hunts and full liveness graphs have **not** been exhausted. S1 composes only the already evidenced Prepare.Put EOF mechanism. Core safety assumptions, the narrower installation-history observer, finite workload, set-message projection and synchronous stable timing are detailed in brief-coverage.md. A bounded pass, timeout, unmet coverage probe, or LivenessBoundsNotReached alarm is coverage information, not a maintainer-actionable bug.

## Phase 3 validation outcome — 2026-09-06

Fresh trace validation passed 7/7. Unchanged MC.cfg reached the mandated 30-minute deadline with an unexplored queue: **INCOMPLETE, NOT CONVERGED**. Hunting was not started. See [bug-report.md](bug-report.md) and [validation-status.json](validation-status.json); the earlier generation/smoke results above do not satisfy this convergence gate.
