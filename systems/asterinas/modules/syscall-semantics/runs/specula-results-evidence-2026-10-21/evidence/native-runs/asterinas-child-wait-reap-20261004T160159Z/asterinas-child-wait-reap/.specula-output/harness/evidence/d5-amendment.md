# Candidate v5 amendment D5: guest BusyBox, CPU probe and rustup cache

Author: lane controller (Claude), 2026-10-09. Trigger: execution attempt d4m-1
(`evidence/20261009T125438Z-2170233-3e62b95a984641e1ab7b2ed689bca884`). Memory was admitted
(effective 44.5 GB). Rustup installed the four missing targets over the network, which took
most of the fixture container's 900 s. Both fixture builds then succeeded. The container
failed at `/bin/busybox --list` (`No such file or directory`), and `timeout` ended the attempt
with exit 124. No Linux control, kernel build or guest ran.

Findings from read-only throwaway containers of the pinned image:
- There is no `/bin/busybox`. The only static x86-64 BusyBox is
  `/nix/store/303jirpnxxqssvpansrgxy7vk6zdyj9g-busybox-1.37.0/bin/busybox` (sha256
  `040f27e8…`, no INTERP). It provides `sh`/`ash` but no `nproc` applet. The x86-64 BusyBox with
  `nproc` is dynamically linked against a Nix glibc.
- A static C probe built with the image's `cc -static` prints `sysconf(_SC_NPROCESSORS_ONLN)` and
  the affinity count. Under that BusyBox's `sh`, the new init line produced
  `WR_GUEST_NPROC <online>`.

Changes:
- `run.sh`: copy the pinned static BusyBox after verifying its hash, compile
  `src/nproc_probe.c` statically, and refuse if either binary has an ELF interpreter. Record both
  hashes and both program-header dumps as evidence.
- `src/initramfs.py`: take the probe path as a new argument, add `bin/nproc_probe` to the cpio,
  and derive `WR_GUEST_NPROC` from the probe's online count instead of `busybox nproc`.
  `boot.py` still requires `WR_GUEST_NPROC` to equal `-smp` (2).
- New `src/nproc_probe.c`.
- Both build containers mount the lane-owned named volume `specula-wait-reap-20261005-rustup` at
  `/root/.rustup`. Docker seeds it from the image on first mount, so the kernel build reuses the
  fixture build's rustup downloads. The fixture-build outer timeout grows from 900 to 1800 s.

No instrumentation, hook, fixture, collector, clock, case, model or memory-gate logic changed.
The author does not approve this change. It needs independent review before the receipt is
rebound or anything executes.
