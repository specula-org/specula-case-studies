/*
 * TLA+ Trace Emission Module for Tarantool Raft.
 *
 * Produces NDJSON trace files for TLA+ trace validation.
 * Activated by setting RAFT_TRACE_FILE environment variable.
 */

#include "tla_trace.h"
#include "raft/raft.h"
#include "vclock/vclock.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdbool.h>
#include <inttypes.h>

/** Global trace file handle. NULL when tracing is disabled. */
static FILE *trace_fp = NULL;

void
tla_trace_init(void)
{
	if (trace_fp != NULL)
		return;
	const char *path = getenv("RAFT_TRACE_FILE");
	if (path == NULL || path[0] == '\0')
		return;
	trace_fp = fopen(path, "w");
	if (trace_fp == NULL) {
		fprintf(stderr, "TLA_TRACE: failed to open %s\n", path);
	}
}

void
tla_trace_shutdown(void)
{
	if (trace_fp != NULL) {
		fflush(trace_fp);
		fclose(trace_fp);
		trace_fp = NULL;
	}
}

bool
tla_trace_is_enabled(void)
{
	return trace_fp != NULL;
}

/** Get current monotonic time in nanoseconds. */
static int64_t
trace_timestamp_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/** Map raft state enum to string. */
static const char *
trace_state_str(enum raft_state state)
{
	switch (state) {
	case RAFT_STATE_FOLLOWER:  return "follower";
	case RAFT_STATE_CANDIDATE: return "candidate";
	case RAFT_STATE_LEADER:    return "leader";
	default:                   return "follower";
	}
}

/**
 * Serialize leader_witness_map bitmap to JSON array of set bit positions.
 * Example: bitmap 0b1010 → "[1, 3]"
 * buf must be at least 256 bytes.
 */
static int
trace_witness_map_snprintf(char *buf, int size, vclock_map_t map)
{
	int total = 0;
	int written;
	bool first = true;

	written = snprintf(buf + total, size - total, "[");
	if (written > 0) total += written;

	for (int i = 0; i < 32 && total < size; i++) {
		if (map & (1u << i)) {
			if (!first) {
				written = snprintf(buf + total, size - total,
						   ", ");
				if (written > 0) total += written;
			}
			written = snprintf(buf + total, size - total, "%d", i);
			if (written > 0) total += written;
			first = false;
		}
	}

	written = snprintf(buf + total, size - total, "]");
	if (written > 0) total += written;

	return total;
}

/**
 * Emit core state fields as JSON fragment (no surrounding braces).
 * Writes: "state":"follower","volatileTerm":1,...
 */
static int
trace_state_snprintf(char *buf, int size, const struct raft *raft)
{
	char witness_buf[256];
	trace_witness_map_snprintf(witness_buf, sizeof(witness_buf),
				   raft->leader_witness_map);

	return snprintf(buf, size,
		"\"state\":\"%s\","
		"\"volatileTerm\":%" PRIu64 ","
		"\"volatileVote\":%" PRIu32 ","
		"\"persistedTerm\":%" PRIu64 ","
		"\"persistedVote\":%" PRIu32 ","
		"\"leader\":%" PRIu32 ","
		"\"isWriteInProgress\":%s,"
		"\"leaderWitnessMap\":%s",
		trace_state_str(raft->state),
		raft->volatile_term,
		raft->volatile_vote,
		raft->term,
		raft->vote,
		raft->leader,
		raft->is_write_in_progress ? "true" : "false",
		witness_buf);
}

/**
 * Emit a trace event with just the event name and node state.
 */
static void
trace_emit_node_event(const char *event_name, const struct raft *raft)
{
	if (trace_fp == NULL)
		return;

	char state_buf[512];
	trace_state_snprintf(state_buf, sizeof(state_buf), raft);

	fprintf(trace_fp,
		"{\"tag\":\"trace\",\"ts\":\"%" PRId64 "\","
		"\"event\":\"%s\",\"node\":%" PRIu32 ",%s}\n",
		trace_timestamp_ns(), event_name, raft->self, state_buf);
	fflush(trace_fp);
}

/**
 * Emit a trace event for message reception.
 * Includes from/to and message fields.
 */
static void
trace_emit_msg_event(const char *event_name, const struct raft *raft,
		     const struct raft_msg *msg, uint32_t source)
{
	if (trace_fp == NULL)
		return;

	char state_buf[512];
	trace_state_snprintf(state_buf, sizeof(state_buf), raft);

	/*
	 * Message fields: term, vote, leaderId, state, isLeaderSeen.
	 * vclock is omitted for simplicity (not validated in Trace.tla
	 * message matching — messages are matched by type and from).
	 */
	fprintf(trace_fp,
		"{\"tag\":\"trace\",\"ts\":\"%" PRId64 "\","
		"\"event\":\"%s\","
		"\"from\":%" PRIu32 ",\"to\":%" PRIu32 ","
		"\"node\":%" PRIu32 ",%s,"
		"\"msgTerm\":%" PRIu64 ","
		"\"msgVote\":%" PRIu32 ","
		"\"msgLeaderId\":%" PRIu32 ","
		"\"msgState\":\"%s\","
		"\"msgIsLeaderSeen\":%s}\n",
		trace_timestamp_ns(), event_name,
		source, raft->self,
		raft->self, state_buf,
		msg->term, msg->vote, msg->leader_id,
		trace_state_str((enum raft_state)msg->state),
		msg->is_leader_seen ? "true" : "false");
	fflush(trace_fp);
}

/* --- Public API --- */

void
tla_trace_election_timeout(const struct raft *raft)
{
	trace_emit_node_event("election_timeout", raft);
}

void
tla_trace_receive_message(const struct raft *raft, const struct raft_msg *msg,
			  uint32_t source)
{
	trace_emit_msg_event("receive_message", raft, msg, source);
}

void
tla_trace_receive_heartbeat(const struct raft *raft, uint32_t source)
{
	if (trace_fp == NULL)
		return;

	char state_buf[512];
	trace_state_snprintf(state_buf, sizeof(state_buf), raft);

	fprintf(trace_fp,
		"{\"tag\":\"trace\",\"ts\":\"%" PRId64 "\","
		"\"event\":\"receive_heartbeat\","
		"\"from\":%" PRIu32 ",\"to\":%" PRIu32 ","
		"\"node\":%" PRIu32 ",%s}\n",
		trace_timestamp_ns(), source, raft->self,
		raft->self, state_buf);
	fflush(trace_fp);
}

void
tla_trace_wal_write_term_only(const struct raft *raft)
{
	trace_emit_node_event("wal_write_term_only", raft);
}

void
tla_trace_wal_write_term_and_vote(const struct raft *raft)
{
	trace_emit_node_event("wal_write_term_and_vote", raft);
}

void
tla_trace_wal_write_revoke_vote(const struct raft *raft)
{
	trace_emit_node_event("wal_write_revoke_vote", raft);
}

void
tla_trace_wal_write_term_no_vote(const struct raft *raft)
{
	trace_emit_node_event("wal_write_term_no_vote", raft);
}

void
tla_trace_complete_wal_write(const struct raft *raft)
{
	trace_emit_node_event("complete_wal_write", raft);
}

void
tla_trace_broadcast_state(const struct raft *raft)
{
	trace_emit_node_event("broadcast_state", raft);
}

void
tla_trace_send_heartbeat(const struct raft *raft)
{
	trace_emit_node_event("send_heartbeat", raft);
}

void
tla_trace_crash(uint32_t node_id)
{
	if (trace_fp == NULL)
		return;

	fprintf(trace_fp,
		"{\"tag\":\"trace\",\"ts\":\"%" PRId64 "\","
		"\"event\":\"crash\",\"node\":%" PRIu32 "}\n",
		trace_timestamp_ns(), node_id);
	fflush(trace_fp);
}

void
tla_trace_promote(const struct raft *raft)
{
	trace_emit_node_event("promote", raft);
}

void
tla_trace_leader_resign(const struct raft *raft)
{
	trace_emit_node_event("leader_resign", raft);
}

void
tla_trace_notify_leader_seen(const struct raft *raft, uint32_t source,
			     bool is_seen)
{
	if (trace_fp == NULL)
		return;

	char state_buf[512];
	trace_state_snprintf(state_buf, sizeof(state_buf), raft);

	fprintf(trace_fp,
		"{\"tag\":\"trace\",\"ts\":\"%" PRId64 "\","
		"\"event\":\"notify_leader_seen\","
		"\"node\":%" PRIu32 ",%s,"
		"\"source\":%" PRIu32 ",\"isLeaderSeen\":%s}\n",
		trace_timestamp_ns(), raft->self, state_buf,
		source, is_seen ? "true" : "false");
	fflush(trace_fp);
}
