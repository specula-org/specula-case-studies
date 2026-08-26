# `gpt-5.5` confirmation supplement

## Purpose

This is a scoped Phase 4 supplement for two findings whose `gpt-5.6-sol`
confirmation workers were interrupted by provider policy. It reuses the exact
source SHA, prompt, candidates, counterexamples, and parent-run evidence. It is
not a second full analysis, specification, harness, or validation run.

## Result

- Managed update can remove the only active leader-eligible replica while PULL
  remains active: `ENV_LIMITED`, consensus after four debate rounds.
- Failure of the second generated-BasicAuth Secret creation can produce a Ready
  SolrCloud without the requested authentication: `REPRODUCED`, consensus in
  one debate round.

## Provenance

- Parent run: `solr-broad-prompt-v2-20260824b`
- Agent/model: Codex / `gpt-5.5`, high effort
- Target source: [`apache/solr-operator@ed5c5c7`](https://github.com/apache/solr-operator/tree/ed5c5c7d28a4c1189d19f581259e05385c0d4b20)
- Findings: `MC-1`, `MC-5`

The curated record includes the scoped run metadata, focused counterexamples,
candidate/finding ledgers, and portable reproduction scripts. Raw agent
transcripts and confirmation worktrees are excluded. Execute the copies
collected by the parent run's
[`run_all.sh`](../solr-broad-prompt-v2-20260824b/repro/run_all.sh).
