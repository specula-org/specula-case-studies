/**
 * Reproduction test for MC-BUG-1:
 * Zero secured_message_version on PSK session establishment (SPDM 1.2+)
 *
 * Root cause: libspdm_rsp_psk_exchange_rsp.c sets secured_message_version=0
 *   and only updates it when opaque_length != 0. When SPDM 1.2 requester
 *   sends PSK_EXCHANGE with opaque_length=0, the responder should reject
 *   with SPDM_ERROR_CODE_INVALID_REQUEST but instead accepts it and creates
 *   a session with secured_message_version=0.
 *
 * Trigger: requester->secured_message_version_count = 0 causes the requester
 *   to send PSK_EXCHANGE with opaque_length=0. For SPDM 1.2+, this violates
 *   the spec requirement that PSK_EXCHANGE MUST carry version selection data
 *   in the opaque field.
 *
 * Expected correct behavior:
 *   Responder returns SPDM_ERROR_CODE_INVALID_REQUEST; exchange fails.
 * Actual (buggy) behavior:
 *   Exchange succeeds; both sessions have secured_message_version=0.
 *
 * Level 0: pure black-box (public API, no failpoints, no timing injection).
 * The trigger (opaque_length=0 for SPDM 1.2) is a valid but adversarial input
 * reachable through the public API by clearing secured_message_version_count.
 */

#include "spdm_unit_test.h"
#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_secured_message_lib.h"
#include "library/spdm_transport_test_lib.h"

/* Required by tla_trace.h (included transitively by responder) */
FILE *g_tla_trace_fp = NULL;

#define BUG1_BUF_SIZE LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE

static uint8_t g_req_sr_buf[BUG1_BUF_SIZE];
static uint8_t g_rsp_sr_buf[BUG1_BUF_SIZE];
static uint8_t g_req_to_rsp[BUG1_BUF_SIZE];
static size_t  g_req_to_rsp_size;
static uint8_t g_rsp_to_req[BUG1_BUF_SIZE];
static size_t  g_rsp_to_req_size;

static libspdm_context_t *g_rsp_ctx = NULL;

/* --- Buffer callbacks --- */
static libspdm_return_t req_acq_send(void *c, void **b) { (void)c; *b = g_req_sr_buf; return LIBSPDM_STATUS_SUCCESS; }
static void req_rel_send(void *c, const void *b) { (void)c; (void)b; }
static libspdm_return_t req_acq_recv(void *c, void **b) { (void)c; *b = g_req_sr_buf; return LIBSPDM_STATUS_SUCCESS; }
static void req_rel_recv(void *c, const void *b) { (void)c; (void)b; }
static libspdm_return_t rsp_acq_send(void *c, void **b) { (void)c; *b = g_rsp_sr_buf; return LIBSPDM_STATUS_SUCCESS; }
static void rsp_rel_send(void *c, const void *b) { (void)c; (void)b; }
static libspdm_return_t rsp_acq_recv(void *c, void **b) { (void)c; *b = g_rsp_sr_buf; return LIBSPDM_STATUS_SUCCESS; }
static void rsp_rel_recv(void *c, const void *b) { (void)c; (void)b; }

static libspdm_return_t req_send(void *c, size_t sz, const void *m, uint64_t t)
{
    (void)c; (void)t;
    memcpy(g_req_to_rsp, m, sz);
    g_req_to_rsp_size = sz;
    return libspdm_responder_dispatch_message(g_rsp_ctx);
}
static libspdm_return_t req_recv(void *c, size_t *sz, void **m, uint64_t t)
{
    (void)c; (void)t;
    memcpy(*m, g_rsp_to_req, g_rsp_to_req_size);
    *sz = g_rsp_to_req_size;
    return LIBSPDM_STATUS_SUCCESS;
}
static libspdm_return_t rsp_recv(void *c, size_t *sz, void **m, uint64_t t)
{
    (void)c; (void)t;
    memcpy(*m, g_req_to_rsp, g_req_to_rsp_size);
    *sz = g_req_to_rsp_size;
    return LIBSPDM_STATUS_SUCCESS;
}
static libspdm_return_t rsp_send(void *c, size_t sz, const void *m, uint64_t t)
{
    (void)c; (void)t;
    memcpy(g_rsp_to_req, m, sz);
    g_rsp_to_req_size = sz;
    return LIBSPDM_STATUS_SUCCESS;
}

static void init_ctx_12(libspdm_context_t *ctx, bool is_req)
{
    void *sb;
    size_t sb_sz;

    libspdm_init_context(ctx);
    libspdm_register_transport_layer_func(
        ctx,
        LIBSPDM_MAX_SPDM_MSG_SIZE,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE,
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message,
        libspdm_transport_test_decode_message);

    if (is_req) {
        libspdm_register_device_io_func(ctx, req_send, req_recv);
        libspdm_register_device_buffer_func(ctx,
            LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
            LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
            req_acq_send, req_rel_send, req_acq_recv, req_rel_recv);
        ctx->local_context.is_requester = true;
    } else {
        libspdm_register_device_io_func(ctx, rsp_send, rsp_recv);
        libspdm_register_device_buffer_func(ctx,
            LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
            LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
            rsp_acq_send, rsp_rel_send, rsp_acq_recv, rsp_rel_recv);
        ctx->local_context.is_requester = false;
    }

    sb_sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    sb = malloc(sb_sz);
    assert(sb != NULL);
    libspdm_set_scratch_buffer(ctx, sb, sb_sz);

    /* SPDM 1.2 connection */
    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_12 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->connection_info.algorithm.aead_cipher_suite =
        SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM;
    ctx->connection_info.algorithm.key_schedule =
        SPDM_ALGORITHMS_KEY_SCHEDULE_SPDM;
    ctx->connection_info.algorithm.dhe_named_group = 0;
    /* SPDM 1.2 requires OPAQUE_DATA_FORMAT_1 to be negotiated */
    ctx->connection_info.algorithm.other_params_support =
        SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;

    /* Supported secured message version: one entry */
    ctx->local_context.secured_message_version.secured_message_version_count = 1;
    ctx->local_context.secured_message_version.secured_message_version[0] =
        SECURED_SPDM_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;

    if (is_req) {
        ctx->local_context.capability.flags |=
            SPDM_GET_CAPABILITIES_REQUEST_FLAGS_PSK_CAP_REQUESTER;
        ctx->local_context.capability.flags |=
            SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP;
        ctx->connection_info.capability.flags |=
            SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_PSK_CAP_RESPONDER;
        ctx->connection_info.capability.flags |=
            SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP;
    } else {
        ctx->local_context.capability.flags |=
            SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_PSK_CAP_RESPONDER;
        ctx->local_context.capability.flags |=
            SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP;
        ctx->connection_info.capability.flags |=
            SPDM_GET_CAPABILITIES_REQUEST_FLAGS_PSK_CAP_REQUESTER;
        ctx->connection_info.capability.flags |=
            SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP;
    }
}

int main(void)
{
    libspdm_context_t *req_ctx = malloc(libspdm_get_context_size());
    libspdm_context_t *rsp_ctx = malloc(libspdm_get_context_size());
    assert(req_ctx && rsp_ctx);

    init_ctx_12(req_ctx, true);
    init_ctx_12(rsp_ctx, false);

    /*
     * Trigger: clear secured_message_version_count on requester.
     * libspdm_get_opaque_data_supported_version_data_size() returns 0 when
     * count==0, so PSK_EXCHANGE is sent with opaque_length=0.
     * For SPDM 1.2, the spec requires version selection opaque data; the
     * responder MUST reject this with SPDM_ERROR_CODE_INVALID_REQUEST.
     */
    req_ctx->local_context.secured_message_version.secured_message_version_count = 0;

    g_rsp_ctx = rsp_ctx;

    uint32_t session_id = 0;
    libspdm_return_t status = libspdm_send_receive_psk_exchange(
        req_ctx,
        "TestPskHint", sizeof("TestPskHint"),
        SPDM_PSK_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH,
        0,
        &session_id,
        NULL, NULL);

    /* --- Evaluate result --- */
    printf("MC-BUG-1 reproduction result:\n");
    printf("  libspdm_send_receive_psk_exchange status: 0x%x\n", (unsigned)status);

    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        printf("  Exchange REJECTED (correct behavior — bug not triggered)\n");
        printf("  RESULT: REPRODUCTION FAILED (Level 0)\n");
        /* Clean up */
        void *sb; size_t sbs;
        libspdm_get_scratch_buffer(req_ctx, &sb, &sbs); free(sb);
        libspdm_get_scratch_buffer(rsp_ctx, &sb, &sbs); free(sb);
        free(req_ctx); free(rsp_ctx);
        return 1;
    }

    printf("  Exchange SUCCEEDED despite opaque_length=0 for SPDM 1.2 (BUG TRIGGERED)\n");
    printf("  session_id: 0x%08x\n", session_id);

    /* Inspect responder session version */
    libspdm_session_info_t *rsp_si =
        libspdm_get_session_info_via_session_id(rsp_ctx, session_id);
    libspdm_session_info_t *req_si =
        libspdm_get_session_info_via_session_id(req_ctx, session_id);

    if (rsp_si && rsp_si->secured_message_context) {
        libspdm_secured_message_context_t *rsp_sm =
            (libspdm_secured_message_context_t *)rsp_si->secured_message_context;
        printf("  Responder session secured_message_version: 0x%04x\n",
               (unsigned)rsp_sm->secured_message_version);
        if (rsp_sm->secured_message_version == 0) {
            printf("  CONFIRMED: responder session has version=0 (invalid)\n");
        }
    }
    if (req_si && req_si->secured_message_context) {
        libspdm_secured_message_context_t *req_sm =
            (libspdm_secured_message_context_t *)req_si->secured_message_context;
        printf("  Requester session secured_message_version: 0x%04x\n",
               (unsigned)req_sm->secured_message_version);
        if (req_sm->secured_message_version == 0) {
            printf("  CONFIRMED: requester session has version=0 (invalid)\n");
        }
    }

    printf("  RESULT: REPRODUCED (Level 0) — SPDM 1.2 PSK exchange with\n");
    printf("          opaque_length=0 succeeds; session version=0\n");

    void *sb; size_t sbs;
    libspdm_get_scratch_buffer(req_ctx, &sb, &sbs); free(sb);
    libspdm_get_scratch_buffer(rsp_ctx, &sb, &sbs); free(sb);
    free(req_ctx); free(rsp_ctx);
    return 0;
}
