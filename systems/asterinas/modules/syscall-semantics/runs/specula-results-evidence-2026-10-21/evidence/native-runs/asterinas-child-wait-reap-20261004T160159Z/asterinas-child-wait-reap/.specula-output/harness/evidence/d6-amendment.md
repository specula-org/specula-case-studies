# Candidate v6 amendment D6: seed the generated kernel workspace lockfile

Author: lane controller (Claude), 2026-10-10. Trigger: outcome run v6-outcome-1
(`evidence/20261010T031219Z-997598-0df77ae38d724934bf0724aa7245307d`). All 21 Linux outcome
controls ran. The kernel build then failed offline:
`failed to get smoltcp ... unable to update https://github.com/asterinas/smoltcp?tag=r_2026-08-11_1b7629c ...
failed to lookup reference in preexisting repository, and can't check for updates in offline mode`.
OSDK's generated base crate (`asterinas-run-base`) has no lockfile, so offline Cargo had to
resolve the git tag, and the `cargo fetch --locked` cache holds commits, not that tag ref. No
guest ran.

Change (in `run.sh` and its frozen copy only): before the offline `osdk build`, copy the
checked-in root `Cargo.lock` into the generated workspace. The root lock pins smoltcp to
`#56ab8379…` for that tag. If the base crate does not exist yet, one offline generation pass runs
first and is expected to fail. OSDK reuses an existing base crate whose `Cargo.toml`, `main.rs` and
linker scripts are unchanged (`osdk/src/base_crate/mod.rs:54-68`), so the seeded lock persists. The
log records the seed hash and the diff between the seed and the lockfile Cargo leaves behind.
The kernel container's inner limits become 600+600+600+1200+300+1500 = 4800 s inside a 5400 s
outer limit.

Pre-review check in a throwaway container (bridge network, lane rustup volume, run directory
read-only): after `cargo fetch --locked` at the source root, a copy of the generated base crate
with the seeded root lock passed `CARGO_NET_OFFLINE=true cargo metadata` (exit 0).

The guest outcome path, collector, cases, clock method, memory gate, network policy and image
pin are unchanged. The author does not approve this change.
