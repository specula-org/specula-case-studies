# MC-1 reproduction

## Harness

- Required executable: `repro/test_bugMC-1_overlapping_flush.sh`
- Built in the supplied worktree with `make -C tests/mock_tests -j20 -s CXXFLAGS='-g -O0 -Wno-error=conversion' tests` after `autogen.sh` and `configure`; the warning override is limited to conversion warnings in extracted protobuf headers.
- Level 0 sends two normal APPL_DB `FLUSHFDBREQUEST` `PORTVLAN` messages and two serialized consolidated ASIC_DB `SAI_FDB_EVENT_FLUSHED` notifications.
- Level 1 runs the same sequence with callback delay only. Level 2 injects the exact State-11 precondition. Level 3 adds only a runtime-gated delay between successful SAI return and the pending-marker write.

## Captured output

```text
MC1_REPRO level=0 public_api_two_flushes timing=none
[ RUN      ] FdbOrchTest.BugMc1OverlappingFlushPublicSequence
MC1_LEVEL=0 requests=2 flush1_had_entry=1 flush2_had_entry=0 pending_after_second=1 request_elapsed_ms=0
MC1_LEVEL=0 after_old_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
MC1_LEVEL=0 after_second_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
[       OK ] FdbOrchTest.BugMc1OverlappingFlushPublicSequence (130 ms)
[  PASSED  ] 1 test.
MC1_REPRO level=1 public_api_two_flushes timing=delayed_callback
[ RUN      ] FdbOrchTest.BugMc1OverlappingFlushPublicSequence
MC1_LEVEL=1 requests=2 flush1_had_entry=1 flush2_had_entry=0 pending_after_second=1 request_elapsed_ms=0
MC1_LEVEL=1 after_old_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
MC1_LEVEL=1 after_second_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
[       OK ] FdbOrchTest.BugMc1OverlappingFlushPublicSequence (152 ms)
[  PASSED  ] 1 test.
MC1_REPRO level=2 injection=counterexample_state_11
[ RUN      ] FdbOrchTest.BugMc1State11Injection
MC1_LEVEL=2 injected=counterexample_state_11 cache_present=1 pending=1 asic_present=0
MC1_LEVEL=2 after_old_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
[       OK ] FdbOrchTest.BugMc1State11Injection (128 ms)
[  PASSED  ] 1 test.
MC1_REPRO level=3 public_api_two_flushes source_change=timing_only
[ RUN      ] FdbOrchTest.BugMc1OverlappingFlushPublicSequence
MC1_LEVEL=3 requests=2 flush1_had_entry=1 flush2_had_entry=0 pending_after_second=1 request_elapsed_ms=40
MC1_LEVEL=3 after_old_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
MC1_LEVEL=3 after_second_ack cache_present=0 state_db_present=0 asic_present=0 vlan_count=0 port_count=0
[       OK ] FdbOrchTest.BugMc1OverlappingFlushPublicSequence (168 ms)
[  PASSED  ] 1 test.
MC1_ESCALATION_COMPLETE invariant_mismatch=1 live_harm=0 real_consumer_wrong_outcome=none
```

## Result

The implementation exhibits the modeled epoch-label mismatch, but the old callback removes only software state for the entry already removed by request 1. Request 2 is a successful idempotent flush over an empty ASIC set. No consumer-visible wrong outcome or persistent divergence was reproduced; this supports an `INVARIANT` repair request for `FlushAckMatchesRequest`.

## Repair round 1 continuation — reproduced post-flush relearn

The prior result above applies to the repaired-away overlapping-request trace. The current counterexample is different and was reproduced at Level 0.

### Artifact/bootstrap preflight

- Worktree and `origin/master` are both source revision `4f3dda156e52ed7647b1dbf900d54d87efaea455`.
- The worktree initially had no `tests/mock_tests/tests` executable. `/users/Pial/targets/sonic-swss-fdb/tests/mock_tests/tests` was inspected as a compatible same-SHA, same-instrumentation artifact and as recipe provenance, but it did not contain the new MC-1 test and was not used for the result.
- Replayed that checkout's known-good configure recipe using `/tmp/fdb-harness-bootstrap-test/root/usr`, ran `autogen.sh`, configured with the recorded include/library/pkg-config paths, and rebuilt the supplied worktree with:

  `timeout 20m make -C tests/mock_tests -j20 -s CXXFLAGS='-g -O0 -Wno-error=conversion' tests`

### Escalation

- Level 0 succeeded, so Levels 1-3 were not entered. The test uses one public `FLUSHFDBREQUEST PORTVLAN` and ordinary serialized SAI `LEARNED`/`FLUSHED` notifications through the production `NotificationConsumer` entry points. There are no failpoints, sleeps, injected `FdbData`, direct handler calls, or core-logic changes.
- The test fixture's mock SAI records the external ASIC oracle only: the successful flush changes ASIC-present to false, and the legitimate second `LEARNED` message changes it to true. The SUT's cache, pending bit, STATE_DB, counters, and consumer result are reached solely by the real message sequence.

### Command and captured output

Command:

`timeout 3m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-1_post_flush_relearn.sh`

```text
MC1_REPRO level=0 interface=normal_notification_consumers timing=none
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = FdbOrchTest.BugMc1PostFlushRelearnDelayedAck
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from FdbOrchTest
[ RUN      ] FdbOrchTest.BugMc1PostFlushRelearnDelayedAck
MC1_AFTER_FLUSH flush_success=1 flush_had_entry=1 asic_present=0 cache_present=1 pending=1
MC1_AFTER_RELEARN event=SAI_FDB_EVENT_LEARNED same_key=1 same_port=1 asic_present=1 cache_present=1 pending=1 mux_consumer_port=Ethernet0
MC1_AFTER_DELAYED_FLUSHED cache_present=0 state_db_present=0 asic_present=1 vlan_count=0 port_count=0 mux_consumer_port=<empty>
MC1_PERSISTENCE_CHECK repeat_query=1 asic_present=1 cache_present=0 state_db_present=0 mux_consumer_port=<empty>
MC1_BUG_TRIGGERED expected_cache_present=1 expected_state_db_present=1 expected_mux_consumer_port=Ethernet0
[       OK ] FdbOrchTest.BugMc1PostFlushRelearnDelayedAck (141 ms)
[----------] 1 test from FdbOrchTest (141 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (141 ms total)
[  PASSED  ] 1 test.
```

`MC1_AFTER_RELEARN` demonstrates the admissible generation-2 precondition and sticky boolean. `MC1_AFTER_DELAYED_FLUSHED` demonstrates the violated outcome: cache and STATE_DB are absent and both counters are zero while ASIC generation 2 remains. The same line shows the real consumer `MuxOrch::getMuxPort()` returning an empty port instead of `Ethernet0`; `MC1_PERSISTENCE_CHECK` repeats that consumer call without another event and observes no repair.

### Counterexample match and result

- Operation order matches repaired trace States 7-17: successful generation-1 flush, same-key/same-port `MCSaiLearnEvent` generation 2, then delayed generation-1 callback.
- The invariant and root cause match: `FlushAckMatchesRequest` reports generation 1's callback deleting generation 2, and production does so because the duplicate-learn path preserves `is_flush_pending` while the callback tests only scope/type/MAC/boolean.
- Expected correct behavior is `cache_present=1`, `state_db_present=1`, counts 1, and `mux_consumer_port=Ethernet0` while ASIC generation 2 exists. Observed behavior is the opposite and is stable absent a new independent FDB event.

Result: Level-0 live harm reproduced through normal message interfaces; no safeguard or downstream repair masks it.

## Repair round 2 execution

The refreshed worktree no longer contained the prior test executable, so it was not treated as reusable evidence. The compatible artifact at `/users/Pial/targets/sonic-swss-fdb/tests/mock_tests/tests` was checked for the same source SHA and instrumentation but lacked the MC-1 test. An initial configure attempt without `PKG_CONFIG_PATH` stopped at missing `jansson`; checking that artifact's `config.status` supplied the known-good pkg-config path. The supplied worktree was then bootstrapped from the same dependency root and rebuilt from current source:

```text
timeout 3m ./autogen.sh
timeout 5m ./configure --with-extra-inc=/tmp/fdb-harness-bootstrap-test/root/usr/include 'CPPFLAGS=-I/tmp/fdb-harness-bootstrap-test/root/usr/include -I/tmp/fdb-harness-bootstrap-test/root/usr/include/swss -I/usr/local/include/swss' 'LDFLAGS=-L/tmp/fdb-harness-bootstrap-test/root/usr/lib/x86_64-linux-gnu -L/tmp/fdb-harness-bootstrap-test/root/usr/lib -L/usr/local/lib -Wl,-rpath,/tmp/fdb-harness-bootstrap-test/root/usr/lib/x86_64-linux-gnu -Wl,-rpath,/tmp/fdb-harness-bootstrap-test/root/usr/lib -Wl,-rpath,/usr/local/lib' PKG_CONFIG_PATH=/tmp/fdb-harness-bootstrap-test/root/usr/lib/x86_64-linux-gnu/pkgconfig
timeout 20m make -C tests/mock_tests -j20 -s CXXFLAGS='-g -O0 -Wno-error=conversion' tests
```

The current test body is `tests/mock_tests/fdborch/flush_syncd_notif_ut.cpp:824-1017`; the required executable wrapper remains `repro/test_bugMC-1_post_flush_relearn.sh` (SHA-256 `2ce37683737bafcf23a1cf40b12f27da3b0f028b3b6df3de7799b046a020335b`). It uses the production APPL_DB and ASIC_DB `NotificationConsumer` paths and calls the production `MuxOrch::getMuxPort()` consumer. Its mock booleans record only external ASIC presence; they do not inject or edit FdbOrch cache, pending, STATE_DB, counter, or consumer state.

Level 0 succeeded again, so Levels 1-3 were not entered. Exact command:

`timeout 3m /users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/repro/test_bugMC-1_post_flush_relearn.sh`

```text
MC1_REPRO level=0 interface=normal_notification_consumers timing=none
Running main() from ./googletest/src/gtest_main.cc
Note: Google Test filter = FdbOrchTest.BugMc1PostFlushRelearnDelayedAck
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from FdbOrchTest
[ RUN      ] FdbOrchTest.BugMc1PostFlushRelearnDelayedAck
MC1_AFTER_FLUSH flush_success=1 flush_had_entry=1 asic_present=0 cache_present=1 pending=1
MC1_AFTER_RELEARN event=SAI_FDB_EVENT_LEARNED same_key=1 same_port=1 asic_present=1 cache_present=1 pending=1 mux_consumer_port=Ethernet0
MC1_AFTER_DELAYED_FLUSHED cache_present=0 state_db_present=0 asic_present=1 vlan_count=0 port_count=0 mux_consumer_port=<empty>
MC1_PERSISTENCE_CHECK repeat_query=1 asic_present=1 cache_present=0 state_db_present=0 mux_consumer_port=<empty>
MC1_BUG_TRIGGERED expected_cache_present=1 expected_state_db_present=1 expected_mux_consumer_port=Ethernet0
[       OK ] FdbOrchTest.BugMc1PostFlushRelearnDelayedAck (157 ms)
[----------] 1 test from FdbOrchTest (157 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (157 ms total)
[  PASSED  ] 1 test.
```

The pass assertions require the wrong outcome: generation 2 remains in the ASIC oracle while cache and STATE_DB are absent, counts are zero, and two real Mux consumer queries return empty. This matches round-2 counterexample States 7-17 and is persistent absent a later independent FDB event.
