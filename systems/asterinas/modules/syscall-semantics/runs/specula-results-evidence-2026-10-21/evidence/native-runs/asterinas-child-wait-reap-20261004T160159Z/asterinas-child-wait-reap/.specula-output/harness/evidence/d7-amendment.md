# Candidate v6 amendment D7: pin Linux controls with taskset and fetch build-std dependencies

Author: lane controller (Claude), 2026-10-10. Trigger: outcome run v6d6-1
(`evidence/20261010T032223Z-1016710-62e0092bfce341908bcef96a09b2d60c`). Two failures, and no
guest ran.

1. Every Linux control aborted at the fixture's `affinity_count == 2` assertion
   (`wait_reap_trace.c:439`), after Docker printed `WARNING: Your kernel does not support cpuset
   or the cgroup is not mounted. Cpuset discarded.` The rootless daemon has no cpuset controller,
   so `--cpuset-cpus` is silently dropped and the container sees 24 CPUs. All 21 Linux outcomes
   are therefore `inconclusive`.
2. The kernel build passed the seeded-lockfile step (D6), then failed offline in build-std:
   `no matching package named rustc-literal-escaper found ... required by package proc_macro
   (... rustlib/src/rust/library/proc_macro)`. The sysroot library workspace's dependencies
   were never fetched.

Changes (in `run.sh` and its frozen copy only):
- The outcome-mode Linux control also passes `-e WR_LINUX_CPUS=<the two selected CPUs>`. Inside
  the container, `taskset -c` wraps both the `nproc` report and the fixture. When the variable
  is unset (consistency mode), the command is unchanged. `--cpuset-cpus` stays in place for
  daemons that support it.
- Before switching Cargo offline, the kernel container runs
  `cargo fetch --locked --manifest-path "$(rustc --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml"`,
  the sysroot's own lockfile. The inner limits become 5400 s inside a 6000 s outer limit.

Pre-review checks in throwaway containers:
- With `WR_LINUX_CPUS=0,1`, the Linux fixture printed `WR_CONTROL_NPROC 2`, ran `nohang 37`
  in outcome mode to `WR_OUTCOME_COMPLETE`, and reported affinity_count 2 (rc 0).
- The sysroot `cargo fetch --locked` succeeded over bridge networking with the lane rustup volume.
- Not checked: whether the full offline kernel build now succeeds, since that needs the heavy
  lock.

The author does not approve this change.
