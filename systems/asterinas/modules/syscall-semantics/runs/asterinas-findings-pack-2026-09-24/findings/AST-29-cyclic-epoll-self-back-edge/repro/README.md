# AST-29 Linux-control test

This test documents why AST-29 was dropped. It ran only on Linux. The
Asterinas guest at pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` never
reached QEMU, so there is no Asterinas result.

## File and source

| File | Source (absolute path) | Role |
|---|---|---|
| `test_bugCR-6_nested_epoll_cycle.c` | `/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro/test_bugCR-6_nested_epoll_cycle.c` | Acyclic nested-epoll control, then a self-edge (`self`) or two-epoll back-edge (`pair`) attempt |

## Where the file goes

Build it as a static binary and put it anywhere in a guest initramfs. It
takes one argument, `self` or `pair`. The recorded attempt placed a static copy
in `test_bugCR-6_nested_epoll_cycle.v2.initramfs.cpio` for an SMP=2 guest.

## How to run

On Linux: `cc -O2 test_bugCR-6_nested_epoll_cycle.c -o cr6 && ./cr6 self && ./cr6 pair`.
Run each mode under an outer timeout on a system under test, because an
accepted cycle is expected to either return or hang.

## Reading the output

| Outcome | Output | Exit |
|---|---|---|
| Linux (recorded) | `CR6 ACYCLIC_CONTROL_OK ...` then `CR6 SELF_EDGE_REJECTED errno=22` or `CR6 PAIR_BACK_EDGE_REJECTED errno=40` | 0 |
| Cycle rejected with an unexpected errno | the `..._REJECTED` line with another errno | 4 |
| Cycle accepted and the eventfd write returned | `CR6 SELF_EDGE_ACCEPTED` (or `PAIR_BACK_EDGE_ACCEPTED`), `..._WRITE_BEGIN`, `..._WRITE_RETURNED` | 3 |
| Cycle accepted and the write never returned | output stops after `..._WRITE_BEGIN` until the outer timeout | none |
| Setup failure | `CR6 FAIL stage=...` on stderr | 2 |

Exit 3 on Asterinas would show only the errno-compatibility gap that upstream
PR #3395 already covers. A hang after `..._WRITE_BEGIN` would be the first
runtime evidence of the deadlock the candidate predicted, which this record
does not contain.

## SMP setting

The planned Asterinas run used `SMP=2`. It never executed.
