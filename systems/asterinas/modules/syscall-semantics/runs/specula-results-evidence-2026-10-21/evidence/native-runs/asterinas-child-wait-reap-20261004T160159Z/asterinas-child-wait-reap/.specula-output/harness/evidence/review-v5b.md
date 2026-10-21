VERDICT: APPROVED

- **S1 — Low — New prose violates the supplied semicolon rule.** [run.sh:20](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/run.sh:20), its frozen copy, and [d1-amendment.md:14](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/evidence/d1-amendment.md:14) join clauses with semicolons. Minimal fix: split those sentences, keep both runner copies identical, and refresh the manifest.
- **S2 — Low — The amendment commit lacks the required sign-off.** `git show -s --format=raw 1cb2d10` shows no `Signed-off-by:` trailer. Minimal fix: add the trailer using the repository’s configured identity.

No High or Medium findings. Spec findings: `[]`.

**D1 disposition: ACCEPTED.**

`git diff 7e0fb7e 1cb2d10` changes exactly the six allowed files. Both runner edits contain only the `docker_cmd` replacement and its explanatory comment. Only the `run.sh` entry changes in the snapshot manifest.

The Docker compatibility review found:

- **Resource limits remain supported.** The supplied cgroup v2/systemd configuration and delegated `cpu`, `memory`, and `pids` controllers support `--cpus=2`, `--memory=8g`, and `--pids-limit=512`. Read-only cgroup inspection corroborated delegation and found `memory.swap.max`. Equal `--memory` and `--memory-swap` values retain the no-swap setting. Missing `cpuset` delegation does not disable `--cpus`. [Docker rootless limits](https://docs.docker.com/engine/security/rootless/tips/#limiting-resources), [memory/swap semantics](https://docs.docker.com/engine/containers/resource_constraints/#--memory-swap-details).
- **Network isolation remains applicable.** `--network=none` supplies only loopback and does not depend on rootless port forwarding. [Docker none network](https://docs.docker.com/engine/network/drivers/none/).
- **KVM exposure remains compatible, with different permission semantics.** Rootless Moby removes device-cgroup rules, and runc exposes existing device nodes through bind mounts. Thus implicit `rwm` does not provide rootful device-cgroup enforcement or grant `mknod` privileges. QEMU uses the existing `/dev/kvm` node and still requires host permission. The supplied memfd configuration supports compatibility but is not proof of D1 guest execution. [Moby conversion](https://raw.githubusercontent.com/moby/moby/master/daemon/internal/rootless/specconv/specconv_linux.go), [runc device setup](https://raw.githubusercontent.com/opencontainers/runc/main/libcontainer/rootfs_linux.go).
- **Bind mounts retain their requested access modes.** `/work` remains writable and `/fixture:ro` remains read-only. The pinned image configuration was independently hashed against the image ID and has no user override. New files written by container UID 0 therefore map to host UID 1000 and the daemon user’s GID. Host-shell redirects were already user-owned. The receipt and collector check contents rather than host-root ownership, and the generated initramfs explicitly encodes UID/GID zero. [Docker UID/GID mapping](https://docs.docker.com/engine/security/rootless/uid-gid-mapping/).
- **Image selection and cleanup remain consistent.** `image inspect`, all six `run` call sites, and the EXIT trap’s `rm -f` use the same amended array. The pinned ID, `--pull=never`, `--rm`, container names, and timeouts are unchanged.

All **27 supplied hashes** match both the working files and commit `1cb2d10`. All **25 frozen files** match the manifest and their live counterparts. The unmodified `review_gate.check()` accepts the current inputs in diagnostic and consistency modes with a hypothetical valid receipt supplied entirely in memory. It rejects the pre-D1 runner hash and rejects consistency mode under a diagnostic-only receipt. The actual receipt remains `INCOMPLETE`.

D1 invalidates none of the remaining review-v5/review-v5a approval reasoning. C1’s container-local QMP path and cleanup remain intact. The C2 correction is present. Approval retains exactly `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND`; R2 remains open for real global order, store visibility, and a run-wide clock bound. Controller installation and rebinding to the installed v5 receipt remain prerequisites.

The workspace remains clean. No files were written, and no Docker, build, QEMU, or TLC commands ran.

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
1058ff203b1a6888de9ebe8b3fbfb2e16fa33b2f3d91f4aa8f8b692d009f8910  run.sh
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
da27ed14c28b2b1bf41ad52662c6abb5b9bdb2fa14e39ff926465a71ac74cd5b  evidence/candidate-v5/hashes.json
abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10  ../spec/base.tla
94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3  ../spec/Trace.tla
82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0  ../spec/Trace.cfg
a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824  ../spec/TraceSearch.cfg
69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d  ../spec/instrumentation-spec.md
```

