/**
 * Test scenarios for willemt/raft trace collection.
 *
 * Drives a 3-node Raft cluster through protocol scenarios, producing
 * NDJSON traces for TLA+ trace validation.
 *
 * Build: gcc -Iinclude -DRAFT_ENABLE_TRACE \
 *            src/raft_server.c src/raft_server_properties.c \
 *            src/raft_node.c src/raft_log.c \
 *            src/tla_trace.c tests/test_trace.c \
 *            -o test_trace
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <time.h>

#include "raft.h"
#include "raft_log.h"
#include "raft_private.h"
#include "tla_trace.h"

/* ===================================================================
 * Message queue — simple FIFO for inter-server messages
 * =================================================================== */

enum {
    MSG_RV = 0,
    MSG_RV_RESP,
    MSG_AE,
    MSG_AE_RESP
};

#define MAX_MSGS 4096
#define MAX_ENTRIES_PER_MSG 32

typedef struct {
    int type;
    int from_id;
    int dest_id;
    union {
        msg_requestvote_t rv;
        msg_requestvote_response_t rv_resp;
        msg_appendentries_t ae;
        msg_appendentries_response_t ae_resp;
    } msg;
    raft_entry_t entries[MAX_ENTRIES_PER_MSG];
} pending_msg_t;

static pending_msg_t msg_queue[MAX_MSGS];
static int mq_head = 0;
static int mq_tail = 0;

static void mq_reset(void) { mq_head = mq_tail = 0; }

static void mq_enqueue(pending_msg_t* m)
{
    assert(mq_tail < MAX_MSGS && "message queue overflow");
    memcpy(&msg_queue[mq_tail++], m, sizeof(pending_msg_t));
}

static pending_msg_t* mq_dequeue(void)
{
    if (mq_head >= mq_tail) return NULL;
    return &msg_queue[mq_head++];
}

static int mq_pending(void) { return mq_tail > mq_head; }

/* ===================================================================
 * Server context
 * =================================================================== */

#define NUM_SERVERS 3

typedef struct {
    int id;
    raft_server_t* raft;
} server_t;

static server_t servers[NUM_SERVERS];

static server_t* find_server(int id)
{
    for (int i = 0; i < NUM_SERVERS; i++)
        if (servers[i].id == id) return &servers[i];
    return NULL;
}

/* ===================================================================
 * Raft callbacks
 * =================================================================== */

static int cb_persist_term(raft_server_t* raft, void* udata,
                           raft_term_t term, int vote)
{
    return 0;
}

static int cb_persist_vote(raft_server_t* raft, void* udata, int vote)
{
    return 0;
}

static int cb_send_requestvote(raft_server_t* raft, void* udata,
                               raft_node_t* node, msg_requestvote_t* msg)
{
    server_t* me = (server_t*)udata;
    pending_msg_t pm;
    memset(&pm, 0, sizeof(pm));
    pm.type = MSG_RV;
    pm.from_id = me->id;
    pm.dest_id = raft_node_get_id(node);
    memcpy(&pm.msg.rv, msg, sizeof(msg_requestvote_t));
    mq_enqueue(&pm);
    return 0;
}

static int cb_send_appendentries(raft_server_t* raft, void* udata,
                                 raft_node_t* node,
                                 msg_appendentries_t* msg)
{
    server_t* me = (server_t*)udata;
    pending_msg_t pm;
    memset(&pm, 0, sizeof(pm));
    pm.type = MSG_AE;
    pm.from_id = me->id;
    pm.dest_id = raft_node_get_id(node);
    memcpy(&pm.msg.ae, msg, sizeof(msg_appendentries_t));

    /* Deep-copy entries */
    if (msg->n_entries > 0 && msg->entries) {
        int n = msg->n_entries;
        if (n > MAX_ENTRIES_PER_MSG) n = MAX_ENTRIES_PER_MSG;
        memcpy(pm.entries, msg->entries, n * sizeof(raft_entry_t));
        pm.msg.ae.entries = pm.entries;  /* pointer will be fixed on dequeue */
        pm.msg.ae.n_entries = n;
    }
    mq_enqueue(&pm);
    return 0;
}

static int cb_send_snapshot(raft_server_t* raft, void* udata,
                            raft_node_t* node)
{
    /* Snapshot send — not exercised in basic tests */
    return 0;
}

static int cb_log_offer(raft_server_t* raft, void* udata,
                        raft_entry_t* entry, raft_index_t entry_idx)
{
    return 0;
}

static int cb_log_poll(raft_server_t* raft, void* udata,
                       raft_entry_t* entry, raft_index_t entry_idx)
{
    return 0;
}

static int cb_log_pop(raft_server_t* raft, void* udata,
                      raft_entry_t* entry, raft_index_t entry_idx)
{
    return 0;
}

static int cb_applylog(raft_server_t* raft, void* udata,
                       raft_entry_t* entry, raft_index_t entry_idx)
{
    return 0;
}

/* ===================================================================
 * Message delivery
 * =================================================================== */

static void deliver_all(void)
{
    /* Process until no more messages. Each delivery can enqueue new messages. */
    while (mq_pending()) {
        pending_msg_t* pm = mq_dequeue();
        server_t* dest = find_server(pm->dest_id);
        if (!dest) continue;

        raft_node_t* sender_node = raft_get_node(dest->raft, pm->from_id);
        if (!sender_node) continue;

        switch (pm->type) {
        case MSG_RV: {
            msg_requestvote_response_t resp;
            memset(&resp, 0, sizeof(resp));
            raft_recv_requestvote(dest->raft, sender_node,
                                  &pm->msg.rv, &resp);
            /* Send response back */
            pending_msg_t rpm;
            memset(&rpm, 0, sizeof(rpm));
            rpm.type = MSG_RV_RESP;
            rpm.from_id = dest->id;
            rpm.dest_id = pm->from_id;
            memcpy(&rpm.msg.rv_resp, &resp, sizeof(resp));
            mq_enqueue(&rpm);
            break;
        }
        case MSG_RV_RESP: {
            raft_recv_requestvote_response(dest->raft, sender_node,
                                           &pm->msg.rv_resp);
            break;
        }
        case MSG_AE: {
            msg_appendentries_response_t resp;
            memset(&resp, 0, sizeof(resp));
            /* Fix up entries pointer after queue copy */
            pm->msg.ae.entries = pm->entries;
            raft_recv_appendentries(dest->raft, sender_node,
                                    &pm->msg.ae, &resp);
            /* Send response back */
            pending_msg_t rpm;
            memset(&rpm, 0, sizeof(rpm));
            rpm.type = MSG_AE_RESP;
            rpm.from_id = dest->id;
            rpm.dest_id = pm->from_id;
            memcpy(&rpm.msg.ae_resp, &resp, sizeof(resp));
            mq_enqueue(&rpm);
            break;
        }
        case MSG_AE_RESP: {
            raft_recv_appendentries_response(dest->raft, sender_node,
                                             &pm->msg.ae_resp);
            break;
        }
        }
    }
}

/* ===================================================================
 * Cluster lifecycle
 * =================================================================== */

static void setup_cluster(void)
{
    for (int i = 0; i < NUM_SERVERS; i++) {
        servers[i].id = i + 1;
        servers[i].raft = raft_new();
        assert(servers[i].raft);

        /* Add all nodes — order must be identical on all servers */
        for (int j = 0; j < NUM_SERVERS; j++) {
            raft_add_node(servers[i].raft, &servers[j],
                          j + 1, /* node id */
                          i == j /* is_self */);
        }

        raft_cbs_t cbs;
        memset(&cbs, 0, sizeof(cbs));
        cbs.send_requestvote = cb_send_requestvote;
        cbs.send_appendentries = cb_send_appendentries;
        cbs.send_snapshot = cb_send_snapshot;
        cbs.persist_term = cb_persist_term;
        cbs.persist_vote = cb_persist_vote;
        cbs.log_offer = cb_log_offer;
        cbs.log_poll = cb_log_poll;
        cbs.log_pop = cb_log_pop;
        cbs.applylog = cb_applylog;
        raft_set_callbacks(servers[i].raft, &cbs, &servers[i]);

        raft_set_election_timeout(servers[i].raft, 500);
        raft_set_request_timeout(servers[i].raft, 200);
    }
}

static void cleanup_cluster(void)
{
    for (int i = 0; i < NUM_SERVERS; i++) {
        if (servers[i].raft) {
            raft_free(servers[i].raft);
            servers[i].raft = NULL;
        }
    }
}

/* ===================================================================
 * Test 1: Basic Consensus
 *
 * s1 wins election, replicates one entry, commits it.
 * Exercises: Timeout, HandleRVRequest, HandleRVResponse,
 *            SendAE, HandleAERequest, HandleAEResponse,
 *            ClientRequest
 * =================================================================== */

static void test_basic_consensus(const char* trace_file)
{
    printf("=== test_basic_consensus ===\n");

    mq_reset();
    setup_cluster();
    tla_trace_init(trace_file);

    /* 1. Trigger election on s1 by advancing past election timeout */
    raft_periodic(servers[0].raft, 1000);

    /* 2. Deliver all messages (RV → RV_RESP → become leader → initial AE) */
    deliver_all();

    assert(raft_is_leader(servers[0].raft));
    printf("  s1 elected leader (term=%ld)\n",
           raft_get_current_term(servers[0].raft));

    /* 3. Submit a client entry to s1 */
    msg_entry_t entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = 1;
    entry.type = RAFT_LOGTYPE_NORMAL;
    msg_entry_response_t eresp;
    int e = raft_recv_entry(servers[0].raft, &entry, &eresp);
    assert(e == 0);

    /* 4. Deliver AE with entry + responses (commit happens here) */
    deliver_all();

    printf("  s1 commitIndex=%ld lastLogIndex=%ld\n",
           raft_get_commit_idx(servers[0].raft),
           raft_get_current_idx(servers[0].raft));

    /* 5. Propagate commit via heartbeat */
    raft_periodic(servers[0].raft, 200);
    deliver_all();

    printf("  s2 commitIndex=%ld, s3 commitIndex=%ld\n",
           raft_get_commit_idx(servers[1].raft),
           raft_get_commit_idx(servers[2].raft));

    cleanup_cluster();
    tla_trace_close();
    printf("  Trace → %s\n\n", trace_file);
}

/* ===================================================================
 * Test 2: Leader Re-election
 *
 * s1 leads, then s2 times out and becomes new leader.
 * Exercises: multiple terms, term-based step-down.
 * =================================================================== */

static void test_leader_reelection(const char* trace_file)
{
    printf("=== test_leader_reelection ===\n");

    mq_reset();
    setup_cluster();
    tla_trace_init(trace_file);

    /* 1. s1 wins election */
    raft_periodic(servers[0].raft, 1000);
    deliver_all();
    assert(raft_is_leader(servers[0].raft));
    printf("  s1 elected leader (term=%ld)\n",
           raft_get_current_term(servers[0].raft));

    /* 2. Submit and commit an entry */
    msg_entry_t entry;
    memset(&entry, 0, sizeof(entry));
    entry.id = 1;
    entry.type = RAFT_LOGTYPE_NORMAL;
    msg_entry_response_t eresp;
    raft_recv_entry(servers[0].raft, &entry, &eresp);
    deliver_all();

    /* 3. s2 times out (simulate s1 not sending heartbeats) */
    raft_periodic(servers[1].raft, 1100);
    deliver_all();

    printf("  s2 state=%d (term=%ld)\n",
           raft_get_state(servers[1].raft),
           raft_get_current_term(servers[1].raft));

    /* s2 might need another election round if s3 hasn't voted yet */
    if (!raft_is_leader(servers[1].raft)) {
        raft_periodic(servers[1].raft, 600);
        deliver_all();
    }

    /* Check which server is leader now */
    int leader_id = -1;
    for (int i = 0; i < NUM_SERVERS; i++) {
        if (raft_is_leader(servers[i].raft)) {
            leader_id = servers[i].id;
            break;
        }
    }
    printf("  New leader: s%d (term=%ld)\n",
           leader_id,
           leader_id > 0 ? raft_get_current_term(find_server(leader_id)->raft) : -1);

    /* 4. Submit another entry to new leader */
    if (leader_id > 0) {
        server_t* leader = find_server(leader_id);
        msg_entry_t entry2;
        memset(&entry2, 0, sizeof(entry2));
        entry2.id = 2;
        entry2.type = RAFT_LOGTYPE_NORMAL;
        msg_entry_response_t eresp2;
        raft_recv_entry(leader->raft, &entry2, &eresp2);
        deliver_all();

        printf("  Leader commitIndex=%ld\n",
               raft_get_commit_idx(leader->raft));
    }

    cleanup_cluster();
    tla_trace_close();
    printf("  Trace → %s\n\n", trace_file);
}

/* ===================================================================
 * Main
 * =================================================================== */

static char trace_path[512];

static const char* make_trace_path(const char* name)
{
    const char* dir = getenv("TRACE_DIR");
    if (!dir) dir = ".";
    snprintf(trace_path, sizeof(trace_path), "%s/%s", dir, name);
    return trace_path;
}

int main(int argc, char** argv)
{
    /* Seed random for election timeout jitter */
    srand(42);

    printf("willemt/raft trace harness\n\n");

    test_basic_consensus(make_trace_path("basic_consensus.ndjson"));
    test_leader_reelection(make_trace_path("leader_reelection.ndjson"));

    printf("All tests completed.\n");
    return 0;
}
