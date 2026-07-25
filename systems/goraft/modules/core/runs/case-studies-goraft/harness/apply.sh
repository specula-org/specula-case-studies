#!/bin/bash
# Apply trace instrumentation to the goraft artifact.
# Run from: case-studies/goraft/
set -euo pipefail

ARTIFACT="artifact/raft"
HARNESS="harness"

echo "=== Applying goraft trace instrumentation ==="

# 1. Reset artifact to clean state
echo "[1/5] Resetting artifact..."
git -C "$ARTIFACT" checkout -- .

# 2. Copy trace module and test files
echo "[2/5] Copying trace module and tests..."
cp "$HARNESS/src/tla_trace.go" "$ARTIFACT/tla_trace.go"
cp "$HARNESS/src/tla_trace_test.go" "$ARTIFACT/tla_trace_test.go"

# 3. Fix old import paths for Go modules compatibility
echo "[3/5] Fixing import paths..."
# Main code: code.google.com/p/gogoprotobuf/proto -> github.com/golang/protobuf/proto
find "$ARTIFACT" -name "*.go" -not -path "*/protobuf/*" -exec \
    sed -i 's|"code.google.com/p/gogoprotobuf/proto"|"github.com/golang/protobuf/proto"|g' {} +

# Generated pb.go: import proto "code.google.com/p/goprotobuf/proto" -> github.com/golang/protobuf/proto
find "$ARTIFACT/protobuf" -name "*.pb.go" -exec \
    sed -i 's|"code.google.com/p/goprotobuf/proto"|"github.com/golang/protobuf/proto"|g' {} +

# 4. Create go.mod if it doesn't exist
echo "[4/5] Setting up Go modules..."
if [ ! -f "$ARTIFACT/go.mod" ]; then
    cat > "$ARTIFACT/go.mod" << 'GOMOD'
module github.com/goraft/raft

go 1.21

require github.com/golang/protobuf v1.5.4

require google.golang.org/protobuf v1.33.0 // indirect
GOMOD
fi

# Tidy dependencies
(cd "$ARTIFACT" && PATH=/usr/local/go/bin:$PATH go mod tidy 2>/dev/null || true)

# 5. Fix vet errors in old code (newer Go compiler is stricter)
echo "[5/6] Fixing vet errors in legacy code..."
# log.go:265 — .Index is a func value, needs () call
sed -i '/traceln.*entries\[len(l.entries)-1\]\.Index$/{s/\.Index$/\.Index()/}' "$ARTIFACT/log.go"
# server_test.go — resp.Term and resp.Success are methods on AppendEntriesResponse
# In Fatalf format strings, these need () to be called
sed -i 's/resp\.Term, resp\.Success)/resp.Term(), resp.Success())/g' "$ARTIFACT/server_test.go"

# 6. Apply instrumentation patch
echo "[5/5] Applying instrumentation patch..."
PATCH_PATH="$(cd "$HARNESS/patches" && pwd)/instrumentation.patch"
(cd "$ARTIFACT" && git apply --stat "$PATCH_PATH" && git apply "$PATCH_PATH")

echo "=== Instrumentation applied successfully ==="
