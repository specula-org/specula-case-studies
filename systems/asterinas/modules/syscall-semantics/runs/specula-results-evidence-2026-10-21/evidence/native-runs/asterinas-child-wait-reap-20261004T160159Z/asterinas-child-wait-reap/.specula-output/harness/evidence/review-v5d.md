VERDICT: NOT_APPROVED

**D3-S1 — Medium — The logger misses the generated kernel lockfile.**

[run.sh:146](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/run.sh:146) searches `/work/source/target/osdk`, but the preceding build specifies `--output /work/.specula-output/harness/build/kernel`.

The pinned [OSDK build code](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/commands/build/mod.rs:38) creates the generated workspace under that explicit output directory. For kernel package `asterinas`, its lockfile is:

```text
/work/.specula-output/harness/build/kernel/asterinas-run-base/Cargo.lock
```

Consequently, the logger can emit `WR_NO_OSDK_TARGET_DIR` and succeed without recording the kernel’s resolved dependencies. If `target/osdk` exists, its files need not describe this build. D3’s promised dependency provenance is therefore incomplete.

Minimal fix: record the contents and hash of the actual generated lockfile under the explicit output directory. Update the frozen runner and manifest. Missing `target/osdk` should remain harmless.

**D3-S2 — Low — The guide incorrectly attributes locked fetching to both build containers.**

[INSTRUMENTATION.md:21](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/INSTRUMENTATION.md:21) says both builds fetch locked dependencies. The fixture container runs toolchain commands and C compilation. Only the kernel container performs the two Cargo fetches.

Minimal fix: distinguish both containers’ toolchain setup from the kernel container’s locked fetching. Update the frozen guide and manifest.

**D2-C1 — Low — D2’s sign-off remains absent.**

`git show -s --format=raw bcf6969` still contains no `Signed-off-by:` trailer, contrary to the supplied AGENTS.md. D3 correctly carries the repository-configured `Signed-off-by: Ruowen Qin <chinqrw@gmail.com>`, but this does not amend D2.

Minimal fix: include the required trailer when reissuing D2.

No High findings. Only D3-S1 blocks approval.

**D2/D3 disposition**

D2-S1’s online Cargo resolution is corrected, but D3’s provenance mitigation remains incomplete:

- Both fetches use their respective checked-in lockfiles with `--locked`. OSDK compilation also retains `--locked`. These commands fail if their lockfile resolution must change. [Cargo fetch documentation](https://doc.rust-lang.org/cargo/commands/cargo-fetch.html#manifest-options)
- [run.sh:138](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/run.sh:138) exports `CARGO_NET_OFFLINE=true` before both builds. The pinned OSDK constructs inherited command environments. Its [kernel Cargo invocation](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/osdk/src/commands/build/mod.rs:248) removes `RUSTUP_TOOLCHAIN`, without clearing offline mode. Spawned Cargo therefore retains the offline restriction. Build containers remain on bridge networking. [Cargo offline configuration](https://doc.rust-lang.org/cargo/reference/config.html#netoffline)
- A fresh generated kernel workspace still resolves without a supplied lockfile or `--locked`. It can select compatible cached versions, including preexisting image-cache entries. Neither equality with the checked-in lockfiles nor equality with v5’s original dependency selection is guaranteed. Offline resolution can differ from online resolution. [Cargo build documentation](https://doc.rust-lang.org/cargo/commands/cargo-build.html#manifest-options)
- Correctly captured generated lockfile contents and hashes would document the resulting package resolution. They would not enforce future selection or establish reproducible builds. The current logger misses that evidence. The controller-reported missing `inherit-methods-macro` dependency supports retaining locked online prefetching.

**D2-S2 is resolved.** The kernel limits total `600 + 600 + 600 + 1200 + 1500 = 4500` seconds inside a 5100-second outer limit, leaving 600 seconds for startup and final recording. When `target/osdk` is absent, the guard takes the successful `echo` branch instead of invoking `find`.

**D2-S3 is resolved** for timeout values. D3-S2 records the separate wording defect. **D2-C1 remains Low**, while D3 itself satisfies the sign-off rule. **D3 remains on hold pending D3-S1.**

The remaining checks passed:

- Both requested diffs stay within the allowed paths: seven changed files from `1cb2d10`, six from `bcf6969`. Only `run.sh` and `INSTRUMENTATION.md` entries change in the snapshot manifest.
- Both Linux-control paths and both guest paths retain `--network=none`. D1’s daemon selection, resource limits, individual KVM exposure, mounts, image pin and cleanup remain unchanged.
- All 27 supplied hashes match both working files and `7b134f8`. All 25 snapshot entries match their frozen files, live counterparts and committed copies, with no unmanifested files. The earlier reviews’ hashes also match their respective commits.
- The inspected OSDK source and supporting manifests/lockfiles match source commit `0c60537098f4c2949ad2d382aaf499de72263d76`.
- C1’s container-local QMP path remains 45 bytes including NUL, with unchanged cleanup. Clock stamps, calibration, interval encoding, refusals and model inputs remain unchanged. Earlier reasoning continues to support exactly `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND`. R2 remains open for real global order, store visibility and a run-wide clock bound.

Python and Bash syntax checks, including embedded shell programs, and both `git diff --check` checks passed. The workspace remains clean. No files were written and no Docker, builds, QEMU or TLC ran. The historical v3 receipt still requires controller rebinding to the installed v5 receipt.

**REVIEWED INPUTS**

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
b14b314df18447d6eef22ebff83fcd1a38ae6c18d20c10ceb3495a0294fa7606  run.sh
88ee9bbdf9ddc932e2752a72698f529e3454ae93353b01687ae6a48142c0d448  apply.sh
3c4f08d4c83a9fa1477ea55b2ab779851f1bf3fa5ff27b6bfc8470a74021b044  clean.sh
eba30152db35a608f521984474ad0ad7bab0ef67e7785b7259b50a116003efbc  cases.tsv
10de68e9ba57e7749ecb5dbbc86ebc0c2fd838858e7ae5eebe42f3a56ee005fb  patches/instrumentation.patch
1e0fba48688badb9a8faf82632a6c9f0524d5ec3961733ff52ae03315728cc8d  evidence/applied.json
74c5a3352af60e0a572acdf7da6e58ead5a49fd274b74b8cb79a87fe8a78f97b  INSTRUMENTATION.md
88f6b43c9d8d7b4350af1a268ccf1f89ee43e18d19f60e1f584dc88efd45b4a3  STATUS.md
fcaca87d2aa3f748f9e0dff21faa9b1ee242f1d9cd4170be48e8f8e03130134d  evidence/clock-method-v4.md
252e97d05d2216ef6714f2679169e00a8c56df7d5d5d16bac1007bf67528c752  evidence/clock-method-v5.md
49f6a47ce73dbb6e11f6ecdc3ecde6b5640d29eb097840ab3fb9fa103b8bea2b  evidence/v5-inputs.json
db763ad933f9bb2ad237bec9eb448dcb645c188febe3a10fbeda1b7589bdc940  evidence/candidate-v5/hashes.json
abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10  ../spec/base.tla
94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3  ../spec/Trace.tla
82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0  ../spec/Trace.cfg
a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824  ../spec/TraceSearch.cfg
69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d  ../spec/instrumentation-spec.md
```

