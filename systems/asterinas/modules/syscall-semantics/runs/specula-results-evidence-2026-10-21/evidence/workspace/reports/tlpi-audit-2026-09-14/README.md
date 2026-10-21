# TLPI v2 intake and test preparation

Upstream follow-up: [the 2026-09-14 cross-check](../upstream-dedup-2026-09-14/README.md)
found TLPI F16 / AST-62 directly covered by issue #3823 and merged PR #3824
at upstream `bc12195df4acfb1fc4ae968cf7acf9333ed83435`. The attachment's
`a5449e62b` source pin and all target NOT_RUN states remain unchanged.
Other direct/partial matches, including F01 and F20, are recorded there.

Prepared 2026-09-14. Latest user instruction: organize the attachment first;
**do not execute its tests**. This directory contains the preserved input,
AST mapping, source identity checks, and a proposed batch plan. All new Linux
and Asterinas executions remain NOT_RUN; no build or imported tool ran.

## Input and source identity

- Original [archive](inputs/asterinas_tlpi_audit_v2.zip), SHA-256 `0c70d01cb9b8120e848fe8956bf9d594a7b07dc820a5b145e9ac9f5ceec55e07`.
- [Extracted package](package/README.md), unchanged; all 352 entries in its
  SHA256SUMS verified. The archive remains the original byte-for-byte input.
- Attachment pin: `a5449e62b0a5a0affccb6087ea3543a2fdf66052`.
- Authoritative checkout observed at `d007cbb623bde58c6692feb6e3257ca1490438fd`. All 38 indexed source files
  and the extra personality candidate file match that pin exactly;
  [source-check.json](source-check.json) records each content hash.
  This is source identity evidence, not validation of every source claim.
- The original 205 Linux PASS records, logs, and input hashes are internally
  consistent. They belong to the attachment's previous ELF, which is absent
  from the archive. They are not newly executed controls or Asterinas results.

## Integration

- [Finding map](finding-map.md) / [JSON](finding-map.json): all F01..F26 and C01.
- F17 maps to existing **AST-19**. F02 is related to AST-03, with separate
  datagram and pipe tracking entries. F06/F18 share **AST-49**.
- New **AST-42..71**: 28 SOURCE LEAD entries and two explicit UNSUPPORTED
  capability gaps. Grouped reports are split only where the contracts or
  failure paths differ; no candidate was promoted to a reproduced bug.
- [Test plan](test-plan.md) / [case-plan.json](case-plan.json): six batches,
  all 41 supplied cases, six negative controls, exact per-case AST mapping.
- F05/F07/F08 and C01 lack complete runtime cases. F03's attached APPEND case
  does not cover AST-45's SYNC/DSYNC/NOWAIT effects.
- No upstream issue/PR novelty refresh, source patch, kernel build, guest
  launch, or change to historical Specula runs was performed.

The [intake receipt](intake.json) separates saved input evidence from this
turn's actions. The [unified catalog](../asterinas-bug-findings-2026-08/README.md#unified-register)
owns stable numbering and evidence status. The package's own instructions
remain imported reference material.
