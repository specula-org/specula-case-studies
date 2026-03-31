"""
Trace emission library for MongoDB Change Streams TLA+ trace validation.

Emits NDJSON trace events matching the Trace.tla expected format.
Tracks spec-internal clock state to emit correct AdvanceShardClock events
so MergeNextNormal can always pick the correct shard.

Clock model:
  - Spec Init sets shardClock[s] = 1 for all shards.
  - SilentAdvanceShardClock advances clock to trace's state.clusterTime.
  - The traced action (GenerateEvent, AdvanceShardClock) then adds +1.
  - So: after a traced event with state.clusterTime=N, spec clock = N+1.
  - We track spec_clocks[s] = the spec's shardClock after the last event.

Merge constraint:
  - MergeNextNormal picks the shard with the minimum effective token.
  - An idle shard's HWM token = (clock, version, 0, ...).
  - An event token = (ct, version, 128, ...).
  - For MergeNextNormal to pick the source shard, all other shards need
    clock > event.ct. Since event.ct = spec_clocks[source] after generate,
    other shards need clock > spec_clocks[source], i.e., >= spec_clocks[source]+1.
"""

import json
from datetime import datetime, timezone


class TraceEmitter:
    """Emit NDJSON trace events for TLA+ trace validation."""

    def __init__(self, trace_file, shards):
        """
        Args:
            trace_file: Path to output NDJSON file.
            shards: List of TLA+ shard identifiers, e.g. ["s1", "s2"].
        """
        self.f = open(trace_file, "w")
        self.shards = list(shards)
        # Spec-internal state tracking (mirrors TLA+ Init)
        self.spec_clocks = {s: 1 for s in shards}
        self.shard_event_counts = {s: 0 for s in shards}
        self.delivered_count = 0
        self.stream_state = "Active"
        self.topo_mode = "Normal"

    # ------------------------------------------------------------------
    # Low-level: single event emission
    # ------------------------------------------------------------------

    def _emit(self, event_name, **fields):
        """Write one NDJSON trace line with tag=trace."""
        line = {
            "tag": "trace",
            "ts": datetime.now(timezone.utc).isoformat(),
            "event": {"name": event_name, **fields},
        }
        self.f.write(json.dumps(line, separators=(",", ":")) + "\n")
        self.f.flush()

    def emit_advance_shard_clock(self, shard):
        """Emit one AdvanceShardClock event. Advances spec clock by 1."""
        ct = self.spec_clocks[shard]
        self._emit("AdvanceShardClock", shard=shard, state={"clusterTime": ct})
        self.spec_clocks[shard] = ct + 1

    def ensure_shard_clock(self, shard, min_clock):
        """Emit AdvanceShardClock events until spec clock >= min_clock."""
        while self.spec_clocks[shard] < min_clock:
            self.emit_advance_shard_clock(shard)

    def emit_generate_event(self, shard, op_type):
        """Emit GenerateEvent. Advances source shard clock by 1."""
        ct = self.spec_clocks[shard]
        self.shard_event_counts[shard] += 1
        self._emit(
            "GenerateEvent",
            shard=shard,
            opType=op_type,
            state={
                "clusterTime": ct,
                "numEvents": self.shard_event_counts[shard],
            },
        )
        self.spec_clocks[shard] = ct + 1

    def emit_generate_invalidating_event(self, shard, op_type):
        """Emit GenerateInvalidatingEvent (drop/rename)."""
        ct = self.spec_clocks[shard]
        self.shard_event_counts[shard] += 1
        self._emit(
            "GenerateInvalidatingEvent",
            shard=shard,
            opType=op_type,
            state={
                "clusterTime": ct,
                "numEvents": self.shard_event_counts[shard],
            },
        )
        self.spec_clocks[shard] = ct + 1

    def emit_merge_normal(self, op_type):
        """Emit MergeNextNormal."""
        self.delivered_count += 1
        self._emit(
            "MergeNextNormal",
            state={
                "deliveredCount": self.delivered_count,
                "topoMode": self.topo_mode,
            },
            opType=op_type,
        )

    def emit_merge_invalidating(self, op_type):
        """Emit MergeNextInvalidating."""
        self.delivered_count += 1
        self._emit(
            "MergeNextInvalidating",
            state={"deliveredCount": self.delivered_count},
            opType=op_type,
        )

    def emit_deliver_invalidation(self):
        """Emit DeliverInvalidation. Transitions stream to Invalidated."""
        self.delivered_count += 1
        self.stream_state = "Invalidated"
        self._emit(
            "DeliverInvalidation",
            state={
                "streamState": self.stream_state,
                "deliveredCount": self.delivered_count,
            },
        )

    def emit_initiate_resume(self):
        """Emit InitiateResume. Resets delivered count."""
        self._emit("InitiateResume")
        self.delivered_count = 0
        self.stream_state = "Active"

    # ------------------------------------------------------------------
    # High-level: combined actions (generate + advance others + merge)
    # ------------------------------------------------------------------

    def _advance_others_past(self, source_shard):
        """Advance all non-source shards so their HWM > source's latest event."""
        target = self.spec_clocks[source_shard] + 1
        for other in self.shards:
            if other != source_shard:
                self.ensure_shard_clock(other, target)

    def generate_and_merge(self, shard, op_type):
        """GenerateEvent + advance others + MergeNextNormal."""
        self.emit_generate_event(shard, op_type)
        self._advance_others_past(shard)
        self.emit_merge_normal(op_type)

    def invalidate_and_merge(self, shard, op_type):
        """GenerateInvalidatingEvent + advance others + MergeNextInvalidating."""
        self.emit_generate_invalidating_event(shard, op_type)
        self._advance_others_past(shard)
        self.emit_merge_invalidating(op_type)

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def close(self):
        """Flush and close."""
        self.f.flush()
        self.f.close()
