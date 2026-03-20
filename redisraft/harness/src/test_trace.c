/*
 * Test scenarios for TLA+ trace generation.
 *
 * Drives the raft library directly (no Redis) to exercise:
 *   1. basic_consensus: election + log replication + commit
 *   2. leader_failover: leader change after term bump
 *   3. snapshot_basic: snapshot creation and log compaction
 *
 * Uses the CuTest framework and mock_send_functions from the raft library.
 * Each scenario writes to a separate NDJSON file via RAFT_TRACE_FILE env var.
 */

#include <stdbool.h>
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "CuTest.h"
#include "raft.h"
#include "raft_log.h"
#include "raft_private.h"
#include "mock_send_functions.h"
#include "helpers.h"
#include "tla_trace.h"

/* --- Callbacks --- */

static int __persist_metadata(raft_server_t *raft, void *udata,
                              raft_term_t term, raft_node_id_t vote) {
    return 0;
}

static int __applylog(raft_server_t *raft, void *udata,
                      raft_entry_t *ety, raft_index_t idx) {
    return 0;
}

static raft_node_id_t __get_node_id(raft_server_t *raft, void *udata,
                                    raft_entry_t *entry, raft_index_t idx) {
    return atoi(entry->data);
}

/* --- Helpers --- */

typedef struct {
    raft_server_t *r;
    void *sender;
    raft_node_id_t id;
} test_node_t;

/* RAFT_TRACE_FILE is set by the caller (run.sh).
 * setup_trace just initializes the module. */
static void setup_trace(void) {
    tla_trace_init();
}

static void teardown_trace(void) {
    tla_trace_shutdown();
}

/* Create a 3-node cluster. Node IDs: 1, 2, 3 -> s1, s2, s3 */
static void create_cluster(test_node_t nodes[3]) {
    raft_cbs_t cbs = {
        .persist_metadata   = __persist_metadata,
        .applylog           = __applylog,
        .get_node_id        = __get_node_id,
        .send_requestvote   = sender_requestvote,
        .send_appendentries = sender_appendentries,
    };

    senders_new();

    tla_trace_register_server(1, "s1");
    tla_trace_register_server(2, "s2");
    tla_trace_register_server(3, "s3");

    for (int i = 0; i < 3; i++) {
        nodes[i].id = i + 1;
        nodes[i].sender = sender_new(NULL);
        nodes[i].r = raft_new();
        raft_set_callbacks(nodes[i].r, &cbs, nodes[i].sender);
        sender_set_raft(nodes[i].sender, nodes[i].r);
        raft_config(nodes[i].r, 1, RAFT_CONFIG_AUTO_FLUSH, 1);
    }

    /* Add all nodes to each server */
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            raft_node_t *n = raft_add_node(nodes[i].r, nodes[j].sender,
                                           j + 1, (i == j));
            (void)n;
        }
    }
}

/*
 * Scenario 1: basic_consensus
 *
 * - Node 1 times out and becomes candidate (term 1)
 * - Nodes 2,3 grant votes
 * - Node 1 becomes leader, appends noop
 * - Client appends an entry on node 1
 * - Node 1 sends AE to nodes 2,3
 * - Nodes 2,3 accept, leader advances commitIndex
 */
void TestTrace_basic_consensus(CuTest *tc) {
    setup_trace();

    test_node_t nodes[3];
    create_cluster(nodes);

    raft_server_t *r1 = nodes[0].r;
    raft_server_t *r2 = nodes[1].r;
    raft_server_t *r3 = nodes[2].r;

    /* Emit config line */
    tla_trace_emit_config(r1);

    /* --- Election: node 1 times out --- */
    /* Simulate timeout: advance election timer past threshold */
    raft_periodic_internal(r1, 1000);

    /* r1 becomes candidate via the periodic timer which calls
     * raft_election_start -> raft_become_candidate */

    /* Manually trigger election if periodic didn't (depends on timeout config) */
    if (raft_get_state(r1) != RAFT_STATE_CANDIDATE &&
        raft_get_state(r1) != RAFT_STATE_LEADER) {
        raft_election_start(r1, 1);  /* skip precandidate */
    }

    CuAssertIntEquals(tc, RAFT_STATE_CANDIDATE, raft_get_state(r1));
    CuAssertIntEquals(tc, 1, raft_get_current_term(r1));

    /* --- Process vote requests at nodes 2 and 3 --- */
    sender_poll_msgs(nodes[1].sender);  /* r2 receives RequestVote from r1 */
    sender_poll_msgs(nodes[2].sender);  /* r3 receives RequestVote from r1 */

    /* --- Process vote responses at node 1 --- */
    sender_poll_msgs(nodes[0].sender);  /* r1 receives vote responses */

    /* r1 should now be leader */
    CuAssertIntEquals(tc, RAFT_STATE_LEADER, raft_get_state(r1));

    /* --- Process initial AE (noop) at followers --- */
    sender_poll_msgs(nodes[1].sender);  /* r2 receives AE (noop) */
    sender_poll_msgs(nodes[2].sender);  /* r3 receives AE (noop) */

    /* --- Process AE responses at leader --- */
    sender_poll_msgs(nodes[0].sender);  /* r1 receives AE responses */

    /* Commit index should advance (noop committed) */
    CuAssertTrue(tc, raft_get_commit_idx(r1) >= 1);

    /* --- Client request --- */
    raft_entry_t *ety = raft_entry_new(4);
    ety->type = RAFT_LOGTYPE_NORMAL;
    memcpy(ety->data, "cmd1", 4);

    raft_entry_resp_t resp;
    int e = raft_recv_entry(r1, ety, &resp);
    CuAssertIntEquals(tc, 0, e);
    raft_entry_release(ety);

    /* --- Replicate client entry to followers --- */
    sender_poll_msgs(nodes[1].sender);  /* r2 receives AE with entry */
    sender_poll_msgs(nodes[2].sender);  /* r3 receives AE with entry */

    /* --- Process AE responses, commit advances --- */
    sender_poll_msgs(nodes[0].sender);

    CuAssertTrue(tc, raft_get_commit_idx(r1) >= 2);

    teardown_trace();
}

/*
 * Scenario 2: leader_failover
 *
 * - Same cluster setup, node 1 wins election (term 1)
 * - Replicate a few entries
 * - Node 2 times out (term 2), wins election
 * - Node 2 becomes new leader
 */
void TestTrace_leader_failover(CuTest *tc) {
    setup_trace();

    test_node_t nodes[3];
    create_cluster(nodes);

    raft_server_t *r1 = nodes[0].r;
    raft_server_t *r2 = nodes[1].r;

    tla_trace_emit_config(r1);

    /* --- Node 1 wins first election --- */
    raft_election_start(r1, 1);
    CuAssertIntEquals(tc, RAFT_STATE_CANDIDATE, raft_get_state(r1));

    sender_poll_msgs(nodes[1].sender);
    sender_poll_msgs(nodes[2].sender);
    sender_poll_msgs(nodes[0].sender);
    CuAssertIntEquals(tc, RAFT_STATE_LEADER, raft_get_state(r1));

    /* Replicate noop */
    sender_poll_msgs(nodes[1].sender);
    sender_poll_msgs(nodes[2].sender);
    sender_poll_msgs(nodes[0].sender);

    /* --- Client entry on leader r1 --- */
    raft_entry_t *ety = raft_entry_new(4);
    ety->type = RAFT_LOGTYPE_NORMAL;
    memcpy(ety->data, "val1", 4);
    raft_entry_resp_t resp;
    raft_recv_entry(r1, ety, &resp);
    raft_entry_release(ety);

    /* Replicate */
    sender_poll_msgs(nodes[1].sender);
    sender_poll_msgs(nodes[2].sender);
    sender_poll_msgs(nodes[0].sender);

    /* --- Node 2 starts new election (simulating r1 failure) --- */
    raft_election_start(r2, 1);
    CuAssertIntEquals(tc, RAFT_STATE_CANDIDATE, raft_get_state(r2));
    CuAssertIntEquals(tc, 2, raft_get_current_term(r2));

    /* Process vote requests and responses */
    sender_poll_msgs(nodes[0].sender);  /* r1 receives RV from r2, steps down */
    sender_poll_msgs(nodes[2].sender);  /* r3 receives RV from r2 */
    sender_poll_msgs(nodes[1].sender);  /* r2 receives vote responses */

    CuAssertIntEquals(tc, RAFT_STATE_LEADER, raft_get_state(r2));

    /* Replicate noop from new leader */
    sender_poll_msgs(nodes[0].sender);
    sender_poll_msgs(nodes[2].sender);
    sender_poll_msgs(nodes[1].sender);

    teardown_trace();
}

/*
 * Scenario 3: snapshot_basic
 *
 * - Elect leader, commit some entries
 * - Leader takes a snapshot, compacting log
 */
void TestTrace_snapshot_basic(CuTest *tc) {
    setup_trace();

    test_node_t nodes[3];
    create_cluster(nodes);

    raft_server_t *r1 = nodes[0].r;

    tla_trace_emit_config(r1);

    /* Elect leader */
    raft_election_start(r1, 1);
    sender_poll_msgs(nodes[1].sender);
    sender_poll_msgs(nodes[2].sender);
    sender_poll_msgs(nodes[0].sender);
    CuAssertIntEquals(tc, RAFT_STATE_LEADER, raft_get_state(r1));

    /* Replicate noop */
    sender_poll_msgs(nodes[1].sender);
    sender_poll_msgs(nodes[2].sender);
    sender_poll_msgs(nodes[0].sender);

    /* Add entries and commit them */
    for (int i = 0; i < 3; i++) {
        raft_entry_t *ety = raft_entry_new(4);
        ety->type = RAFT_LOGTYPE_NORMAL;
        char data[8];
        snprintf(data, sizeof(data), "v%d", i);
        memcpy(ety->data, data, 4);
        raft_entry_resp_t resp;
        raft_recv_entry(r1, ety, &resp);
        raft_entry_release(ety);

        /* Replicate and commit */
        sender_poll_msgs(nodes[1].sender);
        sender_poll_msgs(nodes[2].sender);
        sender_poll_msgs(nodes[0].sender);
    }

    CuAssertTrue(tc, raft_get_commit_idx(r1) >= 4);

    /* --- Take snapshot --- */
    int e = raft_begin_snapshot(r1);
    CuAssertIntEquals(tc, 0, e);

    e = raft_end_snapshot(r1);
    CuAssertIntEquals(tc, 0, e);

    CuAssertTrue(tc, raft_get_snapshot_last_idx(r1) > 0);

    teardown_trace();
}

/* --- Test runner --- */

/* Run a specific scenario by name, or all if no arg given */
int main(int argc, char **argv) {
    CuString *output = CuStringNew();
    CuSuite *suite = CuSuiteNew();

    const char *filter = (argc > 1) ? argv[1] : NULL;

    if (!filter || strcmp(filter, "basic_consensus") == 0)
        SUITE_ADD_TEST(suite, TestTrace_basic_consensus);
    if (!filter || strcmp(filter, "leader_failover") == 0)
        SUITE_ADD_TEST(suite, TestTrace_leader_failover);
    if (!filter || strcmp(filter, "snapshot_basic") == 0)
        SUITE_ADD_TEST(suite, TestTrace_snapshot_basic);

    CuSuiteRun(suite);
    CuSuiteDetails(suite, output);
    printf("%s\n", output->buffer);

    return suite->failCount > 0 ? 1 : 0;
}
