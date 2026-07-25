/**
 * test_tla_scenarios.c — TLA+ trace collection test scenarios for libspdm secured messaging.
 *
 * Placed in unit_test/test_spdm_secured_message/ by apply.sh.
 *
 * Covers:
 *  Scenario 1 (normal_encode_decode): encode/decode cycles, session_id fail, aead fail
 *  Scenario 2 (key_update_single):    single-direction key update protocol
 *  Scenario 3 (key_update_all_keys):  all-keys update protocol
 *  Scenario 4 (decode_rollback):      AEAD failure with backup → rollback
 */

#ifdef SPDM_TLA_TRACE_ENABLE

#include "spdm_unit_test.h"
#include "internal/libspdm_secured_message_lib.h"
#include "internal/spdm_tla_trace.h"

#include <stdio.h>
#include <string.h>
#include <assert.h>

/* ------------------------------------------------------------------ */
/* Shared callbacks (same as encode_decode.c)                           */
/* ------------------------------------------------------------------ */

static uint8_t get_sequence_number_tla(uint64_t sequence_number,
                                       uint8_t *sequence_number_buffer)
{
    memcpy(sequence_number_buffer, &sequence_number, 8);
    return 8;
}

static uint32_t get_max_random_count_tla(void) { return 0; }

static spdm_version_number_t get_spdm_version_tla(spdm_version_number_t ver)
{
    (void)ver;
    return SECURED_SPDM_VERSION_11;
}

static libspdm_secured_message_callbacks_t m_tla_callbacks = {
    .version                   = LIBSPDM_SECURED_MESSAGE_CALLBACKS_VERSION,
    .get_secured_spdm_version  = get_spdm_version_tla,
    .get_max_random_number_count = get_max_random_count_tla,
    .get_sequence_number       = get_sequence_number_tla,
};

/* ------------------------------------------------------------------ */
/* Paired secured-message context initializer                           */
/* ------------------------------------------------------------------ */
/* Both the requester SMC and responder SMC are initialised with the
 * same AES-256-GCM key material so AEAD operations actually succeed.
 * libspdm_create_update_session_data_key uses HKDF on request_data_secret /
 * response_data_secret; providing the same secret on both sides means they
 * derive the same updated key.                                          */

static const uint8_t REQ_KEY[32] = {
    0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,
    0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,
    0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,
    0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,0x20 };

static const uint8_t RSP_KEY[32] = {
    0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,
    0x29,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f,0x30,
    0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,
    0x39,0x3a,0x3b,0x3c,0x3d,0x3e,0x3f,0x40 };

static const uint8_t REQ_SALT[12] = {
    0xa1,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xab,0xac };

static const uint8_t RSP_SALT[12] = {
    0xb1,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xbb,0xbc };

static const uint8_t REQ_SECRET[32] = {
    0xc1,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,
    0xc9,0xca,0xcb,0xcc,0xcd,0xce,0xcf,0xd0,
    0xd1,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,
    0xd9,0xda,0xdb,0xdc,0xdd,0xde,0xdf,0xe0 };

static const uint8_t RSP_SECRET[32] = {
    0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,
    0xe9,0xea,0xeb,0xec,0xed,0xee,0xef,0xf0,
    0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,
    0xf9,0xfa,0xfb,0xfc,0xfd,0xfe,0xff,0x00 };

static void init_smc_pair(libspdm_secured_message_context_t *smc,
                          const char *role)
{
    memset(smc, 0, sizeof(*smc));

    smc->secured_message_version = SECURED_SPDM_VERSION_11;
    smc->version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    smc->base_hash_algo   = m_libspdm_use_hash_algo;
    smc->aead_cipher_suite = SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM;
    smc->session_type     = LIBSPDM_SESSION_TYPE_ENC_MAC;
    smc->session_state    = LIBSPDM_SESSION_STATE_ESTABLISHED;
    smc->aead_tag_size    = 16;
    smc->aead_key_size    = 32;
    smc->aead_iv_size     = 12;
    smc->hash_size        = 32;
    smc->max_spdm_session_sequence_number = UINT64_MAX;
    smc->sequence_number_endian = LIBSPDM_DATA_SESSION_SEQ_NUM_ENC_LITTLE_DEC_BOTH;

    memcpy(smc->application_secret.request_data_encryption_key, REQ_KEY, 32);
    memcpy(smc->application_secret.response_data_encryption_key, RSP_KEY, 32);
    memcpy(smc->application_secret.request_data_salt, REQ_SALT, 12);
    memcpy(smc->application_secret.response_data_salt, RSP_SALT, 12);
    memcpy(smc->application_secret.request_data_secret, REQ_SECRET, 32);
    memcpy(smc->application_secret.response_data_secret, RSP_SECRET, 32);

    smc->application_secret.request_data_sequence_number  = 0;
    smc->application_secret.response_data_sequence_number = 0;

    spdm_tla_register_ctx(smc, role);
}

/* ------------------------------------------------------------------ */
/* Helper: do one full encode (sender) → decode (receiver) cycle        */
/* ------------------------------------------------------------------ */

static uint8_t g_secured_buf[0x400];
static uint8_t g_app_recv_buf[0x200];

/* Encode app_message from smc_enc, decode on smc_dec.
 * is_request=1 → request direction (req→rsp).
 * session_id for encode; pass altered_session_id to test session_id fail. */
static libspdm_return_t encode_decode_cycle(
    libspdm_secured_message_context_t *smc_enc,
    libspdm_secured_message_context_t *smc_dec,
    int is_request, uint32_t session_id, uint32_t decode_session_id,
    const uint8_t *app_msg, size_t app_msg_size)
{
    libspdm_return_t status;
    size_t secured_size = sizeof(g_secured_buf);
    size_t recv_size    = sizeof(g_app_recv_buf);
    void  *recv_ptr     = g_app_recv_buf;
    uint8_t app_msg_copy[256];

    /* Encode — libspdm takes non-const app_message */
    memcpy(app_msg_copy, app_msg, app_msg_size);
    status = libspdm_encode_secured_message(
        smc_enc, session_id, (bool)is_request,
        app_msg_size, app_msg_copy,
        &secured_size, g_secured_buf, &m_tla_callbacks);
    if (status != LIBSPDM_STATUS_SUCCESS) return status;

    /* Decode */
    status = libspdm_decode_secured_message(
        smc_dec, decode_session_id, (bool)is_request,
        secured_size, g_secured_buf, &recv_size, &recv_ptr,
        &m_tla_callbacks);
    return status;
}

/* ------------------------------------------------------------------ */
/* Scenario 1: normal_encode_decode                                     */
/* ------------------------------------------------------------------ */

void tla_scenario_normal_encode_decode(const char *trace_path)
{
    libspdm_secured_message_context_t req_smc, rsp_smc;
    const uint32_t SESSION_ID = 0xCAFEBABE;
    static const uint8_t msg[] = {0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08};

    spdm_tla_init(trace_path);
    init_smc_pair(&req_smc, "requester");
    init_smc_pair(&rsp_smc, "responder");

    /* 5 request-direction encode/decode rounds */
    for (int i = 0; i < 5; i++) {
        libspdm_return_t st = encode_decode_cycle(
            &req_smc, &rsp_smc, 1 /* request */, SESSION_ID, SESSION_ID,
            msg, sizeof(msg));
        (void)st; /* encode_advance_seq + encode_success + decode_increment_seq + decode_success */
    }

    /* 5 response-direction encode/decode rounds */
    for (int i = 0; i < 5; i++) {
        libspdm_return_t st = encode_decode_cycle(
            &rsp_smc, &req_smc, 0 /* response */, SESSION_ID, SESSION_ID,
            msg, sizeof(msg));
        (void)st;
    }

    /* Session-id fail: encode a request, then decode with wrong session_id.
     * Seq is already incremented before the session_id check, so
     * decode_increment_seq fires, then decode_session_id_fail fires. */
    {
        libspdm_return_t st = encode_decode_cycle(
            &req_smc, &rsp_smc, 1, SESSION_ID, SESSION_ID ^ 0x1 /* wrong */,
            msg, sizeof(msg));
        (void)st; /* expect LIBSPDM_STATUS_INVALID_MSG_FIELD */
        /* Fix up rsp_smc seq: seq was incremented even on fail (F1 bug family) */
    }

    /* AEAD fail, no backup: use a different key on the decode side.
     * Temporarily corrupt one byte of rsp_smc's req key, decode, then restore. */
    {
        rsp_smc.application_secret.request_data_encryption_key[0] ^= 0xFF;
        libspdm_return_t st = encode_decode_cycle(
            &req_smc, &rsp_smc, 1, SESSION_ID, SESSION_ID,
            msg, sizeof(msg));
        (void)st; /* expect CRYPTO_ERROR -> decode_aead_fail fires */
        rsp_smc.application_secret.request_data_encryption_key[0] ^= 0xFF;
        /* Reset seq since we consumed a slot on both sides */
        rsp_smc.application_secret.request_data_sequence_number =
            req_smc.application_secret.request_data_sequence_number;
    }

    /* Two more clean request rounds after failure recovery */
    for (int i = 0; i < 2; i++) {
        libspdm_return_t st = encode_decode_cycle(
            &req_smc, &rsp_smc, 1, SESSION_ID, SESSION_ID,
            msg, sizeof(msg));
        (void)st;
    }

    spdm_tla_close();
}

/* ------------------------------------------------------------------ */
/* Scenario 2: key_update_single (UPDATE_KEY, one direction)            */
/* ------------------------------------------------------------------ */

void tla_scenario_key_update_single(const char *trace_path)
{
    libspdm_secured_message_context_t req_smc, rsp_smc;
    const uint32_t SESSION_ID = 0xDEADBEEF;
    static const uint8_t msg[] = {0x11,0x22,0x33,0x44};
    bool all_keys = false;

    spdm_tla_init(trace_path);
    init_smc_pair(&req_smc, "requester");
    init_smc_pair(&rsp_smc, "responder");

    /* 3 rounds before key update */
    for (int i = 0; i < 3; i++) {
        encode_decode_cycle(&req_smc, &rsp_smc, 1, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
        encode_decode_cycle(&rsp_smc, &req_smc, 0, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
    }

    /* ----- Key update: UPDATE_KEY (requester direction only) ----- */
    uint64_t req_seq_before = req_smc.application_secret.request_data_sequence_number;

    /* [Event] send_key_update_request */
    spdm_tla_set_phase("PendingAck");
    spdm_tla_emit_send_key_update_request(&req_smc, all_keys, req_seq_before);

    /* Responder side: create new requester key */
    libspdm_create_update_session_data_key(&rsp_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    /* [Event] responder_receive_key_update (msg.epoch = req's old req epoch = 0) */
    spdm_tla_emit_responder_receive_key_update(
        &rsp_smc, all_keys,
        rsp_smc.application_secret.request_data_sequence_number,
        0 /* KEY_UPDATE encrypted with old req key epoch = 0 */);

    /* Requester side: create + activate requester key (immediate commit) */
    libspdm_create_update_session_data_key(&req_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    libspdm_activate_update_session_data_key(&req_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, true);
    /* [Event] requester_receive_key_update_ack */
    spdm_tla_set_phase("PendingVerify");
    spdm_tla_set_committed(true);
    spdm_tla_emit_requester_receive_key_update_ack(
        &req_smc, all_keys,
        req_smc.application_secret.request_data_sequence_number,
        0 /* ack msg epoch */);

    /* Responder side: activate requester key on VERIFY_NEW_KEY */
    libspdm_activate_update_session_data_key(&rsp_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, true);
    /* [Event] responder_receive_verify_new_key */
    spdm_tla_set_phase("Idle");
    uint64_t rsp_req_seq = rsp_smc.application_secret.request_data_sequence_number;
    spdm_tla_emit_responder_receive_verify_new_key(
        &rsp_smc, rsp_req_seq,
        spdm_tla_epoch(&req_smc, 1) /* new epoch = active epoch at requester */);

    /* [Event] requester_receive_verify_ack */
    spdm_tla_set_committed(false);
    spdm_tla_emit_requester_receive_verify_ack(
        &req_smc,
        req_smc.application_secret.response_data_sequence_number,
        0 /* verify ack msg epoch */);

    /* 3 rounds after key update (with new requester key) */
    for (int i = 0; i < 3; i++) {
        encode_decode_cycle(&req_smc, &rsp_smc, 1, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
        encode_decode_cycle(&rsp_smc, &req_smc, 0, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
    }

    spdm_tla_close();
}

/* ------------------------------------------------------------------ */
/* Scenario 3: key_update_all_keys (UPDATE_ALL_KEYS)                    */
/* ------------------------------------------------------------------ */

void tla_scenario_key_update_all_keys(const char *trace_path)
{
    libspdm_secured_message_context_t req_smc, rsp_smc;
    const uint32_t SESSION_ID = 0xBEEFCAFE;
    static const uint8_t msg[] = {0xAA,0xBB,0xCC,0xDD};
    bool all_keys = true;

    spdm_tla_init(trace_path);
    init_smc_pair(&req_smc, "requester");
    init_smc_pair(&rsp_smc, "responder");

    /* 2 rounds before key update */
    for (int i = 0; i < 2; i++) {
        encode_decode_cycle(&req_smc, &rsp_smc, 1, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
        encode_decode_cycle(&rsp_smc, &req_smc, 0, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
    }

    /* ----- Key update: UPDATE_ALL_KEYS ----- */

    /* Requester side: create responder key first */
    libspdm_create_update_session_data_key(&req_smc,
        LIBSPDM_KEY_UPDATE_ACTION_RESPONDER);
    /* [Event] create_update_responder_key */
    spdm_tla_emit_create_update_responder_key(&req_smc);

    uint64_t req_seq_before = req_smc.application_secret.request_data_sequence_number;
    /* [Event] send_key_update_request */
    spdm_tla_set_phase("PendingAck");
    spdm_tla_emit_send_key_update_request(&req_smc, all_keys, req_seq_before);

    /* Responder side: create requester key AND responder key, activate responder immediately */
    libspdm_create_update_session_data_key(&rsp_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    libspdm_create_update_session_data_key(&rsp_smc,
        LIBSPDM_KEY_UPDATE_ACTION_RESPONDER);
    libspdm_activate_update_session_data_key(&rsp_smc,
        LIBSPDM_KEY_UPDATE_ACTION_RESPONDER, true);
    /* [Event] responder_receive_key_update (msg.epoch = req's old req epoch = 0) */
    spdm_tla_emit_responder_receive_key_update(
        &rsp_smc, all_keys,
        rsp_smc.application_secret.request_data_sequence_number,
        0 /* KEY_UPDATE encrypted with old req key epoch = 0 */);

    /* Requester receives ACK encrypted with new rsp key: activate rsp key, then create+activate req key */
    libspdm_activate_update_session_data_key(&req_smc,
        LIBSPDM_KEY_UPDATE_ACTION_RESPONDER, true);
    libspdm_create_update_session_data_key(&req_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    libspdm_activate_update_session_data_key(&req_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, true);
    /* [Event] requester_receive_key_update_ack */
    spdm_tla_set_phase("PendingVerify");
    spdm_tla_set_committed(true);
    spdm_tla_emit_requester_receive_key_update_ack(
        &req_smc, all_keys,
        req_smc.application_secret.request_data_sequence_number,
        0 /* ack msg epoch */);

    /* Responder processes VERIFY_NEW_KEY: activate requester key */
    libspdm_activate_update_session_data_key(&rsp_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, true);
    /* [Event] responder_receive_verify_new_key */
    spdm_tla_set_phase("Idle");
    spdm_tla_emit_responder_receive_verify_new_key(
        &rsp_smc,
        rsp_smc.application_secret.request_data_sequence_number,
        spdm_tla_epoch(&req_smc, 1));

    /* [Event] requester_receive_verify_ack */
    spdm_tla_set_committed(false);
    spdm_tla_emit_requester_receive_verify_ack(
        &req_smc,
        req_smc.application_secret.response_data_sequence_number,
        0);

    /* 3 rounds after key update with new keys on both directions */
    for (int i = 0; i < 3; i++) {
        encode_decode_cycle(&req_smc, &rsp_smc, 1, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
        encode_decode_cycle(&rsp_smc, &req_smc, 0, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
    }

    spdm_tla_close();
}

/* ------------------------------------------------------------------ */
/* Scenario 4: decode_rollback (AEAD fail with backup → rollback)       */
/* ------------------------------------------------------------------ */

void tla_scenario_decode_rollback(const char *trace_path)
{
    libspdm_secured_message_context_t req_smc, rsp_smc;
    const uint32_t SESSION_ID = 0xFACEFEED;
    static const uint8_t msg[] = {0x55,0x66,0x77,0x88};

    spdm_tla_init(trace_path);
    init_smc_pair(&req_smc, "requester");
    init_smc_pair(&rsp_smc, "responder");

    /* 2 clean rounds so seq > 0 and both contexts are in sync */
    for (int i = 0; i < 2; i++) {
        encode_decode_cycle(&req_smc, &rsp_smc, 1, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
    }
    /* Both: seq[req][request] == 2 at this point */

    /* Responder installs NEW requester key (backup_valid=true, seq RESETS to 0).
     * Requester still has OLD key and seq=2.
     * IMPORTANT: We need the seq numbers to match for AEAD to be attempted.
     * After create_update, rsp_smc.request_data_sequence_number = 0.
     * So we encode from req_smc AT THEIR CURRENT SEQ (2) and decode at rsp_smc
     * where seq is 0 — these won't match. Instead, we reset req_smc seq too
     * so both are aligned at 0 for the rollback decode. */
    libspdm_create_update_session_data_key(&rsp_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    /* rsp_smc: active=new_req_key_v1, backup=old_req_key_v0, backup_valid=true, seq=0 */

    /* Align requester seq to 0 to match responder (simulates the key-update
     * sequence-number reset that would happen in the real protocol).       */
    req_smc.application_secret.request_data_sequence_number = 0;

    /* Requester encodes with OLD key v0 at seq=0 (pre-encode seq=0, post-encode seq=1) */
    uint8_t old_secured[sizeof(g_secured_buf)];
    size_t  old_secured_size = sizeof(old_secured);
    uint8_t msg_copy_s4[sizeof(msg)];
    memcpy(msg_copy_s4, msg, sizeof(msg));
    libspdm_return_t st = libspdm_encode_secured_message(
        &req_smc, SESSION_ID, true,
        sizeof(msg), msg_copy_s4,
        &old_secured_size, old_secured, &m_tla_callbacks);
    assert(st == LIBSPDM_STATUS_SUCCESS);
    /* Message header contains sequence_number=0.
     * rsp_smc also has seq=0, so the sequence header check PASSES.
     * AEAD decryption fails (wrong key v1 vs message encrypted with v0).
     * backup_valid=true → TRY_DISCARD_KEY_UPDATE.                         */

    size_t recv_size = sizeof(g_app_recv_buf);
    void  *recv_ptr  = g_app_recv_buf;
    st = libspdm_decode_secured_message(
        &rsp_smc, SESSION_ID, true,
        old_secured_size, old_secured,
        &recv_size, &recv_ptr, &m_tla_callbacks);
    /* Expect: TRY_DISCARD_KEY_UPDATE (decode_increment_seq + decode_aead_fail_backup fired) */
    assert(st == LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE);

    /* Rollback: activate old key */
    libspdm_activate_update_session_data_key(&rsp_smc,
        LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, false /* rollback */);

    /* [Event] responder_try_discard_key_update (emitted from test after rollback) */
    /* rsp_smc seq was incremented before the failed decode; after rollback it is
     * restored from backup.  The event captures post-rollback state. */
    spdm_tla_emit_responder_try_discard_key_update(
        &rsp_smc,
        rsp_smc.application_secret.request_data_sequence_number,
        /* msg_epoch = epoch of the failed message, i.e. old epoch = backup epoch */
        spdm_tla_epoch(&rsp_smc, 1));

    /* After rollback: rsp_smc.req_seq restored from backup (=2, seq at create_update call).
     * req_smc.req_seq = 1 (incremented by the old-key encode above).
     * Sync both sides: set req to 1, rsp to 1 for clean subsequent decodes. */
    req_smc.application_secret.request_data_sequence_number = 1;
    rsp_smc.application_secret.request_data_sequence_number = 1;

    /* 2 more clean rounds with original old key (after rollback) */
    for (int i = 0; i < 2; i++) {
        encode_decode_cycle(&req_smc, &rsp_smc, 1, SESSION_ID, SESSION_ID,
                            msg, sizeof(msg));
    }

    spdm_tla_close();
}

/* ------------------------------------------------------------------ */
/* Entry point called from test_spdm_secured_message.c                  */
/* ------------------------------------------------------------------ */

static const char *TRACE_DIR_VAR = "TLA_TRACE_DIR";

int libspdm_tla_trace_scenarios_main(void)
{
    const char *dir = getenv(TRACE_DIR_VAR);
    char path[512];

    if (!dir) dir = ".";

    printf("[TLA] Running scenario 1: normal_encode_decode\n");
    snprintf(path, sizeof(path), "%s/normal_encode_decode.ndjson", dir);
    tla_scenario_normal_encode_decode(path);
    printf("[TLA]   → %s\n", path);

    printf("[TLA] Running scenario 2: key_update_single\n");
    snprintf(path, sizeof(path), "%s/key_update_single.ndjson", dir);
    tla_scenario_key_update_single(path);
    printf("[TLA]   → %s\n", path);

    printf("[TLA] Running scenario 3: key_update_all_keys\n");
    snprintf(path, sizeof(path), "%s/key_update_all_keys.ndjson", dir);
    tla_scenario_key_update_all_keys(path);
    printf("[TLA]   → %s\n", path);

    printf("[TLA] Running scenario 4: decode_rollback\n");
    snprintf(path, sizeof(path), "%s/decode_rollback.ndjson", dir);
    tla_scenario_decode_rollback(path);
    printf("[TLA]   → %s\n", path);

    return 0;
}

#endif /* SPDM_TLA_TRACE_ENABLE */
