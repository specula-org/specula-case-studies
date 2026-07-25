#pragma once
/*
 * TLA+ Trace Emission Module for Tarantool Raft.
 *
 * Emits NDJSON trace lines to a file specified by RAFT_TRACE_FILE env var.
 * Each line is a JSON object with "tag":"trace" for Trace.tla consumption.
 *
 * Thread-safe: No. Tarantool Raft is single-threaded cooperative fiber.
 * This module does not need locking.
 */

#include <stdbool.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

struct raft;
struct raft_msg;

/**
 * Initialize trace emission. Call once at startup.
 * Opens the file specified by RAFT_TRACE_FILE env var.
 * If env var is not set, tracing is disabled (no-op).
 */
void
tla_trace_init(void);

/** Shutdown trace emission. Flushes and closes the file. */
void
tla_trace_shutdown(void);

/** Returns true if tracing is enabled (RAFT_TRACE_FILE is set). */
bool
tla_trace_is_enabled(void);

/*
 * Trace event emitters. Each corresponds to a TLA+ spec action.
 * All capture post-state of the raft instance.
 */

/** ElectionTimeout(s) — election timer fired */
void
tla_trace_election_timeout(const struct raft *raft);

/** ReceiveMessage(s, m) — processed a raft message */
void
tla_trace_receive_message(const struct raft *raft, const struct raft_msg *msg,
			  uint32_t source);

/** ReceiveHeartbeat(s, m) — processed a heartbeat */
void
tla_trace_receive_heartbeat(const struct raft *raft, uint32_t source);

/** WalWriteTermOnly(s) — persisted term only (do_dump path) */
void
tla_trace_wal_write_term_only(const struct raft *raft);

/** WalWriteTermAndVote(s) — persisted term and vote (do_dump_with_vote) */
void
tla_trace_wal_write_term_and_vote(const struct raft *raft);

/** WalWriteRevokeVote(s) — vclock recheck failed, vote revoked */
void
tla_trace_wal_write_revoke_vote(const struct raft *raft);

/** WalWriteTermOnlyNonVote(s) — term only, no vote pending */
void
tla_trace_wal_write_term_no_vote(const struct raft *raft);

/** CompleteWalWrite(s) — WAL write finished, state machine resumed */
void
tla_trace_complete_wal_write(const struct raft *raft);

/** BroadcastRaftState(s) — broadcast persisted state */
void
tla_trace_broadcast_state(const struct raft *raft);

/** LeaderSendHeartbeat(s) — leader sent heartbeat */
void
tla_trace_send_heartbeat(const struct raft *raft);

/** Crash(s) — node crashed (emitted by test harness) */
void
tla_trace_crash(uint32_t node_id);

/** Promote(s) — manual promotion */
void
tla_trace_promote(const struct raft *raft);

/** LeaderResign(s) — leader resigned */
void
tla_trace_leader_resign(const struct raft *raft);

/** NotifyLeaderSeen(s, source, isSeen) */
void
tla_trace_notify_leader_seen(const struct raft *raft, uint32_t source,
			     bool is_seen);

#if defined(__cplusplus)
}
#endif
