VERDICT: NOT_APPROVED

Findings:

**D8-S1 — Medium: the replacement macro’s serial sink is disabled by the harness boot command.**

The calls at [wr_trace.rs:254](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/wr_trace.rs:254) and line 260 resolve to an exported macro with compatible arguments. However, [boot.py:33](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/boot.py:33) supplies `console=ttyS0` without `earlycon`. The pinned kernel’s [registered parser](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/comps/cmdline/src/early.rs:46) overrides OSTD’s default and enables the early console only for `earlycon`. Consequently, [serial initialization returns immediately](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/ostd/src/arch/x86/serial.rs:110), and [early_print silently discards output](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/ostd/src/console/mod.rs:12).

Thus `WR_STREAM` and `WR_RAW` cannot reach the collector through this sink. The missing flag predates D8, but it prevents the explicitly requested serial-transport check from passing.

**Minimal fix:** add `earlycon` before `--` in live and frozen `boot.py`, refresh the snapshot manifest and review inputs, and document the additional amendment.

No Standards findings or additional Spec findings.

Disposition: **D8 is not accepted** at `0f56848e49a52b140e526f47d81ace981dcb7f0e`, pending D8-S1. The prior approval at `7ff3c07ff5b2dc2a75a2027eae79f495ea159f9c` retains its `OUTCOME_ONLY` scope.

The remaining checks pass:

- The diff changes exactly the four specified files. Each recorder copy contains exactly two macro-name substitutions, with identical formats and arguments.
- Outcome mode remains unarmed and never invokes the dump. Grouped recorder state, ordering, counters and serialization remain unchanged.
- All 32 supplied hashes match working files and committed blobs. All 27 manifest entries match frozen and live counterparts, with no missing or extra snapshot files. The reviewed v3-install receipt matches its supplied hash.

The author’s log records a successful release build at line 725. It does not establish serial output. This review performed only static checks. No files were written and no Docker, builds, QEMU or TLC ran. The worktree remains clean.

REVIEWED INPUTS

```text
124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb  src/Makefile
c89fdf8b0105775e53e173941909d4978247dbcca70ca132608781501c21a0ff  src/boot.py
1a5bb46944104a65aed8e34eee7c048c7d87e9774b75ea060401cbd0e7bba08f  src/collect.py
94a563da5905689c110f609d608e72541a5f0d588e50b4e7831212a20089be13  src/collect_outcome.py
ee83062435d51ac1563cd638c1e06bf8c5da13392aa40f0f945e25d331c096e4  src/initramfs.py
3cdd3187ca71d4f3705063e010ebea20995d30947f08f84ef8544128a4e21ef7  src/instrument.py
3eb8516d5a452957ded5d66c98e1068d6941a0d998981bd6c2b04c8a7241b78f  src/nproc_probe.c
5d0ebc742f17a49f53b79f42dd19195dc42fe94097ae20acbc0ff7032105a500  src/review_gate.py
e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3  src/wait_calibration.c
7afafd78c0a3c15540252c77d260c72598ae404d6a09920f6d6eb03aed39031a  src/wait_reap_trace.c
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
347ded44d8b8870330fa6e2c348bb85c09d847820857c8676a60e6b23be63ec0  evidence/candidate-v6/hashes.json
abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10  ../spec/base.tla
94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3  ../spec/Trace.tla
82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0  ../spec/Trace.cfg
a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824  ../spec/TraceSearch.cfg
69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d  ../spec/instrumentation-spec.md
```

