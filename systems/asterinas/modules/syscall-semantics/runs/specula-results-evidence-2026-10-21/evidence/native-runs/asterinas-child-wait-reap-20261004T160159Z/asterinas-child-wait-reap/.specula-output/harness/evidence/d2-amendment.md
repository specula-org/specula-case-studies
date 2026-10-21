# Candidate v5 amendment D2: networked build containers

Author: lane controller (Claude), 2026-10-06. Trigger: execution attempt d1-1
(`evidence/20261006T021533Z-3044447-2a78b8fc141249778a9100e30e7ba368`). Memory was admitted at
13.66 GB and the pinned image was found. The fixture-build container then failed at
`rustc --version`, because rustup tried to download
`channel-rust-nightly.toml.sha256` with `--network=none`. The source's `rust-toolchain.toml` pins
`nightly-2026-07-21` with targets x86_64-unknown-none, riscv64imac-unknown-none-elf,
loongarch64-unknown-none-softfloat and aarch64-unknown-none-softfloat. The pinned image has the
toolchain but only the x86_64-unknown-linux-gnu target, checked read-only with
`rustup target list --installed` in an offline throwaway container. The kernel-dev image in the
rootful daemon also lacks these targets. The earlier memfd harness built the same pin from the
same image with host networking.

Changes, in `run.sh` and its frozen copy only:
- The fixture-build and kernel-build containers use `--network=bridge` instead of
  `--network=none`. A throwaway rootless container reached static.rust-lang.org and
  index.crates.io (HTTP 200). Linux-control and guest containers keep `--network=none`.
- `CARGO_NET_OFFLINE=true` is removed from the kernel build, and `--locked` stays.
- The build logs record `rustup show` and the installed targets, so provenance shows what was
  downloaded.
- Timeouts grow to cover first-use downloads and a cold build. The fixture-build container goes
  from 180 to 900 s, the kernel-build container from 1800 to 3600 s, the OSDK cargo build from
  900 to 1200 s, and `osdk build` from 1500 to 2400 s.

No instrumentation, hook, fixture, collector, clock or case logic changed. The author does not
approve this change. It needs independent re-review before execution.
