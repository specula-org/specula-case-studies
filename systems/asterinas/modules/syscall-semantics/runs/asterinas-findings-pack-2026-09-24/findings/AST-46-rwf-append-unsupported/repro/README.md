# AST-46 reproducer (TLPI-v2 probe, NOT_RUN on Asterinas)

The cases below have not run on Asterinas. The only runtime evidence is the
attachment's saved Linux output, listed per case. `repro.runtime_status` in
`meta.json` is therefore NOT_RUN.

## Files

The files are copied from the extracted TLPI-v2 package without changes.

| File | Copied from | SHA-256 |
|---|---|---|
| `Makefile` | `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/Makefile` | `76f8816ce93bcdae010b50c053ab217d49e82cd95f2a54cec846d2313a6d2636` |
| `LICENSE` | `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/LICENSE` | `434832ddcdcd9f0de6fd708d2da835321c3842a32209c59de3f100495d1069b5` |
| `src/abi_probe.c` | `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/src/abi_probe.c` | `3fa9b1f5f81f02814fbc7e373e1988d2396a266d4d05d596f63d58bccd76d95d` |
| `src/legacy_cases.inc` | `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/src/legacy_cases.inc` | `2165256d3aa042a8a866b5ea69132a9854be202a801614926df66d4c38c762fe` |

`src/abi_probe.c` includes `src/legacy_cases.inc` and registers all 41
attachment cases. This entry uses only the cases listed below. The two source
hashes equal `sources_sha256` in
`/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/metadata.json`, so the saved Linux evidence was
built from these exact sources. The probe is MIT-licensed (see `LICENSE`).

## Cases for AST-46

### `pwritev2_append` (finding probe, `src/legacy_cases.inc` line 232)

The case writes `A` to a temporary file, then calls raw `pwritev2` with offset 0 and `RWF_APPEND` to write `B`, and reads back 2 bytes. It prints PASS when `pwritev2` returns 1 and the file reads `AB`.

- Saved Linux result: PASS in all five saved executions. Distinct output lines:
  - `raw pwritev2(RWF_APPEND, offset=0)=1 errno=0 file-size-read=2 data=AB`
- Source prediction for Asterinas at `a5449e62b` (not observed): `pwritev2` returns -1 with errno 95 (`EOPNOTSUPP`) and the file holds only `A`, so the case reports FAIL.
- Saved logs: `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/00[1-3]-pwritev2_append.log`, `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-tmpfs/logs/001-pwritev2_append.log`, `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-shell-import/logs/001-pwritev2_append.log`.

## Build

The harness targets x86-64 Linux only and fails to compile elsewhere. On an
x86-64 host with a C11 compiler and a static libc, run `make static` in this
directory. It produces `bin/abi_probe`. Plain `make` links dynamically, which
needs the same libc and loader inside the guest.

On this NixOS workspace host, a static build needs a static glibc archive.
`/home/chin39/Documents/play/specula-profile/tools/rw-matrix/build.sh` is a working recipe for a different harness: it compiles with
the Asterinas nix devshell gcc and passes `-L` to a pinned
`glibc-*-static` store path. The adapted command below has not been run:

```sh
nix develop "$ASTERINAS_DEV" -c gcc -std=c11 -O2 -Wall -Wextra -static \
  -L"$GLIBC_STATIC/lib" src/abi_probe.c -lrt -o bin/abi_probe
sha256sum bin/abi_probe
```

Record the ELF's SHA-256 with every run. Run the same ELF on Linux first to
get a fresh baseline, because the ELF behind the saved evidence
(`ae47f66db20e9cc41baa26f2be51588ee324b892b604ba1e8dd14246bf3470ff`) is not in the archive.

## Run

`./bin/abi_probe pwritev2_append` runs one case. The harness forks a child, changes
into a new `$TMPDIR/tlpi-abi-XXXXXX` directory (default `/tmp`), and kills the
child after 5 s. It prints `CASE <name>`, the case's own output line, and
`RESULT<TAB><name><TAB><status>`. The exit code is 0 for PASS, 1 FAIL, 2
SETUP_ERROR, 77 SKIP, 124 TIMEOUT and 125 CRASH. `./bin/abi_probe --list`
prints every case.

## Where it goes in an Asterinas tree

The probe is a standalone static ELF. It has not been ported to the
regression suite under `test/initramfs/src/regression/`. To run it in a guest,
inject the prebuilt binary into a scratch Asterinas worktree.
`/home/chin39/Documents/play/specula-profile/tools/rw-matrix/run-guest.sh` does this for another static harness. It copies the ELF
into `test/initramfs/src/regression/fs/specula/`, writes a Makefile there that
copies the binary to `$(OBJ_OUTPUT_DIR)`, adds `specula` to `SUBDIRS` in
`test/initramfs/src/regression/fs/Makefile`, inserts run lines into
`test/initramfs/src/regression/fs/run_test.sh`, and boots with
`make run_kernel AUTO_TEST=regression SMP=2 ...`. Both files have that layout
at `a5449e62b`. For this probe, use a run line such as
`./specula/abi_probe pwritev2_append || echo "ABI_EXIT pwritev2_append $?"`, because
`run_test.sh` runs under `set -e` and a FAIL exits with status 1. Keep the
injection in a scratch worktree and never commit it.

## Reading the result

A FAIL on Asterinas together with a PASS on Linux for the same ELF supports
the entry. It is not a confirmation by itself. The campaign rules in
`/home/chin39/Documents/play/specula-profile/AGENTS.md` also require the exact source event sequence, a
Linux comparison and an observed Asterinas reproduction. SETUP_ERROR,
SKIP, TIMEOUT and CRASH are not evidence either way. A missing PTY, socket
family or interface is a coverage gap, not the predicted failure.

AST-46 is an UNSUPPORTED capability gap. A FAIL on Asterinas confirms that the operation is unsupported. It does not make the entry an implementation bug.

## SMP

None of these cases depends on concurrency. `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/case-plan.json` plans
guests with at least 2 CPUs (`planned_minimum_guest_cpus: 2`), so use `SMP=2`.
The CPU count of the saved Linux runs was not recorded.

## Saved Linux evidence

The attachment ran one static ELF (SHA-256 `ae47f66db20e9cc41baa26f2be51588ee324b892b604ba1e8dd14246bf3470ff`, glibc 2.41, GCC
14.2.0) on a host whose `uname` reports Linux 6.18.44 x86-64. The image
identity was not verified outside `uname`, and the runs used euid 0. Each case
ran five times: three on overlayfs `/tmp`, one on tmpfs `/dev/shm`, and one
through the shell collector. These are the attachment's own records from
2026-09-14. They were not re-executed during intake.
