# Spec Generation Review: asterinas-memfd-seal-mapping-admission

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All four scenarios have corresponding state, actions and executable workloads. Admission controls, overlapping sealing, split/merge/revocation and operation-specific failures are represented. Bounds and exclusions are documented. |
| Action Design | 5/5 | The 32 actions preserve the source's seal-check/RMW, denial/publication, duplicate/drop and synchronization/release boundaries. Cursor actions now skip absent entries and distinguish returned ranges from completion. |
| Source Annotations | 4/5 | Operational actions and substantive branches cite source locations. Some input, local-state and structural definitions still have only broad file or brief references. See the nonblocking issue below. |
| Invariant Coverage | 5/5 | Every brief §5 obligation is enabled in a hunt configuration. Scenario 1 now has a separate protocol configuration. TV-1a, TV-1b and TV-2 retain independent compatibility checks. |
| MC Spec Structure | 5/5 | Finite scripts bound external requests without truncating internal steps. Thread symmetry is valid for both role assignments. Omitting a pruning constraint or lossy view is justified. No injected faults or unsupported kernel progress claims are introduced. |
| Trace Spec Design | 5/5 | All wrappers call complete base actions and require exact post-state records. There are no silent actions. Per-thread timeboxes, replay fairness and the separate existential search configuration have explicit semantics. |
| Instrumentation Mapping | 5/5 | There are 32 matching base actions, wrappers and mapping rows. The handoff specifies capture timing, cursor ranges, raw results, RMW observations and stable ownership identities without adding synchronization. |
| Logical Correctness | 5/5 | All three modules pass SANY. Independent finite exploration found no protocol violation or deadlock. No tautological contract, impossible required path or temporal-property typo was identified within the documented scope. Known compatibility failures remain observable. |

## Overall: 39/40

Reviewed against source commit `0c60537098f4c2949ad2d382aaf499de72263d76`, including the implementation paths cited by the brief and the saved Linux v6.18 oracle sources. The review also inspected every hunt configuration, `TraceSearch.cfg`, the coverage audit and the generation evidence. All 22 suite hashes and both input hashes matched the generation manifest. The source checkout was clean.

Independent diagnostics are preserved in [output/specgen-review-20261003T152846Z](output/specgen-review-20261003T152846Z/results.json). They use copies of the submitted modules. The [diagnostic protocol configuration](output/specgen-review-20261003T152846Z/ReviewAll.cfg) adds `RetainedWriteEligibility`, `RevocationBeforeOwnerRelease` and `ProtectionPrefixEffects` to the standard configuration, retaining its structural checks, seal invariant, symmetry and complete `AllPlans` driver.

| Independent check | Observed result |
|-------------------|-----------------|
| SANY for `base`, `MC` and `Trace` | All passed parsing and semantic analysis. |
| All plans with all protocol predicates | 40,745 distinct states, depth 157, zero queued states, no invariant violation or deadlock. |
| Dedicated TV-1a, TV-1b and TV-2 hunts | Respectively violated `ReadOnlyAdmissionAfterWrite`, `ReadOnlyAdmissionNoFalseBusy` and `SealRejectedReplacement`, as expected. |
| Unfaulted three-page replacement trace | Complete replay with zero PTE removals and one cursor-completion event. Existential search produced a `TraceNotComplete` witness at `l=32` for 31 events. |
| Overlapping-thread synthetic trace | Complete replay. |
| Corrupted seal-state synthetic trace | Rejected by `TraceMatched` at `l=2`. |

The compatibility counterexamples preserve the brief's existing TV-1/AST-73 and TV-2/AST-75 attribution. They are neither newly discovered defects nor evidence that those compatibility properties hold.

## Issues Found

- **[P3, nonblocking] Complete the source annotations for derived definitions.** In [base.tla](base.tla), lines 30–64 introduce request validation and local state with broad syscall-file and scenario references. Lines 532–553 introduce identity and accounting predicates with a brief reference rather than exact implementation locations. The corresponding operational actions are annotated, so this does not prevent reviewing their behavior. Add precise references for source-derived constraints and explicitly identify purely mathematical or ghost definitions. This is the remaining gap against the checklist's requirement that every logic block cite `file:line`.

- **Previous P1 is resolved.** `CursorUnmap` and `CursorProtect` now select only existing PTEs (`base.tla:370–391`). Their wrappers validate the returned range (`Trace.tla:199–216`), and the instrumentation distinguishes cursor completion from an unchanged protection update (`instrumentation-spec.md:31,94–95`). This matches `take_next`/`protect_next` skipping in `ostd/src/mm/page_table/cursor/mod.rs:484–564` and the caller loop exits. The independent unfaulted-replacement replay and complete-path witness confirm that the previously rejected event sequence is now accepted.

- **Previous P2 is resolved.** [MC_hunt_scenario1_protocol.cfg](MC_hunt_scenario1_protocol.cfg) checks the same admission plans without the expected compatibility predicate. Its saved completed search covers 1,674 distinct states to depth 58. The independent all-plan protocol run also completes. The original compatibility configuration and all three dedicated TV configurations remain intact, so expected failures no longer prevent completing the protocol obligation.

No blocking correctness or scenario-coverage issue remains in this revision. The previous review is preserved in [previous-review-specgen.md](output/specgen-review-20261003T152846Z/previous-review-specgen.md).

`Trace.cfg` checks universal replay completion. For Category B correspondence, use the documented `TraceSearch.cfg` interpretation: a violation specifically of `TraceNotComplete`, after consuming every event, is an existential matching witness. A blocked speculative ordering alone does not establish an implementation defect. The independent trace checks above are synthetic and do not establish kernel correspondence.

The finite workloads cover two threads and three address pages, not arbitrary syscall histories. In particular, they do not exercise a successful address remap after retirement. The model represents generation-aware reuse, but that case remains a useful harness follow-up. Ordinary TLB completion is an explicit substrate assumption. Kernel execution, Linux differential results and genuine SMP implementation-trace validation remain **NOT_RUN**. The submitted specifications and source were left unchanged.

## Verdict: PASS
