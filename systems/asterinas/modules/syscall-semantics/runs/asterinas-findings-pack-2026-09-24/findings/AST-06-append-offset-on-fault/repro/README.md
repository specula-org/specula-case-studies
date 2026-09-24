# AST-06 reproducer

## Files and where they came from

| File | Source |
|---|---|
| `repro.c` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-06-append-offset-on-fault/repro.c`, byte-identical to the 01a run's `/home/chin39/Documents/play/Specula/runs/asterinas-syscall-regular-file-partial-progress-20260823T030315Z/asterinas-syscall-regular-file-partial-progress/.specula-output/repro/test_bugMC-7_append_offset_on_fault.c` |
| `run.sh` | `/home/chin39/Documents/play/specula-profile/reports/asterinas-bug-findings-2026-08/AST-06-append-offset-on-fault/run.sh` |

## Where it goes in an Asterinas tree

The guest has no compiler. Copy `repro.c` (for example as `ast06.c`) into a
regression test directory such as `test/initramfs/src/regression/io/specula/`,
register it, and boot with a custom init script, as
`docs/running-reproducers.md` describes. No kernel hooks are needed.

## Build and run

Linux control (one disk directory and one tmpfs directory):

```sh
cc -Wall -O2 -o /tmp/ast06 repro.c
mkdir -p /var/tmp/ast06 && /tmp/ast06 /var/tmp/ast06
mkdir -p /dev/shm/ast06 && /tmp/ast06 /dev/shm/ast06
```

Asterinas guest, `SMP=2`:

```sh
/test/io/specula/ast06 /ext2
/test/io/specula/ast06 /tmp      # ramfs
```

## Reading the output

Each case prints `MC7_CASE <name> ... rc=<r> errno=<e> ... off_after=<o>
off_expected=<x> dupfd_read=<n>`, followed by `MC7_OK <name>` or one or more
`MC7_BUG <name> <what>` lines. The run ends with `MC7_END dir=<dir> bugs=<n>`.

| Case | Unfixed Asterinas (`604948581`) | Linux |
|---|---|---|
| `A_append_zero_fault` | `rc=-1 errno=14 off_after=4096 off_expected=0`, `MC7_BUG ... shared_offset_moved` (ext2 also `consumer_sees_eof dupfd_read=0`) | `off_after=0 dupfd_read=16`, `MC7_OK` |
| `B_plain_zero_fault` (negative control) | `off_after=0`, `MC7_OK` | `MC7_OK` |
| `C_append_success` (positive control) | `off_after=8192`, `MC7_OK` | `MC7_OK` |
| `D_append_prefix_fault` | `rc=-1 errno=14 off_after=4096`, `MC7_BUG` | `rc=4096 off_after=8192`, `MC7_OK` |
| `MC7_END` | `bugs=2` on `/ext2` and `/tmp` | `bugs=0` |

Cases B and C must pass on both kernels. If B fails, the fault setup is wrong.
The program exits 0 either way, so read `MC7_END`.
