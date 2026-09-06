# vsr-rs focused correctness pass

Target: https://github.com/penberg/vsr-rs, Rust, Category A distributed/message-passing.
Use revision `3ac0104a567092139534c9022205d02281a2da41` unless the run explicitly pins another commit.

## Purpose

The maintainer wants actionable correctness feedback. Prefer small, reachable, maintainer-reviewable defects or missing contract validation over broad assurance statements. A no-violation bounded model-checking run is useful evidence, but it is not by itself the target outcome.

## Scope

Primary: fixed-membership VSR library in `lib.rs`.
Secondary: the shipped `examples/kvstore/main.rs` integration. Separate integration/caller-obligation findings from conforming-library protocol findings.
Use simulator/DST and retained Lean evidence to understand coverage boundaries and design tests; do not treat proof gaps or bounded passes as bugs.

## High-priority questions

1. If an existing kvstore view file cannot be read or parsed, can startup select `Replica::new` instead of `Replica::recover` and allow the old replica id to commit history inconsistent with peers? (`examples/kvstore/main.rs:683-699`, `lib.rs:14-21`, `lib.rs:716-730`)
2. Is a one-replica configuration supported? If `Config::add_replica` accepts one member and `quorum()==1`, does a client request commit and reply without any peer `PrepareOk`, or should the API/simulator reject or document it? (`lib.rs:74-107`, `lib.rs:682-684`, `lib.rs:737-765`, `simulator/lib.rs:258-260`)
3. Can one stalled kvstore peer block the shared sender thread long enough to delay frames to healthy peers beyond the failure-detector interval? (`examples/kvstore/main.rs:342-392`, `examples/kvstore/main.rs:31-33`)
4. Does `persist_view` provide the durable name-publication guarantee required before outputs are released under the supported filesystem crash model? (`examples/kvstore/main.rs:569-579`, `lib.rs:14-21`)
5. Are recovery nonces and client identities fresh across restarts under the example's actual clock and identity policy? Do not count issue #9 or PR #10 as new; use them only for exact duplicate filtering. (`examples/kvstore/main.rs:478-491`, `examples/kvstore/main.rs:690-699`)
6. Do the DST oracles ever miss a regression because they observe incrementally, batch ticks or delivery, or deliver replies outside the simulated network? If so, report it as an assurance or test gap, not as a library bug. (`simulator/properties.rs`, `simulator/lib.rs`)

## Phase 1 handoff

Keep each maintainer-actionable concrete mechanism as its own Scenario or explicit Phase 4 handoff candidate with a stable ID, file:line anchors, expected consequence, and verification route. Do not bury startup fallback, singleton progress, shared-writer blocking, parent-directory fsync, or nonce freshness only inside one broad example-obligations Scenario.

## Phase 2 and 3 focus

Spend model checking on genuinely protocol-level questions where it can add information beyond direct Rust tests. Keep finite liveness claims limited unless the run records assumption-satisfying witnesses and non-exhaustive boundaries.

## Phase 4 confirmation

Confirm concrete code-review candidates independently. A known duplicate of issue #9 may be dropped, but it must not absorb unrelated startup, filesystem, singleton, nonce, or sender-isolation candidates.
