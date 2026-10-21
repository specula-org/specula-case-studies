# Candidate v5 amendment D4: log the generated kernel lockfile

Author: lane controller (Claude), 2026-10-06. Trigger: `review-v5d.md` (NOT_APPROVED for D3).

D3-S1 (Medium): the lockfile logger searched `target/osdk`, but `osdk build --output` places the
generated workspace (for package `asterinas`, `asterinas-run-base/`) under
`/work/.specula-output/harness/build/kernel`. D4 logs the hash and contents of every
`Cargo.lock` within two levels of that directory and prints `WR_NO_GENERATED_KERNEL_LOCKFILE`
if none exists. The `target/osdk` search is removed.

D3-S2 (Low): `INSTRUMENTATION.md` now says that both build containers use the network for rustup
targets and that only the kernel container fetches locked Cargo dependencies.

D2-C1 (Low): commit `bcf6969` cannot gain a sign-off without rewriting the scratch workspace
history, which would orphan the hashes cited by `review-v5c.md`. D3 and D4 carry sign-offs.

Only `run.sh`, `INSTRUMENTATION.md`, their frozen copies and `candidate-v5/hashes.json` change.
The author does not approve this change.
