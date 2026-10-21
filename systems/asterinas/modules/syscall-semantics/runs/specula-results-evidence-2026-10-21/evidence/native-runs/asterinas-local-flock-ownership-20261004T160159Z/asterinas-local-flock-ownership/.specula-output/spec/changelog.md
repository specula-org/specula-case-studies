# Validation changelog

## Round 1 - Initialization

- [evidence] Verified the pinned source, reviewed v12 input hashes, 18 existing runtime traces, and exact post-state checks. The latest attempt contains 1,481 events, covers all 49 actions, and has zero dropped records. C00, C06 and C11 remain runtime prefixes.
- [evidence] The unchanged coverage checker reproduced the latest attempt's coverage result, including C00's 25% cross-thread overlap. The top-level harness status still describes the older v10 attempt.
- [gate] The installed workflow requires `PROPERTIES TraceMatched` and stock trace tools, while the exact reviewed Category B input uses `TraceNoWitness` and an adapter with different success semantics. Preserved the input versions, hashes, tool evidence, prior witness logs and a [controller request](validation-controller-request.md). No semantic correction or dependent verification ran.

## Phase 0 handoff

The first handoff was incomplete pending the controller's acceptance-contract decision. No fresh trace validation, model checking, convergence or bug hunting had run at that point. The controller subsequently authorized continuation below.


## Round 1 - Trace Validation

- [decision] The controller selected the exact reviewed Category B adapter in `validation-controller-decision.md`. All bound input hashes still match. This resumes the same round without a semantic change.
- [pass] All 18 current runtime traces obtained a fresh complete matching witness with the exact reviewed adapter, full base guards and exact post-state equality. No input changed. C00, C06 and C11 remain runtime prefixes. Results and raw logs are in `output/round1-20261005T202037Z`.

## Round 1 - Model Checking

- [time-limit] `MC.cfg` ended with wrapper exit 124 at its 30-minute exploration budget. No invariant violation was reported. The last progress line records 20081186 distinct states, 10460133 queued states and depth 13. These are last-reported counts, not final shutdown totals. General exhaustive convergence is not established.
- [decision] Continue the targeted bounded checks as explicitly directed by `validation-controller-decision.md`, retaining the general result as time-limited. No model, invariant, configuration or trace interpretation changed.

## Round 1 - Targeted Checking

- [bug] `ConversionOracle` fails in C05 after 80 states. Asterinas returns EAGAIN for C because the failed A upgrade retained A SH; the fixed Linux source oracle and the existing Linux control allow C. Classified as a source-mapped Case C candidate. The model correctly preserves the implementation, so no correction was applied. Separate confirmation remains pending.
- [bug] `ConvertersDrain` fails in C06 after 57 concrete states and a stuttering suffix. Both EX requests are parked while both installed SH items remain. The source conflict-before-replacement path and matched C06 prefix support this Case C manifestation. It shares C05's conversion mechanism and will be reported as one finding. No property was weakened.
- [bug] `NoRecursiveListWait` fails in C11 after 34 counterexample states. The final state has B at zero strong references, the outer list guard still owned by t1, and t1 waiting to enter B cleanup with its outer continuation saved. Production Weak/Arc destruction and Mutex paths support Case C. C12 alias/before/after controls exhausted without violations. `FinalReleaseCompletes` has no separate C11 verdict because the safety failure stopped TLC.
- [coverage] All 16 unchanged hunt configurations ran. Thirteen exhausted without violations, and three produced counterexamples representing two mechanisms. Every nonviolating hunt reached depth greater than 25, so the mandatory shallow-BFS simulation condition did not apply. No simulation or semantic correction was needed.

## Result

The controller-authorized bounded execution is complete in one unchanged-spec round. All 18 runtime traces match. Thirteen targeted configurations exhausted without violations, and three produced source-mapped Case C counterexamples representing two findings. General MC ended at its time limit with a nonempty frontier, so exhaustive convergence is not established. No semantic fix was needed or applied. The bug report and findings index are ready for independent validation review; separate confirmation, final classification and repair remain unrun.
