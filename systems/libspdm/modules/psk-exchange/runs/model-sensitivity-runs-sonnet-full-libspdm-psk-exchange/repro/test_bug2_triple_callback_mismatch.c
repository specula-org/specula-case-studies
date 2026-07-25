/**
 * Reproduction test for MC-BUG-2:
 * Triple-call opaque callback version mismatch.
 *
 * Root cause: libspdm_get_response_psk_exchange calls the integrator's
 *   libspdm_psk_exchange_rsp_opaque_data callback THREE times:
 *     Call 1 (probe):  opaque_data=NULL, gets required size
 *     Call 2 (temp):   writes to response buffer header (temporary)
 *     Call 3 (final):  writes to correct ptr in response
 *
 *   secured_message_version is extracted from call-2 data and used to
 *   assign the session. Call 3 may return a DIFFERENT version, which
 *   is what the requester parses from the response. This produces a
 *   session-version mismatch: responder has call-2 version, requester
 *   has call-3 version.
 *
 * This test provides its own libspdm_psk_exchange_rsp_opaque_data that overrides
 * the default library implementation (Level 2 — state injection: the non-deterministic
 * callback that the interface contract permits but does not prohibit).
 * Because the test object file is linked before the static archive, the linker's
 * symbol resolution selects the test's definition over the library's.
 *
 * The wrapped callback returns:
 *   Call 1 (probe, NULL):       size only — no data written
 *   Call 2 (temp, non-NULL):    SECURED_SPDM_VERSION_11 in opaque data
 *   Call 3 (final, non-NULL):   SECURED_SPDM_VERSION_12 in opaque data
 *
 * Expected correct behavior:
 *   Both sessions have the same secured_message_version (call-3's version,
 *   since that is what's in the authenticated response).
 * Actual (buggy) behavior:
 *   Responder session = V11 (call-2);  Requester session = V12 (call-3).
 *   The mismatch is not detected at handshake time because the TH1 HMAC
 *   does not cover secured_message_version.
 *
 * Compile with the test file BEFORE the device-secret library so the linker's
 * first-definition-wins rule selects this override:
 *   gcc ... test_bug2_triple_callback_mismatch.c ... \
 *       -Wl,--start-group [libs] -Wl,--end-group \
 *       -o test_bug2
 */

#include "spdm_unit_test.h"
#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_secured_message_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "industry_standard/spdm_secured_message.h"

/* Required by tla_trace.h (included transitively by responder) */
FILE *g_tla_trace_fp = NULL;

#define BUG2_BUF_SIZE LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE

static uint8_t g_req_sr_buf[BUG2_BUF_SIZE];
static uint8_t g_rsp_sr_buf[BUG2_BUF_SIZE];
static uint8_t g_req_to_rsp[BUG2_BUF_SIZE];
static size_t  g_req_to_rsp_size;
static uint8_t g_rsp_to_req[BUG2_BUF_SIZE];
static size_t  g_rsp_to_req_size;

static libspdm_context_t *g_rsp_ctx_bug2 = NULL;

/* --- Buffer callbacks --- */
static libspdm_return_t b2_req_acq_send(void *c, void **b) { (void)c; *b = g_req_sr_buf; return LIBSPDM_STATUS_SUCCESS; }
static void b2_req_rel_send(void *c, const void *b) { (void)c; (void)b; }
static libspdm_return_t b2_req_acq_recv(void *c, void **b) { (void)c; *b = g_req_sr_buf; return LIBSPDM_STATUS_SUCCESS; }
static void b2_req_rel_recv(void *c, const void *b) { (void)c; (void)b; }
static libspdm_return_t b2_rsp_acq_send(void *c, void **b) { (void)c; *b = g_rsp_sr_buf; return LIBSPDM_STATUS_SUCCESS; }
static void b2_rsp_rel_send(void *c, const void *b) { (void)c; (void)b; }
static libspdm_return_t b2_rsp_acq_recv(void *c, void **b) { (void)c; *b = g_rsp_sr_buf; return LIBSPDM_STATUS_SUCCESS; }
static void b2_rsp_rel_recv(void *c, const void *b) { (void)c; (void)b; }

static libspdm_return_t b2_req_send(void *c, size_t sz, const void *m, uint64_t t)
{
    (void)c; (void)t;
    memcpy(g_req_to_rsp, m, sz);
    g_req_to_rsp_size = sz;
    return libspdm_responder_dispatch_message(g_rsp_ctx_bug2);
}
static libspdm_return_t b2_req_recv(void *c, size_t *sz, void **m, uint64_t t)
{
    (void)c; (void)t;
    memcpy(*m, g_rsp_to_req, g_rsp_to_req_size);
    *sz = g_rsp_to_req_size;
    return LIBSPDM_STATUS_SUCCESS;
}
static libspdm_return_t b2_rsp_recv(void *c, size_t *sz, void **m, uint64_t t)
{
    (void)c; (void)t;
    memcpy(*m, g_req_to_rsp, g_req_to_rsp_size);
    *sz = g_req_to_rsp_size;
    return LIBSPDM_STATUS_SUCCESS;
}
static libspdm_return_t b2_rsp_send(void *c, size_t sz, const void *m, uint64_t t)
{
    (void)c; (void)t;
    memcpy(g_rsp_to_req, m, sz);
    g_rsp_to_req_size = sz;
    return LIBSPDM_STATUS_SUCCESS;
}

/*
 * For SPDM 1.1, the opaque data uses secured_message_general_opaque_data_table_header_t
 * (8 bytes: spec_id + opaque_version + total_elements + reserved), NOT the SPDM 1.2
 * spdm_general_opaque_data_table_header_t (4 bytes: total_elements + reserved[3]).
 *
 * Opaque data layout (SPDM 1.1):
 *   secured_message_general_opaque_data_table_header_t  (8 bytes)
 *   secured_message_opaque_element_table_header_t       (4 bytes)
 *   secured_message_opaque_element_version_selection_t  (4 bytes)
 * = 16 bytes total (4-byte aligned)
 */
#define VERSION_SELECTION_OPAQUE_SIZE \
    (((sizeof(secured_message_general_opaque_data_table_header_t) + \
       sizeof(secured_message_opaque_element_table_header_t) + \
       sizeof(secured_message_opaque_element_version_selection_t)) + 3) & ~3)

/*
 * Intercept libspdm_psk_exchange_rsp_opaque_data via --wrap linker flag.
 * The static counter tracks non-NULL calls only (2nd = temp, 3rd = final).
 *
 * Returns true to indicate "I handle opaque data" (use_default=false path).
 * Returns false would fall through to the default opaque path (not what we want).
 */
static int g_nonnull_call_count = 0;

static void build_version_selection_opaque(void *buf, size_t *sz,
                                           spdm_version_number_t selected_ver)
{
    /* Use SPDM 1.1 format: secured_message_general_opaque_data_table_header_t */
    secured_message_general_opaque_data_table_header_t *gen_hdr = buf;
    secured_message_opaque_element_table_header_t *elem_hdr;
    secured_message_opaque_element_version_selection_t *ver_sel;

    memset(buf, 0, VERSION_SELECTION_OPAQUE_SIZE);

    gen_hdr->spec_id = SECURED_MESSAGE_OPAQUE_DATA_SPEC_ID;
    gen_hdr->opaque_version = SECURED_MESSAGE_OPAQUE_VERSION;
    gen_hdr->total_elements = 1;
    gen_hdr->reserved = 0;

    elem_hdr = (void *)(gen_hdr + 1);
    elem_hdr->id = SPDM_REGISTRY_ID_DMTF;
    elem_hdr->vendor_len = 0;
    elem_hdr->opaque_element_data_len =
        sizeof(secured_message_opaque_element_version_selection_t);

    ver_sel = (void *)(elem_hdr + 1);
    ver_sel->sm_data_version = SECURED_MESSAGE_OPAQUE_ELEMENT_SMDATA_DATA_VERSION;
    ver_sel->sm_data_id = SECURED_MESSAGE_OPAQUE_ELEMENT_SMDATA_ID_VERSION_SELECTION;
    ver_sel->selected_version = selected_ver;

    *sz = VERSION_SELECTION_OPAQUE_SIZE;
}

bool libspdm_psk_exchange_rsp_opaque_data(
    void *spdm_context,
    const void *psk_hint,
    uint16_t psk_hint_size,
    spdm_version_number_t spdm_version,
    uint8_t measurement_hash_type,
    const void *req_opaque_data,
    size_t req_opaque_data_size,
    void *opaque_data,
    size_t *opaque_data_size)
{
    (void)spdm_context; (void)psk_hint; (void)psk_hint_size;
    (void)spdm_version; (void)measurement_hash_type;
    (void)req_opaque_data; (void)req_opaque_data_size;

    if (opaque_data == NULL) {
        /* Probe call: report required size, don't write */
        *opaque_data_size = VERSION_SELECTION_OPAQUE_SIZE;
        return true;
    }

    g_nonnull_call_count++;
    if (g_nonnull_call_count == 1) {
        /* Call 2 (temp): write V11 to response buffer header area */
        printf("  [wrap] Call 2 (temp): returning SECURED_SPDM_VERSION_11 (0x1100)\n");
        build_version_selection_opaque(opaque_data, opaque_data_size,
                                       SECURED_SPDM_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT);
    } else {
        /* Call 3 (final): write V12 to ptr — DIFFERENT from call 2 */
        printf("  [wrap] Call 3 (final): returning SECURED_SPDM_VERSION_12 (0x1200)\n");
        build_version_selection_opaque(opaque_data, opaque_data_size,
                                       SECURED_SPDM_VERSION_12 << SPDM_VERSION_NUMBER_SHIFT_BIT);
    }
    return true;
}

static void init_ctx_11(libspdm_context_t *ctx, bool is_req)
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
        libspdm_register_device_io_func(ctx, b2_req_send, b2_req_recv);
        libspdm_register_device_buffer_func(ctx,
            LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
            LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
            b2_req_acq_send, b2_req_rel_send, b2_req_acq_recv, b2_req_rel_recv);
        ctx->local_context.is_requester = true;
    } else {
        libspdm_register_device_io_func(ctx, b2_rsp_send, b2_rsp_recv);
        libspdm_register_device_buffer_func(ctx,
            LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
            LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
            b2_rsp_acq_send, b2_rsp_rel_send, b2_rsp_acq_recv, b2_rsp_rel_recv);
        ctx->local_context.is_requester = false;
    }

    sb_sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    sb = malloc(sb_sz);
    assert(sb != NULL);
    libspdm_set_scratch_buffer(ctx, sb, sb_sz);

    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->connection_info.algorithm.aead_cipher_suite =
        SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM;
    ctx->connection_info.algorithm.key_schedule =
        SPDM_ALGORITHMS_KEY_SCHEDULE_SPDM;
    ctx->connection_info.algorithm.dhe_named_group = 0;

    /*
     * Both V11 and V12 supported so that:
     * - call-2's V11 passes libspdm_process_opaque_data_version_selection_data (responder)
     * - call-3's V12 passes libspdm_process_opaque_data_version_selection_data (requester)
     */
    ctx->local_context.secured_message_version.secured_message_version_count = 2;
    ctx->local_context.secured_message_version.secured_message_version[0] =
        SECURED_SPDM_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->local_context.secured_message_version.secured_message_version[1] =
        SECURED_SPDM_VERSION_12 << SPDM_VERSION_NUMBER_SHIFT_BIT;

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

    init_ctx_11(req_ctx, true);
    init_ctx_11(rsp_ctx, false);
    g_rsp_ctx_bug2 = rsp_ctx;

    printf("MC-BUG-2 reproduction (Level 2: non-deterministic opaque callback):\n");

    uint32_t session_id = 0;
    libspdm_return_t status = libspdm_send_receive_psk_exchange(
        req_ctx,
        "TestPskHint", sizeof("TestPskHint"),
        SPDM_PSK_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH,
        0,
        &session_id,
        NULL, NULL);

    printf("  libspdm_send_receive_psk_exchange status: 0x%x\n", (unsigned)status);

    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        printf("  Exchange FAILED — mismatch detected at handshake time\n");
        printf("  (This would mean the HMAC covers secured_message_version — not currently the case)\n");
        /* Inspect why it failed */
        printf("  RESULT: REPRODUCTION FAILED (exchange rejected — investigate why)\n");
        void *sb; size_t sbs;
        libspdm_get_scratch_buffer(req_ctx, &sb, &sbs); free(sb);
        libspdm_get_scratch_buffer(rsp_ctx, &sb, &sbs); free(sb);
        free(req_ctx); free(rsp_ctx);
        return 1;
    }

    printf("  Exchange SUCCEEDED (expected — HMAC does not cover version)\n");
    printf("  session_id: 0x%08x\n", session_id);

    /* Inspect session versions on both sides */
    libspdm_session_info_t *rsp_si =
        libspdm_get_session_info_via_session_id(rsp_ctx, session_id);
    libspdm_session_info_t *req_si =
        libspdm_get_session_info_via_session_id(req_ctx, session_id);

    spdm_version_number_t rsp_ver = 0, req_ver = 0;

    if (rsp_si && rsp_si->secured_message_context) {
        libspdm_secured_message_context_t *sm =
            (libspdm_secured_message_context_t *)rsp_si->secured_message_context;
        rsp_ver = sm->secured_message_version;
        printf("  Responder session secured_message_version: 0x%04x\n", (unsigned)rsp_ver);
    }
    if (req_si && req_si->secured_message_context) {
        libspdm_secured_message_context_t *sm =
            (libspdm_secured_message_context_t *)req_si->secured_message_context;
        req_ver = sm->secured_message_version;
        printf("  Requester session secured_message_version: 0x%04x\n", (unsigned)req_ver);
    }

    if (rsp_ver != req_ver) {
        printf("  MISMATCH: responder=0x%04x, requester=0x%04x\n",
               (unsigned)rsp_ver, (unsigned)req_ver);
        printf("  RESULT: REPRODUCED (Level 2) — callback non-determinism causes\n");
        printf("          session-version split; subsequent secured messages will\n");
        printf("          use incompatible parameters\n");
    } else {
        printf("  Versions match: 0x%04x — mismatch not triggered\n", (unsigned)rsp_ver);
        printf("  RESULT: REPRODUCTION FAILED\n");
    }

    void *sb; size_t sbs;
    libspdm_get_scratch_buffer(req_ctx, &sb, &sbs); free(sb);
    libspdm_get_scratch_buffer(rsp_ctx, &sb, &sbs); free(sb);
    free(req_ctx); free(rsp_ctx);
    return (rsp_ver != req_ver) ? 0 : 1;
}
