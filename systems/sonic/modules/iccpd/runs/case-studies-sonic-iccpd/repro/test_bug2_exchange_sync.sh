#!/bin/bash
# test_bug2_exchange_sync.sh — Reproduce Bug 2 (M4): Sync request during EXCHANGE → ERROR
#
# Uses the existing test harness binary which already contains
# scenario_exchange_sync_bug() demonstrating this bug.
#
# Expected: p1 reaches MLACP_STATE_ERROR after receiving a sync request in EXCHANGE state.

set -e

ICCPD_SRC="$(dirname "$0")/../artifact/sonic-buildimage/src/iccpd/src"
TRACE_DIR=$(mktemp -d)

echo "=== Bug 2 (M4): Sync Request During EXCHANGE Advances FSM to ERROR ==="
echo "Running test harness..."

OUTPUT=$("$ICCPD_SRC/iccpd_test" "$TRACE_DIR" 2>&1)

echo "$OUTPUT"
echo ""

# Check for the bug: p1 should reach ERROR state
if echo "$OUTPUT" | grep -q "MLACP_STATE_ERROR"; then
    echo "RESULT: BUG REPRODUCED"
    echo "  p1 reached MLACP_STATE_ERROR after receiving sync request in EXCHANGE state."
    echo "  Root cause: mlacp_sync_send_all_info_handler() calls current_state++"
    echo "  with no guard against current_state == MLACP_STATE_EXCHANGE."
    exit 0
else
    echo "RESULT: BUG NOT REPRODUCED"
    exit 1
fi

rm -rf "$TRACE_DIR"
