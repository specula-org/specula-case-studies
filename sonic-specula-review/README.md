# SONiC Specification-Driven Review — Supporting Material

This package is the supporting material for our SONiC findings. The findings themselves are in a separate document, `sonic-bug-report.md`, delivered alongside this archive — please read that first. Everything in here is what a maintainer is likely to want at hand while reading the report.

## Layout

```
sonic-specula-review/
├── README.md              This file.
│
├── specs/                 TLA+ specifications used to drive the review.
│   ├── sonic-fdb/         FdbOrch / PortsOrch event ordering (Cluster A).
│   ├── sonic-warmreboot/  swss + sairedis warm-reboot reconciliation
│   │                      (Clusters B, F, G).
│   ├── sonic-iccpd/       MCLAG ICCP daemon (Clusters C, H).
│   ├── sonic-linkmgrd/    Active-Active mux state machine (Cluster E).
│   └── sonic-dash-ha/     DASH HA actor lifecycle (Cluster D).
│
└── reproductions/         Test sources that reproduce or demonstrate findings.
    ├── sonic-fdb/         Python state-machine harnesses (model-only).
    ├── sonic-warmreboot/  C++ gtest harnesses for the swss mock_tests framework.
    ├── sonic-iccpd/       C unit tests; a subset compiles under AddressSanitizer.
    ├── sonic-linkmgrd/    C++ gtest in the linkmgrd test suite.
    └── sonic-dash-ha/     Cargo tests in hamgrd.
```

## Reading the specs

Each `specs/<module>/` directory contains:
- `base.tla` / `base.cfg` — the protocol specification, TLC-runnable.
- `MC.tla` / `MC.cfg` — the model-checking wrapper with bounded constants and fault-injection counters.
- `MC_hunt_*.cfg` — targeted bug-hunt configurations, one per family of invariants.
- `Trace.tla` / `Trace.cfg` — the trace-validation wrapper that consumes NDJSON traces from the instrumented system.
- `bug-report.md` (per-spec) — the internal per-module write-up that fed into the standalone `sonic-bug-report.md`. May contain more detail than the public report.
- `confirmed-bugs.md` — the per-bug confirmation log, including counterexample lengths and any notes on spec fidelity.
- `modeling-brief.md` and `instrumentation-spec.md` (where present) — what we set out to model and where the trace points were placed.

Running TLC against any `MC.cfg` or `MC_hunt_*.cfg` requires the standard `tla2tools.jar` plus `CommunityModules-deps.jar`; we used Java 21.

## Reading the reproductions

Each `reproductions/<module>/` directory contains the test source(s) referenced in the corresponding cluster of `bug-report.md`. The harnesses are written against each upstream's existing test infrastructure:

- **sonic-fdb (Python):** standalone state-machine models. `python3 test_*.py` runs them; no SONiC build required. These are demonstrative — they restate the C++ logic in Python and assert the invariant violation. The buggy code path is described file-and-line in the report.
- **sonic-warmreboot (gtest):** drop-in additions to `sonic-swss/tests/mock_tests/`. They use the real `AppRestartAssist`, `RingBuffer`, `Select`, `SelectableTimer`, and `ProducerStateTable` classes.
- **sonic-iccpd (C):** standalone C tests linked against rebuilt iccpd object files. A subset is gated behind `make ASAN=1` and produces AddressSanitizer reports for the buffer-overflow and OOB-read findings.
- **sonic-linkmgrd (gtest):** drop-in additions to the linkmgrd test suite, driving `LinkManagerStateMachineActiveActive` through real transitions.
- **sonic-dash-ha (cargo):** unit tests inside `hamgrd`. `cargo test --package hamgrd` runs them.

The exact run commands are noted in `bug-report.md` and in the per-module `confirmed-bugs.md`.

## What we are looking for

The orchagent and warm-reboot findings (Clusters A, B, F, G) are the items where we most want maintainer feedback. Some of them are small, mechanical fixes; some are design discussions. The report tries to be honest about which is which, including the points where we see a real gap but expect the right shape of a fix to be a maintainer call. We are happy to take any of these further — patches, additional reproductions, or just a conversation.
