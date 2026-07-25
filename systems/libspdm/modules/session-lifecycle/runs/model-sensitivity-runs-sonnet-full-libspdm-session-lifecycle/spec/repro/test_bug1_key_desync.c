/*
 * Reproduction test for MC-BUG-1: Key Generation Desynchronization via Backup Decode Path.
 *
 * HYPOTHESIS (TLA model claim):
 *   After a backup-decode event fires during a KEY_UPDATE flow, the responder's
 *   effective RX key generation counter advances past the requester's TX key
 *   generation, causing permanent AEAD decryption failure.
 *
 * ESCALATION LADDER:
 *   Level 0 -- Normal key_update via high-level API; verify heartbeat succeeds after.
 *   Level 1 -- N/A: no race window; the code path is deterministic.
 *   Level 2 -- State injection: directly call activate(false)+create_update on the
 *              responder secured-message context while a key update is in progress,
 *              then verify key material remains synchronized with the requester.
 *   Level 3 -- N/A: escalation ended at Level 2 with definitive result.
 *
 * BUILD (from repo root):
 *   ARTDIR=/home/ubuntu/Specula/experiments/model-sensitivity/runs/sonnet/full/libspdm-session-lifecycle/artifact/libspdm
 *   BUILDDIR=$ARTDIR/build_tla
 *   cc -g -o test_bug1_key_desync \
 *       -I$ARTDIR/include \
 *       -I$ARTDIR/unit_test \
 *       -I$ARTDIR/unit_test/test_spdm_tla_trace \
 *       test_bug1_key_desync.c \
 *       $ARTDIR/unit_test/spdm_unit_test_common/algo.c \
 *       $ARTDIR/unit_test/spdm_unit_test_common/support.c \
 *       -Wl,--start-group \
 *       $BUILDDIR/lib/libmemlib.a \
 *       $BUILDDIR/lib/libdebuglib.a \
 *       $BUILDDIR/lib/libspdm_responder_lib.a \
 *       $BUILDDIR/lib/libspdm_requester_lib.a \
 *       $BUILDDIR/lib/libspdm_common_lib.a \
 *       $BUILDDIR/lib/librnglib.a \
 *       $BUILDDIR/lib/libcryptlib_openssl.a \
 *       $BUILDDIR/lib/libmalloclib.a \
 *       $BUILDDIR/lib/libspdm_crypt_lib.a \
 *       $BUILDDIR/lib/libspdm_crypt_ext_lib.a \
 *       $BUILDDIR/lib/libspdm_secured_message_lib.a \
 *       $BUILDDIR/lib/libspdm_device_secret_lib_sample.a \
 *       $BUILDDIR/lib/libspdm_cert_verify_callback_sample.a \
 *       $BUILDDIR/lib/libspdm_transport_test_lib.a \
 *       $BUILDDIR/lib/libplatform_lib.a \
 *       -Wl,--end-group \
 *       -lssl -lcrypto -lm
 */

#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_secured_message_lib.h"
#include "library/spdm_responder_lib.h"
#include "library/spdm_requester_lib.h"
#include "library/spdm_transport_test_lib.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

/* Provided by algo.c */
extern uint32_t m_libspdm_use_hash_algo;
extern uint32_t m_libspdm_use_aead_algo;
extern uint32_t m_libspdm_use_asym_algo;
extern uint32_t m_libspdm_use_dhe_algo;

#ifndef LIBSPDM_SENDER_BUFFER_SIZE
#define LIBSPDM_SENDER_BUFFER_SIZE (0x1100 + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE)
#endif
#ifndef LIBSPDM_RECEIVER_BUFFER_SIZE
#define LIBSPDM_RECEIVER_BUFFER_SIZE (0x1100 + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE)
#endif
#if (LIBSPDM_SENDER_BUFFER_SIZE > LIBSPDM_RECEIVER_BUFFER_SIZE)
#define LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE LIBSPDM_SENDER_BUFFER_SIZE
#else
#define LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE LIBSPDM_RECEIVER_BUFFER_SIZE
#endif
#ifndef LIBSPDM_MAX_SPDM_MSG_SIZE
#define LIBSPDM_MAX_SPDM_MSG_SIZE 0x1200
#endif

static void *g_rsp_ctx;
static uint8_t g_rsp_response_buf[LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE];
static size_t  g_rsp_response_size;
static void   *g_rsp_response_ptr;

static uint8_t g_req_sender_buf  [LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE];
static uint8_t g_req_receiver_buf[LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE];

static libspdm_return_t req_acquire_sender(void *ctx, void **buf) {
    memset(g_req_sender_buf, 0, sizeof(g_req_sender_buf));
    *buf = g_req_sender_buf; return LIBSPDM_STATUS_SUCCESS;
}
static void req_release_sender(void *ctx, const void *buf) {}
static libspdm_return_t req_acquire_receiver(void *ctx, void **buf) {
    memset(g_req_receiver_buf, 0, sizeof(g_req_receiver_buf));
    *buf = g_req_receiver_buf; return LIBSPDM_STATUS_SUCCESS;
}
static void req_release_receiver(void *ctx, const void *buf) {}

static libspdm_return_t rsp_acquire_sender(void *ctx, void **buf) { return LIBSPDM_STATUS_ACQUIRE_FAIL; }
static void rsp_release_sender(void *ctx, const void *buf) {}
static libspdm_return_t rsp_acquire_receiver(void *ctx, void **buf) { return LIBSPDM_STATUS_ACQUIRE_FAIL; }
static void rsp_release_receiver(void *ctx, const void *buf) {}

static libspdm_return_t req_send_message(void *ctx, size_t size, const void *msg, uint64_t timeout)
{
    static uint8_t rsp_req_buf[LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE];
    memcpy(rsp_req_buf, msg, size);
    uint32_t *session_id = NULL;
    bool is_app = false;
    libspdm_return_t status = libspdm_process_request(g_rsp_ctx, &session_id, &is_app, size, rsp_req_buf);
    if (LIBSPDM_STATUS_IS_ERROR(status)) { fprintf(stderr, "process_request: 0x%x\n", (unsigned)status); return LIBSPDM_STATUS_SEND_FAIL; }
    g_rsp_response_size = sizeof(g_rsp_response_buf);
    g_rsp_response_ptr  = g_rsp_response_buf;
    status = libspdm_build_response(g_rsp_ctx, session_id, is_app, &g_rsp_response_size, &g_rsp_response_ptr);
    if (LIBSPDM_STATUS_IS_ERROR(status)) { fprintf(stderr, "build_response: 0x%x\n", (unsigned)status); return LIBSPDM_STATUS_SEND_FAIL; }
    if (g_rsp_response_ptr != (void *)g_rsp_response_buf) { memmove(g_rsp_response_buf, g_rsp_response_ptr, g_rsp_response_size); g_rsp_response_ptr = g_rsp_response_buf; }
    return LIBSPDM_STATUS_SUCCESS;
}
static libspdm_return_t req_receive_message(void *ctx, size_t *size, void **buf, uint64_t timeout) {
    if (g_rsp_response_size == 0) return LIBSPDM_STATUS_RECEIVE_FAIL;
    memcpy(*buf, g_rsp_response_ptr, g_rsp_response_size);
    *size = g_rsp_response_size;
    return LIBSPDM_STATUS_SUCCESS;
}

typedef struct { void *ctx; void *scratch; } spdm_ctx_t;

static spdm_ctx_t make_req_ctx(void) {
    spdm_ctx_t c;
    c.ctx = malloc(libspdm_get_context_size()); assert(c.ctx);
    libspdm_init_context(c.ctx);
    libspdm_register_device_io_func(c.ctx, req_send_message, req_receive_message);
    libspdm_register_transport_layer_func(c.ctx, LIBSPDM_MAX_SPDM_MSG_SIZE, LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE, libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_buffer_func(c.ctx, LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE, LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE, req_acquire_sender, req_release_sender, req_acquire_receiver, req_release_receiver);
    size_t ssz = libspdm_get_sizeof_required_scratch_buffer(c.ctx);
    c.scratch  = malloc(ssz); assert(c.scratch);
    libspdm_set_scratch_buffer(c.ctx, c.scratch, ssz);
    libspdm_context_t *x = c.ctx;
    x->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    x->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    x->connection_info.capability.flags |= SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_UPD_CAP | SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP | SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP | SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_HBEAT_CAP;
    x->local_context.capability.flags   |= SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_UPD_CAP  | SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP  | SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP  | SPDM_GET_CAPABILITIES_REQUEST_FLAGS_HBEAT_CAP;
    x->connection_info.algorithm.base_hash_algo    = m_libspdm_use_hash_algo;
    x->connection_info.algorithm.base_asym_algo    = m_libspdm_use_asym_algo;
    x->connection_info.algorithm.dhe_named_group   = m_libspdm_use_dhe_algo;
    x->connection_info.algorithm.aead_cipher_suite = m_libspdm_use_aead_algo;
    return c;
}

static spdm_ctx_t make_rsp_ctx(void) {
    spdm_ctx_t c;
    c.ctx = malloc(libspdm_get_context_size()); assert(c.ctx);
    libspdm_init_context(c.ctx);
    libspdm_register_transport_layer_func(c.ctx, LIBSPDM_MAX_SPDM_MSG_SIZE, LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE, libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_buffer_func(c.ctx, LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE, LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE, rsp_acquire_sender, rsp_release_sender, rsp_acquire_receiver, rsp_release_receiver);
    size_t ssz = libspdm_get_sizeof_required_scratch_buffer(c.ctx);
    c.scratch  = malloc(ssz); assert(c.scratch);
    libspdm_set_scratch_buffer(c.ctx, c.scratch, ssz);
    libspdm_context_t *x = c.ctx;
    x->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    x->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    x->connection_info.capability.flags |= SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_UPD_CAP | SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP | SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP | SPDM_GET_CAPABILITIES_REQUEST_FLAGS_HBEAT_CAP;
    x->local_context.capability.flags   |= SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_UPD_CAP | SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP | SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP | SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_HBEAT_CAP;
    x->connection_info.algorithm.base_hash_algo    = m_libspdm_use_hash_algo;
    x->connection_info.algorithm.base_asym_algo    = m_libspdm_use_asym_algo;
    x->connection_info.algorithm.dhe_named_group   = m_libspdm_use_dhe_algo;
    x->connection_info.algorithm.aead_cipher_suite = m_libspdm_use_aead_algo;
    return c;
}

static uint32_t setup_session(void *req_ctx, void *rsp_ctx) {
    const uint32_t session_id = 0xFFFFFFFF;
    const spdm_version_number_t ver = (spdm_version_number_t)(SECURED_SPDM_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT);
    libspdm_context_t *rc = req_ctx;
    libspdm_session_info_t *rsi = &rc->session_info[0];
    libspdm_session_info_init(req_ctx, rsi, session_id, ver, true);
    libspdm_secured_message_set_session_state(rsi->secured_message_context, LIBSPDM_SESSION_STATE_ESTABLISHED);
    rsi->heartbeat_period = 1;
    libspdm_context_t *sc = rsp_ctx;
    libspdm_session_info_t *ssi = &sc->session_info[0];
    libspdm_session_info_init(rsp_ctx, ssi, session_id, ver, false);
    libspdm_secured_message_set_session_state(ssi->secured_message_context, LIBSPDM_SESSION_STATE_ESTABLISHED);
    ssi->heartbeat_period = 1;
    libspdm_secured_message_context_t *rmc = rsi->secured_message_context;
    libspdm_secured_message_context_t *smc = ssi->secured_message_context;
    uint8_t req_sec[LIBSPDM_MAX_HASH_SIZE], rsp_sec[LIBSPDM_MAX_HASH_SIZE];
    libspdm_set_mem(req_sec, rmc->hash_size, 0xEE);
    libspdm_set_mem(rsp_sec, rmc->hash_size, 0xFF);
    libspdm_copy_mem(rmc->application_secret.request_data_secret, sizeof(rmc->application_secret.request_data_secret), req_sec, rmc->aead_key_size);
    libspdm_copy_mem(rmc->application_secret.response_data_secret, sizeof(rmc->application_secret.response_data_secret), rsp_sec, rmc->aead_key_size);
    libspdm_set_mem(rmc->application_secret.request_data_encryption_key, rmc->aead_key_size, 0xEE);
    libspdm_set_mem(rmc->application_secret.request_data_salt, rmc->aead_iv_size, 0xEE);
    libspdm_set_mem(rmc->application_secret.response_data_encryption_key, rmc->aead_key_size, 0xFF);
    libspdm_set_mem(rmc->application_secret.response_data_salt, rmc->aead_iv_size, 0xFF);
    rmc->application_secret.request_data_sequence_number = 0;
    rmc->application_secret.response_data_sequence_number = 0;
    libspdm_copy_mem(smc->application_secret.request_data_secret, sizeof(smc->application_secret.request_data_secret), req_sec, smc->aead_key_size);
    libspdm_copy_mem(smc->application_secret.response_data_secret, sizeof(smc->application_secret.response_data_secret), rsp_sec, smc->aead_key_size);
    libspdm_set_mem(smc->application_secret.request_data_encryption_key, smc->aead_key_size, 0xEE);
    libspdm_set_mem(smc->application_secret.request_data_salt, smc->aead_iv_size, 0xEE);
    libspdm_set_mem(smc->application_secret.response_data_encryption_key, smc->aead_key_size, 0xFF);
    libspdm_set_mem(smc->application_secret.response_data_salt, smc->aead_iv_size, 0xFF);
    smc->application_secret.request_data_sequence_number = 0;
    smc->application_secret.response_data_sequence_number = 0;
    return session_id;
}

static void print_bytes(const char *label, const uint8_t *data, size_t len) {
    printf("  %s: ", label);
    for (size_t i = 0; i < (len < 8 ? len : 8); i++) printf("%02x", data[i]);
    printf("...\n");
}

/* ============================================================
 * LEVEL 0: Black-box — normal key_update via high-level API
 * Expected: heartbeat after key_update succeeds if implementation is correct.
 * ============================================================ */
static int level0_normal_key_update(void)
{
    printf("\n=== LEVEL 0: Normal key_update + heartbeat (black-box) ===\n");
    spdm_ctx_t req = make_req_ctx();
    spdm_ctx_t rsp = make_rsp_ctx();
    g_rsp_ctx = rsp.ctx;
    uint32_t sid = setup_session(req.ctx, rsp.ctx);

    libspdm_return_t s = libspdm_key_update(req.ctx, sid, true);
    printf("  key_update(single): 0x%x %s\n", (unsigned)s, LIBSPDM_STATUS_IS_ERROR(s) ? "ERROR" : "OK");
    if (LIBSPDM_STATUS_IS_ERROR(s)) { printf("  FAIL: key_update returned error\n"); free(req.scratch); free(req.ctx); free(rsp.scratch); free(rsp.ctx); return 1; }

    s = libspdm_heartbeat(req.ctx, sid);
    printf("  heartbeat after key_update: 0x%x %s\n", (unsigned)s, LIBSPDM_STATUS_IS_ERROR(s) ? "ERROR" : "OK");
    if (LIBSPDM_STATUS_IS_ERROR(s)) { printf("  FAIL: heartbeat failed after key_update => keys DESYNCHRONIZED\n"); free(req.scratch); free(req.ctx); free(rsp.scratch); free(rsp.ctx); return 1; }

    printf("  PASS: heartbeat succeeded after key_update (no desynchronization)\n");
    free(req.scratch); free(req.ctx);
    free(rsp.scratch); free(rsp.ctx);
    return 0;
}

/* ============================================================
 * LEVEL 2: State injection
 *
 * Directly inject the backup-decode sequence (activate(false) + create_update)
 * on the responder's secured-message context, as rsp_receive_send.c:209-267 does.
 * Then verify:
 *   (a) Responder key material is IDENTICAL before and after injection.
 *   (b) Responder key matches requester key after requester completes key_update.
 * ============================================================ */
static int level2_state_injection(void)
{
    printf("\n=== LEVEL 2: State injection — activate(false)+create_update idempotency ===\n");
    printf("  Claim (TLA model): backup-decode advances rsp_rx_gen, causing mismatch.\n");
    printf("  Test: inject backup-decode into responder secured-msg context, verify key sync.\n");

    spdm_ctx_t req = make_req_ctx();
    spdm_ctx_t rsp = make_rsp_ctx();
    g_rsp_ctx = rsp.ctx;
    uint32_t sid = setup_session(req.ctx, rsp.ctx);

    /* Get secured-message contexts */
    libspdm_context_t *rc = req.ctx;
    libspdm_context_t *sc = rsp.ctx;
    libspdm_session_info_t *rsi = libspdm_get_session_info_via_session_id(req.ctx, sid);
    libspdm_session_info_t *ssi = libspdm_get_session_info_via_session_id(rsp.ctx, sid);
    assert(rsi && ssi);
    libspdm_secured_message_context_t *req_smc = rsi->secured_message_context;
    libspdm_secured_message_context_t *rsp_smc = ssi->secured_message_context;

    /* Step 1: Record gen-0 key material */
    uint8_t key_gen0[LIBSPDM_MAX_HASH_SIZE];
    memcpy(key_gen0, rsp_smc->application_secret.request_data_secret, rsp_smc->hash_size);
    print_bytes("RSP req secret (gen-0)", key_gen0, rsp_smc->hash_size);

    /* Step 2: RspRecvUpdateKey -- create_update(REQUESTER) on responder side */
    bool ok = libspdm_create_update_session_data_key(rsp_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    assert(ok);
    uint8_t key_gen1[LIBSPDM_MAX_HASH_SIZE];
    memcpy(key_gen1, rsp_smc->application_secret.request_data_secret, rsp_smc->hash_size);
    uint8_t key_gen1_enc[LIBSPDM_MAX_AEAD_KEY_SIZE];
    memcpy(key_gen1_enc, rsp_smc->application_secret.request_data_encryption_key, rsp_smc->aead_key_size);
    print_bytes("RSP req secret (gen-1, after 1st create_update)", key_gen1, rsp_smc->hash_size);
    printf("  requester_backup_valid after 1st create_update: %d\n", (int)rsp_smc->requester_backup_valid);

    /* Step 3: DecodeWithBackupKey -- inject backup decode sequence */
    /*   rsp_receive_send.c:210: activate(REQUESTER, false) -- revert to backup */
    ok = libspdm_activate_update_session_data_key(rsp_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, false);
    assert(ok);
    printf("  requester_backup_valid after activate(false): %d (should be 0)\n", (int)rsp_smc->requester_backup_valid);
    uint8_t key_after_rollback[LIBSPDM_MAX_HASH_SIZE];
    memcpy(key_after_rollback, rsp_smc->application_secret.request_data_secret, rsp_smc->hash_size);
    print_bytes("RSP req secret (after rollback -- should be gen-0)", key_after_rollback, rsp_smc->hash_size);
    int rollback_correct = (memcmp(key_after_rollback, key_gen0, rsp_smc->hash_size) == 0);
    printf("  Rollback restores gen-0 key: %s\n", rollback_correct ? "YES" : "NO");

    /*   rsp_receive_send.c:256: create_update(REQUESTER) -- re-derive */
    ok = libspdm_create_update_session_data_key(rsp_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    assert(ok);
    uint8_t key_after_backup_decode[LIBSPDM_MAX_HASH_SIZE];
    memcpy(key_after_backup_decode, rsp_smc->application_secret.request_data_secret, rsp_smc->hash_size);
    uint8_t key_after_backup_dec_enc[LIBSPDM_MAX_AEAD_KEY_SIZE];
    memcpy(key_after_backup_dec_enc, rsp_smc->application_secret.request_data_encryption_key, rsp_smc->aead_key_size);
    print_bytes("RSP req secret (after backup-decode sequence)", key_after_backup_decode, rsp_smc->hash_size);
    printf("  requester_backup_valid after 2nd create_update: %d\n", (int)rsp_smc->requester_backup_valid);

    /* KEY ASSERTION (a): activate(false)+create_update is idempotent on key material */
    int secret_match = (memcmp(key_gen1, key_after_backup_decode, rsp_smc->hash_size) == 0);
    int enc_key_match = (memcmp(key_gen1_enc, key_after_backup_dec_enc, rsp_smc->aead_key_size) == 0);
    printf("\n  [ASSERTION A] Secret after backup-decode == secret after 1st create_update: %s\n",
           secret_match ? "MATCH (no generation advance)" : "MISMATCH (generation advanced - BUG!)");
    printf("  [ASSERTION A] AEAD key after backup-decode == AEAD key after 1st create_update: %s\n",
           enc_key_match ? "MATCH" : "MISMATCH");

    /* Step 4: ReqRecvKeyUpdateAck -- requester derives gen-1 TX key */
    ok = libspdm_create_update_session_data_key(req_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    assert(ok);
    ok = libspdm_activate_update_session_data_key(req_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, true);
    assert(ok);
    uint8_t req_tx_key[LIBSPDM_MAX_HASH_SIZE];
    memcpy(req_tx_key, req_smc->application_secret.request_data_secret, req_smc->hash_size);
    print_bytes("REQ tx secret (gen-1, after create+activate)", req_tx_key, req_smc->hash_size);

    /* KEY ASSERTION (b): responder active key == requester active TX key */
    int sync_match = (memcmp(key_after_backup_decode, req_tx_key, rsp_smc->hash_size) == 0);
    printf("\n  [ASSERTION B] RSP active RX secret == REQ active TX secret: %s\n",
           sync_match ? "MATCH (keys synchronized)" : "MISMATCH (keys DESYNCHRONIZED - BUG!)");

    int passed = secret_match && enc_key_match && sync_match;
    printf("\n  Level 2 result: %s\n", passed ? "PASS (FALSE POSITIVE confirmed)" : "FAIL (real bug)");

    free(req.scratch); free(req.ctx);
    free(rsp.scratch); free(rsp.ctx);
    return passed ? 0 : 1;
}

/* ============================================================
 * LEVEL 2 (counterexample replication): exact TLA trace Steps 2-6
 *
 * Manually drives the protocol through the exact 6-state TLA counterexample:
 *   Step 2: RspRecvUpdateKey   -- responder calls create_update(REQ)
 *   Step 3: DecodeWithBackupKey -- inject backup-decode: activate(false)+create_update
 *   Step 4: ReqRecvKeyUpdateAck -- requester calls create_update(REQ)+activate(true)
 *   Step 5: RspRecvVerifyNewKey -- responder calls activate(true) to commit
 *   Check:  RSP committed key == REQ committed key (KeySynchronization invariant)
 *
 * No VERIFY_NEW_KEY message exchange is needed — the TLA invariant is about
 * key material equality, which we check directly on the secured-message contexts.
 * ============================================================ */
static int level2_counterexample_replication(void)
{
    printf("\n=== LEVEL 2 (counterexample replication): exact TLA trace Steps 2-6 ===\n");
    printf("  Replicating the 6-state TLA counterexample directly.\n");
    printf("  If KeySynchronization were really violated, RSP active key != REQ active key.\n");

    spdm_ctx_t req = make_req_ctx();
    spdm_ctx_t rsp = make_rsp_ctx();
    g_rsp_ctx = rsp.ctx;
    uint32_t sid = setup_session(req.ctx, rsp.ctx);

    libspdm_session_info_t *rsi = libspdm_get_session_info_via_session_id(req.ctx, sid);
    libspdm_session_info_t *ssi = libspdm_get_session_info_via_session_id(rsp.ctx, sid);
    assert(rsi && ssi);
    libspdm_secured_message_context_t *req_smc = rsi->secured_message_context;
    libspdm_secured_message_context_t *rsp_smc = ssi->secured_message_context;

    printf("  Initial state: req_tx=gen-0, rsp_rx=gen-0 (both 0xEE...)\n");

    /* --- TLA Step 2: RspRecvUpdateKey --- */
    /* rsp_key_update_ack.c:127-129: create_update(REQUESTER) */
    bool ok = libspdm_create_update_session_data_key(rsp_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    assert(ok);
    uint8_t rsp_after_step2[LIBSPDM_MAX_HASH_SIZE];
    memcpy(rsp_after_step2, rsp_smc->application_secret.request_data_secret, rsp_smc->hash_size);
    print_bytes("Step 2 RSP active (gen-1 pending)", rsp_after_step2, rsp_smc->hash_size);
    printf("  Step 2: rsp_rx_backup_valid=%d\n", (int)rsp_smc->requester_backup_valid);

    /* --- TLA Step 3: DecodeWithBackupKey --- */
    /* rsp_receive_send.c:210: activate(REQUESTER,false) -- revert to backup */
    ok = libspdm_activate_update_session_data_key(rsp_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, false);
    assert(ok);
    /* rsp_receive_send.c:256: create_update(REQUESTER) -- re-derive */
    ok = libspdm_create_update_session_data_key(rsp_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    assert(ok);
    uint8_t rsp_after_step3[LIBSPDM_MAX_HASH_SIZE];
    memcpy(rsp_after_step3, rsp_smc->application_secret.request_data_secret, rsp_smc->hash_size);
    print_bytes("Step 3 RSP active (after backup-decode)", rsp_after_step3, rsp_smc->hash_size);
    printf("  Step 3: rsp_rx_backup_valid=%d\n", (int)rsp_smc->requester_backup_valid);

    int step2_step3_match = (memcmp(rsp_after_step2, rsp_after_step3, rsp_smc->hash_size) == 0);
    printf("  Step2 == Step3 key: %s  [SPEC ERROR if these differ]\n",
           step2_step3_match ? "MATCH" : "MISMATCH");

    /* --- TLA Step 4: ReqRecvKeyUpdateAck --- */
    /* req_key_update.c:216-228: create_update(REQUESTER)+activate(REQUESTER,true) */
    ok = libspdm_create_update_session_data_key(req_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    assert(ok);
    ok = libspdm_activate_update_session_data_key(req_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, true);
    assert(ok);
    uint8_t req_after_step4[LIBSPDM_MAX_HASH_SIZE];
    memcpy(req_after_step4, req_smc->application_secret.request_data_secret, req_smc->hash_size);
    print_bytes("Step 4 REQ tx key (gen-1 committed)", req_after_step4, req_smc->hash_size);

    /* --- TLA Step 5: RspRecvVerifyNewKey --- */
    /* rsp_key_update_ack.c:216-213: activate(REQUESTER,true) -- commit */
    ok = libspdm_activate_update_session_data_key(rsp_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, true);
    assert(ok);
    uint8_t rsp_after_step5[LIBSPDM_MAX_HASH_SIZE];
    memcpy(rsp_after_step5, rsp_smc->application_secret.request_data_secret, rsp_smc->hash_size);
    print_bytes("Step 5 RSP active RX key (gen-1 committed)", rsp_after_step5, rsp_smc->hash_size);
    printf("  Step 5: rsp_rx_backup_valid=%d (should be 0)\n", (int)rsp_smc->requester_backup_valid);

    /* --- KeySynchronization check --- */
    int sync = (memcmp(rsp_after_step5, req_after_step4, rsp_smc->hash_size) == 0);
    printf("\n  [KeySynchronization check]\n");
    printf("  RSP committed RX key == REQ committed TX key: %s\n",
           sync ? "MATCH (invariant holds)" : "MISMATCH (invariant violated - REAL BUG)");

    int passed = step2_step3_match && sync;
    printf("\n  Level 2 (counterexample replication) result: %s\n",
           passed ? "PASS (FALSE POSITIVE confirmed)" : "FAIL (real bug)");

    free(req.scratch); free(req.ctx);
    free(rsp.scratch); free(rsp.ctx);
    return passed ? 0 : 1;
}

int main(void)
{
    printf("=== MC-BUG-1 Reproduction Test: Key Generation Desynchronization ===\n");
    printf("Claim: backup-decode path during KEY_UPDATE causes permanent key mismatch.\n");

    int r0  = level0_normal_key_update();
    int r2a = level2_state_injection();
    int r2b = level2_counterexample_replication();

    printf("\n=== SUMMARY ===\n");
    printf("  Level 0  (normal key_update + heartbeat):            %s\n", r0  ? "FAIL" : "PASS");
    printf("  Level 2a (activate(false)+create_update idempotency): %s\n", r2a ? "FAIL" : "PASS");
    printf("  Level 2b (exact TLA counterexample replication):      %s\n", r2b ? "FAIL" : "PASS");

    int overall = r0 | r2a | r2b;
    if (overall == 0) {
        printf("\nOVERALL: PASS -- all levels pass, bug NOT reproduced.\n");
        printf("CONCLUSION: MC-BUG-1 is a FALSE POSITIVE.\n");
        printf("  The backup-decode sequence (activate(false)+create_update) is idempotent:\n");
        printf("  activate(false) first restores the key to gen-0 (old_key) and CLEARS the backup,\n");
        printf("  then create_update re-derives gen-1 (KDF(old_key)) -- identical material to before.\n");
        printf("  The TLA model's DecodeWithBackupKey action incorrectly increments rsp_rx_gen\n");
        printf("  without accounting for the preceding activate(false) rollback.\n");
        printf("  Spec repair needed: base.tla:318 rsp_rx_gen should NOT increment.\n");
    } else {
        printf("\nOVERALL: FAIL -- bug reproduced.\n");
    }
    return overall;
}
