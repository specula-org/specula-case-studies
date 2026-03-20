/**
 * Bug reproduction tests for willemt/raft.
 *
 * Bugs #33–#38 from Specula bug tracker.
 *
 * Build:
 *   cd artifact/raft && make static
 *   gcc -Iartifact/raft/include -Iartifact/raft/CLinkedListQueue \
 *       -o repro/test_bugs repro/test_bugs.c artifact/raft/libraft.a \
 *       -lgcov
 *
 * Run:
 *   ./repro/test_bugs
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <signal.h>
#include <setjmp.h>

#include "raft.h"
#include "raft_log.h"
#include "raft_private.h"

/* ===================================================================
 * Shared test infrastructure
 * =================================================================== */

static int pass_count = 0;
static int fail_count = 0;

#define TEST_START(name) \
    printf("  [TEST] %-60s ", name); fflush(stdout)
#define TEST_PASS() \
    do { printf("PASS\n"); pass_count++; } while(0)
#define TEST_FAIL(msg) \
    do { printf("FAIL: %s\n", msg); fail_count++; } while(0)

/* Minimal callbacks */
static int cb_persist_term(raft_server_t* r, void* ud, raft_term_t t, int v) { return 0; }
static int cb_persist_vote(raft_server_t* r, void* ud, int v) { return 0; }
static int cb_send_rv(raft_server_t* r, void* ud, raft_node_t* n, msg_requestvote_t* m) { return 0; }
static int cb_send_ae(raft_server_t* r, void* ud, raft_node_t* n, msg_appendentries_t* m) { return 0; }
static int cb_log_offer(raft_server_t* r, void* ud, raft_entry_t* e, raft_index_t i) { return 0; }

static raft_cbs_t basic_cbs = {
    .persist_term = cb_persist_term,
    .persist_vote = cb_persist_vote,
    .send_requestvote = cb_send_rv,
    .send_appendentries = cb_send_ae,
    .log_offer = cb_log_offer,
};

/* Helper: create a 3-node cluster and return the leader (servers[0]) */
static void make_leader(raft_server_t** servers, int n)
{
    for (int i = 0; i < n; i++) {
        servers[i] = raft_new();
        raft_set_callbacks(servers[i], &basic_cbs, NULL);
        for (int j = 0; j < n; j++)
            raft_add_node(servers[i], NULL, j + 1, i == j);
        raft_set_election_timeout(servers[i], 500);
    }

    /* Force s1 to become leader */
    raft_periodic(servers[0], 1000); /* triggers election */
    /* Grant votes from s2 and s3 */
    for (int i = 1; i < n; i++) {
        raft_node_t* node = raft_get_node(servers[0], i + 1);
        msg_requestvote_response_t resp = {
            .term = raft_get_current_term(servers[0]),
            .vote_granted = 1
        };
        raft_recv_requestvote_response(servers[0], node, &resp);
    }
    assert(raft_is_leader(servers[0]));
}

static void free_servers(raft_server_t** servers, int n)
{
    for (int i = 0; i < n; i++)
        if (servers[i]) raft_free(servers[i]);
}

/* ===================================================================
 * Bug #33: send_appendentries_all stops on first error
 *
 * raft_server.c:970-987
 * If sending to one node returns RAFT_ERR_NEEDS_SNAPSHOT, the
 * function aborts without sending to remaining nodes. One lagging
 * node starves the entire cluster of heartbeats.
 *
 * Trigger: leader has snapshot, one peer's next_idx < snapshot_last_idx,
 *          call send_appendentries_all → second peer never gets AE.
 * =================================================================== */

static int ae_send_count;
static int ae_dest_ids[16];

static int cb_send_ae_tracking(raft_server_t* r, void* ud,
                               raft_node_t* n, msg_appendentries_t* m)
{
    ae_dest_ids[ae_send_count++] = raft_node_get_id(n);
    return 0;
}

static int cb_send_snapshot_noop(raft_server_t* r, void* ud, raft_node_t* n)
{
    return 0;
}

static void test_bug33_send_ae_all_early_return(void)
{
    TEST_START("Bug #33: send_appendentries_all early return on error");

    raft_server_t* servers[3];
    make_leader(servers, 3);
    raft_server_t* leader = servers[0];

    /* Install snapshot callback so NEEDS_SNAPSHOT path is taken */
    raft_cbs_t cbs = basic_cbs;
    cbs.send_appendentries = cb_send_ae_tracking;
    cbs.send_snapshot = cb_send_snapshot_noop;
    raft_set_callbacks(leader, &cbs, NULL);

    /* Simulate leader having a snapshot at index 5 */
    raft_server_private_t* me = (raft_server_private_t*)leader;
    me->snapshot_last_idx = 5;
    me->snapshot_last_term = 1;

    /* Append some entries to the leader so it has content past snapshot */
    for (int i = 0; i < 3; i++) {
        msg_entry_t entry = { .id = i + 1, .type = RAFT_LOGTYPE_NORMAL };
        msg_entry_response_t resp;
        raft_recv_entry(leader, &entry, &resp);
    }

    /* Set node 2's next_idx to 1 (way behind, needs snapshot) */
    raft_node_t* node2 = raft_get_node(leader, 2);
    raft_node_set_next_idx(node2, 1);

    /* Node 3's next_idx is current (up to date) */
    raft_node_t* node3 = raft_get_node(leader, 3);
    raft_node_set_next_idx(node3, raft_get_current_idx(leader) + 1);

    /* Now call send_appendentries_all */
    ae_send_count = 0;
    memset(ae_dest_ids, 0, sizeof(ae_dest_ids));

    int e = raft_send_appendentries_all(leader);

    /*
     * BUG: send_appendentries_all returns RAFT_ERR_NEEDS_SNAPSHOT after
     * trying node 2, and never sends AE to node 3.
     *
     * Expected: both nodes should be attempted. Node 2 gets snapshot,
     * node 3 gets normal AE.
     * Actual: only node 2 is attempted, function returns error.
     */
    if (e == RAFT_ERR_NEEDS_SNAPSHOT && ae_send_count == 0) {
        /* Bug confirmed: node 3 was starved because node 2's error
         * caused early return. ae_send_count==0 because the snapshot
         * path doesn't call send_appendentries callback. */
        TEST_PASS();
    } else {
        TEST_FAIL("Expected early return with NEEDS_SNAPSHOT");
    }

    free_servers(servers, 3);
}

/* ===================================================================
 * Bug #34: AE response current_idx out-of-bounds → NULL deref
 *
 * raft_server.c:366,375-376
 * The assert at line 366 is compiled out in release. If a follower
 * sends current_idx > leader's log length, raft_get_entry_from_idx
 * returns NULL, and ety->term dereferences NULL.
 *
 * Trigger: leader with 1 entry receives AE response with current_idx=999.
 * =================================================================== */

static jmp_buf segfault_jmp;
static volatile int caught_segfault = 0;

static void crash_handler(int sig)
{
    caught_segfault = sig;
    longjmp(segfault_jmp, 1);
}

static void test_bug34_ae_response_null_deref(void)
{
    TEST_START("Bug #34: AE response current_idx → NULL deref");

    raft_server_t* servers[3];
    make_leader(servers, 3);
    raft_server_t* leader = servers[0];

    /* Add one entry to leader's log */
    msg_entry_t entry = { .id = 1, .type = RAFT_LOGTYPE_NORMAL };
    msg_entry_response_t eresp;
    raft_recv_entry(leader, &entry, &eresp);
    /* Leader log: index 1, current_idx = 1 */

    /* Fabricate an AE response with current_idx far beyond leader's log */
    msg_appendentries_response_t resp = {
        .term = raft_get_current_term(leader),
        .success = 1,
        .current_idx = 999,  /* way beyond leader's log length of 1 */
        .first_idx = 1
    };

    raft_node_t* node2 = raft_get_node(leader, 2);

    /* Install signal handlers to catch the crash.
     * Debug build: assert fires → SIGABRT.
     * Release build: NULL deref → SIGSEGV. */
    struct sigaction sa, old_segv, old_abrt;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crash_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGABRT, &sa, &old_abrt);

    caught_segfault = 0;
    if (setjmp(segfault_jmp) == 0) {
        raft_recv_appendentries_response(leader, node2, &resp);
        TEST_FAIL("Expected crash from out-of-bounds current_idx");
    } else {
        /* Caught crash — bug confirmed.
         * SIGABRT (6) = assert in debug build,
         * SIGSEGV (11) = NULL deref in release build. */
        TEST_PASS();
    }

    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGABRT, &old_abrt, NULL);

    /* Cannot safely free after SIGSEGV — skip cleanup */
}

/* ===================================================================
 * Bug #35: apply_entry ADD_NODE node=NULL → crash
 *
 * raft_server.c:877-879
 * When applying RAFT_LOGTYPE_ADD_NODE, the code dereferences `node`
 * without NULL check. The DEMOTE and REMOVE cases DO check for NULL.
 *
 * Trigger: append ADD_NODE entry for a node_id that doesn't exist in
 *          the cluster, commit it, then apply.
 * =================================================================== */

static int cb_log_get_node_id(raft_server_t* r, void* ud,
                               raft_entry_t* entry, raft_index_t idx)
{
    /* Return the node ID embedded in the entry data */
    return entry->data.buf ? atoi(entry->data.buf) : 0;
}

static void test_bug35_apply_add_node_null(void)
{
    TEST_START("Bug #35: apply_entry ADD_NODE with NULL node → crash");

    raft_server_t* r = raft_new();

    /* Use minimal callbacks WITHOUT log_offer. In the current codebase,
     * log_append_entry calls raft_offer_log (which pre-adds nodes) when
     * log_offer is set. By omitting it, the node won't be pre-added,
     * simulating a scenario where the node was removed between offer and apply.
     *
     * The bug is: ADD_NODE case doesn't check for NULL node, while
     * DEMOTE_NODE (line 889) and REMOVE_NODE (line 893) both do. */
    raft_cbs_t cbs = {
        .persist_term = cb_persist_term,
        .persist_vote = cb_persist_vote,
        .log_get_node_id = cb_log_get_node_id,
    };
    raft_set_callbacks(r, &cbs, NULL);
    raft_add_node(r, NULL, 1, 1);
    raft_add_node(r, NULL, 2, 0);
    raft_add_node(r, NULL, 3, 0);
    raft_set_current_term(r, 1);

    /* Append ADD_NODE for node_id=99 (doesn't exist in cluster) */
    char node_id_str[] = "99";
    raft_entry_t entry = {
        .term = 1,
        .id = 1,
        .type = RAFT_LOGTYPE_ADD_NODE,
        .data = { .buf = node_id_str, .len = strlen(node_id_str) + 1 }
    };
    int e = raft_append_entry(r, &entry);
    assert(e == 0);
    assert(raft_get_node(r, 99) == NULL);  /* node 99 NOT pre-added */

    /* Set commit_idx to make the entry applyable */
    raft_server_private_t* me = (raft_server_private_t*)r;
    me->commit_idx = 1;

    struct sigaction sa, old_segv, old_abrt;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crash_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGABRT, &sa, &old_abrt);

    caught_segfault = 0;
    if (setjmp(segfault_jmp) == 0) {
        int apply_ret = raft_apply_entry(r);
        /*
         * BUG: raft_get_node(r, 99) returns NULL because node 99
         * doesn't exist. Line 878 calls
         * raft_node_set_addition_committed(NULL, 1) → SEGFAULT.
         *
         * DEMOTE_NODE and REMOVE_NODE check `if (node)` first.
         * ADD_NODE does not — inconsistent null safety.
         */
        if (apply_ret == 0) {
            TEST_FAIL("Expected crash but apply_entry returned 0");
        } else {
            char msg[128];
            snprintf(msg, sizeof(msg), "apply_entry returned %d", apply_ret);
            TEST_FAIL(msg);
        }
    } else {
        TEST_PASS();
    }

    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGABRT, &old_abrt, NULL);
}

/* ===================================================================
 * Bug #36: log_clear_entries off-by-one → ghost slot
 *
 * raft_log.c:134
 * Loop condition `i <= me->base + me->count` iterates count+1 times,
 * calling the log_clear callback on an out-of-bounds (uninitialized) slot.
 *
 * Trigger: add N entries, call log_clear_entries, count callbacks.
 * =================================================================== */

static int clear_callback_count;
static int clear_callback_indices[64];

static int cb_log_clear_tracking(raft_server_t* r, void* ud,
                                  raft_entry_t* entry, raft_index_t idx)
{
    if (clear_callback_count < 64)
        clear_callback_indices[clear_callback_count] = (int)idx;
    clear_callback_count++;
    return 0;
}

static void test_bug36_log_clear_off_by_one(void)
{
    TEST_START("Bug #36: log_clear_entries off-by-one (count+1 callbacks)");

    raft_server_t* r = raft_new();
    raft_cbs_t cbs = basic_cbs;
    cbs.log_clear = cb_log_clear_tracking;
    raft_set_callbacks(r, &cbs, NULL);
    raft_add_node(r, NULL, 1, 1);

    /* Append exactly 3 entries via the log API */
    raft_entry_t entries[3];
    for (int i = 0; i < 3; i++) {
        memset(&entries[i], 0, sizeof(raft_entry_t));
        entries[i].term = 1;
        entries[i].id = i + 1;
        entries[i].type = RAFT_LOGTYPE_NORMAL;
    }

    /* Use raft_append_entry to add entries */
    for (int i = 0; i < 3; i++) {
        int e = raft_append_entry(r, &entries[i]);
        assert(e == 0);
    }

    clear_callback_count = 0;

    /* Trigger log_clear_entries through raft_begin_load_snapshot.
     * Precondition: last_included_index >= raft_get_current_idx.
     * With 3 entries appended, current_idx = 3. Use index 10. */
    int e = raft_begin_load_snapshot(r, 1 /* term */, 10 /* index */);
    assert(e == 0);

    /*
     * BUG: log_clear_entries loop is `i <= base + count` instead of
     * `i < base + count`. With 3 entries (base=0, count=3), the loop
     * runs for i=0,1,2,3 → 4 callbacks instead of 3.
     *
     * The 4th callback receives an entry from slot [(front + 3) % size]
     * which is beyond the valid entries — a "ghost" slot with garbage data.
     */
    if (clear_callback_count == 4) {
        /* Off-by-one confirmed: 4 callbacks for 3 entries */
        TEST_PASS();
    } else if (clear_callback_count == 3) {
        TEST_FAIL("Bug not triggered: got exactly 3 callbacks (expected 4)");
    } else {
        char msg[128];
        snprintf(msg, sizeof(msg), "Unexpected callback count: %d", clear_callback_count);
        TEST_FAIL(msg);
    }

    raft_end_load_snapshot(r);
    raft_free(r);
}

/* ===================================================================
 * Bug #37: log_free skips log_clear callback → memory leak
 *
 * raft_log.c:298-304
 * log_free() directly frees entries array and struct without calling
 * log_clear_entries first. User-allocated entry data is leaked.
 *
 * Trigger: add entries with malloc'd data, call raft_free, check if
 *          log_clear callback was invoked.
 * =================================================================== */

static int free_clear_callback_count;

static int cb_log_clear_counting(raft_server_t* r, void* ud,
                                  raft_entry_t* entry, raft_index_t idx)
{
    free_clear_callback_count++;
    return 0;
}

static void test_bug37_log_free_no_clear(void)
{
    TEST_START("Bug #37: log_free skips log_clear callback → leak");

    raft_server_t* r = raft_new();
    raft_cbs_t cbs = basic_cbs;
    cbs.log_clear = cb_log_clear_counting;
    raft_set_callbacks(r, &cbs, NULL);
    raft_add_node(r, NULL, 1, 1);

    /* Append 5 entries */
    for (int i = 0; i < 5; i++) {
        raft_entry_t entry = {
            .term = 1,
            .id = i + 1,
            .type = RAFT_LOGTYPE_NORMAL
        };
        int e = raft_append_entry(r, &entry);
        assert(e == 0);
    }

    /* Now free the server (which calls log_free) */
    free_clear_callback_count = 0;
    raft_free(r);

    /*
     * BUG: log_free (raft_log.c:298-304) directly calls:
     *   __raft_free(me->entries);
     *   __raft_free(me);
     * WITHOUT calling log_clear_entries() first.
     *
     * Compare with log_load_from_snapshot (line 80-86) which DOES call
     * log_clear_entries before clearing.
     *
     * Expected: log_clear callback should be invoked for all 5 entries.
     * Actual: callback is never invoked. Any user-allocated entry data leaks.
     */
    if (free_clear_callback_count == 0) {
        /* Bug confirmed: log_clear was never called during raft_free */
        TEST_PASS();
    } else {
        char msg[128];
        snprintf(msg, sizeof(msg), "Unexpected: log_clear called %d times", free_clear_callback_count);
        TEST_FAIL(msg);
    }
}

/* ===================================================================
 * Bug #38: voting_cfg_change_log_idx stuck after leader stepdown
 *
 * raft_server.c:833, 221-229, 867-868
 *
 * Two sub-bugs:
 * (a) raft_append_entry sets voting_cfg_change_log_idx = current_idx
 *     BEFORE the entry is appended (off-by-one for follower path).
 * (b) raft_become_follower does NOT clear voting_cfg_change_log_idx.
 *
 * Combined: a follower receives a voting config change via AE. The
 * index is recorded wrong (off-by-one). When the entry is applied,
 * log_idx != voting_cfg_change_log_idx, so the flag never clears.
 * The follower permanently blocks further config changes.
 *
 * Trigger: follower receives AE with ADD_NODE entry, applies it,
 *          then check if voting_cfg_change_log_idx was cleared.
 * =================================================================== */

static int cb_log_get_node_id_38(raft_server_t* r, void* ud,
                                  raft_entry_t* entry, raft_index_t idx)
{
    return entry->data.buf ? atoi(entry->data.buf) : 0;
}

static void test_bug38_voting_cfg_change_stuck(void)
{
    TEST_START("Bug #38: voting_cfg_change_log_idx stuck on follower");

    raft_server_t* r = raft_new();
    raft_cbs_t cbs = basic_cbs;
    cbs.log_get_node_id = cb_log_get_node_id_38;
    raft_set_callbacks(r, &cbs, NULL);

    /* Setup 3-node cluster: this server is node 1 (follower) */
    raft_add_node(r, NULL, 1, 1);
    raft_add_node(r, NULL, 2, 0);
    raft_add_node(r, NULL, 3, 0);

    /* Server is a follower with term 1 */
    raft_set_current_term(r, 1);

    /* Add a non-voting node 4 first (so ADD_NODE for 4 is valid) */
    raft_add_non_voting_node(r, NULL, 4, 0);

    /* Receive AE from leader (node 2) containing a voting config change.
     * The AE has one entry: ADD_NODE for node 4. */
    char node_id_str[] = "4";
    raft_entry_t ae_entry = {
        .term = 1,
        .id = 1,
        .type = RAFT_LOGTYPE_ADD_NODE,
        .data = { .buf = node_id_str, .len = strlen(node_id_str) + 1 }
    };

    msg_appendentries_t ae = {
        .term = 1,
        .prev_log_idx = 0,
        .prev_log_term = 0,
        .leader_commit = 1,  /* leader has committed this entry */
        .n_entries = 1,
        .entries = &ae_entry
    };

    msg_appendentries_response_t ae_resp;
    memset(&ae_resp, 0, sizeof(ae_resp));

    raft_node_t* leader_node = raft_get_node(r, 2);
    int e = raft_recv_appendentries(r, leader_node, &ae, &ae_resp);
    assert(e == 0);
    assert(ae_resp.success == 1);

    /* The entry is at log index 1, committed (leader_commit=1).
     * Check what voting_cfg_change_log_idx was set to. */
    raft_server_private_t* me = (raft_server_private_t*)r;

    int recorded_idx = (int)me->voting_cfg_change_log_idx;

    /* The entry is at index 1, but raft_append_entry recorded
     * raft_get_current_idx BEFORE the append, so it recorded index 0.
     * This is the off-by-one: should be 1, but is 0. */

    /* Now apply the entry (commit_idx should be 1 from leader_commit) */
    e = raft_apply_entry(r);

    /*
     * BUG: raft_apply_entry checks `log_idx == me->voting_cfg_change_log_idx`.
     * log_idx = last_applied_idx + 1 = 1.
     * But voting_cfg_change_log_idx was set to 0 (off-by-one in raft_append_entry).
     * So the check fails, and voting_cfg_change_log_idx is NEVER cleared.
     *
     * Consequence: raft_voting_change_is_in_progress() returns true forever,
     * blocking all future membership changes with RAFT_ERR_ONE_VOTING_CHANGE_ONLY.
     */
    int still_in_progress = raft_voting_change_is_in_progress(r);

    if (recorded_idx == 0 && still_in_progress) {
        /* Off-by-one confirmed: index recorded as 0 instead of 1,
         * and voting change flag is permanently stuck */

        /* Verify consequence: try to submit another config change → blocked */
        /* First, add another non-voting node to have a target */
        raft_add_non_voting_node(r, NULL, 5, 0);

        /* Make this server a leader so it can accept recv_entry */
        /* Actually, let's just check raft_voting_change_is_in_progress */
        if (me->voting_cfg_change_log_idx != -1) {
            TEST_PASS();
        } else {
            TEST_FAIL("voting_cfg_change_log_idx was cleared (bug fixed?)");
        }
    } else if (recorded_idx == 1 && !still_in_progress) {
        TEST_FAIL("Bug not triggered: index correctly recorded as 1");
    } else {
        char msg[128];
        snprintf(msg, sizeof(msg), "Unexpected: recorded_idx=%d, in_progress=%d",
                 recorded_idx, still_in_progress);
        TEST_FAIL(msg);
    }

    raft_free(r);
}

/* ===================================================================
 * Bug #38 (part b): Leader stepdown doesn't clear voting_cfg_change_log_idx
 *
 * Trigger: leader starts config change, steps down, flag stays set.
 * =================================================================== */

static void test_bug38b_leader_stepdown_stuck(void)
{
    TEST_START("Bug #38b: leader stepdown doesn't clear voting change flag");

    raft_server_t* servers[3];
    make_leader(servers, 3);
    raft_server_t* leader = servers[0];

    raft_cbs_t cbs = basic_cbs;
    cbs.log_get_node_id = cb_log_get_node_id_38;
    raft_set_callbacks(leader, &cbs, NULL);

    /* Add a non-voting node 4 */
    raft_add_non_voting_node(leader, NULL, 4, 0);

    /* Submit ADD_NODE for node 4 (a voting config change) */
    char node_id_str[] = "4";
    msg_entry_t entry = {
        .id = 1,
        .type = RAFT_LOGTYPE_ADD_NODE,
        .data = { .buf = node_id_str, .len = strlen(node_id_str) + 1 }
    };
    msg_entry_response_t eresp;
    int e = raft_recv_entry(leader, &entry, &eresp);
    assert(e == 0);

    /* Verify the flag is set */
    assert(raft_voting_change_is_in_progress(leader));

    /* Now force leader to step down by receiving a higher term */
    msg_appendentries_t ae = {
        .term = raft_get_current_term(leader) + 1,
        .prev_log_idx = 0,
        .prev_log_term = 0,
        .leader_commit = 0,
        .n_entries = 0,
        .entries = NULL
    };
    msg_appendentries_response_t ae_resp;
    memset(&ae_resp, 0, sizeof(ae_resp));

    raft_node_t* node2 = raft_get_node(leader, 2);
    raft_recv_appendentries(leader, node2, &ae, &ae_resp);

    /* Leader should now be a follower */
    assert(!raft_is_leader(leader));

    /*
     * BUG: raft_become_follower() (raft_server.c:221-229) does NOT
     * clear voting_cfg_change_log_idx. The flag remains set, permanently
     * blocking any future config changes on this server.
     */
    int still_stuck = raft_voting_change_is_in_progress(leader);
    if (still_stuck) {
        TEST_PASS();
    } else {
        TEST_FAIL("voting_cfg_change_log_idx was cleared on stepdown (bug fixed?)");
    }

    free_servers(servers, 3);
}

/* ===================================================================
 * Main
 * =================================================================== */

int main(void)
{
    printf("=== willemt/raft Bug Reproduction Tests ===\n\n");

    printf("[Bug #33] send_appendentries_all early return (Issue #79)\n");
    test_bug33_send_ae_all_early_return();

    printf("\n[Bug #35] apply_entry ADD_NODE NULL crash\n");
    test_bug35_apply_add_node_null();

    printf("\n[Bug #36] log_clear_entries off-by-one\n");
    test_bug36_log_clear_off_by_one();

    printf("\n[Bug #37] log_free skips log_clear callback\n");
    test_bug37_log_free_no_clear();

    printf("\n[Bug #38] voting_cfg_change_log_idx stuck\n");
    test_bug38_voting_cfg_change_stuck();
    test_bug38b_leader_stepdown_stuck();

    /* Run crash tests last since longjmp from signal handlers is risky */
    printf("\n[Bug #34] AE response current_idx NULL deref\n");
    test_bug34_ae_response_null_deref();

    printf("\n=== Results: %d passed, %d failed ===\n",
           pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
