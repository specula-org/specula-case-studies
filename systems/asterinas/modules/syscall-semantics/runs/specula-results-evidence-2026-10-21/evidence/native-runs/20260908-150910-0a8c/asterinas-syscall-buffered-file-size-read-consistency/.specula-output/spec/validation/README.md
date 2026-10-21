# Generation-time validation

These checks validate the generated artifacts. They do not establish agreement with a running Asterinas kernel or confirm a bug.

| Check | Observed result |
|---|---|
| Source identity | All seven requested anchors match `604948581512d83734377974d4c34adb4530f2d7`; [hash receipt](source-anchors.json). |
| SANY | base.tla, MC.tla and Trace.tla parsed and passed semantic analysis. |
| Variable assignment validation | No missing or duplicate assignments in base.tla; [VAV log](vav.log). |
| Config loading | All 43 MC configs initialized with one depth-1 simulation. This checks constants and admission, not the hunting state space. |
| Ramfs structural run | MC.cfg: 8,131 distinct states, depth 32, no errors. |
| Ext2 structural run | MC_converge_ext2.cfg: 4,967 distinct states, depth 35, no errors. |
| ExFAT structural run | MC_converge_exfat.cfg: 5,665 distinct states, depth 35, no errors. |
| Synthetic read replay | 11 distinct states; TraceMatched satisfied. |
| Synthetic shrink/overlap replay | 29 distinct states; TraceMatched satisfied. This hand-authored source schedule deliberately allows K=2 and D=0. It is not kernel evidence. |
| Negative replay controls | Independent changes to K, D, destination tags, C and cache ownership each produced exit 13: `Temporal property TraceMatched was violated.` |
| Existential witness mode | Valid overlap trace: exit 12, TraceNotComplete violation at full consumption. Tampered capacity: exit 0 after exhaustive search, no complete witness. |
| Preprocessing | Preserved all 196 pairwise interval-order comparisons and payloads; rejected a reversed interval. The compressed trace also replayed successfully. |
| Coverage audit | 40 hunt cfgs; all 11 brief safety predicates enabled in at least one; all 42 base action/event mappings present. |

[results.json](results.json) records commands, exit statuses, log tails and hashes of the checked modules. [artifact-audit.json](artifact-audit.json) records the final required-file/action/config checks. [cfg-audit.json](cfg-audit.json) records every actual cfg's constants and active invariants.

The installed MCP syntax helper initially could not find Java in PATH. Checks used the existing JDK directly; no dependency installation or source change was needed:

```sh
SPECULA_ROOT=/home/chin39/Documents/play/Specula
SPECULA_JAVA=/nix/store/1slz0vmmgsd7p6i4c0jaywkpw56wl2yg-openjdk-21.0.12+8/bin/java
"$SPECULA_JAVA" -cp "$SPECULA_ROOT/lib/tla2tools.jar:$SPECULA_ROOT/lib/CommunityModules-deps.jar" tla2sany.SANY Trace.tla
"$SPECULA_JAVA" -Xmx512m -XX:+UseParallelGC -cp "$SPECULA_ROOT/lib/tla2tools.jar" tlc2.TLC -noGenerateSpecTE -workers 1 -config MC.cfg MC.tla
JSON=validation/synthetic-read.ndjson "$SPECULA_JAVA" -Xmx512m -XX:+UseParallelGC -cp "$SPECULA_ROOT/lib/tla2tools.jar:$SPECULA_ROOT/lib/CommunityModules-deps.jar" tlc2.TLC -noGenerateSpecTE -workers 1 -config Trace.cfg Trace.tla
```

Run these commands from spec/. TLC version: `2026.07.31.184830`, revision `30cc360`; OpenJDK 21.0.12. All synthetic inputs are labeled in their filenames and can be rebuilt with [make_synthetic_traces.py](make_synthetic_traces.py).

Pending: real kernel instrumentation and per-thread traces, source/model convergence using those traces, and subsequent targeted hunt execution. The TV fixtures and operation-specific Linux/backend comparisons also need guest evidence. None of the generation-time passes supplies those results.
