/**
 * BUG-3 Reproduction: Encap SEND_EVENT initiated without subscription check
 *
 * libspdm_init_send_event_encap_state() (libspdm_rsp_encap_response.c:249)
 * sets response_state = PROCESSING_ENCAP without consulting the session's
 * subscription state.  If the requester has SUBSCRIBE_NONE, the encap flow
 * starts anyway — an event delivery to an unsubscribed recipient.
 *
 * Correct behaviour: libspdm_init_send_event_encap_state() returns without
 *                    initiating the flow when subscription_state is NONE.
 * Buggy behaviour:   response_state is unconditionally set to PROCESSING_ENCAP.
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

    libspdm_init_context(ctx);

    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state =
        LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;

    ctx->connection_info.capability.flags |=
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP;
    ctx->connection_info.capability.flags |=
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP;
    ctx->connection_info.capability.flags |=
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP;
    ctx->connection_info.capability.flags |=
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCAP_CAP;

    ctx->local_context.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_EVENT_CAP;
    ctx->local_context.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP;
    ctx->local_context.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP;
    ctx->local_context.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP;
    ctx->local_context.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCAP_CAP;

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

    /* Subscription state is NONE after KEY_EXCHANGE without EVENT_ALL_POLICY.
     * The integrator never called libspdm_event_subscribe — session has no
     * active subscription.  The default zeroed session_info reflects this. */
}

int main(void)
{
    libspdm_context_t *ctx;
    libspdm_response_state_t state_before, state_after;

    printf("=== BUG-3: Encap SEND_EVENT initiated without subscription check ===\n\n");

    ctx = calloc(1, libspdm_get_context_size());
    if (!ctx) { fprintf(stderr, "calloc failed\n"); return 2; }

    setup_context(ctx);

    state_before = ctx->response_state;
    printf("Setup: response_state=NORMAL (%d), session subscription=NONE\n",
           (int)state_before);
    printf("Expected (correct): libspdm_init_send_event_encap_state() should\n"
           "                    refuse to start encap when subscription is NONE.\n");
    printf("                    response_state should remain NORMAL.\n");
    printf("\n");

    /* Integrator (application layer) calls this to push an event to the
     * requester via the encapsulated flow.  The bug is that it doesn't check
     * whether the requester actually subscribed to events. */
    libspdm_init_send_event_encap_state(ctx, ctx->last_spdm_request_session_id);

    state_after = ctx->response_state;

    printf("After libspdm_init_send_event_encap_state():\n");
    printf("  response_state = %s (%d)\n",
           (state_after == LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP)
               ? "PROCESSING_ENCAP"
               : (state_after == LIBSPDM_RESPONSE_STATE_NORMAL ? "NORMAL" : "OTHER"),
           (int)state_after);
    printf("\n");

    if (state_after == LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP) {
        printf("BUG CONFIRMED: response_state transitioned to PROCESSING_ENCAP even "
               "though session has no active subscription (SUBSCRIBE_NONE).\n");
        printf("  The responder will now attempt to push an event to an "
               "unsubscribed requester.\n");
        printf("RESULT: REPRODUCED (Level 0)\n");
        free(ctx);
        return 0;
    }

    if (state_after == LIBSPDM_RESPONSE_STATE_NORMAL) {
        printf("NOT REPRODUCED: response_state stayed NORMAL "
               "(subscription check exists, bug appears fixed)\n");
        free(ctx);
        return 1;
    }

    printf("UNEXPECTED state=%d\n", (int)state_after);
    free(ctx);
    return 1;
}
