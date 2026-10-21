# Spec-generation checks

The P1/P2 revision passed SANY parsing and semantic analysis for `base.tla`, `MC.tla` and `Trace.tla`. All ten MC configurations were rerun. The six standard/protocol searches completed with no enabled invariant violation, no deadlock and zero queued states. Four compatibility searches retained their expected violations. These results cover the documented finite drivers and substrate assumptions. Kernel execution and genuine implementation-trace correspondence remain **NOT_RUN**.

TLC version `2026.07.31.184830` used the supplied Java 21.0.12.1, a 1 GiB heap, 512 MiB fingerprint storage, one worker per hunt/trace and two workers for `MC.cfg`. Runs were sequential, each with a 60-second timeout. Every run finished before its timeout. Metadata is under the workspace's ignored `states/` directory. Thread symmetry and finite request bounds are unchanged.

## Model checks

| Configuration | Distinct states | Depth | Queued | Observed result | Evidence |
|---|---:|---:|---:|---|---|
| [MC.cfg](../MC.cfg) | 40,745 | 157 | 0 | No enabled invariant violation or deadlock. | [TLC log](MC.tlc.log) |
| [MC_hunt_TV1a.cfg](../MC_hunt_TV1a.cfg) | 14 | 14 | 0 | Expected `ReadOnlyAdmissionAfterWrite` counterexample. | [TLC log](MC_hunt_TV1a.tlc.log) |
| [MC_hunt_TV1b.cfg](../MC_hunt_TV1b.cfg) | 22 | 22 | 0 | Expected `ReadOnlyAdmissionNoFalseBusy` counterexample. | [TLC log](MC_hunt_TV1b.tlc.log) |
| [MC_hunt_TV2.cfg](../MC_hunt_TV2.cfg) | 61 | 31 | 1 | Expected `SealRejectedReplacement` counterexample. | [TLC log](MC_hunt_TV2.tlc.log) |
| [MC_hunt_scenario1.cfg](../MC_hunt_scenario1.cfg) | 495 | 14 | 37 | Expected `ReadOnlyAdmissionCompatibility` counterexample. | [TLC log](MC_hunt_scenario1.tlc.log) |
| [MC_hunt_scenario1_protocol.cfg](../MC_hunt_scenario1_protocol.cfg) | 1,674 | 58 | 0 | No enabled invariant violation or deadlock. | [TLC log](MC_hunt_scenario1_protocol.tlc.log) |
| [MC_hunt_scenario2.cfg](../MC_hunt_scenario2.cfg) | 6,466 | 88 | 0 | No enabled invariant violation or deadlock. | [TLC log](MC_hunt_scenario2.tlc.log) |
| [MC_hunt_scenario2_default_seal.cfg](../MC_hunt_scenario2_default_seal.cfg) | 1,984 | 84 | 0 | No enabled invariant violation or deadlock. | [TLC log](MC_hunt_scenario2_default_seal.tlc.log) |
| [MC_hunt_scenario3.cfg](../MC_hunt_scenario3.cfg) | 32,382 | 157 | 0 | No enabled invariant violation or deadlock. | [TLC log](MC_hunt_scenario3.tlc.log) |
| [MC_hunt_scenario4.cfg](../MC_hunt_scenario4.cfg) | 223 | 68 | 0 | No enabled invariant violation or deadlock. | [TLC log](MC_hunt_scenario4.tlc.log) |

P2 adds `MC_hunt_scenario1_protocol.cfg` with the same `AdmissionPlans`, constants and thread symmetry as `MC_hunt_scenario1.cfg`. It enables `SealPublicationAndFreeze` and `RetainedWriteEligibility` without the compatibility predicate, as in the reviewer's reference. Its complete search closes the protocol-coverage gap left by the original hunt's depth-14 compatibility failure. No predicate was removed from an existing configuration or changed in `base.tla`.

P1 removes per-address steps for absent PTEs. This reduces several state counts and schedule depths without changing driver bounds. The scenario-1 protocol run now has 1,674 distinct states at depth 58, compared with the review diagnostic's 1,712 at depth 60 before the cursor fix.

The four compatibility configurations expose the existing TV-1/AST-73 and TV-2/AST-75 mechanisms. Their JSON counterexamples were regenerated: [TV1a.json](TV1a.json), [TV1b.json](TV1b.json), [TV2.json](TV2.json) and [scenario1.json](scenario1.json). Some stop with queued states, and even zero queued states at an invariant failure is not a completed search. Only the six normally completed searches establish exhaustive coverage of their finite schedules.

[model-check-results.json](model-check-results.json) records exact commands, working directories, exit codes, state counts, depths and dispositions. `PASS` for a compatibility run means that its expected named counterexample was observed. It does not mean the compatibility property holds. The unchanged `tlc-traces/` archive contains historical, pre-revision generation artifacts. Current commands use `-noGenerateSpecTE` and the JSON dumps linked above.

## Trace-validator checks

`make-synthetic.py` regenerated the three model-counterexample fixtures, the seal-read fixture, its corrupted copy and the overlapping-thread fixture. It also adapted the reviewer's `source-empty-unmap.ndjson` into [synthetic-source-empty-unmap.ndjson](synthetic-source-empty-unmap.ndjson). That diagnostic's event sequence is preserved. Its old `touched`, `dispatched` and `completed` lists counted the three skipped pages, so the revised fixture sets them to empty and adds the cursor completion's `range=[]`. It still creates and replaces an unfaulted three-page mapping, with zero PTE removals and one cursor completion.

Cursor events now carry the actual returned page range, or `[]` at completion. This distinguishes an update that leaves flags unchanged from completion even when both have `state.ptes=[]`. The wrappers still invoke the full base actions and compare exact post-state records. There are no silent actions.

| Check | Configuration | Expected and observed result | Evidence |
|---|---|---|---|
| good | `Trace.cfg` | Complete replay. | [TLC log](trace-good.tlc.log), [result](trace-good-result.json) |
| bad | `Trace.cfg` | Rejected by `TraceMatched` at `l=2`. | [TLC log](trace-bad.tlc.log), [result](trace-bad-result.json) |
| search-good | `TraceSearch.cfg` | `TraceNotComplete` witness at `l=4` for 3 events. | [TLC log](trace-search-good.tlc.log), [result](trace-search-good-result.json) |
| search-bad | `TraceSearch.cfg` | Rejected by `TraceMatched` at `l=2`. | [TLC log](trace-search-bad.tlc.log), [result](trace-search-bad-result.json) |
| TV1a | `Trace.cfg` | Complete replay. | [TLC log](trace-TV1a.tlc.log), [result](trace-TV1a-result.json) |
| TV1b | `Trace.cfg` | Complete replay. | [TLC log](trace-TV1b.tlc.log), [result](trace-TV1b-result.json) |
| TV2 | `Trace.cfg` | Complete replay. | [TLC log](trace-TV2.tlc.log), [result](trace-TV2-result.json) |
| overlap | `Trace.cfg` | Complete replay. | [TLC log](trace-overlap.tlc.log), [result](trace-overlap-result.json) |
| source-empty-unmap | `Trace.cfg` | Complete replay. | [TLC log](trace-source-empty-unmap.tlc.log), [result](trace-source-empty-unmap-result.json) |
| search-source-empty-unmap | `TraceSearch.cfg` | `TraceNotComplete` witness at `l=32` for 31 events. | [TLC log](trace-search-source-empty-unmap.tlc.log), [result](trace-search-source-empty-unmap-result.json) |

A `TraceNotComplete` invariant violation in `TraceSearch.cfg` is the documented existential acceptance witness. The source-empty-unmap witness consumed all 31 events (`l=32`). A `TraceMatched` violation on the corrupted fixture is the expected rejection, with no acceptance witness. [trace-check-results.json](trace-check-results.json) indexes all ten checks. These are synthetic checks of the specification assembly, not traces collected from Asterinas. Linux differential execution and SMP evidence also remain **NOT_RUN**.

## Reproduce the commands

Run the following from the workspace root. The JSON results contain the expanded command for each individual run. The commands retain the original checks' deadlock policy: MC uses the default **enabled** check, so the task's example `-deadlock` flag is omitted because TLC defines that flag as disabling deadlock checking. Both trace configurations retain `CHECK_DEADLOCK FALSE` and use `TraceMatched` to detect an unconsumed trace.

```sh
JAVA=/nix/store/vymiz4fvnc1s8k19kz2lqvkv3g2k0ys6-openjdk-headless-21.0.12.1+1/bin/java
CP=/home/chin39/Documents/play/Specula/lib/tla2tools.jar:/home/chin39/Documents/play/Specula/lib/CommunityModules-deps.jar
cd spec
for module in base MC Trace; do
    timeout 60s "$JAVA" -cp "$CP" tla2sany.SANY "$module.tla" > "generation-checks/syntax-$module.log" 2>&1
done
for cfg in MC*.cfg; do
    name=${cfg%.cfg}
    workers=1
    if [ "$name" = MC ]; then workers=2; fi
    case "$name" in
        MC_hunt_TV1a) dump=TV1a ;;
        MC_hunt_TV1b) dump=TV1b ;;
        MC_hunt_TV2) dump=TV2 ;;
        MC_hunt_scenario1) dump=scenario1 ;;
        *) dump= ;;
    esac
    set --
    if [ -n "$dump" ]; then
        set -- -dumpTrace json "generation-checks/$dump.json"
    fi
    timeout 60s "$JAVA" -Xmx1g -XX:+UseParallelGC -cp "$CP" tlc2.TLC -workers "$workers" -fpmem 512 -noGenerateSpecTE -metadir "../states/$name" -config "$cfg" "$@" MC.tla > "generation-checks/$name.tlc.log" 2>&1
    # Exit 12 is expected for the four compatibility counterexamples.
    result=$?
    case "$result" in 0|12) ;; *) exit "$result" ;; esac
done
python generation-checks/make-synthetic.py > generation-checks/make-synthetic.log
```

Use this trace command for each row in `trace-check-results.json`, substituting its `name`, `fixture` and `config`. It is the command recorded in each `trace-*-result.json`:

```sh
JSON="generation-checks/$fixture" timeout 60s "$JAVA" -Xmx1g -XX:+UseParallelGC -cp "$CP" tlc2.TLC -workers 1 -fpmem 512 -noGenerateSpecTE -metadir "../states/trace-$name" -config "$config" Trace.tla > "generation-checks/trace-$name.tlc.log" 2>&1
```

Normal matches return 0, `TraceNotComplete` witnesses return 12, and corrupted fixtures return 13 for `TraceMatched`. Inspect the named predicate and final cursor when interpreting a nonzero exit. The commands above produce raw logs and counterexample dumps. The saved result JSON records describe the completed revision runs and must be refreshed if the suite or commands change.

## Coverage and records

From the workspace root, audit the delivered records with:

```sh
python spec/generation-checks/check-revision.py > spec/generation-checks/static-audit.json
git diff --check
```

[static-audit.json](static-audit.json) records the 32 action/wrapper/instrumentation correspondences, brief §5 property enablement, unchanged invariants/drivers/symmetry, source/input/suite identity, and consistency of the logs, result JSON and revision inventory. The parser logs are [syntax-base.log](syntax-base.log), [syntax-MC.log](syntax-MC.log) and [syntax-Trace.log](syntax-Trace.log), with matching result JSON. The [coverage audit](../brief-coverage.md) explains the scenario schedules and limits.

The source checkout remains clean at `0c60537098f4c2949ad2d382aaf499de72263d76`. The brief, analysis and supplied review/diagnostics are unchanged. [manifest.json](manifest.json) pins the inputs and revised suite. [REVISION-2026-10-03.md](../REVISION-2026-10-03.md) ties every changed or added file to P1/P2 and records the six acceptance criteria.
