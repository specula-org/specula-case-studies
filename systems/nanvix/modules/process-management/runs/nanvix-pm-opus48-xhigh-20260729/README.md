# Nanvix process-management run (2026-07-29)

This record preserves the reviewable evidence from the Specula run against
[`nanvix/nanvix@a47b0904c20dbe92ede704eb5ee431a7d29fec46`](https://github.com/nanvix/nanvix/tree/a47b0904c20dbe92ede704eb5ee431a7d29fec46).
It is the primary source run for the developer-reviewed PM-01 through PM-18
disposition.

## Reviewed result

The [developer disposition](review/developer-disposition.md) accepts 16 bug
mechanisms and rejects two. The source screenshot uses `Confirmed` for 11 and
`Likely` for five; both labels are approvals for this review. PM-13 and PM-18
are excluded.

The generated run had 22 internal candidates: 17 `REPRODUCED`, one
`ENV_LIMITED`, one `PENDING REPAIR`, two `MASKED`, and one `FALSE POSITIVE`.
Only the 18 entries mapped in the developer disposition belong to the external
review. MC-5, MC-10b, CR-8, and CR-9 were not part of that 18-entry decision and
are not added to its count.

## Navigation

- [Developer disposition and source mapping](review/developer-disposition.md)
- [Generated confirmation report](confirmed-bugs.md)
- [Model-checking report](spec/bug-report.md)
- [Consolidated candidates](spec/candidates.json)
- [Analysis report](analysis-report.md)
- [Modeling brief](modeling-brief.md)
- `confirmation/` contains per-finding investigations and generated verdicts.
- `repro/` contains the archived reproduction sources, scripts, and selected
  outputs.

## Provenance and limits

- Original run ID: `nanvix-pm-opus48-xhigh-20260729`
- Source revision: `a47b0904c20dbe92ede704eb5ee431a7d29fec46`
- Source archive SHA-256:
  `60d9f5ab376106ab44e2c3bbb70e6d16b61c039838a72c1c1c4b073eadd76841`
- Developer screenshot SHA-256:
  `7909b6052442f86aed85fa90592605f3f94801774c4e990464446af7b6e82bf8`

The preserved `pipeline-summary.md` was generated at run startup and still
reports later phases as missing, although the archive contains their completed
artifacts. It is retained byte-for-byte as provenance, not used as the final
status source.

This is a curated, navigable subset of the 1,148-file source archive. Agent
activity streams, resume state, source worktrees, model-checker state
directories, and build products remain in the verified local archive and are
not duplicated here. Reproduction scripts may require the archived source
revision and the Nanvix build environment; no new rerun was performed during
curation.
