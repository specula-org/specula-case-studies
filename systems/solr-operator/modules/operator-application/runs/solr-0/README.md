# Solr Operator interaction run `solr-0`

## Reviewed result

This earlier run contributes one reproduced bug to the public ledger:

- Scale-down can submit `REPLACENODE` when fewer than two Solr nodes are live;
  Solr rejects the request with HTTP 400, the v1 client erases the semantic
  error body, and level-triggered reconciliation can repeat the impossible
  operation while retaining the scale-down lock.

The run also re-derived three bugs that its prompt explicitly supplied as
known-good grounding. They remain useful calibration evidence but are not
counted as independent discoveries. A dropped-error retry finding was masked by
controller-runtime's periodic resync and is outside the six-item public ledger.

## Provenance

- Archived run: [`jinlang226/Specula` `run/solr-0` at `2724def2`](https://github.com/jinlang226/Specula/tree/2724def2c2013a874100ac689b8159df4c2c8936/runs/solr-0)
- Original run ID: `20260806-203521-010a`
- Agent/model: GitHub Copilot CLI / Claude Opus 4.8, high effort
- Target source: [`apache/solr-operator@ed5c5c7`](https://github.com/apache/solr-operator/tree/ed5c5c7d28a4c1189d19f581259e05385c0d4b20)
- Duration: 101 minutes 44 seconds

## Included evidence

This curated record includes the original prompt guidance, modeling brief,
analysis report, TLA+ model and focused counterexample, findings ledger, and
the MC-1 reproduction program. Source snapshots, raw agent transcripts,
session state, confirmation worktrees, caches, and TLC state directories are
excluded.

The MC-1 reproduction uses admissible Level-2 state injection and the real
operator API client/control function. It is not a live-cluster reproduction.
Use the consolidated runner in the
[broad run](../solr-broad-prompt-v2-20260824b/README.md) to execute it against a
clean target checkout.
