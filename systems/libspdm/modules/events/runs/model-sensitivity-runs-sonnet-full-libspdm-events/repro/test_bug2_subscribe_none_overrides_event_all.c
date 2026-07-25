/**
 * BUG-2 Reproduction: SUBSCRIBE_NONE silently overrides EVENT_ALL_POLICY
 *
 * libspdm_get_response_subscribe_event_types_ack() (line 124) processes a
 * SUBSCRIBE_EVENT_TYPES with count=0 by calling libspdm_event_subscribe(NONE)
 * unconditionally — with no guard checking whether an EVENT_ALL_POLICY
 * subscription is active.
 *
 * In event.c, libspdm_event_subscribe(NONE) sets g_event_all_subscribe=false,
 * silently discarding the policy set by KEY_EXCHANGE.
 *
 * Correct behaviour: reject the request with INVALID_REQUEST when event_all
 *                    policy is active, or preserve the subscription.
 * Buggy behaviour:   g_event_all_subscribe becomes false with no error.
 *
 * Level 0 reproduction — purely through public API, no code modification.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_secured_message_lib.h"

/* from os_stub/spdm_device_secret_lib_sample/event.c */
extern bool g_event_all_subscribe;
extern bool g_event_all_unsubscribe;

/* algo vars provided by algo.c (spdm_unit_test_common) */
extern uint32_t m_libspdm_use_hash_algo;
extern uint32_t m_libspdm_use_asym_algo;
extern uint16_t m_libspdm_use_dhe_algo;
extern uint16_t m_libspdm_use_aead_algo;

static void setup_context(libspdm_context_t *ctx)
{
    libspdm_session_info_t *session_info;
    const uint32_t session_id = 0xFFFFFFFF;

    libspdm_init_context(ctx);

    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state =
        LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;

    ctx->connection_info.capability.flags |=
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_EVENT_CAP;
    ctx->connection_info.capability.flags |=
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP;
    ctx->connection_info.capability.flags |=
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP;
    ctx->connection_info.capability.flags |=
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP;

    ctx->local_context.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP;
    ctx->local_context.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP;
    ctx->local_context.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP;
    ctx->local_context.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_EVENT_CAP;

    ctx->connection_info.algorithm.base_hash_algo  = m_libspdm_use_hash_algo;
    ctx->connection_info.algorithm.base_asym_algo  = m_libspdm_use_asym_algo;
    ctx->connection_info.algorithm.dhe_named_group = m_libspdm_use_dhe_algo;
    ctx->connection_info.algorithm.aead_cipher_suite = m_libspdm_use_aead_algo;

    ctx->latest_session_id = session_id;
    ctx->last_spdm_request_session_id_valid = true;
    ctx->last_spdm_request_session_id = session_id;

    session_info = &ctx->session_info[0];
    libspdm_session_info_init(ctx, session_info, session_id,
                              SECURED_SPDM_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT,
                              true);
    libspdm_secured_message_set_session_state(
        session_info->secured_message_context,
        LIBSPDM_SESSION_STATE_ESTABLISHED);
}

int main(void)
{
    libspdm_context_t *ctx;
    spdm_message_header_t subscribe_req;   /* count=0 -> no additional payload */
    uint8_t response_buf[256];
    size_t  response_size;
    const spdm_subscribe_event_types_ack_response_t *ack;
    const spdm_error_response_t *err;
    libspdm_return_t status;

    printf("=== BUG-2: SUBSCRIBE_NONE silently overrides EVENT_ALL_POLICY ===\n\n");

    ctx = calloc(1, libspdm_get_context_size());
    if (!ctx) { fprintf(stderr, "calloc failed\n"); return 2; }

    setup_context(ctx);

    /* --- Step 1: Simulate EVENT_ALL_POLICY established by KEY_EXCHANGE ---
     * In real usage libspdm_event_subscribe(SUBSCRIBE_ALL) is called from
     * libspdm_get_response_key_exchange() when session_policy has
     * EVENT_ALL_POLICY bit set.  We call it directly here to set the same
     * state, which is the same call the production code makes.
     */
    g_event_all_subscribe = false;
    g_event_all_unsubscribe = false;

    bool subscribe_ok = libspdm_event_subscribe(
        ctx,
        ctx->connection_info.version,
        ctx->last_spdm_request_session_id,
        LIBSPDM_EVENT_SUBSCRIBE_ALL,
        0, 0, NULL);

    printf("Step 1 — KEY_EXCHANGE EVENT_ALL_POLICY: libspdm_event_subscribe(ALL) = %s\n",
           subscribe_ok ? "success" : "failure");
    printf("         g_event_all_subscribe = %s  (should be true)\n",
           g_event_all_subscribe ? "true" : "false");

    if (!subscribe_ok || !g_event_all_subscribe) {
        fprintf(stderr, "Setup failed: could not establish ALL subscription\n");
        free(ctx);
        return 2;
    }

    /* --- Step 2: Send SUBSCRIBE_EVENT_TYPES with count=0 (SUBSCRIBE_NONE) ---
     * A requester legitimately sends this to change its subscription.
     * The spec permits this message, but should the responder allow it when
     * EVENT_ALL_POLICY is active?  The current code has no guard.
     */
    memset(&subscribe_req, 0, sizeof(subscribe_req));
    subscribe_req.spdm_version         = SPDM_MESSAGE_VERSION_13;
    subscribe_req.request_response_code = SPDM_SUBSCRIBE_EVENT_TYPES;
    subscribe_req.param1               = 0;   /* subscribe_event_group_count = 0 */
    subscribe_req.param2               = 0;

    response_size = sizeof(response_buf);
    memset(response_buf, 0, sizeof(response_buf));

    status = libspdm_get_response_subscribe_event_types_ack(
        ctx,
        sizeof(spdm_message_header_t),
        &subscribe_req,
        &response_size,
        response_buf);

    ack = (const spdm_subscribe_event_types_ack_response_t *)response_buf;
    err = (const spdm_error_response_t *)response_buf;

    printf("\nStep 2 — SUBSCRIBE_EVENT_TYPES(count=0): status=0x%llx\n",
           (unsigned long long)status);
    printf("         response_code=0x%02x  error_code=0x%02x\n",
           ack->header.request_response_code, err->header.param1);
    printf("         g_event_all_subscribe = %s  (should still be true if fixed)\n",
           g_event_all_subscribe ? "true" : "false");
    printf("\n");

    if (!g_event_all_subscribe &&
        ack->header.request_response_code == SPDM_SUBSCRIBE_EVENT_TYPES_ACK) {
        printf("BUG CONFIRMED: SUBSCRIBE_NONE with count=0 succeeded and cleared "
               "EVENT_ALL_POLICY subscription without error.\n");
        printf("  g_event_all_subscribe: true -> false (subscription lost silently)\n");
        printf("RESULT: REPRODUCED (Level 0)\n");
        free(ctx);
        return 0;
    }

    if (err->header.param1 == SPDM_ERROR_CODE_INVALID_REQUEST) {
        printf("NOT REPRODUCED: Request correctly rejected with INVALID_REQUEST "
               "(bug appears fixed)\n");
        free(ctx);
        return 1;
    }

    printf("UNEXPECTED outcome (status=0x%llx, response=0x%02x, g_event_all=%s)\n",
           (unsigned long long)status,
           ack->header.request_response_code,
           g_event_all_subscribe ? "true" : "false");
    free(ctx);
    return 1;
}
