#!/usr/bin/env bash
# Runs the four CR-11 (AST-07) ktests, one kernel boot each, with QEMU exception logging.
set -u
S=${SCRATCH:-/tmp/claude-1000/-home-chin39-Documents-play-specula-profile/fdddff6c-e100-4393-bfca-70a770b0b10b/scratchpad}
WT=$S/aster-pin; L=$S/logs/cr11; mkdir -p $L
TESTS=(cr11_l0_empty_slice_round_trip_matrix cr11_l0_empty_slice_answers_from_a_foreign_frame cr11_l0_empty_slice_at_end_boundary_faults cr11_l0_max_tracked_boundary_probe)
for t in "${TESTS[@]}"; do
  echo "=== $t start $(date -u +%FT%TZ)"
  ( cd $WT/ostd && KTEST_QEMU_LOG=$L/$t.qemu-int.log SMP=2 timeout 2400 $WT/osdk/target/debug/cargo-osdk osdk test "cr11_repro::$t" --target-arch x86_64 ) > $L/$t.log 2>&1
  echo "=== $t exit=$? end $(date -u +%FT%TZ)"
  grep -aoE "CR11\|[^ ]*|test result:.*|panicked at.*|Cannot handle kernel.*" $L/$t.log | head -40
done
echo CR11_DRIVER_DONE
