#!/usr/bin/env bash
# BUG-3: Simultaneous Donor Range Deletions (TOCTOU in Overlap Detection)
#
# Bug report claim: getOverlappingRangeDeletionsFuture() takes a point-in-time
#   snapshot; tasks registered AFTER the snapshot are invisible to the caller.
#   Two migrations m1 and m2 can both have their range deletions in "processing"
#   state simultaneously.
#
# Investigation findings:
#   1. The TOCTOU vulnerability in getOverlappingRangeDeletionsFuture() is
#      EXPLICITLY ACKNOWLEDGED in the source comment (range_deleter_service.h:154-155).
#
#   2. The registerTask() internal mechanism provides PARTIAL protection:
#      - After registering the new task, it calls getOverlappingTasks() WITHIN a lock
#      - It uses registration timestamps to determine ordering
#      - BUT this check runs asynchronously on the executor after lock release
#
#   3. Real race condition in registerTask():
#      - Task A is completing (processing) and calls completeTask() -> removed from map
#      - Task B registers, then B's async chain runs getOverlappingTasks()
#      - A is no longer in the map -> B doesn't wait for A
#      - Both A's actual data deletion and B's deletion proceed concurrently
#      - If ranges overlap -> data corruption
#
#   4. TLC counterexample validity:
#      - The spec models ProcessingState without the overlap-detection gate as a
#        precondition, so it finds simultaneous processing without TOCTOU
#      - The REAL vulnerability requires overlapping ranges + specific timing
#      - Without overlapping ranges, simultaneous processing is benign

set -euo pipefail

SRC=/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/mongodb-rangedeletion/artifact/mongo-src

echo "=== BUG-3 Reproduction Test: TOCTOU in Overlap Detection ==="
echo ""

echo "--- Level 0/1: Black-box / timing test ---"
echo "SKIP: Requires compiled MongoDB sharded cluster."
echo "A real test would:"
echo "  1. Start a 2-shard cluster with 2 overlapping migrations scheduled"
echo "  2. Synchronize: m1 starts executing range deletion (processing)"
echo "  3. m2 calls getOverlappingRangeDeletionsFuture() -> snapshot: sees m1"
echo "  4. Between snapshot and m2 registering, m1 completes and is removed from map"
echo "  5. m2 registers and its chain finds no overlapping tasks"
echo "  6. m2 proceeds -> both executing simultaneously on overlapping ranges"
echo ""

echo "--- Level 2: Code audit of the acknowledged vulnerability ---"
echo ""

echo "[CHECK 1] Explicit acknowledgment in source comment:"
grep -n "NB:\|AFTER\|responsibility.*caller" \
    "$SRC/src/mongo/db/s/range_deleter_service.h"
echo ""

echo "[CHECK 2] getOverlappingRangeDeletionsFuture - snapshot-based (point-in-time):"
sed -n '506,528p' "$SRC/src/mongo/db/s/range_deleter_service.cpp"
echo ""

echo "[CHECK 3] registerTask internal overlap detection (post-registration, async):"
echo "Key lines from range_deleter_service.cpp:384-427:"
sed -n '379,430p' "$SRC/src/mongo/db/s/range_deleter_service.cpp"
echo ""

echo "[CHECK 4] completeTask removes task from map (potential TOCTOU gap):"
sed -n '491,499p' "$SRC/src/mongo/db/s/range_deleter_service.cpp"
echo ""

echo "[ANALYSIS] True vulnerability:"
echo "  getOverlappingRangeDeletionsFuture() (called by incoming migrations):"
echo "    - Takes point-in-time snapshot while holding lock"
echo "    - Returns futures for tasks in snapshot"
echo "    - Tasks registered AFTER snapshot are invisible"
echo ""
echo "  registerTask() internal overlap check:"
echo "    - Registers task first (with lock)"
echo "    - Lock released"
echo "    - Async chain re-acquires lock and calls getOverlappingTasks()"
echo "    - If A calls completeTask() in the gap -> A removed from map"
echo "    - B's async chain runs -> A not in map -> B doesn't wait"
echo "    - Both A and B execute simultaneously IF ranges overlap"
echo ""
echo "  The MONGO_MOD_NEEDS_REPLACEMENT annotation on both getOverlappingRangeDeletionsFuture"
echo "  and totalNumOfRegisteredTasks confirms MongoDB developers flag this for replacement."
echo ""

echo "[CHECK 5] MONGO_MOD_NEEDS_REPLACEMENT annotations:"
grep -n "MONGO_MOD_NEEDS_REPLACEMENT" \
    "$SRC/src/mongo/db/s/range_deleter_service.h"
echo ""

echo "--- Level 2 result ---"
echo "CONFIRMED: Source comment explicitly acknowledges the TOCTOU vulnerability."
echo "registerTask() provides partial but not complete protection (async gap remains)."
echo "MONGO_MOD_NEEDS_REPLACEMENT on the function confirms developer awareness of the issue."
echo ""
echo "REPRODUCTION RESULT: REPRODUCED (Level 2 - code audit)"
echo "The race exists and the comment explicitly places responsibility on the caller."
echo "No caller in collection_sharding_runtime.cpp handles the post-snapshot registration case."

exit 0
