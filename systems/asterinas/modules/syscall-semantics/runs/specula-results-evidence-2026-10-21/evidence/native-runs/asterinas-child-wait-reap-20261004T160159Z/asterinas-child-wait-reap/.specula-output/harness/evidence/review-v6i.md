VERDICT: NOT_APPROVED

Findings (Spec):

**D9R4-S1 — Medium: a newline-terminated malformed placement header still discards completed calls.**

The [transport allowlist](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/collect_outcome.py:224) requires `WR_OUTCOME_PLACEMENT ` with a trailing space. A bare `WR_OUTCOME_PLACEMENT\n` fails before syscall validation.

An in-memory probe used the supplied `linux-observer-consume4.log` metadata and first two completed calls, valid child/w1 placement, missing w2 placement, and exit code 124:

| Appended fragment | Retained calls | Their comparisons |
|---|---:|---|
| Missing | 2 | `match`, `match` |
| `WR_OUTCOME_PLACEMENT` without newline | 2 | `match`, `match` |
| `WR_OUTCOME_PLACEMENT {\n` | 2 | `match`, `match` |
| `WR_OUTCOME_PLACEMENT\n` | 0 | Both become `inconclusive` |
| `WR_OUTCOME_PLACEMENT\r\n` | 0 | Both become `inconclusive` |

Every overall result remains inconclusive. The bare header is malformed placement transport, so discarding preceding valid calls violates the requested preservation requirement.

**Minimal fix:** defer malformed placement transport rejection until after validating syscall records. Preserve the error and overall inconclusive result, and continue rejecting foreign recorder/clock transport. Update both collector copies and snapshot hashes.

Findings (Standards):

**D9R4-T1 — Low: the new diagnostic violates the supplied prose rules.**

[collect_outcome.py:219](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/collect_outcome.py:219) contains “Truncated final log line excluded from the outcome transport; the run is incomplete.” The first clause lacks a verb, and the semicolon conflicts with the supplied AGENTS.md rules. The frozen copy and amendment repeat it.

**Minimal fix:** use “The truncated final log line was excluded from the outcome transport. The run is incomplete.” Synchronize the copies, documentation and hashes. This finding is nonblocking.

Disposition: **REJECTED for `OUTCOME_ONLY`** at `c355e070c694193ec4dca61af0ecd019b98cc183`. **D9R4-S1 blocks approval.** D9R3-S1’s unterminated-header reproducer is repaired, but the requested malformed-placement preservation guarantee remains incomplete. The prior approval remains bound to `6607d1685792fadb71e9c2d1acf30d0bb75ac7bb`.

The remaining checks passed:

- The diff changes exactly the seven permitted files. `pin()`, grouped helpers and `main()` are byte-identical to the baseline.
- Outcome execution no longer asserts actual placement. Participating actors record requested and actual CPUs. The pinned scheduler’s lack of migration no longer creates a placement-dependent abort. Guest completion remains unverified at runtime.
- All 21 Linux controls preserved their call and history comparisons across requested, colocated and swapped placement patterns. Reports expose placement and waiter distinctness.
- Thirty-four missing/schema/JSON placement variants preserved completed calls while remaining inconclusive. All 579 tested byte-position truncations preserved preceding calls. Failed setup observations retained their `mismatch`.
- Outcome routing and explicit non-trace classifications remain intact. Four foreign recorder/clock transport probes were rejected without embedding their payloads.
- All 32 supplied hashes match working files and HEAD blobs. All 27 manifest entries match live and frozen files, with no missing or extra snapshot files. `evidence/applied.json` was verified as the supplied reviewed v3-install receipt.
- Existing evidence contains 21 Linux matches and 21 inconclusive guest placement-assertion failures. All 42 raw-log hashes match.

Python syntax and `git diff --check` passed. Probes used an in-memory output sink and stubbed review gate. The workspace remains clean. No files were written and no Docker, builds, QEMU or TLC ran.

REVIEWED INPUTS

```text
124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb  src/Makefile
21b9e2e00c504392357142e9819fbce050ace5c9bd89cbdd683d054c8792eaf4  src/boot.py
1a5bb46944104a65aed8e34eee7c048c7d87e9774b75ea060401cbd0e7bba08f  src/collect.py
f6eff1b2d2d2e2c9ec1b022a6ec22671265406e01d1cc91e8ebb7d4fbcb1c1d4  src/collect_outcome.py
ee83062435d51ac1563cd638c1e06bf8c5da13392aa40f0f945e25d331c096e4  src/initramfs.py
3cdd3187ca71d4f3705063e010ebea20995d30947f08f84ef8544128a4e21ef7  src/instrument.py
3eb8516d5a452957ded5d66c98e1068d6941a0d998981bd6c2b04c8a7241b78f  src/nproc_probe.c
5d0ebc742f17a49f53b79f42dd19195dc42fe94097ae20acbc0ff7032105a500  src/review_gate.py
e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3  src/wait_calibration.c
ef394a6acc1ad88425f3c3fb702c3b44b8b702dcb919f0db5aa760a868d90f28  src/wait_reap_trace.c
aee0e9ad96b463d2524a5ad5498b665b8dc6e5be37cad99309b8e0576f21d38b  src/wr_syscall.rs
be259a36672e86a0c6710e20ae3a8d6e94c17b7ef8b64849f9073cf40f2167b4  src/wr_trace.rs
fa6027893e37d734274657147bfb3ff409707a3cd434f4ee666b4e82dae144dd  run.sh
88ee9bbdf9ddc932e2752a72698f529e3454ae93353b01687ae6a48142c0d448  apply.sh
3c4f08d4c83a9fa1477ea55b2ab779851f1bf3fa5ff27b6bfc8470a74021b044  clean.sh
e41813141c7aeb3f9ccaf5fe023d8d19fe19a8b8c275408b5f6e3af8d72e4b9e  cases.tsv
10de68e9ba57e7749ecb5dbbc86ebc0c2fd838858e7ae5eebe42f3a56ee005fb  patches/instrumentation.patch
1e0fba48688badb9a8faf82632a6c9f0524d5ec3961733ff52ae03315728cc8d  evidence/applied.json
981fce04ee3d7c000e562044419e5a06d467fb91b70582bb437cc26c1241961e  INSTRUMENTATION.md
05047292ab7e422497dc025da64293e249e40559461fe3eba8e416b0698be457  STATUS.md
fcaca87d2aa3f748f9e0dff21faa9b1ee242f1d9cd4170be48e8f8e03130134d  evidence/clock-method-v4.md
252e97d05d2216ef6714f2679169e00a8c56df7d5d5d16bac1007bf67528c752  evidence/clock-method-v5.md
49f6a47ce73dbb6e11f6ecdc3ecde6b5640d29eb097840ab3fb9fa103b8bea2b  evidence/v5-inputs.json
8e3b936025a6028c5794ae568006a5f6abc34ae044173d8b88096e0a7cdb32f1  evidence/candidate-v5/hashes.json
05f55403ef92af50dc752b605cf5da07720abb43137e5b1cf323d5f03132d88b  evidence/outcome-mode-v6.md
435ba914e0fade23fa70921c45bb4191b68fe7da75d9fda78811c0cd856baf3b  evidence/v6-inputs.json
913d1d7c984fd9532ddeed57f7a4cda534467d206cf6a3181800cb056c5eb1c2  evidence/candidate-v6/hashes.json
abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10  ../spec/base.tla
94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3  ../spec/Trace.tla
82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0  ../spec/Trace.cfg
a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824  ../spec/TraceSearch.cfg
69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d  ../spec/instrumentation-spec.md
```

