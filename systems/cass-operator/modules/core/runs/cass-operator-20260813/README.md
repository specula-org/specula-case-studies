# cass-operator run

## Reviewed result

The independent review records **4 new bugs** and **3 previously known, unfixed bugs**:

- New: a transient management-API failure can trigger premature decommission cleanup and storage removal (MC-2).
- New: missing node load bypasses the decommission capacity check (MC-3).
- New: a failed status checkpoint can duplicate an asynchronous maintenance job (MC-5).
- New: a lost start request can leave a pod permanently stuck in `Starting` (MC-6).
- Known: a stale deletion view can remove storage from a recreated datacenter (MC-1, issue #118).
- Known: the disruption budget remains stale during scale-up (MC-7, issue #741).
- Known: a missing required secret can block finalizer removal (MC-8, issues #812 and #952).

Read [independent-review.md](review/independent-review.md) for the reviewed ledger and [modeling-brief.md](modeling-brief.md) for the modeled scope.

## Provenance

- Source archive: `cass-operator.tar (1).zst`
- Archive SHA-256: `8c50277e414a7c56cbb8dba683b62ce6f813cdc3f1155afb320f6d201511f0d1`
- Run ID: `20260813-170446-8b0a`
- Run created: `2026-08-13T17:04:46Z`
- Agent/model: `copilot-cli` / `claude-opus-4.8`
- Target source: [`k8ssandra/cass-operator@704bf4c2e9a48e3d0381ddfaec6fb0346f0a164c`](https://github.com/k8ssandra/cass-operator/tree/704bf4c2e9a48e3d0381ddfaec6fb0346f0a164c)

## Included evidence

This curated record includes the seven reviewed reproduction tests, their supporting test harness, the relevant TLA+ configurations and counterexample outputs, and the original `run.json`. Generated worktrees, logs, caches, TLC state directories, and unrelated pipeline dispositions are excluded.

Most reproductions use fake Kubernetes or management-API clients. MC-3 confirms the capacity-check bypass without demonstrating a cluster disk failure, and MC-7 evaluates Kubernetes eviction admission using its deterministic rule rather than a live API server.

## Reproduction

Use a clean checkout at the target commit and run:

```bash
./repro/run_all.sh /path/to/cass-operator
```

The runner verifies the source commit, installs the archived test helpers temporarily, runs all seven tests with timeouts, and removes the temporary files afterward.
