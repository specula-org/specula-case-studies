# Continue the same harness campaign

The controller should resume this phase when host `MemAvailable` reaches 10 GiB and this lane holds its normal resource allocation. Keep the existing shared heavy lock and per-run writer contract. The native worker must not reacquire a controller-held lock or recursively launch the pipeline.

Run exactly:

```sh
cd /home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/asterinas-local-flock-ownership/.specula-output
bash harness/run.sh
```

The script starts the existing private container if needed, verifies the independently reviewed v12 hashes, applies the pinned source patch, checks the private alloc patch exactly, rebuilds with two Cargo jobs, runs five Linux controls and 18 Asterinas cases, preserves raw per-thread records and manifests, checks all 49 event types and the unchanged 20 percent overlap criterion, and invokes the reviewed complete-witness adapter. It checks the 6 GiB host-memory threshold before each TLC invocation. Test/build timeouts remain bounded. A timeout or a failed export is incomplete evidence, never an automatic protocol verdict.

The owned container is stopped and retains its private toolchain/cache for continuation. It is `specula-flock-harness-20261005`, ID `2da25e1fcc61b58bbf6e7b724716711723522f9195eec87ea39b85077d17a029`, based on `asterinas/kernel-dev:0.18.1-20260926`. Its private Rust alloc source hash after instrumentation is `2807716613f6f134b7a5df0c9c91f0c92cc8769d46eb7019e8c6d9a17990b6dd`. The pinned compiler is `rustc 1.99.0-nightly (87e5904f5 2026-07-20)`, toolchain `nightly-2026-07-21`. Host Rust was not modified. Cargo dependency cache imports were checked against the lockfile's exact Git commits and crate checksums and are recorded in `evidence/dependency-cache-import.json`.

After the run, inspect C00's observed controller/holder/contender CPU placement and its actual raw intervals. Its four events are a deliberate runtime prefix, with both original open references still pending, not a trimmed completed trace. The holder and controller must occupy different CPUs. The contender waits outside its measured insertion interval and outside the preemption-disabling table guard. C13 must show FD removal before the final original-open put. Check C08's two actual blocker identities and preserve C06/C11 prefix status. Inspect all fixture return values, dropped counts, trace witness outcomes and coverage before changing `STATUS.md` to complete.

Preserve new attempt logs and exact artifact hashes. If a semantic source/model/harness/interpretation correction becomes necessary, save old/new versions, diff, reason and triggering evidence, obtain independent exact-version review, close material findings, and only then rerun. Existing reviews do not authorize changed bytes. Continue this same campaign rather than creating replacement traces by hand. No confirmation, classification or repair phase is authorized by this handoff.
