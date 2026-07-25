#!/bin/bash
# BUG-F2: Timeout digest ignores all content (SHA512("") for all inputs).
# A Byzantine node can forge any Timeout content and reuse any honest signature.
# Affected: primary/src/messages.rs:1352-1362 (impl Hash for Timeout)

set -e

ARTIFACT_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/autobahn/artifact/autobahn"
TEST_FILE="$ARTIFACT_DIR/primary/src/tests/trace_scenarios.rs"
BACKUP="$TEST_FILE.bug1.bak"

cp "$TEST_FILE" "$BACKUP"
cleanup() { cp "$BACKUP" "$TEST_FILE"; rm -f "$BACKUP"; }
trap cleanup EXIT

# Insert test before the last closing brace
python3 - "$TEST_FILE" << 'PYEOF'
import sys
content = open(sys.argv[1]).read()
test_code = r"""
    #[test]
    fn bug_f2_timeout_hash_empty() {
        // BUG-F2: primary::messages::Timeout::digest() always returns SHA512("").
        // All hasher.update() calls are commented out at messages.rs:1355-1358.
        // This allows any Byzantine node to reuse an honest signature on arbitrary Timeout content.
        use crypto::generate_keypair;
        use rand::rngs::StdRng;
        use rand::SeedableRng as _;
        use crypto::Hash as _;

        let mut rng = StdRng::from_seed([42u8; 32]);
        let (author, _secret) = generate_keypair(&mut rng);

        // Two Timeouts with completely different slot and view fields
        let t1 = Timeout {
            slot: 1, view: 1,
            high_qc: None, high_prop: None,
            author,
            signature: Signature::default(),
        };
        let t2 = Timeout {
            slot: 999, view: 999,  // completely different content
            high_qc: None, high_prop: None,
            author,
            signature: Signature::default(),
        };

        let d1 = t1.digest();
        let d2 = t2.digest();

        println!("[BUG-F2] t1(slot=1, view=1) digest:     {:?}", d1);
        println!("[BUG-F2] t2(slot=999, view=999) digest: {:?}", d2);
        println!("[BUG-F2] Digests equal: {}", d1 == d2);

        assert_eq!(d1, d2,
            "FAIL: Digests should differ for different slot/view values.\n\
             A correct Hash impl would cover slot and view fields.");

        println!("[BUG-F2] CONFIRMED: Timeout::digest() = SHA512(\"\") for ALL inputs.");
        println!("[BUG-F2] hasher.update calls at messages.rs:1355-1358 are commented out.");
        println!("[BUG-F2] A Byzantine node can sign SHA512(\"\") and reuse that signature");
        println!("[BUG-F2] on any Timeout message with arbitrary slot/view/high_qc content.");
    }
"""
last_brace = content.rfind('}')
new_content = content[:last_brace] + test_code + '\n' + content[last_brace:]
open(sys.argv[1], 'w').write(new_content)
print("Inserted bug_f2_timeout_hash_empty into trace_scenarios.rs")
PYEOF

cd "$ARTIFACT_DIR"
echo "=== Running BUG-F2 reproduction test ==="
timeout 120 cargo test -p primary -- bug_f2_timeout_hash_empty --nocapture 2>&1
echo "=== Test complete ==="
