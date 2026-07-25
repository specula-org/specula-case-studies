#!/usr/bin/env bash
# Apply HotShot trace instrumentation to the artifact.
#
# Usage:
#   bash harness/apply.sh           # apply patches
#   bash harness/apply.sh --clean   # revert via `git checkout`
#
# This script is idempotent: applying twice is a no-op (the patches detect
# their own marker comments and skip).
#
# Initial instrumentation covers a CORE subset (HandleQuorumProposalRecv,
# ProposeLeader, Crash, Recover). Other events (SubmitVote, TimeoutVote,
# FormQC/FormTC, ObserveQC, ViewSyncVote) are documented in
# INSTRUMENTATION.md for the Phase 3 agent to extend if needed.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "${HARNESS_DIR}/../../artifact/espresso-network" && pwd)"
SRC_DIR="${ARTIFACT_DIR}/crates/hotshot/task-impls/src"

if [[ "${1:-}" == "--clean" ]]; then
    echo "Reverting artifact via git checkout..."
    cd "${ARTIFACT_DIR}"
    git checkout -- crates/hotshot/task-impls/ 2>/dev/null || true
    git checkout -- crates/hotshot/testing/tests/ 2>/dev/null || true
    rm -f "${SRC_DIR}/tla_trace.rs"
    rm -f "${ARTIFACT_DIR}/crates/hotshot/testing/tests/tests_1/trace_harness_test.rs"
    echo "Done."
    exit 0
fi

echo "Applying HotShot trace instrumentation..."
echo "  HARNESS_DIR=${HARNESS_DIR}"
echo "  ARTIFACT_DIR=${ARTIFACT_DIR}"

# ------------------------------------------------------------------
# 1. Copy the trace module into the artifact
# ------------------------------------------------------------------
cp "${HARNESS_DIR}/src/tla_trace.rs" "${SRC_DIR}/tla_trace.rs"
echo "  + ${SRC_DIR}/tla_trace.rs"

# ------------------------------------------------------------------
# 2. Patch lib.rs to include the trace module
# ------------------------------------------------------------------
python3 - "${SRC_DIR}/lib.rs" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
marker = "pub mod tla_trace;"
if marker in src:
    print(f"  = {p} (already patched)")
else:
    needle = "pub mod stats;"
    if needle not in src:
        sys.exit(f"lib.rs anchor not found: {needle}")
    src = src.replace(
        needle,
        needle + "\n\n/// TLA+ trace emission for Specula harness\npub mod tla_trace;",
    )
    p.write_text(src)
    print(f"  + {p}")
PYEOF

# ------------------------------------------------------------------
# 3. Patch task-impls/Cargo.toml to add serde_json
# ------------------------------------------------------------------
python3 - "${ARTIFACT_DIR}/crates/hotshot/task-impls/Cargo.toml" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
if "serde_json = { workspace = true }" in src:
    print(f"  = {p} (already patched)")
else:
    needle = "serde = { workspace = true }"
    if needle not in src:
        sys.exit(f"Cargo.toml anchor not found: {needle}")
    src = src.replace(
        needle,
        needle + "\nserde_json = { workspace = true }",
    )
    p.write_text(src)
    print(f"  + {p}")
PYEOF

# ------------------------------------------------------------------
# 4. Patch quorum_proposal_recv/handlers.rs — HandleQuorumProposalRecv emit
# ------------------------------------------------------------------
python3 - "${SRC_DIR}/quorum_proposal_recv/handlers.rs" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
marker = "// TLA_TRACE_MARKER: HandleQuorumProposalRecv"
if marker in src:
    print(f"  = {p} (already patched)")
    sys.exit(0)

# Anchor: the FINAL broadcast_view_change (4-space indent, success path).
# The earlier broadcast_view_change at L389 has 8-space indent so the
# anchor below only matches the second occurrence.
anchor = '''    broadcast_view_change(
        event_sender,
        view_number,
        proposal_epoch,
        validation_info.first_epoch,
    )
    .await;

    Ok(())
}'''
new = '''    broadcast_view_change(
        event_sender,
        view_number,
        proposal_epoch,
        validation_info.first_epoch,
    )
    .await;

    // TLA_TRACE_MARKER: HandleQuorumProposalRecv
    {
        use crate::tla_trace;
        if tla_trace::is_enabled() {
            let cr = validation_info.consensus.read().await;
            let cur_view_n = cr.cur_view().u64();
            let cur_epoch_n = cr.cur_epoch().map(|e| *e).unwrap_or(0);
            let locked_view_n = cr.locked_view().u64();
            let high_qc_view_n = cr.high_qc().view_number().u64();
            let highest_block_n = cr.highest_block;
            drop(cr);
            let nid = tla_trace::nid(validation_info.id);
            let leaf_commit_s = format!("{}", hotshot_types::data::Leaf2::from_quorum_proposal(&proposal.data).commit());
            let parent_leaf_s = format!("{}", proposal.data.justify_qc().data.leaf_commit);
            let evidence_kind = match proposal.data.view_change_evidence().as_ref() {
                None => "EvNone",
                Some(hotshot_types::data::ViewChangeEvidence2::Timeout(_)) => "EvTimeout",
                Some(hotshot_types::data::ViewChangeEvidence2::ViewSync(_)) => "EvViewSync",
            };
            let view_u = view_number.u64();
            let proposal_epoch_n = proposal_epoch.map(|e| *e).unwrap_or(0);
            let state = tla_trace::state_obj(
                cur_view_n,
                cur_epoch_n,
                locked_view_n,
                0,
                highest_block_n,
                high_qc_view_n,
                high_qc_view_n,
                false,
            );
            let msg = serde_json::json!({
                "view": view_u,
                "leaf": leaf_commit_s,
                "parentLeaf": parent_leaf_s,
                "epochClaim": proposal_epoch_n,
                "evidenceKind": evidence_kind,
            });
            tla_trace::emit(
                "HandleQuorumProposalRecv",
                &nid,
                view_u,
                proposal_epoch_n,
                state,
                msg,
            );
        }
    }

    Ok(())
}'''
if anchor not in src:
    sys.exit(f"quorum_proposal_recv anchor not found")
src = src.replace(anchor, new)
p.write_text(src)
print(f"  + {p}")
PYEOF

# ------------------------------------------------------------------
# 5. Patch quorum_proposal/handlers.rs — ProposeLeader emit
# ------------------------------------------------------------------
python3 - "${SRC_DIR}/quorum_proposal/handlers.rs" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
marker = "// TLA_TRACE_MARKER: ProposeLeader"
if marker in src:
    print(f"  = {p} (already patched)")
    sys.exit(0)

anchor = '''        broadcast_event(
            Arc::new(HotShotEvent::QuorumProposalSend(
                message.clone(),
                self.public_key.clone(),
            )),
            &self.sender,
        )
        .await;

        Ok(())
    }'''
new = '''        broadcast_event(
            Arc::new(HotShotEvent::QuorumProposalSend(
                message.clone(),
                self.public_key.clone(),
            )),
            &self.sender,
        )
        .await;

        // TLA_TRACE_MARKER: ProposeLeader
        {
            use crate::tla_trace;
            if tla_trace::is_enabled() {
                let cr = self.consensus.read().await;
                let cur_view_n = cr.cur_view().u64();
                let locked_view_n = cr.locked_view().u64();
                let high_qc_view_n = cr.high_qc().view_number().u64();
                let highest_block_n = cr.highest_block;
                drop(cr);
                let nid = tla_trace::nid(self.id);
                let view_u = self.view_number.u64();
                let leaf_commit_s = format!("{}", proposed_leaf.commit());
                let evidence_kind = match message.data.view_change_evidence().as_ref() {
                    None => "EvNone",
                    Some(hotshot_types::data::ViewChangeEvidence2::Timeout(_)) => "EvTimeout",
                    Some(hotshot_types::data::ViewChangeEvidence2::ViewSync(_)) => "EvViewSync",
                };
                let epoch_n = epoch.map(|e| *e).unwrap_or(0);
                let state = tla_trace::state_obj(
                    cur_view_n, epoch_n, locked_view_n, 0, highest_block_n,
                    high_qc_view_n, high_qc_view_n, false,
                );
                let msg = serde_json::json!({
                    "view": view_u,
                    "leaf": leaf_commit_s,
                    "evidenceKind": evidence_kind,
                });
                tla_trace::emit("ProposeLeader", &nid, view_u, epoch_n, state, msg);
            }
        }

        Ok(())
    }'''
if anchor not in src:
    sys.exit(f"publish_proposal broadcast anchor not found")
src = src.replace(anchor, new)
p.write_text(src)
print(f"  + {p}")
PYEOF

# ------------------------------------------------------------------
# 6. Patch hotshot-testing/Cargo.toml to add serde_json
# ------------------------------------------------------------------
python3 - "${ARTIFACT_DIR}/crates/hotshot/testing/Cargo.toml" <<'PYEOF'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
if "serde_json = { workspace = true }" in src:
    print(f"  = {p} (already patched)")
else:
    needle = "serde = { workspace = true }"
    if needle not in src:
        sys.exit(f"testing Cargo.toml anchor not found: {needle}")
    src = src.replace(
        needle,
        needle + "\nserde_json = { workspace = true }",
    )
    p.write_text(src)
    print(f"  + {p}")
PYEOF

# ------------------------------------------------------------------
# 7. Copy the test scenario into the testing crate.
# ------------------------------------------------------------------
TESTING_DIR="${ARTIFACT_DIR}/crates/hotshot/testing/tests/tests_1"
cp "${HARNESS_DIR}/src/trace_harness_test.rs" "${TESTING_DIR}/trace_harness_test.rs"
echo "  + ${TESTING_DIR}/trace_harness_test.rs"

# tests_1.rs uses `automod::dir!("tests/tests_1")` which auto-discovers
# new files, so no patch needed there.

echo ""
echo "Instrumentation applied. Next steps:"
echo "  cd ${ARTIFACT_DIR}"
echo "  cargo build -p hotshot-task-impls"
echo "  TLA_TRACE_DIR=${HARNESS_DIR}/../traces cargo test -p hotshot-testing --test tests_1 tla_trace -- --nocapture --test-threads=1"
