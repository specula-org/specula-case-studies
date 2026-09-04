# Nanvix process-management follow-up (2026-08-03)

This record preserves a later complete Specula pipeline run against
[`nanvix/nanvix@8a92410b80dd677026ef262f475e1d438f7267b5`](https://github.com/nanvix/nanvix/tree/8a92410b80dd677026ef262f475e1d438f7267b5).
It is supporting evidence for the process-management study and is not a second
set of developer confirmations.

## Generated result

The run produced 13 confirmation entries: six `REPRODUCED`, one `MASKED`, and
six `FALSE POSITIVE`. Its severity report records one Critical, five High, and
one Medium severity-bearing finding. Several reproduced mechanisms overlap the
earlier developer-reviewed run under different internal identifiers.

See:

- [Pipeline summary](pipeline-summary.md)
- [Generated confirmation report](confirmed-bugs.md)
- [Severity report](bug-severity.md)
- [Model-checking report](spec/bug-report.md)
- [Consolidated candidates](spec/candidates.json)
- `confirmation/` for per-finding investigations and verdicts
- `repro/` for archived reproduction sources and selected outputs

## Provenance and limits

- Original run ID: `nanvix-pm-opus48-xhigh-20260803`
- Source revision: `8a92410b80dd677026ef262f475e1d438f7267b5`
- Completed: 2026-08-03 11:00:48 UTC
- Source archive SHA-256:
  `60d9f5ab376106ab44e2c3bbb70e6d16b61c039838a72c1c1c4b073eadd76841`

This is a curated subset of the same verified 1,148-file archive. Runtime
activity streams, resume state, source worktrees, model-checker state, and build
products remain only in the local archive. The generated findings are retained
as internal validation evidence; the 16-entry public count comes from the
developer disposition attached to the earlier run.
