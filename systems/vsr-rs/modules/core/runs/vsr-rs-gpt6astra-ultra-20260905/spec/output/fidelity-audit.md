# Independent specification fidelity audit

Audit date: 2026-09-05. Source revision: `3ac0104a567092139534c9022205d02281a2da41`.
This records two bounded read-only reviews conducted alongside the validation workflow. The reviews followed the installed validation/checking guides and the checking skill's spec-fidelity checklist. They did not launch TLC or tests and did not change semantic specifications, configurations, the modeling brief, or source code. This document is the only artifact written by the audit.

**Verdict:** no evidence-backed Case A invariant correction or Case B handler-translation correction was identified. No implementation finding was established. This is a focused audit, not proof of equivalence, convergence, or protocol correctness. Counterexamples from the main workflow still require independent classification.

## Handler translation and scope

The audit compared `base.tla` and `MC.tla` with pinned source obtained using `git show HEAD:lib.rs`; the working source contains instrumentation, so its live line numbers differ from the pinned references below.

| Area checked | Pinned source | Specification | Result |
|---|---|---|---|
| Request deduplication, prepare/commit acceptance, distinct cumulative acknowledgements | `lib.rs:646–812` | `base.tla:212–264` | Role/status/view guards, side effects before gap handling, and ordered prefix application match. |
| Same-view transfer and cross-view replacement | `lib.rs:818–894,1095–1121` | `base.tla:203–217,265–292` | Offset checks, retained suffix before catch-up, replacement timing, and Normal-status transition match. |
| View change and log selection | `lib.rs:906–1080` | `base.tla:166–202,294–312` | Quorum gates, synchronous self-recording, last-normal-view/log-length selection, and largest-ID tie behavior match. |
| Recovery | `lib.rs:505–535,1131–1205` | `base.tla:313–336,365–383,454–462` | Dispatch suppression, fresh nonce, distinct responders, persisted-view floor, latest primary state, and application reconstruction match. |
| Application and cached replies | `lib.rs:1310–1376` | `base.tla:122–159` | Table replacement/rebuilding and apply-before-commit/cache/reply ordering match. |
| Client discipline and publication | `lib.rs:14–18,274–375,1467–1475` | `base.tla:402–441,464–502` | Explicit owner assumptions, single outstanding request, distinct lifetime identities, and separate persistence/output publication are retained. |

No missing source suppression guard was identified in these paths. This conclusion excludes the brief's separately assigned example filesystem, transport, startup, nonce-policy, and identity-integration questions.

The six supplied hunt configurations enable the scenario checks listed in `brief-coverage.md`: S1 preservation at three/five replicas; S2 logical requests/application/replies; S3 request progress and quiescent recovery at three/five replicas. This establishes configuration wiring, not execution reachability or completed search coverage.

## Milestones and historical oracles

The actual observations preserve distinct protocol milestones:

- Acceptance records an appended request in `acceptanceHistory` (`base.tla:226–230,388`). Acceptance alone is not an `EmissionCertificates` premise.
- Primary self-acknowledgements are recorded only at `RegisterSelf` sites (`160–164`); a backup acknowledgement captures its prefix when buffered (`99–102`) and enters `ackHistory` when released (`424–431`).
- `EmissionCertificates` counts distinct replica IDs with cumulative acknowledgements at or beyond a slot in the same view (`594–595`). Prefix equality is checked separately, rather than assumed while constructing the certificate (`596–607`).
- Actual received-quorum evidence is retained in `quorumHistory` (`243–258,390`). Application, historical prefixes, and reply observations remain separate (`144–159,393–397,568–591`).

The audit's inference is that this distinction supports the intended oracle: accepted/preparing suffixes may be replaced across views, while protected and executed prefixes retain their positions. Neither reviewed invariant demands that every accepted request keep its initial slot. VSR describes ordered cumulative preparation, execution after quorum acknowledgement, and preservation across view change, while expressly allowing some preparing requests to be displaced. [VSR Revisited, §§4.1–4.3 and 8.1](https://www.cs.princeton.edu/courses/archive/fall19/cos418/papers/vr-revisited.pdf).

`ProtectedPrefixSurvives` also checks support in later eligible logs and every hypothetical eligible quorum's best current log, received-certificate consistency, and preservation of the old applied prefix during installation (`base.tla:602–613`). A violation of its hypothetical `BestCurrent` support clause is an intermediate preservation failure; it must be traced to an implementation-feasible continuation before being described as actual committed-data loss. The audit found no concrete counterexample justifying weakening the clause.

The separation between `view` and `lastNormal`, deferred replacement during catch-up, and status/view restrictions are consistent with the state-transfer failure mechanisms in the referenced analysis. That analysis identifies unsafe early truncation, claiming a newer normal view without synchronized state, and stale transfer/view-start messages overwriting later progress. [Vanlightly, State Transfer part 3](https://jack-vanlightly.com/analyses/2022/12/28/paper-vr-revisited-state-transfer-part-3).

Two assurance qualifications apply:

1. **Redundant identity conjunct.** `PrimaryForView`'s first conjunct (`base.tla:566`) is guaranteed by the `Observe` insertion filter (`398–399`), which records only the arithmetic primary of a view. It is not independent semantic coverage. The second conjunct (`567`) checks substantive historical same-view log compatibility and is not dismissed by this observation.
2. **Missing direct historical-view oracle.** Neither `PrimaryForView` nor `ProtectedPrefixSurvives` directly compares a replica's current operational view against every view-change commitment it historically released. `PublicationOrder` (`562–564`) compares current durable and volatile views, without an independent historical maximum. Michael et al. explain why recovery must preserve earlier view-change promises, including across incarnations. [Recovery paper, §6 and Appendix B.1](https://drkp.net/papers/recovery-tr17.pdf). The pinned source (`lib.rs:517–523,1180–1182`) and model (`base.tla:324–335,454–461`) faithfully implement the persisted floor. Existing action semantics enforce it and downstream prefix checks can detect consequences of a failure. The missing direct oracle is therefore an explicit assurance gap, **not a Case A or Case B finding, and not an implementation defect**. This audit supplies no basis for changing the current model or weakening its existing checks.

## Timing and result interpretation

`MC.tla:31–38` blocks service ticks while any service persistence phase, replica output buffer, or client output buffer is pending. It also enforces message/reply ages measured in global service ticks and bounds relative replica clocks. These are explicit environment choices stronger than the library's untimed public contract; they are not conclusions about the shipped example's scheduler.

`ServiceAssumptions` (`MC.tla:153–160`) requires stabilization, continuing service clocks, owner fairness, and continued failure-budget compliance. The stable core need not initially share a view or contain a Normal primary (`97–107`). Both enabled temporal formulas discharge every behavior that ever reaches `BoundHit` (`129–136,173–174`). Consequently a boundary-reaching behavior is inconclusive, and a finite no-error run does not establish unrestricted service progress.

The generation artifacts inspected for these reviews contained no explicit bound-avoiding, assumption-satisfying infinite service witness. This statement concerns those inspected artifacts; it does not anticipate results produced later by the main validation workflow. Record temporal coverage as limited unless the actual run evidence supports a more specific conclusion. Do not equate declared action/fault availability, a smoke test, or a simulation pass with complete exploration or an unbounded liveness result.

## Reviewed semantic file identities

SHA-256 at audit persistence time:

```text
447085336c6ab1948127bc82c5293ad5fdf16e5235aa210900e6ae15f4d94453  base.tla
82c684326f596d23927a7940dc571b69bf733a6603a71811952f82b03df0c2e4  MC.tla
```
