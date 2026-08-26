# Solr Operator broad prompt run

## Reviewed result

The cross-run independent review retains six reportable mechanisms: five
`REPRODUCED` bugs and one `ENV_LIMITED` finding. This full run produced three of
the final reproduced verdicts directly; the
[`gpt-5.5` supplement](../solr-broad-prompt-v2-repro55-20260825/README.md)
completed confirmation for the leader-eligibility and generated-BasicAuth
findings, and the earlier [`solr-0`](../solr-0/README.md) run contributes the
scale-down `REPLACENODE` finding.

Read [independent-review.md](review/independent-review.md) for the stable ledger
and evidence levels.

## Provenance

- Run ID: `solr-broad-prompt-v2-20260824b`
- Created: `2026-08-24T12:45:13Z`
- Agent/model: Codex / `gpt-5.6-sol`, high effort
- Target source: [`apache/solr-operator@ed5c5c7`](https://github.com/apache/solr-operator/tree/ed5c5c7d28a4c1189d19f581259e05385c0d4b20)
- Reviews and confirmation debate: enabled

## Included evidence

This curated record includes the blind target guidance, modeling brief, source
analysis, base/MC/trace specifications, focused configurations and
counterexamples, generated traces and harness, inter-phase reviews, the stable
independent review, and the six public reproduction assets. Raw agent
transcripts and confirmation worktrees are excluded; the supplement records
the authoritative final disposition for MC-1 and MC-5.

The spec-generation and validation reviews found abstraction defects and a
time-bounded standard MC run. Those limits are retained in the archive. The
public findings rest on subsequent code-level confirmation, not on treating the
standard model-checking timeout as an exhaustive pass.

## Reproduction

Use a clean checkout at the target commit and run:

```bash
./repro/run_all.sh /path/to/solr-operator
```

The runner verifies the source commit, creates a temporary source snapshot,
runs all six public reproductions with timeouts, and removes temporary files.
The cross-namespace exporter test needs envtest assets; if they are absent, the
runner uses the repository's pinned setup targets to install them inside the
temporary checkout.
