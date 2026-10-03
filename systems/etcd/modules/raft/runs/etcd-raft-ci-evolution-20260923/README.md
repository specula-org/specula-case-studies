# etcd/raft historical CI evolution study

This collection records the 2026-09-12 through 2026-09-23 study of historical Raft revisions. The [version index](provenance/upstream-versions.json) identifies upstream commits; pipeline summaries also contain wrapper-repository commits, which are different identities. The source sequence spans 2019–2023; the retained evolution experiment covers V00–V03.

## Results and limits

- Pipeline V00 reports five reproduced entries and one dropped entry. V01 reports two reproduced, two fixed, two needs-more-information, and one dropped entry. V02 reports two reproduced, three fixed, two needs-more-information, and one dropped entry. Repeated findings across versions are not additional bugs.
- [Bug A](evidence/reproduce-A/out/confirmation.md) is a supplied historical dataset label, reproduced through public RawNode APIs on V01/V02/V03. It is not a novel current-version finding.
- [Bug B exploration](evidence/progress-probe-V03/out/report.md) has a fair-loop V03 model counterexample and a V02 control. Independent implementation reproduction in this continuation remains unfinished.
- The action matrix records 479 code-to-model and 174 model-to-code instances per version, totaling 1,959 comparisons. These are local constructed-state checks, not system equivalence or independent reachable scenarios.
- V02's retained top-level summary says Incomplete despite a populated confirmation report. The overall research acceptance criteria remain incomplete.

## Evidence

- Original [stage report](REPORT-20260923.md) and per-version [pipeline reports](pipeline).
- Frozen and evolved [models](work), [control reports](control), and [frozen inputs](frozen).
- [Final action matrix](evidence/action-framework-final/out/final-results.json), [invariant validation](evidence/inv-evidence/out/report.md), and [progress-driver audit](evidence/progress-probe-V03/out/driver-audit.md).
- [Metadata](run.json) and [.record/files.tsv](.record/files.tsv).

This is a curated research collection, not a complete execution image. Repeated per-case expansions, dependency caches, TLC states, large trace expansions, and nested source checkouts are excluded; canonical models, drivers, compact receipts, reports, and selected native-test evidence remain. Original documents retain historical paths and references to omitted artifacts. No runtime tests were repeated while packaging this collection. Evaluation labels and results must not be supplied as blind model-generation inputs.
