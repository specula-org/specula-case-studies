#!/bin/bash
# Apply TLA+ trace instrumentation to the safety-rules crate.
#
# Steps:
#  1. Copy tla_trace.rs into consensus/safety-rules/src/.
#  2. Add `pub mod tla_trace;` to safety-rules/src/lib.rs (under cfg(test)).
#  3. Patch safety_rules_2chain.rs and safety_rules.rs to emit trace
#     events at the locations the instrumentation spec calls for:
#       - SignVote                between sign() and persist (line 88-92)
#       - CompletePersistVote     after set_safety_data (line 92)
#       - SignOrderVote           after set_safety_data (line 117)
#       - SignTimeout             after persist + sign   (line 47-49)
#       - SignCommitVote          after sign (safety_rules.rs:415)
#       - EpochChange             after SafetyData::new persist (line 303)
#  4. Copy the scenario file into safety-rules/src/tests/.
#  5. Add `mod tla_trace_scenario;` to safety-rules/src/tests/mod.rs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../../artifact/aptos-core" && pwd)"
SR_SRC="$ARTIFACT_DIR/consensus/safety-rules/src"

echo "=== Applying TLA+ trace instrumentation (aptosbft round 2) ==="
echo "Artifact: $ARTIFACT_DIR"
echo "SafetyRules src: $SR_SRC"

# --- 1. Copy trace module ---------------------------------------------------
echo "[1/5] Copying tla_trace.rs..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$SR_SRC/tla_trace.rs"

# --- 2. Register module in lib.rs ------------------------------------------
echo "[2/5] Registering tla_trace in lib.rs..."
LIB_RS="$SR_SRC/lib.rs"
if ! grep -q "pub mod tla_trace;" "$LIB_RS"; then
    # Insert the cfg(test)-gated declaration after the existing
    # `mod safety_rules_2chain;` line so it's available to all tests.
    awk '
        BEGIN { added = 0 }
        /^mod safety_rules_2chain;/ {
            print
            if (!added) {
                print ""
                print "#[cfg(any(test, feature = \"testing\"))]"
                print "pub mod tla_trace;"
                added = 1
            }
            next
        }
        { print }
    ' "$LIB_RS" > "$LIB_RS.new"
    mv "$LIB_RS.new" "$LIB_RS"
    echo "  added tla_trace declaration"
else
    echo "  tla_trace already declared"
fi

# --- 3. Patch safety_rules_2chain.rs ---------------------------------------
echo "[3/5] Patching safety_rules_2chain.rs..."
SR2_RS="$SR_SRC/safety_rules_2chain.rs"

if ! grep -q "tla_trace::emit_event" "$SR2_RS"; then
    python3 - "$SR2_RS" <<'PY'
import re, sys
path = sys.argv[1]
src  = open(path).read()

# SignTimeout: after persist (line 47) and sign (line 49)
src = src.replace(
    "        self.persistent_storage.set_safety_data(safety_data)?;\n\n        let signature = self.sign(&timeout.signing_format())?;\n        Ok(signature)\n    }",
    "        self.persistent_storage.set_safety_data(safety_data.clone())?;\n\n        let signature = self.sign(&timeout.signing_format())?;\n\n        #[cfg(any(test, feature = \"testing\"))]\n        if crate::tla_trace::is_active() {\n            let nid = crate::tla_trace::active_nid();\n            let state = crate::tla_trace::safety_state(&safety_data);\n            crate::tla_trace::emit_event(\n                \"SignTimeout\",\n                &nid,\n                timeout.round(),\n                safety_data.epoch,\n                state,\n                None,\n            );\n        }\n        Ok(signature)\n    }",
    1,
)

# SignVote (between sign and persist) + CompletePersistVote (after persist)
old = (
    "        let signature = self.sign(&ledger_info)?;\n"
    "        let vote = Vote::new_with_signature(vote_data, author, ledger_info, signature);\n"
    "\n"
    "        safety_data.last_vote = Some(vote.clone());\n"
    "        self.persistent_storage.set_safety_data(safety_data)?;\n"
    "\n"
    "        Ok(vote)\n    }"
)
new = (
    "        let signature = self.sign(&ledger_info)?;\n"
    "        let vote = Vote::new_with_signature(vote_data, author, ledger_info, signature);\n"
    "\n"
    "        safety_data.last_vote = Some(vote.clone());\n"
    "\n"
    "        #[cfg(any(test, feature = \"testing\"))]\n"
    "        if crate::tla_trace::is_active() {\n"
    "            let nid = crate::tla_trace::active_nid();\n"
    "            let state = crate::tla_trace::safety_state(&safety_data);\n"
    "            crate::tla_trace::emit_event(\n"
    "                \"SignVote\",\n"
    "                &nid,\n"
    "                proposed_block.round(),\n"
    "                safety_data.epoch,\n"
    "                state,\n"
    "                None,\n"
    "            );\n"
    "        }\n"
    "\n"
    "        self.persistent_storage.set_safety_data(safety_data.clone())?;\n"
    "\n"
    "        #[cfg(any(test, feature = \"testing\"))]\n"
    "        if crate::tla_trace::is_active() {\n"
    "            let nid = crate::tla_trace::active_nid();\n"
    "            let state = crate::tla_trace::safety_state(&safety_data);\n"
    "            crate::tla_trace::emit_event(\n"
    "                \"CompletePersistVote\",\n"
    "                &nid,\n"
    "                proposed_block.round(),\n"
    "                safety_data.epoch,\n"
    "                state,\n"
    "                None,\n"
    "            );\n"
    "        }\n"
    "\n"
    "        Ok(vote)\n    }"
)
if old not in src:
    print("ERROR: could not find SignVote/CompletePersistVote anchor", file=sys.stderr)
    sys.exit(1)
src = src.replace(old, new, 1)

# SignOrderVote: after set_safety_data (line 117)
old_ov = (
    "        let order_vote = OrderVote::new_with_signature(author, ledger_info.clone(), signature);\n"
    "        self.persistent_storage.set_safety_data(safety_data)?;\n"
    "        Ok(order_vote)\n    }"
)
new_ov = (
    "        let order_vote = OrderVote::new_with_signature(author, ledger_info.clone(), signature);\n"
    "        self.persistent_storage.set_safety_data(safety_data.clone())?;\n"
    "\n"
    "        #[cfg(any(test, feature = \"testing\"))]\n"
    "        if crate::tla_trace::is_active() {\n"
    "            let nid = crate::tla_trace::active_nid();\n"
    "            let state = crate::tla_trace::safety_state(&safety_data);\n"
    "            crate::tla_trace::emit_event(\n"
    "                \"SignOrderVote\",\n"
    "                &nid,\n"
    "                proposed_block.round(),\n"
    "                safety_data.epoch,\n"
    "                state,\n"
    "                None,\n"
    "            );\n"
    "        }\n"
    "\n"
    "        Ok(order_vote)\n    }"
)
if old_ov not in src:
    print("ERROR: could not find SignOrderVote anchor", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_ov, new_ov, 1)

open(path, "w").write(src)
PY
    echo "  patched safety_rules_2chain.rs"
else
    echo "  safety_rules_2chain.rs already patched"
fi

# --- 4. Patch safety_rules.rs (SignCommitVote + EpochChange) ----------------
echo "[4/5] Patching safety_rules.rs..."
SR_RS="$SR_SRC/safety_rules.rs"

if ! grep -q "tla_trace::emit_event" "$SR_RS"; then
    python3 - "$SR_RS" <<'PY'
import sys
path = sys.argv[1]
src  = open(path).read()

# SignCommitVote: after sign returns (line 415).  The local
# `new_ledger_info` and its embedded BlockInfo give us the round + epoch.
old = (
    "        // TODO: add guarding rules in unhappy path\n"
    "        // TODO: add extension check\n"
    "\n"
    "        let signature = self.sign(&new_ledger_info)?;\n"
    "\n"
    "        Ok(signature)\n    }"
)
new = (
    "        // TODO: add guarding rules in unhappy path\n"
    "        // TODO: add extension check\n"
    "\n"
    "        let signature = self.sign(&new_ledger_info)?;\n"
    "\n"
    "        #[cfg(any(test, feature = \"testing\"))]\n"
    "        if crate::tla_trace::is_active() {\n"
    "            let nid = crate::tla_trace::active_nid();\n"
    "            let sd  = self.persistent_storage.safety_data().ok();\n"
    "            let mut state = sd.as_ref().map(crate::tla_trace::safety_state).unwrap_or_else(|| serde_json::json!({}));\n"
    "            if let Some(obj) = state.as_object_mut() {\n"
    "                obj.insert(\"epoch\".into(), serde_json::json!(new_ledger_info.epoch()));\n"
    "            }\n"
    "            crate::tla_trace::emit_event(\n"
    "                \"SignCommitVote\",\n"
    "                &nid,\n"
    "                new_ledger_info.commit_info().round(),\n"
    "                new_ledger_info.epoch(),\n"
    "                state,\n"
    "                None,\n"
    "            );\n"
    "        }\n"
    "\n"
    "        Ok(signature)\n    }"
)
if old not in src:
    print("ERROR: could not find SignCommitVote anchor", file=sys.stderr)
    sys.exit(1)
src = src.replace(old, new, 1)

# EpochChange: after the SafetyData::new persist in the
# Ordering::Less branch (around line 296-303).  Splice the emit
# immediately after the closing `)` of `set_safety_data(...)`.
old_ep = (
    "            Ordering::Less => {\n"
    "                // start new epoch\n"
    "                self.persistent_storage.set_safety_data(SafetyData::new(\n"
    "                    epoch_state.epoch,\n"
    "                    0,\n"
    "                    0,\n"
    "                    0,\n"
    "                    None,\n"
    "                    0,\n"
    "                ))?;\n"
    "\n"
    "                info!(SafetyLogSchema::new(LogEntry::Epoch, LogEvent::Update)\n"
    "                    .epoch(epoch_state.epoch));\n"
    "            },"
)
new_ep = (
    "            Ordering::Less => {\n"
    "                // start new epoch\n"
    "                self.persistent_storage.set_safety_data(SafetyData::new(\n"
    "                    epoch_state.epoch,\n"
    "                    0,\n"
    "                    0,\n"
    "                    0,\n"
    "                    None,\n"
    "                    0,\n"
    "                ))?;\n"
    "\n"
    "                #[cfg(any(test, feature = \"testing\"))]\n"
    "                if crate::tla_trace::is_active() {\n"
    "                    let nid = crate::tla_trace::active_nid();\n"
    "                    if let Ok(sd) = self.persistent_storage.safety_data() {\n"
    "                        let state = crate::tla_trace::safety_state(&sd);\n"
    "                        crate::tla_trace::emit_event(\n"
    "                            \"EpochChange\",\n"
    "                            &nid,\n"
    "                            0,\n"
    "                            sd.epoch,\n"
    "                            state,\n"
    "                            None,\n"
    "                        );\n"
    "                    }\n"
    "                }\n"
    "\n"
    "                info!(SafetyLogSchema::new(LogEntry::Epoch, LogEvent::Update)\n"
    "                    .epoch(epoch_state.epoch));\n"
    "            },"
)
if old_ep not in src:
    print("ERROR: could not find EpochChange anchor", file=sys.stderr)
    sys.exit(1)
src = src.replace(old_ep, new_ep, 1)

open(path, "w").write(src)
PY
    echo "  patched safety_rules.rs"
else
    echo "  safety_rules.rs already patched"
fi

# --- 5. Drop in the scenario file -------------------------------------------
echo "[5/5] Installing test scenario..."
TESTS_DIR="$SR_SRC/tests"
cp "$SCRIPT_DIR/src/tla_trace_scenario.rs" "$TESTS_DIR/tla_trace_scenario.rs"

if ! grep -q "mod tla_trace_scenario;" "$TESTS_DIR/mod.rs"; then
    cat >> "$TESTS_DIR/mod.rs" <<'EOF'

#[cfg(any(test, feature = "testing"))]
mod tla_trace_scenario;
EOF
    echo "  registered tla_trace_scenario"
else
    echo "  tla_trace_scenario already registered"
fi

echo "=== Instrumentation applied ==="
