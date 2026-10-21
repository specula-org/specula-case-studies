VERDICT: APPROVED

Findings: []. No High, Medium or Low findings from either review axis.

Disposition: **ACCEPTED for `OUTCOME_ONLY`** at `7ff3c07ff5b2dc2a75a2027eae79f495ea159f9c`, against approved D6 baseline `1fbef8edd2be37875f1e889ffe8fe3e49f86cecd`. The controller may bind this review and rebind the reviewed v3-install receipt to the installed receipt as before.

- The diff contains exactly the four requested files. Both runners are byte-identical. Only `run.sh` changes in the snapshot manifest. All 32 supplied hashes match working files and committed files. All 27 snapshot entries match their frozen and live counterparts, with no extra snapshot files.
- [The Linux wrapper](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/run.sh:142) passes the same two selected CPU IDs to `taskset -c` for both `nproc` and the fixture’s `timeout` parent. The fixture inherits that affinity, checks its size and pins its actors within the pair. Thus `WR_CONTROL_NPROC` measures the restricted two-CPU affinity. Affinity survives fork and exec. [Linux affinity documentation](https://man7.org/linux/man-pages/man2/sched_setaffinity.2.html).
- With `WR_LINUX_CPUS` unset, the empty array preserves the original `nproc` and fixture commands. The recorded image does not preset that variable. Retaining `--cpuset-cpus` is harmless here: the recorded rootless daemon drops it with a warning, which the unchanged collector tolerates. Supporting daemons enforce the same pair. Outcome semantics, arguments, expectations and comparisons remain unchanged.
- [The sysroot fetch](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/run.sh:201) addresses the recorded missing `rustc-literal-escaper` dependency before Cargo goes offline. Direct inspection of the mounted sysroot confirms its library lockfile pins version `0.0.8` and its checksum. `--locked` rejects missing or changed resolution, preserving dependency selection for this fetch. D6’s accepted limitation concerning the generated kernel workspace remains unchanged. [Cargo fetch documentation](https://doc.rust-lang.org/cargo/commands/cargo-fetch.html).
- Inner limits total `4×600 + 1200 + 300 + 1500 = 5400` seconds within the 6000-second outer limit, leaving 600 seconds for startup and logging.

Bash syntax checks for both runners and all four embedded shell programs, plus `git diff --check`, passed. The worktree remains clean. No files were written and no Docker, builds, QEMU or TLC ran. The author’s preflight was not repeated. Full offline build and runtime success remain **unverified**.

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
ec9aed3f6b032b626f86ff8a97636ecaa37e6f3fa037662264889cd445232219  src/wr_trace.rs
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
b924f7a4ad524f39dd1bca5a3e9573cb48591f424a1347aabecf160a96d3a6f9  evidence/candidate-v6/hashes.json
abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10  ../spec/base.tla
94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3  ../spec/Trace.tla
82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0  ../spec/Trace.cfg
a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824  ../spec/TraceSearch.cfg
69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d  ../spec/instrumentation-spec.md
```
