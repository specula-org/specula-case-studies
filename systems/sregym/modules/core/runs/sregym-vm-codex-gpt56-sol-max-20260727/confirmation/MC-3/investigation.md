# MC-3 Phase 1 investigation

## Scope and source provenance

- Finding: MC-3, `BaselineMatchesCluster`.
- The supplied TLC output is a real invariant-violation trace:
  `spec/output/MC_hunt_scenario3_bfs.out:36` reports
  `Invariant BaselineMatchesCluster is violated`.
- Relevant trace sequence:
  - State 7 is `MCCrash`; the persisted baseline exists and has generation 0.
  - State 8 is `MCReplaceCluster`; `clusterGen` becomes 1, the live resource
    set changes, and `persistedBaselineGen` remains 0.
  - State 9 restarts the process, State 10 starts another problem, and State 11
    makes the generation-0 baseline authoritative while `clusterGen = 1`.
- The worktree is at `d9a0663e3930d90bd98122e8a852cf8d27c410ec`.
  It has pre-existing Specula tracing edits in the cited files. The diff adds
  observational `tla_trace` calls but does not add cluster provenance checks or
  change the load/delete set calculations.

## Step 1: code audit

### Relevant implementation

- `sregym/paths.py:4,12,16` resolves one process-user home directory and names
  one persistent file, `~/cache_dir/cluster_baseline_state.json`. The path has
  no kube context, server, cluster UID, or generation component.
- `sregym/service/cluster_state.py:83-114` serializes only resource sets and
  mutable cluster values. There is no schema version, cluster identity,
  generation, capture timestamp, or completeness marker.
- `sregym/service/cluster_state.py:170-181` captures and writes directly to the
  final path with `open(path, "w")`; the persisted payload is not wrapped with
  provenance metadata.
- `sregym/service/cluster_state.py:183-201` accepts any existing JSON object
  that `ClusterBaseline.from_json` can consume. It performs no live Kubernetes
  API query and no comparison against the current cluster before assigning
  `self.baseline` and returning `True`.
- `sregym/conductor/conductor.py:841-850` calls the loader before infrastructure
  deployment. A successful parse logs that the persisted baseline was loaded
  and sets `_baseline_captured = True`; recapture is only the missing/invalid
  file fallback.
- `sregym/service/cluster_state.py:227-237` computes live namespaces absent from
  the loaded baseline and deletes every such namespace outside a small
  hard-coded protected set.
- Equivalent destructive consumers exist for arbitrary non-system
  ClusterRoles at `sregym/service/cluster_state.py:239-255`,
  ClusterRoleBindings at `:257-272`, PersistentVolumes at `:274-285`,
  StorageClasses at `:305-316`, CRDs at `:318-332`, and webhook configurations
  at `:334-362`.
- `sregym/service/cluster_state.py:370-374,551-576` also overwrites a differing
  live CoreDNS ConfigMap with the persisted baseline value.
- The real namespace consumer is `KubeCtl.delete_namespace` at
  `sregym/service/kubectl.py:498-503`; it calls
  `CoreV1Api.delete_namespace` and waits for deletion.

### Normal call chain

1. `main.py:297-320` selects a benchmark problem and calls the public
   `Conductor.start_problem()`.
2. `Conductor.start_problem` calls `deploy_app` at
   `sregym/conductor/conductor.py:456-460`.
3. A new process has `_baseline_captured = False`
   (`sregym/conductor/conductor.py:61-62`), so `deploy_app` loads the single
   persisted file at `sregym/conductor/conductor.py:841-850`.
4. Normal completion, deploy-retry cleanup, agent exit, or the public
   `finish_after_agent_timeout` path enters `_cleanup_sync`.
5. `_cleanup_sync` calls `reconcile_to_baseline` at
   `sregym/conductor/conductor.py:360-369`.
6. The reconciler issues the Kubernetes deletion/restoration calls described
   above and reports them to its caller in the `changes` result.

### Concrete reachable trigger

1. Run SREGym as user U against cluster A. Its first deployment invokes
   `save_baseline_state`, producing U's one cache file from cluster A.
2. The SREGym process crashes or is stopped. The home-directory cache survives.
3. Cluster A is replaced, or U's kube context is repointed to replacement
   cluster B. Cluster B legitimately contains a non-protected namespace/RBAC
   object and has its own CoreDNS value.
4. Restart SREGym as U and start a normal problem. The new `Conductor` loads
   cluster A's parseable file and marks the baseline captured.
5. Finish the problem normally or use the public timeout cleanup path.
   Reconciliation classifies cluster B's legitimate objects as unexpected,
   deletes them, and can restore cluster A's CoreDNS data over cluster B's.

This is the implementation analogue of the admissible counterexample sequence
State 7 `MCCrash` -> State 8 `MCReplaceCluster` -> State 9 restart -> State 10
`MCStartProblem` -> State 11 loading the old baseline as authoritative.

### Safeguards and downstream behavior found

- `PROTECTED_NAMESPACES` at `sregym/service/cluster_state.py:24` protects only
  six fixed names. It does not protect arbitrary legitimate replacement-cluster
  namespaces.
- Role filters at `sregym/service/cluster_state.py:243-247,261-264` cover
  `system:`, `kubeadm:`, and Chaos Mesh naming patterns, not arbitrary
  replacement-cluster platform roles.
- Exception handlers run only after a destructive API call fails; they do not
  validate baseline provenance.
- Repository-wide searches found no code that removes, expires, versions, or
  recaptures `CLUSTER_BASELINE_STATE_FILE` after a successful load.
- Reconciliation restores mutable values but does not recreate namespaces,
  RBAC, PVs, storage classes, CRDs, or webhooks it deleted. A later SREGym
  reconciliation therefore sees the deleted object as absent and does not
  restore it. No SREGym sync, resend, loopback, or caller guard masks that loss.

## Step 2: developer-knowledge evidence

- Reconciliation began in commit `8181d966` ("Reset to a clean cluster state
  between problems by using state reconciliation").
- The fixed persisted path, JSON conversion, loader, and pre-deploy load were
  introduced together in commit `74f9fef4` / PR
  [#613](https://github.com/SREGym/SREGym/pull/613), "Cluster cleanup
  heuristic". Its body calls the cleanup “not a perfect cleanup” and says it
  “may be good enough.”
- The linked issue [#460](https://github.com/SREGym/SREGym/issues/460) records
  the intended goal of returning to the known clean state from before a problem
  and explicitly worried that after a benchmark crash the baseline could
  contain the injected fault. This explains why persistence was added, but it
  does not establish any promise that a cluster-A snapshot is valid for
  cluster B.
- No existing test under `tests/` references `ClusterStateManager`,
  `load_baseline_state`, `save_baseline_state`,
  `CLUSTER_BASELINE_STATE_FILE`, or `reconcile_to_baseline`.

## Step 3: known-status and precedent

- Upstream issue/PR searches covered all states and included recently closed
  and merged pull requests. Queries included the persisted filename, persisted
  baseline, stale baseline, cluster replacement/new cluster, crash/restart,
  identity/generation, and namespace deletion.
- Merged PR [#767](https://github.com/SREGym/SREGym/pull/767) reports this same
  mechanism at the same persisted-baseline/reconciliation site: after changing
  the cluster from Flannel to Calico, operators must delete the cached baseline
  so reconciliation does not “nuke Calico ClusterRoles/Bindings as
  unexpected.”
- Commit `e853796c`, which merged PR #767, changes only
  `scripts/ansible/setup_cluster.yml`. It does not implement automatic
  invalidation, provenance binding, or stale-baseline rejection. The current
  loader and destructive consumers remain unchanged.
- Known-status evidence: `KNOWN (cite:
  https://github.com/SREGym/SREGym/pull/767; fix-status: unfixed)`.
- Because this finding is MC-sourced with an actual invariant-violation trace,
  the known report is recorded as evidence and does not invoke the
  code-review-only drop pre-filter.
