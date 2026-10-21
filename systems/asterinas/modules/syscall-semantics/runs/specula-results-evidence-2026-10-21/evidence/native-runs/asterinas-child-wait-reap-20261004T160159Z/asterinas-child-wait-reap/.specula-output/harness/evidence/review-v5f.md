VERDICT: APPROVED

**D5-S1 — Low — CPU-measurement failures can produce an unmeasured count of 2.**

Evidence: [nproc_probe.c:12](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/nproc_probe.c:12) accepts any positive `sysconf` result, and [initramfs.py:9](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/initramfs.py:9) discards the separate affinity count. Glibc tries sysfs, `/proc/stat`, then affinity, but ultimately returns a guessed `2` if measurement fails. That error path could satisfy the boot count check without establishing two CPUs. [glibc 2.39 implementation](https://raw.githubusercontent.com/bminor/glibc/glibc-2.39/sysdeps/unix/sysv/linux/getsysstats.c)

This is nonblocking for the pinned guest: its implemented affinity syscall returns the actual mask, and no trigger for measurement failure was established. Missing sysfs alone does **not** make this guest report a false `2`.

Minimal fix: use a successful, positive affinity count as the probe’s result and propagate probe failure before emitting the marker.

No High or Medium findings.

**D5 disposition: ACCEPTED at `e9893140ebd3403ee99ccbb79ef98dc923da3fdf`.**

- **Scope and hashes pass.** `git diff b8aa643 e989314` changes exactly the eight permitted files. All 28 supplied hashes match both working files and committed contents. All 26 snapshot entries match their manifest, live counterparts and committed copies, with no unmanifested snapshot files. Only the runner, initramfs generator and new probe entries change in `hashes.json`.

- **The normal guest count is measured correctly.** This initramfs mounts neither `/sys` nor `/proc`, so glibc reaches affinity. The pinned [Asterinas syscall](/home/chin39/Documents/play/Specula/runs/asterinas-child-wait-reap-20261004T160159Z/asterinas-child-wait-reap/source/kernel/core/src/syscall/sched_affinity.rs:114) returns the actual mask and its byte length. Initial affinity covers the guest’s CPU set. Glibc counts only returned bytes. Consequently, a functioning single-CPU guest reports `1`. The generated init contains exactly one marker before `exec /fixture`, and unchanged [boot.py:58](/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/wait-reap/harness-fix-ws/harness/src/boot.py:58) rejects missing, duplicate or mismatching counts.

- **BusyBox and packaging checks pass.** Offline inspection of the pinned image’s layers verified BusyBox SHA-256 `040f27e8c6075fcd7aefcd977d7c39cb9d35880c318a6ffc2db336353eb6f9fd`, ELF64 x86-64 format and absence of `PT_INTERP`. The runner checks its hash and shell availability, compiles the probe with `-static`, rejects either binary having an interpreter, and records both hashes and program-header dumps. The probe itself was not built during review. In-memory checks of the actual cpio writer confirmed valid headers, alignment, executable modes, parent-before-child ordering and trailer for `bin/`, `bin/busybox`, `bin/nproc_probe`, `init` and `fixture`.

- **The rustup volume is appropriately scoped.** `specula-wait-reap-20261005-rustup` mounts only at `/root/.rustup` in this lane’s two build containers. It does not cover source or evidence directories. Its name and destination are recorded in the reviewed runner and amendment, while toolchain identity and installed targets remain logged. Image-layer inspection confirmed the seed directory and pinned toolchain settings. Docker populates an empty volume from that directory and preserves a named volume across container removal. Actual creation and seeding were not executed. [Docker volume semantics](https://docs.docker.com/engine/storage/volumes/)

- **Timeouts and prior controls remain intact.** Fixture compilation limits total 240 seconds within the enlarged 1800-second outer limit. Kernel limits still total 4500 seconds within 5100, leaving 600 seconds of headroom. Linux-control and guest timeout pairs remain unchanged. Clock method, collector, hooks, fixtures, cases, model, memory admission and network policy are unchanged.

Approval retains `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND`. R2 remains open for real global order, store visibility and a run-wide clock bound. The reviewed v3 installation receipt still requires controller rebinding to the installed v5 receipt.

Python/Bash syntax and diff checks passed. The worktree remains clean. No files were written and no Docker, builds, QEMU or TLC ran.

REVIEWED INPUTS

```text
8c32b9c9bb4fb7efa68013d0fcc35b06bc3629adad0047702196b7b4fd3330bd  src/boot.py
f47ea876227669dd3ded951d661a1716b9c8b75b2cc2abfc25575dbd20e7d283  src/collect.py
ee83062435d51ac1563cd638c1e06bf8c5da13392aa40f0f945e25d331c096e4  src/initramfs.py
3cdd3187ca71d4f3705063e010ebea20995d30947f08f84ef8544128a4e21ef7  src/instrument.py
124457dd18d700a8a3080f87956e34f578da7ef982b3aa8cbfafe965be1c14bb  src/Makefile
3eb8516d5a452957ded5d66c98e1068d6941a0d998981bd6c2b04c8a7241b78f  src/nproc_probe.c
2d23fd66b008a1f41938dd4fee0348397af01949133b7c7af30581399c9dae9e  src/review_gate.py
e591d0b635f3854038d8323ba03565a359fc38768b0bfc3173d61d08e04671c3  src/wait_calibration.c
c321494aed02c1bfb89d676b7c2c1ed5f1ecd9c9923400be76f43a929d232e12  src/wait_reap_trace.c
aee0e9ad96b463d2524a5ad5498b665b8dc6e5be37cad99309b8e0576f21d38b  src/wr_syscall.rs
ec9aed3f6b032b626f86ff8a97636ecaa37e6f3fa037662264889cd445232219  src/wr_trace.rs
396bc6f72d9ce5571443d07e09e24e8a163a040a0936dde7677dc1d1fdb62eea  run.sh
88ee9bbdf9ddc932e2752a72698f529e3454ae93353b01687ae6a48142c0d448  apply.sh
3c4f08d4c83a9fa1477ea55b2ab779851f1bf3fa5ff27b6bfc8470a74021b044  clean.sh
eba30152db35a608f521984474ad0ad7bab0ef67e7785b7259b50a116003efbc  cases.tsv
10de68e9ba57e7749ecb5dbbc86ebc0c2fd838858e7ae5eebe42f3a56ee005fb  patches/instrumentation.patch
1e0fba48688badb9a8faf82632a6c9f0524d5ec3961733ff52ae03315728cc8d  evidence/applied.json
f98929327fc4408abc4c5cbff93861116f5f4fbd23296d1b9fbb66e34ce52778  INSTRUMENTATION.md
88f6b43c9d8d7b4350af1a268ccf1f89ee43e18d19f60e1f584dc88efd45b4a3  STATUS.md
fcaca87d2aa3f748f9e0dff21faa9b1ee242f1d9cd4170be48e8f8e03130134d  evidence/clock-method-v4.md
252e97d05d2216ef6714f2679169e00a8c56df7d5d5d16bac1007bf67528c752  evidence/clock-method-v5.md
49f6a47ce73dbb6e11f6ecdc3ecde6b5640d29eb097840ab3fb9fa103b8bea2b  evidence/v5-inputs.json
8e3b936025a6028c5794ae568006a5f6abc34ae044173d8b88096e0a7cdb32f1  evidence/candidate-v5/hashes.json
abe074fc44af1d20769708c927dc0826284e2b31c512e02ba12bc460b8104f10  ../spec/base.tla
94268b234a91a0182cc1c298ca9d04e000d2d62c8f60882e841d93c0ecaa05c3  ../spec/Trace.tla
82d1903ce6ef8e20be1f15cd152ad8c2f3553a7cfdb15673493baf5cfac498b0  ../spec/Trace.cfg
a4fa6a110e244d50ae2275d2e6f3d2a9d64e689314fbe1232bf5e390387bb824  ../spec/TraceSearch.cfg
69d549309d139255ad1debc1083f3c7dd6584259bf1fc05f5dbd605581e6668d  ../spec/instrumentation-spec.md
```

