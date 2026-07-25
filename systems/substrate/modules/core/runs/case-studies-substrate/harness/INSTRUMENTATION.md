# Substrate GRANDPA Trace Instrumentation

## Overview

Trace emission is built directly into the `sc-consensus-grandpa` crate via a `tla_trace` module. It is activated by setting the `GRANDPA_TRACE_FILE` environment variable to a file path.

## Architecture

- **Trace module**: `client/consensus/grandpa/src/tla_trace.rs`
- **Activation**: `GRANDPA_TRACE_FILE=/path/to/trace.ndjson`
- **Thread safety**: Uses `Mutex<BufWriter<File>>` via `once_cell::Lazy`
- **Node ID mapping**: Test peers named `peer#N` → `s{N+1}` (e.g., `peer#0` → `s1`)
- **Thread-local context**: Node name and current round passed via thread-locals for the `finalize_block` free function

## Instrumented Events

| Event | Source File | Trigger Point |
|-------|-----------|---------------|
| `Propose` | `environment.rs:proposed()` | After `write_voter_set_state` succeeds |
| `Prevote` | `environment.rs:prevoted()` | After `write_voter_set_state` succeeds |
| `Precommit` | `environment.rs:precommitted()` | After `write_voter_set_state` succeeds |
| `CompleteRound` | `environment.rs:completed()` | After `write_voter_set_state` succeeds |
| `FinalizeBlock` | `environment.rs:finalize_block()` | After `client.apply_finality()` succeeds |

## Event Format

Each line is a JSON object:
```json
{
  "tag": "trace",
  "timestamp": 1772717530036,
  "event": "Prevote",
  "node": "s1",
  "round": 1,
  "block": 20,
  "state": {
    "finalizedBlock": 0,
    "setId": 0,
    "currentRound": 1,
    "bestBlock": 20
  }
}
```

## Build Patches Applied

1. `primitives/io/src/lib.rs`: Removed `#[no_mangle]` from panic handler (rustc 1.93 compat)
2. `utils/wasm-builder/src/wasm_project.rs`: Skip `runtime_version` check on deserialize failure
3. `vendor/parity-wasm-0.45.0`: Added saturating float-to-int (0xFC 0x00-0x07) instruction support
4. `vendor/wasm-instrument-0.3.0`: Added `bulk` feature with stack height tracking for bulk instructions
5. `client/executor/common/Cargo.toml`: Enabled `bulk` and `sign_ext` features on `wasm-instrument`
6. `client/executor/src/wasm_runtime.rs`: Enabled `wasm_bulk_memory: true` in wasmtime config
7. Root `Cargo.toml`: Added `[patch.crates-io]` for vendored crates

## Test Scenarios

| Test | Description | Expected Events |
|------|-------------|----------------|
| `finalize_3_voters_no_observers` | 3 voters finalize block 20 | Prevote×3, Precommit×3, CompleteRound×3, FinalizeBlock×3 |
| `transition_3_voters_twice_1_full_observer` | Authority set changes twice | ~134 events across 8 peers, setId 0→2 |
| `force_change_to_new_set` | Forced authority change | ~12 events |

## Running

```bash
cd case-studies/substrate
bash harness/run.sh
```

Or manually:
```bash
cd artifact/substrate
GRANDPA_TRACE_FILE=../../traces/output.ndjson \
  cargo test -p sc-consensus-grandpa -- tests::finalize_3_voters_no_observers --exact
```
