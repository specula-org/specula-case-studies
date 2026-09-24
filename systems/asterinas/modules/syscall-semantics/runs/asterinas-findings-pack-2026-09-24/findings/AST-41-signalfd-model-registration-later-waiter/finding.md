# AST-41: signalfd model attributes registration to a later waiter

| Field | Value |
|---|---|
| Evidence status | MODEL ERROR |
| Origin | FD `asterinas-fd-epoll-pipeline-20260811T164254Z`, historical `s4_binding` model counterexample (no native finding ID), Asterinas pin `4ba4abbe8cb3f2892129d67b0301cf247bbdda0f` |
| Also seen in | none |
| Syscalls | `epoll_ctl`, `epoll_wait`, `signalfd4` (as modeled). No syscall was run for this record. |
| Upstream | Non-actionable record (`NON_ACTIONABLE_RECORD` against upstream main `bc12195df`): keep the corrected model-oracle error separate from implementation findings. Reviewed for context only: open issue [#200](https://github.com/asterinas/asterinas/issues/200) and merged PR [#1277](https://github.com/asterinas/asterinas/pull/1277). Upstream fix status: not applicable. |
| Fix | Not applicable. The model oracle was corrected during validation Round 1. |
| Reproducer | none |

## Summary

During the FD run's first model-checking round, the hunt configuration
`MC_hunt_s4_binding.cfg` violated the oracle `MCSignalfdBindingCoversConsumer`.
That oracle expected the signalfd poller binding created by `epoll_ctl` to
cover a later `epoll_wait` thread. Validation classified it as a Case-B model
error (the model, not the implementation, was wrong) and replaced the oracle
with `SignalfdRegistrationHasBinding`, which binds registration to the
`EPOLL_CTL_ADD` or `EPOLL_CTL_MOD` caller as the source does. This record
exists so that the old counterexample is not reported as a separate Asterinas
bug. The runtime-reproduced bug with a related shape is AST-22 (see Caveats).

## Linux contract

Not applicable to this record, because it is a model error. For the related
runtime contract (a signalfd watched by epoll must report a signal directed at
the waiting thread even when another thread registered it), see AST-22.

## Asterinas behavior

What the source does at the pin, which the corrected oracle now matches:

- `kernel/core/src/events/epoll/entry.rs::Entry::update` calls
  `file.poll(.., Some(poller))` in the context of the `epoll_ctl` caller.
- `kernel/core/src/syscall/signalfd.rs::SignalFile::poll` registers that
  poller with the current thread's queues through
  `kernel/core/src/process/posix_thread/mod.rs::PosixThread::register_signalfd_poller`.
- A later `epoll_wait` from another thread does not create a new binding.

The old counterexample (`spec/output/MC_hunt_s4_binding_bfs.out`, 7 states)
reads as follows. In state 2 thread `t1` captures an `EPOLL_CTL_ADD` of the
signalfd. In state 3 thread `t2` updates the signalfd mask, and in state 4 `t2`
registers as the `epoll_wait` consumer. In state 5 a thread-directed signal is
enqueued for `t2` (`threadPending[t2] = TRUE`, `signalNotify[t2]` pending on
the thread queue). In states 6 and 7 the add completes and the poller binding
is recorded on `t1`. The oracle fails because the binding (`t1`) does not cover
the consumer (`t2`). The trace ends at that structural violation and contains
no `epoll_wait` return or other caller-visible outcome.

## Reproduction

None. There is no runtime reproducer for a model error. The corrected model's
`MC_hunt_s4_binding` round-2 check completed with no error (625 generated and
329 distinct states, depth 8), and a randomized simulation reached 73,182
traces without a violation.

## Fix and upstream status

The oracle fix is recorded in the run's validation changelog: "[fix-spec]
`MCSignalfdBindingCoversConsumer`: Case B. The model attached a signalfd poller
binding to a later `epoll_wait` consumer. Source registers the poller during
`EPOLL_CTL_ADD` or `EPOLL_CTL_MOD`; the model now records that
registration-time binding and checks `SignalfdRegistrationHasBinding`." After
the fix all four captured traces replayed successfully. The later validation
review confirmed that the Round-1 Case-B model error was correctly fixed.

## Evidence

- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/changelog.md (Round 1, Model Checking)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s4_binding_bfs.out (old oracle violation)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s4_binding_bfs_cex.json
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/output/MC_hunt_s4_binding_round2_bfs.out (corrected model, no error)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/MC_hunt_s4_binding.cfg
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/base.tla (definition `SignalfdRegistrationHasBinding`)
- /home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/spec/review-validation.md
- /home/chin39/Documents/play/specula-profile/reports/independent-review/terra-asterinas-bug-report-vm-final.md (section "Historical model-oracle exclusion")
- /home/chin39/Documents/play/specula-profile/reports/workflow-validation.md (Stage 2 recovery, "Model evidence")

## Caveats

- Sources pull in different directions here, and the register decides. The
  validation stage and the Terra review call the old oracle a model error,
  because the source binds the poller to the `EPOLL_CTL_ADD`/`MOD` caller by
  design and the model had attributed the binding to the later waiter. The
  retained trace, however, has the same shape as the precondition of AST-22:
  `t1` registers, a thread-directed signal is pending for `t2`, and `t2` is the
  epoll consumer. AST-22 (code review CR-4) later showed at runtime that this
  shape produces a Linux-visible missed wakeup. The register keeps AST-41 as
  MODEL ERROR and AST-22 as the implementation finding, and this note does not
  change either status. Inference for deduplication: a new model
  counterexample that only asserts binding coverage matches AST-41, while one
  that reaches a missed epoll wakeup for a signal directed at a non-registering
  thread should be compared with AST-22 first.
- The corrected oracle checks only that a completed registration has some
  binding. It does not check the AST-22 failure, and the corrected hunt found
  no violation.
- The Terra review states that this counterexample is excluded from its table,
  its count, and all its conclusions. The MC-5 (AST-20) mask-transition trace
  is a different property and is not this oracle.
