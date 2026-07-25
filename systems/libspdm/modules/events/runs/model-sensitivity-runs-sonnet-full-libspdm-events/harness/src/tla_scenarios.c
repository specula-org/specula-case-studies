/**
 * TLA+ Trace Scenarios — libspdm SPDM 1.3 Event Subscription
 *
 * Exercises all instrumented code paths to collect NDJSON trace files.
 * Uses the same test infrastructure as the existing unit tests.
 */

#include "spdm_unit_test.h"
#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_secured_message_lib.h"

#include "tla_trace.h"
#include <stdlib.h>
#include <string.h>

/* External globals from os_stub/spdm_device_secret_lib_sample/event.c */
extern uint32_t g_event_count;
extern size_t g_events_list_size;
extern bool g_event_all_subscribe;
extern bool g_event_all_unsubscribe;
extern bool g_event_subscribe_error;
extern bool g_generate_event_list_error;

/* Build a trace file path from TLA_TRACES_DIR env var (or "." if unset). */
static void make_trace_path(char *buf, size_t buf_size, const char *filename)
{
    const char *dir = getenv("TLA_TRACES_DIR");
    if (!dir || dir[0] == '\0') dir = ".";
    snprintf(buf, buf_size, "%s/%s", dir, filename);
}

/* -----------------------------------------------------------------------
 * Helpers
 * ----------------------------------------------------------------------- */

/**
 * Emit HandleKeyExchange + HandleFinish by doing a real KEX and then
 * setting the session to ESTABLISHED.
 * Returns the session_id on success, 0 on failure.
 */
static uint32_t do_key_exchange(libspdm_context_t *ctx, bool with_event_all)
{
#if LIBSPDM_ENABLE_CAPABILITY_KEY_EX_CAP && LIBSPDM_ENABLE_CAPABILITY_EVENT_CAP
    libspdm_return_t status;
    void *data1 = NULL;
    size_t data_size1;
    size_t dhe_key_size;
    void *dhe_context;
    size_t opaque_size;
    uint8_t request_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    uint8_t response_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t response_size = sizeof(response_buf);

#pragma pack(1)
    typedef struct {
        spdm_message_header_t header;
        uint16_t req_session_id;
        uint8_t  session_policy;
        uint8_t  reserved;
        uint8_t  random_data[SPDM_RANDOM_DATA_SIZE];
        uint8_t  exchange_data[LIBSPDM_MAX_DHE_KEY_SIZE];
        uint16_t opaque_length;
        uint8_t  opaque_data[SPDM_MAX_OPAQUE_DATA_SIZE];
    } kex_request_t;
#pragma pack()

    kex_request_t *kex_req = (kex_request_t *)request_buf;
    size_t kex_size;

    /* Context setup */
    /* Ensure the responder is in a clean state for a new connection. */
    ctx->last_spdm_request_session_id_valid = false;
    ctx->connection_info.version = SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;
    ctx->connection_info.multi_key_conn_rsp = false;

    ctx->connection_info.capability.flags |= SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP;
    ctx->connection_info.capability.flags |= SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP;
    ctx->connection_info.capability.flags |= SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP;
    ctx->connection_info.capability.flags |= SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCAP_CAP;

    ctx->local_context.capability.flags |= SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP;
    ctx->local_context.capability.flags |= SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP;
    ctx->local_context.capability.flags |= SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP;
    ctx->local_context.capability.flags |= SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_EVENT_CAP;
    ctx->local_context.capability.flags |= SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCAP_CAP;
    ctx->local_context.capability.flags |= SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP;

    ctx->connection_info.algorithm.base_hash_algo    = m_libspdm_use_hash_algo;
    ctx->connection_info.algorithm.base_asym_algo    = m_libspdm_use_asym_algo;
    ctx->connection_info.algorithm.measurement_spec  = m_libspdm_use_measurement_spec;
    ctx->connection_info.algorithm.measurement_hash_algo = m_libspdm_use_measurement_hash_algo;
    ctx->connection_info.algorithm.dhe_named_group   = m_libspdm_use_dhe_algo;
    ctx->connection_info.algorithm.aead_cipher_suite = m_libspdm_use_aead_algo;
    ctx->connection_info.algorithm.other_params_support = SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;
    ctx->local_context.secured_message_version.secured_message_version_count = 1;

    libspdm_session_info_init(ctx, ctx->session_info, INVALID_SESSION_ID, 0, false);
    libspdm_read_responder_public_certificate_chain(m_libspdm_use_hash_algo,
                                                    m_libspdm_use_asym_algo,
                                                    &data1, &data_size1, NULL, NULL);
    ctx->local_context.local_cert_chain_provision[0] = data1;
    ctx->local_context.local_cert_chain_provision_size[0] = data_size1;
    libspdm_reset_message_a(ctx);

    /* Build KEX request */
    memset(kex_req, 0, sizeof(*kex_req));
    kex_req->header.spdm_version = SPDM_MESSAGE_VERSION_13;
    kex_req->header.request_response_code = SPDM_KEY_EXCHANGE;
    kex_req->header.param1 = SPDM_KEY_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH;
    kex_req->header.param2 = 0;
    kex_req->req_session_id = 0xFFFF;
    kex_req->reserved = 0;
    kex_req->session_policy = with_event_all ?
        SPDM_KEY_EXCHANGE_REQUEST_SESSION_POLICY_EVENT_ALL_POLICY : 0;

    libspdm_get_random_number(SPDM_RANDOM_DATA_SIZE, kex_req->random_data);

    dhe_key_size = libspdm_get_dhe_pub_key_size(m_libspdm_use_dhe_algo);
    dhe_context = libspdm_dhe_new(ctx->connection_info.version, m_libspdm_use_dhe_algo, false);
    libspdm_dhe_generate_key(m_libspdm_use_dhe_algo, dhe_context,
                             kex_req->exchange_data, &dhe_key_size);
    libspdm_dhe_free(m_libspdm_use_dhe_algo, dhe_context);

    uint8_t *ptr = kex_req->exchange_data + dhe_key_size;
    opaque_size = libspdm_get_opaque_data_supported_version_data_size(ctx);
    libspdm_write_uint16(ptr, (uint16_t)opaque_size);
    ptr += sizeof(uint16_t);
    libspdm_build_opaque_data_supported_version_data(ctx, &opaque_size, ptr);
    ptr += opaque_size;

    kex_size = (size_t)(ptr - (uint8_t *)kex_req);

    status = libspdm_get_response_key_exchange(ctx, kex_size, kex_req,
                                               &response_size, response_buf);

    free(data1);

    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        return 0;
    }

    spdm_key_exchange_response_t *kex_rsp = (spdm_key_exchange_response_t *)response_buf;
    /* libspdm returns SUCCESS even for error responses — verify we got a real KEX_RSP. */
    if (kex_rsp->header.request_response_code != SPDM_KEY_EXCHANGE_RSP) {
        return 0;
    }
    /* session_id layout: upper=rsp_session_id, lower=req_session_id (libspdm convention) */
    uint32_t session_id = ((uint32_t)kex_rsp->rsp_session_id << 16) | kex_req->req_session_id;

    /* Set context fields for subsequent requests */
    ctx->latest_session_id = session_id;
    ctx->last_spdm_request_session_id_valid = true;
    ctx->last_spdm_request_session_id = session_id;

    /* Transition to ESTABLISHED (emits HandleFinish) */
    libspdm_set_session_state(ctx, session_id, LIBSPDM_SESSION_STATE_ESTABLISHED);

    return session_id;
#else
    (void)ctx; (void)with_event_all;
    return 0;
#endif
}

/**
 * Send a SUBSCRIBE_EVENT_TYPES request.
 * subscribe_none: send empty list (group_count=0).
 */
static bool do_subscribe(libspdm_context_t *ctx, bool subscribe_none)
{
    libspdm_return_t status;
    uint8_t req_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    uint8_t rsp_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t rsp_size = sizeof(rsp_buf);
    spdm_subscribe_event_types_request_t *req = (spdm_subscribe_event_types_request_t *)req_buf;
    size_t req_size;

    if (subscribe_none) {
        req->header.spdm_version = SPDM_MESSAGE_VERSION_13;
        req->header.request_response_code = SPDM_SUBSCRIBE_EVENT_TYPES;
        req->header.param1 = 0; /* group_count = 0 */
        req->header.param2 = 0;
        req_size = sizeof(spdm_message_header_t);
    } else {
        /* Subscribe to a single DMTF event group with "subscribe all" attribute */
        uint8_t *p = req_buf;
        req->header.spdm_version = SPDM_MESSAGE_VERSION_13;
        req->header.request_response_code = SPDM_SUBSCRIBE_EVENT_TYPES;
        req->header.param1 = 1; /* group_count = 1 */
        req->header.param2 = 0;

        /* Build subscribe_list: one DMTF group with ALL attribute */
        typedef struct {
            uint8_t id;
            uint8_t vendor_id_len;
        } group_id_t;
        typedef struct {
            uint16_t event_type_count;
            uint16_t event_group_ver;
            uint32_t attributes;
        } group_t;

        p = (uint8_t *)(req + 1);
        ((group_id_t *)p)->id = SPDM_REGISTRY_ID_DMTF;
        ((group_id_t *)p)->vendor_id_len = 0;
        p += sizeof(group_id_t);
        ((group_t *)p)->event_type_count = 0;
        ((group_t *)p)->event_group_ver = 1;
        ((group_t *)p)->attributes = SPDM_SUBSCRIBE_EVENT_TYPES_REQUEST_ATTRIBUTE_ALL;
        p += sizeof(group_t);

        uint32_t list_len = (uint32_t)(p - (uint8_t *)(req + 1));
        req->subscribe_list_len = list_len;
        req_size = sizeof(spdm_subscribe_event_types_request_t) + list_len;
    }

    status = libspdm_get_response_subscribe_event_types_ack(ctx, req_size, req,
                                                            &rsp_size, rsp_buf);
    return !LIBSPDM_STATUS_IS_ERROR(status);
}

/**
 * Send a SEND_EVENT request with correct version.
 * Emits HandleSendEventVersionMatch + (from test) HandleSendEventComplete.
 */
static bool do_send_event(libspdm_context_t *ctx, uint32_t event_instance_id)
{
    libspdm_return_t status;
    uint8_t req_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    uint8_t rsp_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t rsp_size = sizeof(rsp_buf);

    /* Build a minimal valid SEND_EVENT request */
#pragma pack(1)
    typedef struct {
        spdm_send_event_request_t hdr;
        uint32_t event_instance_id;
        uint8_t  reserved[4];
        uint8_t  svh_id;
        uint8_t  svh_vendor_id_len;
        uint16_t event_type_id;
        uint16_t event_detail_len;
        /* EVENT_LOST has detail_len=0 */
    } send_event_req_t;
#pragma pack()

    send_event_req_t *req = (send_event_req_t *)req_buf;
    memset(req, 0, sizeof(*req));
    req->hdr.header.spdm_version = SPDM_MESSAGE_VERSION_13;
    req->hdr.header.request_response_code = SPDM_SEND_EVENT;
    req->hdr.header.param1 = 0;
    req->hdr.header.param2 = 0;
    req->hdr.event_count = 1;
    req->event_instance_id = event_instance_id;
    req->svh_id = SPDM_REGISTRY_ID_DMTF;
    req->svh_vendor_id_len = 0;
    req->event_type_id = SPDM_DMTF_EVENT_TYPE_EVENT_LOST;
    req->event_detail_len = SPDM_DMTF_EVENT_TYPE_EVENT_LOST_SIZE;

    /* Add event_detail bytes */
    size_t req_size = sizeof(send_event_req_t) + SPDM_DMTF_EVENT_TYPE_EVENT_LOST_SIZE;
    memset(req_buf + sizeof(send_event_req_t), 0, SPDM_DMTF_EVENT_TYPE_EVENT_LOST_SIZE);

    /* Need process_event callback set */
    status = libspdm_get_response_event_ack(ctx, req_size, req, &rsp_size, rsp_buf);
    if (!LIBSPDM_STATUS_IS_ERROR(status)) {
        /* Harness-level: emit HandleSendEventComplete */
        tla_emit_send_event_complete();
        return true;
    }
    return false;
}

/**
 * Send a SEND_EVENT request with wrong version (triggers VersionMismatch).
 */
static void do_send_event_version_mismatch(libspdm_context_t *ctx)
{
    uint8_t req_buf[512];
    uint8_t rsp_buf[512];
    size_t rsp_size = sizeof(rsp_buf);

    spdm_send_event_request_t *req = (spdm_send_event_request_t *)req_buf;
    memset(req, 0, sizeof(*req));
    /* Use version 0x12 while connection is 0x13 → mismatch */
    req->header.spdm_version = SPDM_MESSAGE_VERSION_12;
    req->header.request_response_code = SPDM_SEND_EVENT;
    req->event_count = 1;

    /* Minimal event body */
    memset(req_buf + sizeof(spdm_send_event_request_t), 0, 16);
    size_t req_size = sizeof(spdm_send_event_request_t) + 16;

    libspdm_get_response_event_ack(ctx, req_size, req, &rsp_size, rsp_buf);
    /* Note: no HandleSendEventComplete on mismatch path */
}

/**
 * Run the encap flow: init encap state → get encap request → process encap ACK.
 */
static bool do_encap_flow(libspdm_context_t *ctx, uint32_t session_id)
{
    libspdm_return_t status;
    uint8_t req_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    uint8_t ack_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t req_size = sizeof(req_buf);
    bool need_continue = true;

    g_event_count = 1;

    /* Sets response_state = PROCESSING_ENCAP, emits InitEncapSendEvent */
    libspdm_init_send_event_encap_state(ctx, session_id);

    /* Emits HandleEncapSendEvent */
    status = libspdm_get_encap_request_send_event(ctx, &req_size, req_buf);
    if (LIBSPDM_STATUS_IS_ERROR(status)) return false;

    /* Build a valid EVENT_ACK response */
    spdm_event_ack_response_t *ack = (spdm_event_ack_response_t *)ack_buf;
    ack->header.spdm_version = SPDM_MESSAGE_VERSION_13;
    ack->header.request_response_code = SPDM_EVENT_ACK;
    ack->header.param1 = 0;
    ack->header.param2 = 0;

    /* Emits ProcessEncapEventAck */
    status = libspdm_process_encap_response_event_ack(ctx, sizeof(spdm_event_ack_response_t),
                                                       ack, &need_continue);
    if (LIBSPDM_STATUS_IS_ERROR(status)) return false;

    /* Caller must reset response_state to NORMAL after need_continue=false */
    ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;
    return true;
}

/* -----------------------------------------------------------------------
 * Scenario 1: happy_path.ndjson
 *
 * Covers: HandleKeyExchange, HandleFinish, HandleSubscribeEventTypes,
 *         HandleSendEventVersionMatch, HandleSendEventComplete, TerminateSession
 * Multiple sessions to reach 20+ events.
 * ----------------------------------------------------------------------- */
static void scenario_happy_path(void **state)
{
    libspdm_test_context_t *test_ctx = *state;
    libspdm_context_t *ctx = test_ctx->spdm_context;
    uint32_t session_id;

    char trace_path[512];
    make_trace_path(trace_path, sizeof(trace_path), "happy_path.ndjson");
    tla_trace_init(trace_path);

    /* --- Session 1: No event_all, subscribe with list, 3 send events --- */
    g_event_all_subscribe = false;
    g_event_all_unsubscribe = false;
    session_id = do_key_exchange(ctx, false); /* HandleKeyExchange + HandleFinish */
    assert_int_not_equal(session_id, 0);
    do_subscribe(ctx, false);                  /* HandleSubscribeEventTypes(none=false, SUB_LIST) */
    do_send_event(ctx, 1);                     /* HandleSendEventVersionMatch + HandleSendEventComplete */
    do_send_event(ctx, 2);
    do_send_event(ctx, 3);
    libspdm_terminate_session(ctx, session_id); /* TerminateSession */
    /* = 10 events */

    /* --- Session 2: event_all, override with subscribe(none) --- */
    libspdm_unit_test_group_teardown(state);
    libspdm_unit_test_group_setup(state);
    ctx = ((libspdm_test_context_t *)*state)->spdm_context;

    g_event_all_subscribe = false;
    g_event_all_unsubscribe = false;
    session_id = do_key_exchange(ctx, true); /* HandleKeyExchange(event_all=true) + HandleFinish */
    assert_int_not_equal(session_id, 0);
    do_subscribe(ctx, true);                  /* HandleSubscribeEventTypes(none=true, SUB_NONE) */
    do_send_event(ctx, 1);
    do_send_event(ctx, 2);
    libspdm_terminate_session(ctx, session_id); /* TerminateSession */
    /* = 8 events, running total = 18 */

    /* --- Session 3: event_all, direct send (no subscribe), 2 sends --- */
    libspdm_unit_test_group_teardown(state);
    libspdm_unit_test_group_setup(state);
    ctx = ((libspdm_test_context_t *)*state)->spdm_context;

    g_event_all_subscribe = false;
    g_event_all_unsubscribe = false;
    session_id = do_key_exchange(ctx, true); /* HandleKeyExchange(event_all=true) + HandleFinish */
    assert_int_not_equal(session_id, 0);
    do_send_event(ctx, 1);                   /* HandleSendEventVersionMatch + HandleSendEventComplete */
    do_send_event(ctx, 2);
    libspdm_terminate_session(ctx, session_id); /* TerminateSession */
    /* = 7 events, running total = 25 */

    tla_trace_close();
    *state = test_ctx; /* restore for teardown */
}

/* -----------------------------------------------------------------------
 * Scenario 2: encap_flow.ndjson
 *
 * Covers: InitEncapSendEvent, HandleEncapSendEvent, ProcessEncapEventAck
 * ----------------------------------------------------------------------- */
static void scenario_encap_flow(void **state)
{
    libspdm_test_context_t *test_ctx = *state;
    libspdm_context_t *ctx = test_ctx->spdm_context;
    uint32_t session_id;

    char trace_path[512];
    make_trace_path(trace_path, sizeof(trace_path), "encap_flow.ndjson");
    tla_trace_init(trace_path);

    /* --- Session 1: KEX + Finish + Subscribe(list) + encap flow --- */
    g_event_count = 1;
    session_id = do_key_exchange(ctx, false); /* KEX + Finish */
    assert_int_not_equal(session_id, 0);
    do_subscribe(ctx, false);                  /* Subscribe(SUB_LIST) */
    do_encap_flow(ctx, session_id);            /* InitEncap + HandleEncap + ProcessAck */
    libspdm_terminate_session(ctx, session_id); /* Terminate */
    /* = 7 events */

    /* --- Session 2: KEX + Finish + encap (no subscribe, uses event_all) --- */
    libspdm_unit_test_group_teardown(state);
    libspdm_unit_test_group_setup(state);
    ctx = ((libspdm_test_context_t *)*state)->spdm_context;

    g_event_count = 1;
    session_id = do_key_exchange(ctx, true); /* KEX(event_all) + Finish */
    assert_int_not_equal(session_id, 0);
    do_encap_flow(ctx, session_id);          /* InitEncap + HandleEncap + ProcessAck */
    libspdm_terminate_session(ctx, session_id); /* Terminate */
    /* = 6 events, total = 13 */

    /* --- Session 3: KEX(event_all) + Finish + Subscribe(none) + encap (sub=NONE: Bug3) --- */
    libspdm_unit_test_group_teardown(state);
    libspdm_unit_test_group_setup(state);
    ctx = ((libspdm_test_context_t *)*state)->spdm_context;

    g_event_count = 1;
    session_id = do_key_exchange(ctx, true); /* KEX(event_all=true) + Finish */
    assert_int_not_equal(session_id, 0);
    do_subscribe(ctx, true);                  /* Subscribe(none=true) → SUB_NONE now */
    do_encap_flow(ctx, session_id);           /* HandleEncap with SUB_NONE! (Bug3) */
    libspdm_terminate_session(ctx, session_id); /* Terminate */
    /* = 7 events, total = 20 */

    /* --- Session 4: KEX + Finish + encap + direct send simultaneously --- */
    libspdm_unit_test_group_teardown(state);
    libspdm_unit_test_group_setup(state);
    ctx = ((libspdm_test_context_t *)*state)->spdm_context;

    g_event_count = 1;
    session_id = do_key_exchange(ctx, true);
    assert_int_not_equal(session_id, 0);
    do_encap_flow(ctx, session_id);
    do_send_event(ctx, 1);
    libspdm_terminate_session(ctx, session_id);
    /* = 7 events, total = 27 */

    tla_trace_close();
    *state = test_ctx;
}

/* -----------------------------------------------------------------------
 * Scenario 3: bug_families.ndjson
 *
 * Specifically exercises the three bug family scenarios.
 * ----------------------------------------------------------------------- */
static void scenario_bug_families(void **state)
{
    libspdm_test_context_t *test_ctx = *state;
    libspdm_context_t *ctx = test_ctx->spdm_context;
    uint32_t session_id;

    char trace_path[512];
    make_trace_path(trace_path, sizeof(trace_path), "bug_families.ndjson");
    tla_trace_init(trace_path);

    /* --- Bug Family 2: KEX(event_all) + Subscribe(none) overrides SUB_ALL --- */
    g_event_all_subscribe = false;
    session_id = do_key_exchange(ctx, true); /* KEX(event_all=true) + Finish */
    assert_int_not_equal(session_id, 0);
    /* Per spec: HandleSubscribeEventTypes with subscribe_none=true should NOT override
     * EVENT_ALL_POLICY subscription. The bug is that it does. */
    do_subscribe(ctx, true);                 /* Subscribe(none=true) — overrides to SUB_NONE */
    do_send_event(ctx, 1);                   /* Send with SUB_NONE (shouldn't work per spec) */
    libspdm_terminate_session(ctx, session_id);
    /* = 6 events */

    /* --- Bug Family 3: encap event delivered with SUB_NONE subscription --- */
    libspdm_unit_test_group_teardown(state);
    libspdm_unit_test_group_setup(state);
    ctx = ((libspdm_test_context_t *)*state)->spdm_context;

    /* KEX with no event_all: subscription stays SUB_NONE (Bug3 scenario) */
    g_event_count = 1;
    session_id = do_key_exchange(ctx, false); /* HandleKeyExchange(event_all=false) + HandleFinish */
    if (session_id != 0) {
        /* Init encap sends event even though subscription is SUB_NONE — Bug3 */
        libspdm_init_send_event_encap_state(ctx, session_id); /* InitEncapSendEvent */

        uint8_t req_buf3[LIBSPDM_MAX_SPDM_MSG_SIZE];
        size_t req_size3 = sizeof(req_buf3);
        libspdm_get_encap_request_send_event(ctx, &req_size3, req_buf3); /* HandleEncapSendEvent */

        spdm_event_ack_response_t ack;
        ack.header.spdm_version = SPDM_MESSAGE_VERSION_13;
        ack.header.request_response_code = SPDM_EVENT_ACK;
        ack.header.param1 = 0;
        ack.header.param2 = 0;
        bool need_continue;
        libspdm_process_encap_response_event_ack(ctx, sizeof(ack), &ack, &need_continue);
        ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL; /* ProcessEncapEventAck */

        libspdm_terminate_session(ctx, session_id);
    }
    /* = 6 events (KEX+Finish+InitEncap+HandleEncap+ProcessAck+Terminate), total = 12 */

    /* --- Bug Family 1: VERSION_MISMATCH during PROCESSING_ENCAP state --- */
    libspdm_unit_test_group_teardown(state);
    libspdm_unit_test_group_setup(state);
    ctx = ((libspdm_test_context_t *)*state)->spdm_context;

    session_id = do_key_exchange(ctx, false);
    if (session_id != 0) {
        /* Set response_state to PROCESSING_ENCAP (as if encap was initiated) */
        ctx->response_state = LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP;
        /* Now send a version-mismatched SEND_EVENT — Bug1: check happens before response_state */
        do_send_event_version_mismatch(ctx);  /* HandleSendEventVersionMismatch(PROCESSING_ENCAP) */
        ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;
        libspdm_terminate_session(ctx, session_id);
    }
    /* = 4 events (KEX, Finish, VersionMismatch, Terminate), total = 14 */

    /* --- Normal version mismatch (NORMAL state) --- */
    libspdm_unit_test_group_teardown(state);
    libspdm_unit_test_group_setup(state);
    ctx = ((libspdm_test_context_t *)*state)->spdm_context;

    session_id = do_key_exchange(ctx, false);
    if (session_id != 0) {
        do_send_event_version_mismatch(ctx);  /* HandleSendEventVersionMismatch(NORMAL) */
        libspdm_terminate_session(ctx, session_id);
    }
    /* = 4 events (KEX, Finish, VersionMismatch, Terminate), total = 18 */

    /* --- Version match during PROCESSING_ENCAP (REQUEST_IN_FLIGHT) --- */
    libspdm_unit_test_group_teardown(state);
    libspdm_unit_test_group_setup(state);
    ctx = ((libspdm_test_context_t *)*state)->spdm_context;

    g_event_count = 1;
    session_id = do_key_exchange(ctx, true);
    if (session_id != 0) {
        /* Start encap to set PROCESSING_ENCAP */
        uint8_t r[LIBSPDM_MAX_SPDM_MSG_SIZE];
        size_t rs = sizeof(r);
        libspdm_init_send_event_encap_state(ctx, session_id);
        libspdm_get_encap_request_send_event(ctx, &rs, r);
        /* Now try a direct SEND_EVENT with correct version while PROCESSING_ENCAP */
        /* This fires HandleSendEventVersionMatch with resp="PROCESSING_ENCAP" */
        {
            uint8_t req_buf2[LIBSPDM_MAX_SPDM_MSG_SIZE];
            uint8_t rsp_buf2[LIBSPDM_MAX_SPDM_MSG_SIZE];
            size_t rsp_sz = sizeof(rsp_buf2);
            spdm_send_event_request_t *req2 = (spdm_send_event_request_t *)req_buf2;
            memset(req2, 0, sizeof(*req2));
            req2->header.spdm_version = SPDM_MESSAGE_VERSION_13; /* correct version */
            req2->header.request_response_code = SPDM_SEND_EVENT;
            req2->event_count = 1;
            /* Minimal event body */
            memset(req_buf2 + sizeof(spdm_send_event_request_t), 0, 16);
            libspdm_get_response_event_ack(ctx, sizeof(spdm_send_event_request_t) + 16,
                                           req2, &rsp_sz, rsp_buf2);
            /* response_state is PROCESSING_ENCAP → REQUEST_IN_FLIGHT */
        }
        ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;
        libspdm_terminate_session(ctx, session_id);
    }
    /* = 7 events (KEX, Finish, InitEncap, HandleEncap, VersionMatch(ENCAP), Terminate) total=25 */

    tla_trace_close();
    *state = test_ctx;
}

/* -----------------------------------------------------------------------
 * Test registration
 * ----------------------------------------------------------------------- */
int libspdm_tla_scenarios_test(void)
{
    const struct CMUnitTest tests[] = {
        cmocka_unit_test(scenario_happy_path),
        cmocka_unit_test(scenario_encap_flow),
        cmocka_unit_test(scenario_bug_families),
    };

    libspdm_test_context_t test_context = {
        LIBSPDM_TEST_CONTEXT_VERSION,
        false, /* is_requester */
    };

    libspdm_setup_test_context(&test_context);

    return cmocka_run_group_tests(tests,
                                  libspdm_unit_test_group_setup,
                                  libspdm_unit_test_group_teardown);
}
