# CR-3 Phase 1 Investigation

## Scope and source

- Finding source: Code Review. No model-checking counterexample is used for this finding.
- Audited checkout: `d9a0663e3930d90bd98122e8a852cf8d27c410ec`, which matched upstream `origin/HEAD` when checked on 2026-07-27.
- Existing uncommitted `tla_trace` instrumentation in the checkout was preserved. The instrumentation records the relevant actions but does not change the baseline values, persistence validation, set-difference logic, or Kubernetes mutations.

## Step 1 — code audit

### Cited code and behavior

- `sregym/service/cluster_state.py:99-114`: `ClusterBaseline.from_json()` uses `data.get(..., [])` or `data.get(..., {})` for every collection. There is no schema version, required-field validation, capture identifier, or completeness flag.
- `sregym/service/cluster_state.py:131-168`: `capture_baseline()` observes each resource family independently, then constructs a `ClusterBaseline` without checking whether any observation failed.
- `sregym/service/cluster_state.py:170-181`: `save_baseline_state()` always serializes the returned baseline and has no incomplete-capture guard.
- `sregym/service/cluster_state.py:183-201`: `load_baseline_state()` accepts any JSON object that `from_json()` can default and returns `True`; only JSON decoding and `KeyError` are caught. The defaults mean omitted fields do not raise `KeyError`.
- `sregym/service/cluster_state.py:379-427,483-549`: each resource/value getter catches `ApiException` and returns an empty set or dictionary. The empty value is indistinguishable from a successful observation of an empty resource family.
- `sregym/service/cluster_state.py:227-362`: reconciliation computes `current - baseline` for namespaces, ClusterRoles, ClusterRoleBindings, PersistentVolumes, StorageClasses, CRDs, and admission webhook configurations, then sends delete operations for unprotected names. A resource missing only because its baseline list failed is therefore classified as unexpected.
- `sregym/service/cluster_state.py:578-665`: value restoration is limited to node labels, node taints, and CoreDNS. Node restoration iterates only nodes present in the baseline maps. The file contains no create/replace/patch path for restoring a deleted or content-mutated ClusterRole, binding, volume, storage class, CRD, webhook configuration, or ordinary namespaced object.

### Normal call chain and reachability

1. `Conductor.start_problem()` reaches `deploy_app()` during normal benchmark startup (`sregym/conductor/conductor.py:410-455` and its later deploy call).
2. On the first deployment for a `Conductor`, `deploy_app()` loads `~/cache_dir/cluster_baseline_state.json`; if absent it calls `save_baseline_state()`, then unconditionally sets `_baseline_captured = True` (`sregym/conductor/conductor.py:841-850`).
3. A Kubernetes list endpoint can transiently return an error while the other independent list/read calls succeed. The corresponding getter catches an `ApiException`, records an empty collection, and capture continues.
4. `save_baseline_state()` persists that mixed-success observation. A process restart creates a new manager, and `load_baseline_state()` accepts the file as complete.
5. Normal problem completion calls `_finish_problem()`, then `_cleanup_sync()` (`sregym/conductor/conductor.py:376-400`). `_cleanup_sync()` calls `reconcile_to_baseline()` when `_baseline_captured` is true (`sregym/conductor/conductor.py:360-369`).
6. Once the failed endpoint has recovered, its current resource set includes pre-existing objects that the persisted empty set omits. Reconciliation issues deletion calls for those objects.

This path does not require an inconsistent internal state: a valid Kubernetes error response followed by recovery is sufficient. The persisted file and restart are normal product paths.

### Concrete trigger scenario

Start with a bare cluster containing a user-managed ClusterRole named `baseline-critical-reader`. On first benchmark startup, all baseline reads succeed except `list_cluster_role`, which transiently returns HTTP 503. `_get_cluster_roles()` converts that error to `set()`, and `save_baseline_state()` persists `"cluster_roles": []`. Restart the benchmark after the API recovers. `load_baseline_state()` returns `True`. At normal cleanup, `list_cluster_role` returns `baseline-critical-reader`; `reconcile_to_baseline()` classifies it as unexpected and deletes it.

The same name-only design has two additional normal-operation gaps: deleting an object that was present in a complete baseline is not reversed, and changing the contents of a baseline object without changing its name is not detected or restored.

### Safeguards found

- Namespace deletions exclude `PROTECTED_NAMESPACES`; ClusterRole and binding deletions exclude `system:*`, `kubeadm:*`, and Chaos Mesh names. These are name-specific allowlists, not capture-completeness checks. A normal user-managed baseline object is unprotected.
- A missing baseline file causes fresh capture, and malformed JSON makes `load_baseline_state()` return `False`. Neither safeguard rejects a syntactically valid partial snapshot.
- Individual deletion failures are logged and cleanup continues. A successful Kubernetes deletion has no compensating create path.
- `_baseline_captured` prevents repeated capture within one `Conductor`; after a partial file is loaded, it also prevents a fresh observation from replacing it.
- No later sync, loopback, resend, or caller guard was found that recreates arbitrary user-managed cluster-scoped resources. A Kubernetes controller could independently recreate a controller-owned object, but the trigger uses an unowned user-managed ClusterRole.

## Step 2 — developer-knowledge evidence

### History and intent

- Commit `8181d966ac28b2077fb1e5b1e71ea96572f98c55` introduced the manager with the message “Reset to a clean cluster state between problems by using state reconciliation.” The Conductor comment said the purpose was to “clean up any changes made by the agent.”
- Merged PR [#472](https://github.com/SREGym/SREGym/pull/472), “Reset to a clean cluster state between problems,” introduced the original reconciliation and closed issue #460.
- Commit `74f9fef40e7e2f7b65efe5ccc00efeb8127138da` / merged PR [#613](https://github.com/SREGym/SREGym/pull/613), “Cluster cleanup heuristic,” added lossless JSON persistence and startup loading. Its body calls the cleanup “Not a perfect cleanup, but I think it may be good enough.”
- The current docstrings state that capture should establish a “known-clean reference state” and reconciliation should “Reset cluster to baseline state” (`sregym/service/cluster_state.py:170-175,203-206`).
- Issue [#460](https://github.com/SREGym/SREGym/issues/460) records concern that a crash/restart could capture a faulted state and that the snapshot was “not comprehensive.” Later discussion distinguishes restoring deleted objects from removing newly created objects. This is evidence that clean restoration is the intended outcome and that broader limitations were discussed.
- Issue [#559](https://github.com/SREGym/SREGym/issues/559) records a flaky CRD-list `IncompleteRead` that aborted startup. It was closed after it stopped recurring. The report does not describe a caught `ApiException`, a silently persisted empty field, or a later deletion.
- No nearby TODO/FIXME, design document, or existing test asserts that partial observations should be authoritative. No existing non-Specula test targets `ClusterStateManager` persistence/reconciliation.

## Step 3 — known-status and precedent

Searches covered open and closed issues plus open, closed, and merged PRs in `SREGym/SREGym`. Terms included `baseline`, `cluster_state`, `reconcile`, `snapshot`, `"Failed to list" baseline`, `empty baseline`, `partial baseline`, and `deleted baseline`. The local history for `sregym/service/cluster_state.py` was also reviewed through upstream HEAD, including recently merged/closed work.

- Issue #559 is a same-area failure precedent, but its mechanism is an uncaught transport `IncompleteRead` that crashes capture.
- Issue #460 and PRs #472/#613 are same-area design/history precedents, but they do not report a caught per-resource observation error being serialized as a valid empty collection and later used to delete a pre-existing object.
- No issue, PR, CVE, advisory, or commit found in those searches reports this mechanism at this site, and no later commit fixes it.

Novelty evidence: `NEW` for the caught-error → authoritative-empty snapshot → deletion mechanism.
