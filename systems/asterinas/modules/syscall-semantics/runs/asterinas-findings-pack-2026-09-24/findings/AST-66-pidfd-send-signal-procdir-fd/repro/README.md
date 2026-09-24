# Reproducer for AST-66 (TLPI-v2 F22)

**Runtime status: NOT_RUN on Asterinas.** Nobody has run this program on any
Asterinas kernel. The only saved results are Linux runs recorded by the
attachment's author with a static build of these exact sources. The
Asterinas line below is a prediction from reading the source at pin
`a5449e62b0a5a0affccb6087ea3543a2fdf66052`, not an observation.

## Files

All files are unmodified copies from the TLPI-v2 package. The hashes match
the package's `SHA256SUMS` and the source hashes recorded in the saved Linux
run metadata.

| File | Copied from | SHA-256 |
|---|---|---|
| `src/abi_probe.c` | `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/src/abi_probe.c` | `3fa9b1f5f81f02814fbc7e373e1988d2396a266d4d05d596f63d58bccd76d95d` |
| `src/legacy_cases.inc` | `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/src/legacy_cases.inc` | `2165256d3aa042a8a866b5ea69132a9854be202a801614926df66d4c38c762fe` |
| `Makefile` | `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/Makefile` | `76f8816ce93bcdae010b50c053ab217d49e82cd95f2a54cec846d2313a6d2636` |
| `LICENSE` | `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/LICENSE` | `434832ddcdcd9f0de6fd708d2da835321c3842a32209c59de3f100495d1069b5` |

`abi_probe.c` is one program that holds all 41 TLPI-v2 cases and includes
`legacy_cases.inc`. `LICENSE` is the MIT notice that covers both sources.
This entry uses these cases:

| Case | Kind | Defined at |
|---|---|---|
| `pidfd_procdir` | finding probe | `src/abi_probe.c:183` |

## Build

On an x86-64 Linux host with a C compiler and static glibc:

```sh
make static      # writes bin/abi_probe
```

The source stops with `#error` on other architectures, because the raw
syscall cases assume the x86-64 ABI. Build once and use the same ELF on
Linux and Asterinas, so that a difference cannot come from the build.

## Where it goes in an Asterinas tree

The program is not an Asterinas regression test. The simplest route is to
put the static `bin/abi_probe` into the guest initramfs and run it there
(see `docs/running-reproducers.md` at the package root). To build it
in-tree instead, place `abi_probe.c` and `legacy_cases.inc` together in one
leaf directory under `test/initramfs/src/regression/` whose `Makefile`
includes `common/Makefile`. That common Makefile compiles every `.c` file in
the directory to a binary of the same name.

## Run

```sh
./bin/abi_probe pidfd_procdir
```

Each case runs in a forked child inside a fresh directory under `$TMPDIR`
(default `/tmp`) with a 5-second watchdog. The output is a `CASE` line,
optional `DETAIL` and `OBS` lines, and a final
`RESULT<TAB><case><TAB><status>` line. Exit codes are 0 PASS, 1 FAIL,
2 SETUP_ERROR, 77 SKIP, 124 TIMEOUT, and 125 CRASH. SETUP_ERROR, SKIP,
TIMEOUT and CRASH are not evidence for or against the finding. They mean a
prerequisite is missing or the guest misbehaved, and need their own
investigation. Keep an external VM watchdog, because the in-process watchdog
cannot recover a kernel-wide hang.

The package's guest collector and comparison tools (`tools/run_guest.sh`,
`tools/import_guest.py`, `tools/compare.py`) need the full package layout and
are not copied here. They are in `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/tools/`.

## Expected results

Saved Linux output (Linux 6.18.44 x86-64 as reported by `uname`, glibc 2.41,
static ELF SHA-256 `ae47f66db20e9cc41baa26f2be51588ee324b892b604ba1e8dd14246bf3470ff`,
run as root). Every case passed in all five recorded executions: three on
overlayfs, one on tmpfs, and one through the shell collector. The first
overlayfs log:

```text
CASE pidfd_procdir
OBS {"ret":0,"errno":0}
RESULT	pidfd_procdir	PASS
```

Full logs are under `/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-overlayfs/logs/`,
`/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-tmpfs/logs/` and
`/home/chin39/Documents/play/specula-profile/reports/tlpi-audit-2026-09-14/package/results/linux-shell-import/logs/`.

Predicted Asterinas result at the pin (source reading, NOT_RUN):
`OBS {"ret":-1,"errno":9}` (EBADF) and `RESULT FAIL`, because the FD is not a PidFile.

A FAIL on Asterinas with the same ELF that passes on Linux supports the
finding. Confirming it still needs the checks in the finding's caveats.

## SMP

`case-plan.json` plans at least 2 guest CPUs for every TLPI batch, so use
SMP=2. The probe itself does not depend on concurrency. No SMP setting has
been exercised on Asterinas.
