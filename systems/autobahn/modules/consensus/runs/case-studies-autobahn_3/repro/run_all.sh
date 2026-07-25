#!/usr/bin/env bash
# Drive every reproduction in sequence.

set -e
DIR=$(dirname "$0")
bash "$DIR/test_bug1_qc_omits_proposals.sh"
echo
bash "$DIR/test_bug2_tc_verify_shortcircuits.sh"
echo
bash "$DIR/test_bug3_view_advance_side_effect.sh"
echo
bash "$DIR/test_bug4_winning_view_wrong.sh"
echo
bash "$DIR/test_bug5_no_leader_check.sh"
echo
bash "$DIR/test_bug6_committed_slot_overwrite.sh"
