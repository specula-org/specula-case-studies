# Running a userspace reproducer on Asterinas and Linux

This guide is for an agent that has to run one of the package's userspace
reproducers (a `repro/*.c` file) against an Asterinas kernel in QEMU and
compare the result with Linux. It describes the procedure that produced the
recorded AST-01..06 and AST-09 results. The kernel-side reproducers for AST-07
and AST-08 are ostd ktests with their own procedure, described in their
`repro/README.md` files.

Everything below was taken from recorded scripts and handoff notes in the
workspace that produced this package. Paths under `/home/chin39/...`,
`/nix/store/...`, and `/tmp/claude-1000/...` are **environment-specific**:
they show what was run on that machine, not something your machine has.

## What you need

- An Asterinas checkout at the commit you want to test, with a clean tree
  apart from the edits described here. Record its commit and dirt before you
  start.
- One way to build and boot Asterinas:
  - the official Docker image (`asterinas/dev:<version>`, for example
    `asterinas/dev:0.18.1-20260805` as the 01a and GLM runs used), with
    `/dev/kvm` passed through, or
  - a native toolchain. The recorded 2026-09-02 runs used a Nix dev shell
    (`nix develop` in a checkout that carries a local `flake.nix`, branch
    `feat/nix-flake-devenv` in `/home/chin39/Documents/asterinas`;
    environment-specific, because upstream Asterinas has no flake).
- A Linux host with a C compiler for the control run.
- KVM for the Asterinas guest. The recorded userspace runs used QEMU/KVM with
  8 GiB of guest memory.

## The workflow in one paragraph

Compile the reproducer on Linux and run it as the oracle. For Asterinas, put
the same source into the initramfs regression tree so the image build
compiles it, add a small driver script that runs it and prints begin/end
markers, boot the kernel with that script as the init program, capture the
console, and compare the marker lines with the Linux output. Use `SMP=2` or
more for anything involving concurrency. The guest has no C compiler, so the
`run.sh` files in the package (which call `cc`) only work on Linux.

## Step 1: Linux control

```sh
cc -Wall -O2 -o /tmp/ast05 repro.c            # add -pthread for AST-03
mkdir -p /dev/shm/ast05 && /tmp/ast05 /dev/shm/ast05
```

Pick the Linux filesystem that plays the role of the Asterinas one:

| Asterinas target | Linux control used in the records |
|---|---|
| ramfs (`/`, `/tmp`, `/mc3`) | tmpfs (`/dev/shm/...`) |
| ext2 (`/ext2`) | ext4 directory (the host had no ext2 mount) |
| exFAT (`/exfat`) | not run on Linux |
| pipes (AST-09) | no filesystem needed |

The recorded controls ran a separately compiled binary (host gcc) rather than
the exact binary the guest ran. That is a known weakness. If you need a
stricter comparison, build one static binary, run it on both sides, and print
its SHA-256 in the guest, as `tools/rw-matrix/run-guest.sh` in the workspace
does (`RWM_SHA256` line, compared against the host hash).

## Step 2: Put the reproducer into the initramfs

The 2026-09-02 validation added a scratch test directory `io/specula` to the
regression tree. In your checkout:

```sh
D=test/initramfs/src/regression/io/specula
mkdir -p $D
cp /path/to/findings/AST-05-ramfs-read-past-eof/repro/repro.c $D/ast05.c
cat > $D/Makefile <<'EOF'
# SPDX-License-Identifier: MPL-2.0

EXTRA_C_FLAGS := -static -lpthread

include ../../common/Makefile
EOF
```

Then list the directory in `test/initramfs/src/regression/io/Makefile`:

```make
SUBDIRS := \
	epoll \
	eventfd2 \
	file_io \
	specula \
```

What this gives you:

- The regression build (a Nix derivation, also inside the Docker image)
  compiles every `*.c` in the directory to `/test/io/specula/<name>` in the
  guest, statically linked, and copies every `*.sh` next to them.
- The common Makefile adds `-Wall -Werror -D__asterinas__`. A source that
  warns will not build. The catalog reproducers built unmodified on
  2026-09-02.
- The `Makefile` above is the one the 01a harness used
  (`.specula-output/harness/src/specula-Makefile` in the 01a run). The exact
  `io/specula/Makefile` of the 2026-09-02 run was not saved, because it was an
  untracked scratch file.

The 01a and GLM runs used other directories (a separate Nix package for
`io/specula`, or `io/file_io/`). Any registered regression subdirectory works.

## Step 3: Write a guest driver script

Put a shell script in the same directory and make it executable. This is
`/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/run_ast_all.sh`,
the driver of the 2026-09-02 run:

```sh
#!/bin/sh
# Guest driver: run every AST userspace reproducer once, print marker lines.
echo "AST_BOOT_OK"
T=/test/io/specula
run() {
  name=$1; shift
  echo "AST_BEGIN $name"
  "$@" 2>&1
  echo "AST_EXIT $name rc=$?"
  echo "AST_END $name"
}
mkdir -p /mc3
run AST-01-ext2   $T/ast01 /ext2
run AST-02-ramfs  $T/ast02 /
run AST-03-ramfs  $T/ast03 /
run AST-04-both   $T/ast04 /mc1-regular-file /ext2/mc1-regular-file
run AST-05-ramfs  $T/ast05 /mc3
run AST-06-ext2   $T/ast06 /ext2
run AST-06-ramfs  $T/ast06 /tmp
run AST-09-pipe   $T/ast09
echo "AST_ALL_DONE"
```

```sh
cp run_ast_all.sh test/initramfs/src/regression/io/specula/ && chmod +x test/initramfs/src/regression/io/specula/run_ast_all.sh
```

In the guest, `/` and `/tmp` are ramfs. The initramfs `init` script mounts
ext2 on `/ext2` (`/dev/vda`) and exFAT on `/exfat` (`/dev/vdb`) before it runs
the init arguments, and it powers the VM off when they exit. Create any
directory a reproducer expects (AST-05's `run.sh` expects `/mc3`).

## Step 4: Boot with the driver as init

The upstream Makefile has no switch that runs an arbitrary init script with
the regression tests built in. The 2026-09-02 run added a scratch hook to the
top-level `Makefile`, just before the `include .../xfstests/build_config.mk`
line (see
`/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scratch-worktree-tooling.diff`):

```make
# scratch-only: run a custom guest init script (validation harness)
ifneq ($(AST_INIT),)
ENABLE_REGRESSION_TEST := true
CARGO_OSDK_BUILD_ARGS += --init-args="$(AST_INIT)"
endif
```

Then boot. The exact 2026-09-02 command line was not recorded. The flags below
are the ones every recorded `make run_kernel` invocation in that workspace
used:

```sh
rm -rf target/osdk        # always, after any change under test/initramfs/ (see pitfalls)
timeout 3000 make run_kernel AST_INIT=/test/io/specula/run_ast_all.sh \
    SMP=2 CONSOLE=ttyS0 INITRAMFS_SKIP_GZIP=1 \
    > guest.log 2>&1
```

Add `CARGO_OSDK=<checkout>/osdk/target/debug/cargo-osdk` when you use a
worktree-local OSDK (see pitfalls). The default `SMP` is 1, so set it
explicitly. The default memory is `MEM=8G`.

Docker instead of a native toolchain: the 01a confirmation drivers
(for example
`/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-2_retained_write_prefix_efault.sh`)
mount the checkout at `/root/asterinas`, pass `--device=/dev/kvm`, set
`RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu`, and run
`make kernel` followed by `make run_kernel SMP=2 CONSOLE=ttyS0 ...` with their
own init hook (`SPECULA_INIT`, from the 01a harness patch). Inside the image
the OVMF firmware is at the path the upstream scripts expect, so the OVMF
patch below is not needed there.

For interactive work, the Makefile also builds the regression binaries without
an init script: `make run_kernel ENABLE_REGRESSION_TEST=true SMP=2` boots to a
shell (the init script spawns `/bin/sh` when it has no arguments), and you can
run `/test/io/specula/ast05 /mc3` by hand. The recorded runs did not use this
mode.

## Step 5: Read the result

```sh
sed 's/\r//' guest.log | sed -n '/AST_BOOT_OK/,/AST_ALL_DONE/p'
```

- Console lines end in `\r`. Strip it before you grep or compare.
- `AST_BOOT_OK` proves the driver ran. `AST_ALL_DONE` proves it finished. A
  missing `AST_END` for one reproducer means it hung or killed the guest.
- The standalone reproducers exit 0 whether or not the bug is present, so
  `AST_EXIT ... rc=0` means nothing about the bug. Read each reproducer's own
  verdict line, as its `repro/README.md` describes. Examples:
  `MC2_RESULT DIVERGES_FROM_LINUX` (AST-01), `MC4_SUMMARY ... deviations=5`
  (AST-02), `VERDICT=VECTOR_TORN` (AST-03), `MC1_RESULT DIVERGES_FROM_LINUX`
  (AST-04), `MC3_RESULT DIVERGES_FROM_LINUX` (AST-05), `MC7_END ... bugs=2`
  (AST-06), `CR2_RESULT: FAIL (5 checks, 2 failed)` (AST-09).
- A result counts only when the same program on Linux prints the Linux-side
  value, and when the reproducer's built-in controls pass on both kernels
  (for example AST-03's CASE D must tear on both, AST-04's zero-prefix control
  must fail on both, AST-09's checks 1 and 3 must pass on both).

The recorded 2026-09-02 transcript is
`/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/logs/asterinas-604948581-guest-transcript.txt`,
and the Linux outputs are the `linux-7.1.9-AST-*.txt` files in the same
directory.

## Alternative: run an in-tree regression test

Some entries ship a test patch (`repro/*-regression*.patch`) instead of, or in
addition to, a standalone program: AST-02 (`fs/empty_write`), AST-05
(`fs/read_eof`), and AST-09 (`process/signal/vectored_io_restart`). Apply it
with `git apply` and run the normal regression suite:

```sh
git apply /path/to/repro/read_eof-regression-pr3778.patch
rm -rf target/osdk
timeout 3000 make run_kernel AUTO_TEST=regression SMP=4 CONSOLE=ttyS0 INITRAMFS_SKIP_GZIP=1 > guest.log 2>&1
sed 's/\r//' guest.log | grep -aE '^Running test in|^All test in|All regression tests passed|summary: .* [1-9][0-9]* tests failed'
```

- These tests use `test/initramfs/src/regression/common/test.h`. Each test
  function prints `test_<name> summary: N tests passed, M tests failed`, and a
  failure makes the binary exit nonzero.
- Every suite's `run_test.sh` and the top-level `run_regression_test.sh` run
  under `set -e`, so the first failing test stops the rest.
- To run one suite only, the recorded scripts inserted a skip into
  `test/initramfs/src/regression/scripts/run_regression_test.sh`, just before
  `    if [ -x "${dir}/run_test.sh" ]; then`:

  ```sh
      if [ "${dir}" != "/test/fs" ]; then
          echo "Skipping $dir (scratch: fs suite only)"
          continue
      fi
  ```

  See `series-run.sh` and `ast09-validate.sh` in
  `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/scripts/`.
- Race tests in these patches skip on one CPU. The AST-05 series was validated
  with `SMP=4`, which matches the CI `multiboot2-smp4` variant.

To show that a kernel change fixes the bug, run the same test tree twice: once
with the fix and once with only the kernel files reverted (for example
`git checkout upstream/main -- <fixed files>`, as `ast09-validate.sh` did),
and keep both logs.

## Pitfalls

These cost real time in the recorded work. Check each one before you believe
a result.

1. **Stale OSDK bundle.** After you change anything under `test/initramfs/`,
   run `rm -rf target/osdk` before `make run_kernel`. Otherwise OSDK can boot
   its cached bundle with the old binaries. The initramfs path is unchanged
   even though its symlink now points at a new store path. The kernel objects
   under `target/<triple>` stay cached, so this costs little.
2. **No compiler in the guest.** Build everything into the initramfs. Calling
   `cc` in the guest was the first failure of the 01a patch-validation driver.
3. **OSDK built without `OSDK_LOCAL_DEV=1`.** If you build `cargo-osdk` by
   hand for a scratch worktree, build it with
   `OSDK_LOCAL_DEV=1 cargo build --manifest-path osdk/Cargo.toml` from that
   worktree. Without it the generated run crate depends on `ostd` from
   crates.io next to the in-tree one. Recorded symptoms: "the
   `#[global_allocator]` in ostd conflicts with global allocator in: ostd", or
   `x86_64 0.14.13` failing to compile. `make install_osdk` sets the variable
   for you.
4. **The wrong `cargo-osdk`.** OSDK bakes its own source path in at compile
   time, so a binary built from another checkout tests that checkout's `ostd`.
   The top-level Makefile defaults to `~/.cargo/bin/cargo-osdk`. Pass
   `CARGO_OSDK=<worktree>/osdk/target/debug/cargo-osdk` to `make`. `cargo`
   looks for external subcommands in `~/.cargo/bin` before `PATH`, so the
   recorded scripts also put a wrapper named `cargo` first in `PATH` that
   routes `cargo osdk` to the worktree binary (see `series-run.sh`).
5. **The Makefile can overwrite your global `cargo-osdk`.** The rule
   `$(CARGO_OSDK): $(OSDK_SRC_FILES)` runs
   `cargo install cargo-osdk --path osdk` into `~/.cargo/bin` whenever the
   named binary is older than any OSDK source, whatever path you passed. Run
   `touch <worktree>/osdk/target/debug/cargo-osdk` before `make`, especially
   after `git checkout -- osdk/Cargo.lock`.
6. **Do not seed `target/` from another worktree.** The generated
   `target/osdk/` crate carries that tree's paths.
7. **OVMF path outside Docker.** Upstream `tools/qemu_args.sh` hard-codes
   `-bios /root/ovmf/release/OVMF.fd`. The native runs rewrote it to
   `-bios ${OVMF_DIR:-/root/ovmf/release}/OVMF.fd`
   (`sed -i 's#-bios /root/ovmf/release/OVMF.fd#-bios ${OVMF_DIR:-/root/ovmf/release}/OVMF.fd#' tools/qemu_args.sh`)
   and set `OVMF_DIR`. The Nix dev shell exports it. The fallback in
   `series-run.sh` is `ls -d /nix/store/*-asterinas-ovmf` (environment-specific).
   Revert the edit afterwards.
8. **Networking.** `NETDEV=none` does not boot, because the QEMU arguments
   always attach a `virtio-net` device. Keep the default `NETDEV=user`. A host
   port collision with another guest makes QEMU fail to start. Rerun it, or
   give each guest its own `VNC_PORT` as the recorded scripts did. The GLM
   Docker runs also passed `QEMU_HOSTFWD=off`.
9. **Known failures unrelated to these findings.** On main in the recorded
   environment (QEMU 10.2.1), the `network` suite's
   `test_tcp_read_wrap_receive_buffer_tail` failed intermittently (2 of 46
   checks), and `device/nvme` failed with `mount('/dev/nvme0n1') ... EINVAL`.
   The recorded scripts skipped both when running full suites. Reproduce a
   failure on the unfixed base before you attribute it to anything.
10. **SMP.** The default is `SMP=1`. Use `SMP=2` or more for any concurrency
    claim (AST-03, the AST-05 race tests). Several race tests skip or never
    trigger on one CPU.
11. **Build resources (environment-specific).** The recording host ran near
    its per-user process limit. Builds only succeeded with
    `CARGO_BUILD_JOBS=4` and `NIX_CONFIG=$'max-jobs = 1\ncores = 4'`, and
    offline builds needed `CARGO_NET_OFFLINE=true`. After upstream bumped the
    `smoltcp` git tag, offline builds also needed the tag fetched into cargo's
    git database once.
12. **Leave the tree as you found it.** Revert the scratch edits
    (`io/Makefile`, the top-level `Makefile` hook, `tools/qemu_args.sh`, any
    `run_regression_test.sh` filter) and delete `io/specula/` when you are
    done. Report the commit and every edit you made next to the result.

## Kernel-side reproducers (AST-07, AST-08)

These are `ostd` ktests run with `cargo osdk test` from `ostd/`. They are not
initramfs programs. Their READMEs cover installing the test module, the
`ostd/OSDK.toml` override (`qemu-direct` boot, 8 GiB, plus a vIOMMU and the QEMU
`edu` device for AST-08), and how to read the result. For both, a FAILED
ktest is the positive result. Pitfalls 3 to 6 apply to them as well.

## Sources

- `/home/chin39/Documents/play/specula-profile/reports/ast-validation-2026-09-02/README.md`,
  `run_ast_all.sh`, `scratch-worktree-tooling.diff`, `minimal/run_ast_min.sh`,
  and `scripts/` (`series-run.sh`, `exfat-series-run.sh`, `ast09-validate.sh`,
  `post-validate.sh`, `validate-final.sh`, `run-cr11.sh`, `run-cr20.sh`)
- `/home/chin39/Documents/play/specula-profile/references/workspace-handoff.md`
  and `references/glm53-eval-handoff.md` (pitfall tables)
- `/home/chin39/Documents/play/specula-profile/tools/rw-matrix/run-guest.sh`
- `/home/chin39/Documents/play/specula-profile/reports/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z.patchval/e2e-rf01/E2E-RESULT.md`
- `/home/chin39/Documents/play/specula-profile/reports/cr20/REPRODUCE.md`
- The 01a run's harness and drivers under
  `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/`
  (`harness/src/specula-Makefile`, `harness/patches/source-hooks.patch`,
  `repro/test_bug*.sh`)
- Asterinas at `604948581`: `Makefile`, `test/initramfs/src/init`,
  `test/initramfs/src/regression/common/Makefile`,
  `test/initramfs/src/regression/scripts/run_regression_test.sh`,
  `test/initramfs/nix/regression/common.nix`
