# Reproduction: MC-2 (repair continuation)

## Artifact/bootstrap preflight

- Current source SHA: `4f3dda156e52ed7647b1dbf900d54d87efaea455`.
- The repair-round-2 worktree initially had neither a generated `Makefile` nor `tests/mock_tests/tests`, and its refreshed test source no longer contained the prior MC-2 case. The same Level-2 case was restored in the existing fixture and compiled in this worktree.
- A same-SHA object cache existed at `/users/Pial/targets/sonic-swss-fdb/tests/mock_tests/`. The cache checkout had the same dirty conformance-instrumentation file set; SHA-256 checks matched for `orchagent/fdborch.cpp`, `fdb_trace.cpp`, `fdb_trace.h`, and `tests/mock_tests/Makefile.am`.
- The first five-minute invocation generated/configured the build and freshly compiled `tests-fdborch_vxlan_ut.o`, then timed out while redundantly compiling the full suite before linking. This was a build timeout, not a test result.
- The dependency tree `/tmp/fdb-harness-bootstrap-test/root/usr` and 209 same-source object files were then reused as a build cache. The cached `tests-fdborch_vxlan_ut.o` was deliberately excluded; the current worktree linked its own fresh MC-2 object and test binary.
- A clean compile first exposed a dependency-only protobuf conversion warning promoted to an error. The fresh MC-2 object was built with `CXXFLAGS='-g -O2 -Wno-error=conversion'`; product warnings and product logic were not suppressed or modified.

## Escalation

- Level 0: unavailable because this confirmation environment has no live SONiC SAI/ASIC stack that can physically generate the age/re-learn callbacks.
- Level 1: timing assistance alone cannot create or delay callbacks without that live producer.
- Level 2: succeeded at the public `FdbOrch::update()` notification-handler boundary by instantiating exact State 4 of `repair_RR003_MC_hunt_mc2_stale_age_bfs.out`. State 4 has pending generation-1 LEARN `ev1`, generation-1 AGE `ev2`, and same-port generation-2 LEARN `ev3`; States 5-8 deliver/commit `ev3`, then States 9-11 deliver `ev2`. The test delivers those latter two legitimate SAI payloads in that order. It does not prepopulate a cache, call a private function, or modify product logic.
- Level 3: unnecessary because Level 2 deterministically triggered the claimed consequence twice.

## Command

```text
timeout 5m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-2_delayed_age.sh
```

## Output

```text
MC-2 ladder Level 0: unavailable (no live SONiC SAI/ASIC stack in this confirmation environment)
MC-2 ladder Level 1: not triggerable here (timing alone cannot reorder callbacks without the live producer)
MC-2 ladder Level 2: instantiate CE State 4 at the public FdbOrch handler boundary; deliver LEARN(gen2,same port), then delayed AGE(gen1)
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from VxlanFdbOrchTest
[ RUN      ] VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation
MC-2 Level 2 CE State 4: pending={LEARN(gen1),AGE(gen1),LEARN(gen2)} deliver=LEARN(gen2),AGE(gen1)
MC-2 before_delayed_age harness_logical_generation=2 cache_present=1 state_db_present=1 mux_lookup_completed=1 mux_port=Ethernet0
MC-2 after_delayed_age delayed_event_generation=1 cache_present=0 state_db_present=0 mux_lookup_completed=1 mux_port=<empty> sai_remove_calls=0
[       OK ] VxlanFdbOrchTest.BugMC2DelayedAgeDeletesNewerSamePortIncarnation (106 ms)
[----------] 1 test from VxlanFdbOrchTest (106 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (106 ms total)
[  PASSED  ] 1 test.
```

The decisive line is `MC-2 after_delayed_age ... cache_present=0 state_db_present=0 ... mux_port=<empty> sai_remove_calls=0`. The test passes because its assertions capture current defective behavior. Correct behavior for the State-4 precondition would retain the current logical generation-2 row: `cache_present=1`, `state_db_present=1`, and `mux_port=Ethernet0`.

The current-source run succeeded twice (110 ms, then 106 ms). The consumer result comes from real `MuxOrch::getMuxPort()`, not an argued substitute. No automatic steady-state repair was found: the FDB cache remains absent until an independent later LEARN/replay, while `fdbsyncd` can propagate the `STATE_DB` deletion and its own refresh requires the cache row that deletion removes.
