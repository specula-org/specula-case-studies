# Candidate v5 amendment D3: locked dependency fetch and nested build timeouts

Author: lane controller (Claude), 2026-10-06. Trigger: `review-v5c.md` (NOT_APPROVED for D2) with
two Medium findings.

D2-S1: D2 dropped `CARGO_NET_OFFLINE`, so OSDK's generated kernel workspace, which has no
lockfile, could resolve newer dependency versions online. The reviewer's minimal fix of
restoring offline mode alone does not work here. An offline `cargo fetch --locked --offline` in
a throwaway container of the pinned image failed for both the root workspace (git dependency
`inherit-methods-macro` absent) and `osdk/`. D3 therefore fetches dependencies online with
`--locked` from the checked-in lockfiles, then sets `CARGO_NET_OFFLINE=true` before building
OSDK and the kernel. The OSDK build can then only use cached versions and cannot select newer
ones online. The generated workspaces' `Cargo.lock` files are logged with hashes after the
build as dependency provenance.

D2-S2: the kernel container's inner limits are now 600 (rustup show) + 600 + 600 (two locked
fetches) + 1200 (OSDK cargo build) + 1500 (osdk build) = 4500 s, inside a 5100 s outer limit.

D2-S3: `INSTRUMENTATION.md` (live and frozen) now states the 15-minute fixture-build and
85-minute kernel-build limits and that guest and Linux-control containers have no network.

D2-C1: this commit carries a sign-off.

Only `run.sh`, `INSTRUMENTATION.md`, their frozen copies and `candidate-v5/hashes.json` change.
The author does not approve this change.
