# Resharding Coordinator Instrumentation Guide

## Approach

No C++ source code modification. Traces are parsed from MongoDB's existing structured logs (LOGV2).

## How to adjust

### Add a new event type
1. Find the corresponding LOGV2 call in `resharding_coordinator.inl`
2. Add its log ID to `parse_resharding_logs.py` with the appropriate event name mapping
3. Add a corresponding `TraceXxx` action wrapper in `Trace.tla`

### Change state fields captured
Edit the `extract_trace_events()` function in `parse_resharding_logs.py` to include additional fields from `attr`.

### Add participant events
Currently only coordinator events (from configsvr log) are parsed. To add donor/recipient events:
1. Parse `shard1_raw.log` and `shard2_raw.log`
2. Look for donor/recipient log IDs (search for `DonorStateEnum` and `RecipientStateEnum` transitions in donor/recipient service cpp files)
3. Map to `DonorAdvance`, `RecipientAdvance`, etc.

### Rebuild and re-run
```bash
cd case-studies/mongodb-resharding
bash harness/run.sh
```
No compilation needed — only Docker restart and log re-parse.
