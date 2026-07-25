/**
 * BUG-1 Reproduction: Response-state check order in SEND_EVENT handler
 *
 * libspdm_rsp_event_ack.c checks the SPDM version (line 47) BEFORE checking
 * response_state (line 68). When response_state == PROCESSING_ENCAP and a
 * SEND_EVENT with version mismatch arrives, the handler returns VERSION_MISMATCH
 * instead of REQUEST_IN_FLIGHT.
 *
 * Correct behaviour: response_state is checked first -> REQUEST_IN_FLIGHT
 * Buggy behaviour:   version mismatch fires first   -> VERSION_MISMATCH
 *
 * Level 0 reproduction — purely through public API, no code modification.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_secured_message_lib.h"

/* algo vars provided by algo.c (spdm_unit_test_common) */
extern uint32_t m_libspdm_use_hash_algo;
extern uint32_t m_libspdm_use_asym_algo;
extern uint16_t m_libspdm_use_dhe_algo;
extern uint16_t m_libspdm_use_aead_algo;

static void setup_context(libspdm_context_t *ctx)
{
    libspdm_session_info_t *session_info;
    const uint32_t session_id = 0xFFFFFFFF;

    /* ctx already zeroed by calloc; init_context sets up secured_message_contexts */
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
    uint8_t request_buf[sizeof(spdm_send_event_request_t)];
    uint8_t response_buf[256];
    size_t  response_size;
    spdm_send_event_request_t *req;
    const spdm_error_response_t     *err_resp;
    libspdm_return_t status;

    printf("=== BUG-1: Response-state check order in SEND_EVENT handler ===\n\n");

    ctx = calloc(1, libspdm_get_context_size());
    if (!ctx) { fprintf(stderr, "calloc failed\n"); return 2; }

    setup_context(ctx);

    /* --- Scenario: encap flow is active (PROCESSING_ENCAP) --- */
    ctx->response_state = LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP;

    /* Craft SEND_EVENT with version 0x12, not 0x13 (version mismatch) */
    memset(request_buf, 0, sizeof(request_buf));
    req = (spdm_send_event_request_t *)request_buf;
    req->header.spdm_version         = SPDM_MESSAGE_VERSION_12;   /* mismatch */
    req->header.request_response_code = SPDM_SEND_EVENT;
    req->header.param1                = 0;
    req->header.param2                = 0;
    req->event_count                  = 1;   /* non-zero; won't reach parse loop */

    response_size = sizeof(response_buf);
    memset(response_buf, 0, sizeof(response_buf));

    status = libspdm_get_response_event_ack(ctx,
                                            sizeof(request_buf),
                                            request_buf,
                                            &response_size,
                                            response_buf);

    err_resp = (const spdm_error_response_t *)response_buf;

    printf("Setup:    response_state=PROCESSING_ENCAP, request version=0x%02x "
           "(connection version=0x%02x)\n",
           SPDM_MESSAGE_VERSION_12, SPDM_MESSAGE_VERSION_13);
    printf("Expected: SPDM_ERROR_CODE_REQUEST_IN_FLIGHT (0x%02x) — encap in flight\n",
           SPDM_ERROR_CODE_REQUEST_IN_FLIGHT);
    printf("Actual:   error_code=0x%02x  (response_code=0x%02x)\n",
           err_resp->header.param1,
           err_resp->header.request_response_code);
    printf("\n");

    if (err_resp->header.param1 == SPDM_ERROR_CODE_VERSION_MISMATCH) {
        printf("BUG CONFIRMED: returned VERSION_MISMATCH (0x%02x) instead of "
               "REQUEST_IN_FLIGHT (0x%02x)\n",
               SPDM_ERROR_CODE_VERSION_MISMATCH,
               SPDM_ERROR_CODE_REQUEST_IN_FLIGHT);
        printf("RESULT: REPRODUCED (Level 0)\n");
        free(ctx);
        return 0;   /* exit 0 = bug triggered as expected */
    }

    if (err_resp->header.param1 == SPDM_ERROR_CODE_REQUEST_IN_FLIGHT) {
        printf("NOT REPRODUCED: correctly returned REQUEST_IN_FLIGHT "
               "(bug appears fixed)\n");
        free(ctx);
        return 1;
    }

    printf("UNEXPECTED error_code=0x%02x (status=0x%llx)\n",
           err_resp->header.param1, (unsigned long long)status);
    free(ctx);
    return 1;
}
