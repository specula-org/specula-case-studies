# AST-07 reproducer (ostd ktest)

AST-07 is not reachable from userspace. The reproducer is a kernel test
module for `ostd` that uses only safe, public `ostd::mm` APIs. It does not
modify the code under test.

## Files and where they came from

| File | Source | Notes |
|---|---|---|
| `verification-package.md` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-07-segment-empty-slice/verification-package.md` | The external CR-11 package: claim, expected output, falsification criteria, fix direction. It embeds the harness (§6) and driver (§7). |
| `test_bugCR-11_empty_slice_conversion.rs` | `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scripts/harness/cr11_repro.rs` | Byte-identical to the §6 listing in the package. This is the ktest module. |
| `test_bugCR-11_empty_slice_conversion.sh` | Extracted from §7 of the package | One fix applied, see below. |
| `OSDK.cr11.toml` | `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scripts/OSDK.cr11.toml` | The `ostd/OSDK.toml` used on 2026-09-02: `qemu-direct` boot, 8G, SMP from `$SMP`, QEMU exception logging to `$KTEST_QEMU_LOG`. |
| `run-cr11-validation-2026-09-02.sh` | `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scripts/run-cr11.sh` | The exact loop run on 2026-09-02. **Environment-specific:** its default `SCRATCH` is a session scratch directory under `/tmp/claude-1000/...` that no longer exists. Set `SCRATCH` so that `$SCRATCH/aster-pin` is your worktree. |

**Driver fix.** Line 87 of the extracted driver originally read
`for t in "${TESTS[]}"; do`, which bash rejects as a bad substitution. It is
changed to `for t in "${TESTS[@]}"; do`. Nothing else was changed.

## Where the files go in an Asterinas tree

1. Copy `test_bugCR-11_empty_slice_conversion.rs` to
   `ostd/src/mm/frame/cr11_repro.rs`.
2. In `ostd/src/mm/frame/mod.rs`, register the module just before the existing
   ktest module:

   ```rust
   #[cfg(ktest)]
   pub(crate) mod cr11_repro;
   #[cfg(ktest)]
   mod test;
   ```

3. Optional, and what the 2026-09-02 run did: copy `OSDK.cr11.toml` to
   `ostd/OSDK.toml`. OSDK reads the manifest from the current directory first,
   so this file fully overrides the workspace-root `OSDK.toml` while tests run
   from `ostd/`. It boots `qemu-direct`, which avoids the OVMF/GRUB path.

The driver script does steps 1 and 2 itself (idempotently) and leaves the
module in place afterwards.

## Build and run

Build `cargo-osdk` from the same worktree, with `OSDK_LOCAL_DEV=1`. OSDK bakes
its own source path in at compile time. A binary built elsewhere tests that
other tree's `ostd`, and one built without `OSDK_LOCAL_DEV=1` pulls `ostd`
from crates.io.

```sh
cd /path/to/asterinas
OSDK_LOCAL_DEV=1 cargo build --manifest-path osdk/Cargo.toml   # inside the Asterinas dev environment (nix develop or the asterinas/dev Docker image)
```

Run each test in its own boot, because one of them can kill the kernel:

```sh
cd ostd
for t in cr11_l0_empty_slice_round_trip_matrix \
         cr11_l0_empty_slice_answers_from_a_foreign_frame \
         cr11_l0_empty_slice_at_end_boundary_faults \
         cr11_l0_max_tracked_boundary_probe; do
  SMP=2 KTEST_QEMU_LOG=/tmp/$t.qemu.log \
    ../osdk/target/debug/cargo-osdk osdk test "cr11_repro::$t" --target-arch x86_64 \
    > /tmp/$t.log 2>&1
  grep -aoE 'CR11\|[^ ]*|test result:.*' /tmp/$t.log
done
```

The ktest whitelist matches whole path suffixes, so each test must be named in
full (`cr11_repro::<name>`). Alternatively run
`./test_bugCR-11_empty_slice_conversion.sh /path/to/asterinas`, which installs
the module, builds OSDK if needed, runs the four tests, and prints the
`CR11|` markers and a hard-fault check. On 2026-09-02 each boot took under a
minute under TCG. Budget up to 2400 s for the first OSDK and kernel build.

`SMP=2` matches the recorded runs. The bug is not a concurrency bug.

## Reading the output

Two FAILED tests are the positive result.

| Test | Bug present | Bug absent |
|---|---|---|
| `round_trip_matrix` | `test result: FAILED`, `CR11\|matrix\|FAILURE\|n=1\|case=empty@end` | `ok`, `end_round_trip_ok=true` |
| `answers_from_a_foreign_frame` | `FAILED`, `adjacency=obtained`, `round_trip_ok=false`, `accepted_as_usegment=true` | `ok` |
| `at_end_boundary_faults` | Hard-fault form: `CR11\|fault\|about_to_call` with no later `survived` line and no `test result:` line. Wrong-answer form (seen at `604948581`): `CR11\|fault\|survived\|round_trip_ok=false` and `FAILED` | `survived\|round_trip_ok=true`, `ok` |
| `max_tracked_boundary_probe` | `ok` (environment probe only) | `ok` |

The run is invalid if any control fails (`control_ok=false`,
`control_round_trip_ok=false`, or `control_accepted_as_usegment=true`), or if
the foreign-frame test prints `adjacency=not-obtained` (it then self-skips and
must not be counted). If `from_in_use=...|Ok(in use)` appears in the fault
test, the frame past the end was in use and the framing needs review. The full
list is in `verification-package.md` §10.
