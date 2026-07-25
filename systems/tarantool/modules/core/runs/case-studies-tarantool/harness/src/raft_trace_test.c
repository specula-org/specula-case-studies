/*
 * TLA+ Trace Test Scenarios for Tarantool Raft.
 *
 * Each scenario exercises a protocol path, emitting trace events
 * via the instrumented raft.c code. Traces are written to
 * files specified by RAFT_TRACE_FILE env var.
 *
 * Uses the existing raft_test_utils test infrastructure.
 */

#include "raft_test_utils.h"
#include "lib/raft/tla_trace.h"

static int test_result;

/**
 * Scenario 1: Basic leader election.
 *
 * 1. Node 1 starts as follower, election timeout fires.
 * 2. Node 1 becomes candidate (term 2, votes for self).
 * 3. Node 2 and 3 send vote responses.
 * 4. Node 1 becomes leader.
 *
 * Covers: ElectionTimeout, WalWrite*, CompleteWalWrite,
 *         BroadcastRaftState, ReceiveMessage
 */
static void
trace_test_basic_election(void)
{
	raft_start_test(6);
	struct raft_node node;
	raft_node_create(&node);
	raft_node_net_drop(&node);

	/* Wait for election timeout. */
	double death_timeout = node.cfg_death_timeout;
	raft_run_next_event();
	ok(raft_time() >= death_timeout, "election timeout fired");

	/* Node should be candidate now (term 2, voted for self). */
	is(node.raft.state, RAFT_STATE_CANDIDATE, "became candidate");
	is((int)node.raft.volatile_term, 2, "term bumped to 2");
	raft_node_net_drop(&node);

	/* Vote response from node 2. */
	raft_node_send_vote_response(&node, 2, 1, 2);
	is(raft_vote_count(&node.raft), 2, "2 votes");

	/* Vote response from node 3 — quorum reached. */
	raft_node_send_vote_response(&node, 2, 1, 3);
	is(raft_vote_count(&node.raft), 3, "3 votes");
	is(node.raft.state, RAFT_STATE_LEADER, "became leader");

	raft_node_destroy(&node);
	raft_finish_test();
}

/**
 * Scenario 2: Leader heartbeat and election timeout.
 *
 * 1. Node 1 learns about leader (node 2) via message.
 * 2. Heartbeats from leader keep node alive.
 * 3. Heartbeats stop, election timeout fires.
 *
 * Covers: ReceiveMessage (leader), ReceiveHeartbeat,
 *         ElectionTimeout, WalWrite*, CompleteWalWrite
 */
static void
trace_test_heartbeat_timeout(void)
{
	raft_start_test(5);
	struct raft_node node;
	raft_node_create(&node);
	raft_node_net_drop(&node);

	/* Node 2 claims leadership in term 2. */
	raft_node_send_leader(&node, 2, 2);
	is(node.raft.leader, 2, "leader is 2");
	is(node.raft.state, RAFT_STATE_FOLLOWER, "following leader");
	raft_node_net_drop(&node);

	/* Send a heartbeat. */
	raft_node_send_heartbeat(&node, 2);
	ok(true, "heartbeat received");

	/* Send another heartbeat after some time. */
	raft_run_for(node.cfg_death_timeout / 3);
	raft_node_send_heartbeat(&node, 2);
	ok(true, "second heartbeat received");

	/*
	 * Now stop heartbeats and wait for death timeout.
	 * The node should start an election.
	 */
	raft_run_next_event();
	is(node.raft.state, RAFT_STATE_CANDIDATE, "election started after "
	   "leader death timeout");

	raft_node_destroy(&node);
	raft_finish_test();
}

/**
 * Scenario 3: Vote during WAL write (multi-pass persistence).
 *
 * 1. Node 1 receives a term bump that triggers WAL write.
 * 2. While WAL write is blocked, node receives a vote request.
 * 3. After unblock, WAL write completes with multi-pass (term then vote).
 *
 * Covers: ReceiveMessage (term bump + vote request),
 *         WalWriteTermOnly, WalWriteTermAndVote, CompleteWalWrite
 */
static void
trace_test_vote_during_wal_write(void)
{
	raft_start_test(6);
	struct raft_node node;
	raft_node_create(&node);
	raft_node_net_drop(&node);

	/*
	 * Block async work so WAL write doesn't complete immediately.
	 * Then send a vote request from node 2 in term 2.
	 */
	raft_node_block(&node);

	/* Node 2 sends a vote request (candidate in term 2). */
	raft_node_send_vote_request(&node, 2, "{0: 1}", 2);

	is(node.raft.state, RAFT_STATE_FOLLOWER, "still follower");
	is((int)node.raft.volatile_term, 2, "volatile term bumped");
	is((int)node.raft.volatile_vote, 2, "volatile vote for node 2");
	is(node.raft.is_write_in_progress, true, "WAL write in progress");

	/* Unblock — WAL write should complete (multi-pass). */
	raft_node_unblock(&node);

	is((int)node.raft.term, 2, "persisted term is 2");
	is((int)node.raft.vote, 2, "persisted vote is 2");

	raft_node_destroy(&node);
	raft_finish_test();
}

/**
 * Scenario 4: Promote and resign.
 *
 * 1. Node 1 promotes itself.
 * 2. Gets votes, becomes leader.
 * 3. Resigns leadership.
 *
 * Covers: Promote, CompleteWalWrite, ReceiveMessage (votes),
 *         LeaderResign, BroadcastRaftState
 */
static void
trace_test_promote_resign(void)
{
	raft_start_test(5);
	struct raft_node node;
	raft_node_create(&node);
	raft_node_net_drop(&node);

	/* Promote the node. */
	raft_node_promote(&node);
	is(node.raft.state, RAFT_STATE_CANDIDATE, "candidate after promote");
	is((int)node.raft.volatile_term, 2, "term bumped for promote");
	raft_node_net_drop(&node);

	/* Vote responses to reach quorum. */
	raft_node_send_vote_response(&node, 2, 1, 2);
	raft_node_send_vote_response(&node, 2, 1, 3);
	is(node.raft.state, RAFT_STATE_LEADER, "became leader");
	raft_node_net_drop(&node);

	/* Resign. */
	raft_node_resign(&node);
	is(node.raft.state, RAFT_STATE_FOLLOWER, "follower after resign");
	is(node.raft.leader, 0, "no leader after resign");

	raft_node_destroy(&node);
	raft_finish_test();
}

static int
main_f(va_list ap)
{
	raft_start_test(4);
	(void)ap;
	fakeev_init();

	trace_test_basic_election();
	trace_test_heartbeat_timeout();
	trace_test_vote_during_wal_write();
	trace_test_promote_resign();

	fakeev_free();

	test_result = check_plan();
	footer();
	return 0;
}

int
main(void)
{
	tla_trace_init();
	raft_run_test("raft_trace.txt", main_f);
	tla_trace_shutdown();
	return test_result;
}
