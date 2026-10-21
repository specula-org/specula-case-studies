VERDICT: APPROVED

**C2 — Low — The amendment’s scope statement is inaccurate.**

`git diff --name-status e601dea 2af46b8` lists **five** files. Besides the four expected paths, it adds `harness/src/__pycache__/boot.cpython-314.pyc`, contradicting [c1-amendment.md:10](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/evidence/c1-amendment.md:10). Commit `7e0fb7e` removes that file and also adds `.gitignore`’s `__pycache__/` rule.

Minimal fix: correct the amendment’s scope statement to acknowledge the bytecode and subsequent cleanup. This is nonblocking: the runner executes `boot.py` directly, and the reviewed HEAD contains no bytecode file.

No High or Medium findings.

**C1 disposition: RESOLVED.**

- [boot.py:25](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/boot.py:25) generates `/tmp/wr-<uuid4 hex>.qmp` separately for each invocation. It occupies **44 ASCII bytes, 45 including NUL**, within the 108-byte capacity. The same variable supplies QEMU’s argument, the connection, the unlink operation, and the outcome JSON.
- Both guest paths invoke Python inside disposable containers. The runner neither mounts host `/tmp` nor requests a read-only root filesystem. Read-only inspection verified the local image configuration against pinned ID `sha256:897cb1b354b3d7d28184d7a417c27565390fc3fa6886b328d2588e6de93c1dab` and followed its 43 layer mappings. Its effective `/tmp` is a real directory with mode `01777`, preserved by subsequent layers. This establishes static image evidence, not runtime availability.
- The existing `finally` block stops/reaps QEMU before unlinking. External termination that bypasses Python cleanup remains covered by container disposal through `--rm` and the runner’s EXIT removal trap.
- All **27 supplied hashes** match both the working files and `2af46b8`. All **25 frozen files** match the manifest and their live counterparts. The unmodified `review_gate.check()` accepts them in both modes with a hypothetical valid receipt supplied entirely in memory. The actual receipt remains `INCOMPLETE` and requires controller binding.
- Other than the UUID import, pathname assignment, and outcome field, `boot.py` is AST-identical to the baseline. The amendment invalidates none of review-v5’s remaining reasoning. Approval retains the `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND` scope. R2 remains open for real global order, store visibility, and a run-wide clock bound. Installation and receipt rebinding remain prerequisites.

The workspace remains clean. No files were written, and no Docker, build, QEMU, or TLC commands ran.

## REVIEWED INPUTS

```text
8c32b9c9bb4fb7efa68013d0fcc35b06bc3629adad0047702196b7b4fd3330bd  src/boot.py
f47ea876227669dd3ded951d661a1716b9c8b75b2cc2abfc25575dbd20e7d283  src/collect.py
a89ecd347eadb36b2a25c16d8cd96dd3c04964bd50c6bd0ff570d4e186c72561  src/initramfs.py
3cdd3187ca71d4f3705063e010ebea20995d30947f08f84ef8544128a4e21ef7  src/instrument.py
124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb  src/Makefile
2d23fd66b008a1f41938dd4fee0348397af01949133b7c7af30581399c9dae9e  src/review_gate.py
e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3  src/wait_calibration.c
c321494aed02c1bfb89d676b7c2c1ed5f1ecd9c9923400be76f43a929d232e12  src/wait_reap_trace.c
aee0e9ad96b463d2524a5ad5498b665b8dc6e5be37cad99309b8e0576f21d38b  src/wr_syscall.rs
ec9aed3f6b032b626f86ff8a97636ecaa37e6f3fa037662264889cd445232219  src/wr_trace.rs
a31c69536a7b5ba8bdac945c773b98cbf830a7fb493600934659612d083ef8f8  run.sh
88ee9bbdf9ddc932e2752a72698f529e3454ae93353b01687ae6a48142c0d448  apply.sh
3c4f08d4c83a9fa1477ea55b2ab779851f1bf3fa5ff27b6bfc8470a74021b044  clean.sh
eba30152db35a608f521984474ad0ad7bab0ef67e7785b7259b50a116003efbc  cases.tsv
10de68e9ba57e7749ecb5dbbc86ebc0c2fd838858e7ae5eebe42f3a56ee005fb  patches/instrumentation.patch
1e0fba48688badb9a8faf82632a6c9f0524d5ec3961733ff52ae03315728cc8d  evidence/applied.json
3e5e8f0fcd7de09c4bc0a72ed026d597b3c7cdcfda890f48433132820c4e7e06  INSTRUMENTATION.md
88f6b43c9d8d7b4350af1a268ccf1f89ee43e18d19f60e1f584dc88efd45b4a3  STATUS.md
fcaca87d2aa3f748f9e0dff21faa9b1ee242f1d9cd4170be48e8f8e03130134d  evidence/clock-method-v4.md
252e97d05d2216ef6714f2679169e00a8c56df7d5d5d16bac1007bf67528c752  evidence/clock-method-v5.md
49f6a47ce73dbb6e11f6ecdc3ecde6b5640d29eb097840ab3fb9fa103b8bea2b  evidence/v5-inputs.json
caf0ff616961425454f62a6ceae543d0169035e30231db66b31986cacacba5f0  evidence/candidate-v5/hashes.json
abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10  ../spec/base.tla
94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3  ../spec/Trace.tla
82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0  ../spec/Trace.cfg
a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824  ../spec/TraceSearch.cfg
69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d  ../spec/instrumentation-spec.md
```

