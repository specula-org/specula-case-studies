# Validation continuation request

The acceptance decision was closed by [validation-controller-decision.md](validation-controller-decision.md). The controller authorized the exact reviewed adapter without a semantic change. The remainder of this document preserves the original Phase 0 request. Current progress is in [validation-status.json](validation-status.json).

This campaign is **INCOMPLETE at Phase 0**. The reviewed Category B trace acceptance contract conflicts with the current instruction to follow every installed workflow step. No model, configuration, oracle, instrumentation, harness, or acceptance adapter was changed. No fresh trace replay, model checking, simulation, build, or guest execution was started.

The controller must resolve the acceptance contract before Phase 1. The existing exact-version reviews remain evidence for the current inputs. They do not by themselves resolve the current prompt's instruction that no workflow step may be overridden.

## Decision needed

The installed [validation-workflow SKILL.md](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/validation-workflow/SKILL.md) delegates to [guide.md](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/validation-workflow/guide.md). Phase 0 requires: "Check `Trace.cfg` has `PROPERTIES TraceMatched` (uncommented). If missing, add it". Phase 1 requires `run_trace_validation_parallel`. The delegated [trace workflow](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/tla-trace-workflow/guide.md) also requires that property.

The reviewed [Trace.cfg](Trace.cfg) instead enables `TraceNoWitness`. [Trace.tla](Trace.tla) defines no `TraceMatched` operator. It searches all permitted per-thread timebox interleavings until it finds one that consumes every event. [instrumentation-spec.md](instrumentation-spec.md) explicitly says that R3 replaces the generic property prerequisite, and the existing [spec-generation review](review-specgen.md) approves that interpretation. The trace sub-skill's [Category B reference](/home/chin39/.codex/plugins/cache/specula/specula-codex/1.2.0/skills/tla-trace-workflow/references/validation.md) also says rejection requires that no interleaving can consume all events. Thus the installation's generic prerequisite and its Category B behavior need an explicit resolution.

Choose one of the following continuations:

1. **Recommended: authorize the exact reviewed Category B adapter for this campaign.** Keep the current specification, enabled safety checks, exact post-state equality, and existential acceptance. Explicitly allow the supplied adapter instead of the generic `TraceMatched` prerequisite and stock parser. No semantic input change is proposed for this option.
2. **Require the stock workflow.** Arrange a reviewed TraceSpec/configuration/tooling correction that preserves acceptance of one complete permitted interleaving, rejection when no witness exists, and all state checks. Preserve old and proposed versions, diff, reason, triggering evidence, reviewed hashes, reviewer identity, and material dispositions before replaying any trace. Merely adding an undefined operator, a tautology, or universal completion of all candidate orders does not resolve this requirement.

The stock handler's `_parse_output` treats "Model checking completed. No error has been found." as success and treats the witness invariant violation as an error. Those outcomes have different meanings for these reviewed inputs:

| Existing search outcome | Reviewed adapter meaning | Stock parser meaning |
|---|---|---|
| TLC exit 12 with only `TraceNoWitness` violated | A complete matching witness exists. | Error. |
| Exhaustive TLC exit 0 with no errors | No matching witness exists. | Success. |
| Timeout, another invariant violation, or execution error | Incomplete or error. | Must not be accepted. |

The current [adapter](generation-checks/validate_trace.py) already implements these distinctions. It uses two workers and a 3 GiB heap with an outer timeout. The stock parallel handler admits up to `min(trace_count, cpu_count)` JVMs, each with `-Xmx4G`, and exposes no concurrency parameter. An unconstrained batch of all 18 traces would also exceed the lane's 4 GiB allocation. Any authorized continuation must keep the combined resource limit.

## Verified Phase 0 evidence

The evidence directory is [phase0-20261005T201613Z](/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output/spec/output/phase0-20261005T201613Z). It freezes the disputed inputs, installed workflow text, tool handlers, existing review evidence and prior witness logs. Its JSON records bind every inspected input and trace by SHA-256.

- The current source HEAD is `0c60537098f4c2949ad2d382aaf499de72263d76`, with tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The existing canonical instrumentation patch passes a reverse-application check. The untracked OSTD logger matches its harness copy. All 30 source/reference hashes in the contracts matched.
- All base/Trace/MC inputs, the instrumentation mapping, modeling brief, harness instructions, 18 trace files and 16 hunting configurations exist. `ValidatePostState(t, e)` uses exact record equality and is not a stub.
- All 35 inputs in runtime attempt `attempt-20261005T165124-821788448` match both their preserved copies and current files. All 16 entries in `harness/evidence/runtime-reviewed.sha256` match. The existing v12 independent review closes R1–R8 for those bytes.
- The latest runtime attempt has 18 Asterinas traces with 1,481 events and all 49 event types. Raw, preprocessed and reported event counts agree. Every preserved serial-log hash matches. All buffers report zero dropped records and all fixtures report zero failures.
- Every guest manifest records two CPUs and ramfs magic `0x858458f6`. C00 records controller CPU 0, holder CPU 1 and contender CPU 0. Its actual intervals overlap in one of four cross-thread pairs, or 25%. Running the unchanged coverage checker as a data audit returned 0 and reproduced the attempt's coverage JSON exactly. This data audit did not invoke TLC.
- C00, C06 and C11 are preserved runtime prefixes. C13 is a completed case. Prior witness logs contain `TraceNoWitness` violations with exactly event-count-plus-one states for all 18 traces. Those are inspected historical logs, not a fresh validation round.
- Existing Linux C01–C05 control logs record Linux 7.2.8 on tmpfs. They do not represent a boot of the archived Linux v6.16.5 source.

The top-level `harness/STATUS.md`, `harness/status.json` and `harness/coverage.json` still describe the earlier v10 run and a pre-v12 memory wait. They are stale relative to the preserved v12 runtime attempt. This request records that discrepancy without overwriting the historical reports or claiming formal convergence.

| Disputed input | SHA-256 |
|---|---|
| `Trace.tla` | `918b7c4afe353cf32e50bc01c598b621d7ffd667b4e8ff835d4ba78716c17abf` |
| `Trace.cfg` | `a3b384f0dd0c4155222692134581790b0f7097fbebb54c160bc24f114398a140` |
| `generation-checks/validate_trace.py` | `944aeb8ea4f6af4ca7070144a006a3451ad3d06f58992a5a922f26464b515f29` |
| `instrumentation-spec.md` | `beeec7c8d523d76299bee5beb9f136919465cffba680d716db95023217581f72` |

## Review gate and continuation

The [shared resource policy](/home/chin39/Documents/play/specula-profile/reports/flock-wait-handoff-2026-10-05/resources.json) requires independent review before rerunning after a semantic correction and says: "Preserve a change/review request and return incomplete to the controller." No proposed semantic revision was installed or self-approved. The controller decision is pending. A changed version must receive a new version-bound independent review before affected verification.

The current controller holds the shared heavy lock and per-run writer lock. This worker did not reacquire either lock or start child pipeline workers. The recorded host memory was 9,737,164 KiB, above the 6 GiB TLC admission threshold and below the 10 GiB build threshold. No new build is justified merely by the stale status document: the exact reviewed v12 runtime evidence already exists.

Once the acceptance decision and any required review are closed, continue this same run with a fresh replay of all 18 traces under the authorized contract. Then run `MC.cfg` for the prescribed 30-minute bound with at most 4 GiB combined heap/off-heap and two workers. Preserve the original configuration bounds. Apply the Case A/B/C and convergence rules, including review before semantic correction reruns. Only after convergence, execute every hunting configuration and its required simulation follow-up, then produce `bug-report.md` and `findings.json`.

Fresh Phase 1, Phase 2, convergence, and bug hunting are `NOT_RUN`. No finding was classified and no no-bugs claim was made. The post-convergence bug report and findings index were not fabricated while their precondition remains unmet.

