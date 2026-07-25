#!/usr/bin/env python3
"""
preprocess_traces.py - Normalize node IDs in trace files.

CometBFT uses hex-encoded public key addresses (long strings) as node IDs.
For trace validation against TLA+, we may need to map these to simpler names
like "v1", "v2", etc., or extract the first few chars.

Usage:
  python3 preprocess_traces.py INPUT_TRACE OUTPUT_TRACE [--rename-to-v-style]

By default, keeps the full hex node IDs. Use --rename-to-v-style to map to v1, v2, etc.
"""

import json
import sys
from collections import defaultdict
from pathlib import Path


def preprocess_trace(input_file, output_file, rename_style="keep"):
    """
    Preprocess a trace file to normalize node IDs.

    Args:
        input_file: Path to input NDJSON trace file
        output_file: Path to output NDJSON trace file
        rename_style: "keep" (keep original), "short" (first 8 chars), "v-style" (v1, v2, ...)
    """
    node_id_map = {}
    next_v_index = 1

    with open(input_file, 'r') as fin, open(output_file, 'w') as fout:
        for line in fin:
            if not line.strip():
                continue

            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"Warning: Skipping invalid JSON line: {e}", file=sys.stderr)
                continue

            # Extract and normalize node ID
            if 'event' in obj and 'nid' in obj['event']:
                nid = obj['event']['nid']
                if nid not in node_id_map:
                    if rename_style == "keep":
                        node_id_map[nid] = nid
                    elif rename_style == "short":
                        node_id_map[nid] = nid[:8]
                    elif rename_style == "v-style":
                        node_id_map[nid] = f"v{next_v_index}"
                        next_v_index += 1
                obj['event']['nid'] = node_id_map[nid]

            # Write normalized event
            fout.write(json.dumps(obj) + '\n')

    print(f"Processed {input_file} -> {output_file}", file=sys.stderr)
    print(f"Node ID mappings: {json.dumps(node_id_map, indent=2)}", file=sys.stderr)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]
    rename_style = "keep"

    if len(sys.argv) > 3:
        if sys.argv[3] == "--rename-to-v-style":
            rename_style = "v-style"
        elif sys.argv[3] == "--rename-short":
            rename_style = "short"

    if not Path(input_file).exists():
        print(f"Error: Input file not found: {input_file}", file=sys.stderr)
        sys.exit(1)

    preprocess_trace(input_file, output_file, rename_style)


if __name__ == "__main__":
    main()
