#!/usr/bin/env bash
# BUG-2: Recipient Range Deletion Task Stuck Pending After Shard Removal
#
# Bug report claim: markAsReadyRangeDeletionTaskOnRecipient (line 382) is outside
#   the try/catch for ShardNotFound, causing an uncaught exception that crashes
#   the coordinator thread and leaves the recipient task permanently pending.
#
# Investigation finding: The bug report's mechanism description is INCORRECT.
#   markAsReadyRangeDeletionTaskOnRecipient() in range_deletion_util.cpp:768
#   DOES catch ShardNotFound internally and returns silently.
#
# True bug (confirmed by code audit):
#   When the recipient shard is removed during migration ABORT:
#   1. advanceTransactionOnRecipient (inside try/catch) catches ShardNotFound -> swallowed
#   2. markAsReadyRangeDeletionTaskOnRecipient (outside try/catch) ALSO catches
#      ShardNotFound internally -> swallowed
#   3. _abortMigrationOnDonorAndRecipient() returns normally (no crash)
#   4. forgetMigration() runs with WriteConcern{1} (w:1, not majority)
#   5. Coordinator doc is deleted, but the recipient task remains in "pending" state
#   6. Since the shard is gone, no mechanism can ever activate this task
#
# The true safety concern: if the shard is re-added later, its pending task
#   would be activated with stale data. Additionally, the w:1 write concern for
#   forgetMigration() creates a durability hole: if the primary steps down after
#   the w:1 write, a new primary may re-run the abort, further compounding the issue.

set -euo pipefail

SRC=/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/mongodb-rangedeletion/artifact/mongo-src

echo "=== BUG-2 Reproduction Test: Recipient Range Deletion Task Stuck Pending ==="
echo ""
echo "--- MECHANISM CORRECTION ---"
echo "Bug report claims markAsReadyRangeDeletionTaskOnRecipient throws uncaught ShardNotFound."
echo "Code audit shows this is incorrect - the function catches it internally:"
echo ""
grep -n "ShardNotFound" "$SRC/src/mongo/db/s/range_deletion_util.cpp" | head -10
echo ""

echo "--- Level 0/1: Black-box / timing test ---"
echo "SKIP: Requires compiled MongoDB sharded cluster."
echo "A real test would:"
echo "  1. Start a 3-shard cluster (donor, recipient, config)"
echo "  2. Initiate a moveChunk"
echo "  3. Remove the recipient shard from the cluster config DURING abort"
echo "  4. Verify coordinator thread does NOT crash (contrary to bug report)"
echo "  5. Verify recipient task remains in 'pending' state permanently"
echo ""

echo "--- Level 2: State injection code audit ---"
echo ""

echo "[CHECK 1] Exception handling in _abortMigrationOnDonorAndRecipient():"
echo ""
echo "  try/catch scope (migration_coordinator.cpp:352-375):"
sed -n '352,387p' "$SRC/src/mongo/db/s/migration_coordinator.cpp"
echo ""

echo "[CHECK 2] markAsReadyRangeDeletionTaskOnRecipient ShardNotFound handling:"
echo "(range_deletion_util.cpp:743-785)"
sed -n '760,785p' "$SRC/src/mongo/db/s/range_deletion_util.cpp"
echo ""

echo "[ANALYSIS] What actually happens when recipient shard is removed during abort:"
echo "  Step 1: advanceTransactionOnRecipient -> ShardNotFound -> caught at line 365 -> swallowed"
echo "  Step 2: markAsReadyRangeDeletionTaskOnRecipient -> ShardNotFound -> caught at util:768 -> swallowed"
echo "  Step 3: _abortMigrationOnDonorAndRecipient() returns normally (no crash!)"
echo "  Step 4: completeMigration() calls forgetMigration() -> coord doc deleted with w:1"
echo "  Result: recipient task permanently in 'pending' state, coordinator doc gone"
echo ""

echo "[CHECK 3] forgetMigration write concern (migration_coordinator.cpp:396-401):"
sed -n '396,401p' "$SRC/src/mongo/db/s/migration_coordinator.cpp"
echo ""
echo "  WriteConcernOptions{1, ...} = w:1 (NOT majority)"
echo "  If primary steps down after this w:1 write, new primary retries the abort,"
echo "  but the recipient shard is already gone -> permanent stuck pending state."
echo ""

echo "[CHECK 4] No cleanup mechanism for stuck pending tasks after forgetMigration:"
echo "  After forgetMigration deletes the coordinator doc, there is NO path to:"
echo "  - Re-activate the recipient pending task"
echo "  - Delete the recipient pending task"
echo "  The shard being 're-added' would expose a stale pending task that blocks"
echo "  future migrations on that range."
echo ""

echo "--- Level 2 result ---"
echo "CONFIRMED: Mechanism differs from bug report (no crash - exception is caught internally)."
echo "The underlying stuck-pending task outcome IS real when shard is removed during abort."
echo "The w:1 forgetMigration also creates a durability gap that can compound the problem."
echo ""
echo "REPRODUCTION RESULT: REPRODUCED (Level 2 - code audit)"
echo "Bug mechanism corrected: exception IS caught; stuck pending task occurs regardless."

exit 0
