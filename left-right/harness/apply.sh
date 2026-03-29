#!/bin/bash
# Apply instrumentation patches to the left-right artifact.
# Adds trace accessor methods and copies test scenarios.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT="$CASE_DIR/artifact/left-right"

echo "=== Applying instrumentation to $ARTIFACT ==="

# 1. Clean artifact to pristine state
cd "$ARTIFACT"
git checkout -- .

# 2. Add trace accessor methods to read.rs
# Insert before the closing "}" of the impl block that contains raw_handle
# Strategy: replace the exact line "    }\n}" after raw_handle with the accessors
python3 << 'PYEOF'
with open('src/read.rs', 'r') as f:
    lines = f.readlines()

# Find the raw_handle method and its impl block closing brace
found_raw_handle = False
insert_idx = None
for i, line in enumerate(lines):
    if 'pub fn raw_handle' in line:
        found_raw_handle = True
    if found_raw_handle and line.strip() == '}' and i > 0 and lines[i-1].strip().startswith('NonNull::new'):
        # This is the closing brace of raw_handle method (line 210)
        # The NEXT "}" is the impl block close (line 211)
        insert_idx = i + 1  # insert before the impl block close
        break

if insert_idx is None:
    raise RuntimeError("Could not find insertion point in read.rs")

accessors = [
    '\n',
    '    /// Trace instrumentation accessor: current epoch value.\n',
    '    pub fn trace_epoch(&self) -> usize {\n',
    '        self.epoch.load(Ordering::Relaxed)\n',
    '    }\n',
    '\n',
    '    /// Trace instrumentation accessor: current enters count.\n',
    '    pub fn trace_enters(&self) -> usize {\n',
    '        self.enters.get()\n',
    '    }\n',
]

lines = lines[:insert_idx] + accessors + lines[insert_idx:]

with open('src/read.rs', 'w') as f:
    f.writelines(lines)

print('  Patched src/read.rs: added trace_epoch(), trace_enters()')
PYEOF

# 3. Add trace accessor methods to write.rs
python3 << 'PYEOF'
with open('src/write.rs', 'r') as f:
    lines = f.readlines()

# Find raw_write_handle closing brace and insert after it
found_rwh = False
insert_idx = None
for i, line in enumerate(lines):
    if 'pub fn raw_write_handle' in line:
        found_rwh = True
    if found_rwh and line.strip() == '}' and 'self.w_handle' in lines[i-1]:
        insert_idx = i + 1
        break

if insert_idx is None:
    raise RuntimeError("Could not find insertion point in write.rs")

accessors = [
    '\n',
    '    /// Trace instrumentation accessor: first flag.\n',
    '    pub fn trace_first(&self) -> bool {\n',
    '        self.first\n',
    '    }\n',
    '\n',
    '    /// Trace instrumentation accessor: second flag.\n',
    '    pub fn trace_second(&self) -> bool {\n',
    '        self.second\n',
    '    }\n',
]

lines = lines[:insert_idx] + accessors + lines[insert_idx:]

with open('src/write.rs', 'w') as f:
    f.writelines(lines)

print('  Patched src/write.rs: added trace_first(), trace_second()')
PYEOF

# 4. Copy test scenarios
cp "$SCRIPT_DIR/src/tla_scenarios.rs" "$ARTIFACT/tests/tla_scenarios.rs"
echo "  Copied tests/tla_scenarios.rs"

echo "=== Instrumentation applied successfully ==="
