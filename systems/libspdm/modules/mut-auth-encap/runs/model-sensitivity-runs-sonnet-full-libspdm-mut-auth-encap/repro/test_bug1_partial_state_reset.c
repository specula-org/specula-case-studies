/**
 * test_bug1_partial_state_reset.c
 *
 * Reproduction test for BUG-1 in libspdm encapsulated mutual authentication:
 *
 *   After a non-NOT_READY error from libspdm_process_encapsulated_response,
 *   the error handlers at libspdm_rsp_encap_response.c:388-395 (GET_ENCAP_REQ path)
 *   and :509-515 (DELIVER_ENCAP_RESP path) reset response_state to NORMAL but do NOT
 *   zero encap_context.current_request_op_code. This violates the invariant:
 *
 *     NoPartialAuthState: response_state = RS_NORMAL => current_request_op_code = 0
 *
 * BUG LOCATIONS:
 *   libspdm_rsp_encap_response.c:509-515 (DELIVER path, tested here)
 *   libspdm_rsp_encap_response.c:388-395 (GET_ENCAP_REQ path, same defect)
 *
 * Scenario (matches MC counterexample, BASIC_PK / VAR_BASIC_PK variant):
 *   request_op_code_sequence = [SPDM_CHALLENGE, OP_NONE]
 *
 *   Step 1: libspdm_init_basic_mut_auth_encap_state()
 *           → current_request_op_code = 0, response_state = RS_PROCESSING_ENCAP
 *
 *   Step 2: GET_ENCAPSULATED_REQUEST
 *           → libspdm_process_encapsulated_response(ctx, 0, NULL, ...)
 *             moves op_code to SPDM_CHALLENGE, calls get_encap_request_challenge()
 *           → current_request_op_code = SPDM_CHALLENGE, response_state = RS_PROCESSING_ENCAP
 *
 *   Step 3: DELIVER_ENCAPSULATED_RESPONSE with wrong response code (SPDM_DIGESTS)
 *           → libspdm_process_encap_response_challenge_auth() returns INVALID_MSG_FIELD
 *           → error path at :509-515 fires:
 *               response_state = RS_NORMAL            ← reset
 *               current_request_op_code = SPDM_CHALLENGE  ← NOT zeroed (BUG)
 *
 * Observable: response_state == NORMAL AND current_request_op_code != 0 simultaneously.
 *
 * Exit codes:
 *   0  = REPRODUCTION FAILED (bug not observed; behavior may have been fixed)
 *   1  = BUG CONFIRMED (inconsistent state observed)
 *   2  = TEST SETUP ERROR
 */

/* Must be defined before tla_trace.h is included so that it emits
 * global-variable definitions rather than extern declarations. */
#define TLA_TRACE_DEFINE_GLOBALS

#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_common_lib.h"
#ifdef LIBSPDM_TRACE_ENCAP
#include "tla_trace.h"   /* defines g_tla_trace_file, g_tla_variant_str, g_tla_ts_counter */
#endif
#include "spdm_device_secret_lib_internal.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

#define USE_HASH_ALGO  SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256
#define USE_ASYM_ALGO  SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048
#define USE_REQ_ASYM   SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048

#ifndef LIBSPDM_MAX_SPDM_MSG_SIZE
#define LIBSPDM_MAX_SPDM_MSG_SIZE 0x1200
#endif
#ifndef LIBSPDM_MAX_CERT_CHAIN_SIZE
#define LIBSPDM_MAX_CERT_CHAIN_SIZE 0x1000
#endif

/* ──── device buffer stubs ──────────────────────────────────────────────── */
static uint8_t g_sender_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
static uint8_t g_receiver_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];

static libspdm_return_t acq_sender(void *ctx, void **msg)
{ (void)ctx; *msg = g_sender_buf; return LIBSPDM_STATUS_SUCCESS; }
static void rel_sender(void *ctx, const void *msg) { (void)ctx; (void)msg; }
static libspdm_return_t acq_receiver(void *ctx, void **msg)
{ (void)ctx; *msg = g_receiver_buf; return LIBSPDM_STATUS_SUCCESS; }
static void rel_receiver(void *ctx, const void *msg) { (void)ctx; (void)msg; }

/* file-scope stubs for spdm_device_secret_lib_sample helpers */
bool libspdm_read_input_file(const char *file_name, void **file_data, size_t *file_size)
{
    FILE *fp = fopen(file_name, "rb");
    if (!fp) { *file_data = NULL; return false; }
    fseek(fp, 0, SEEK_END);
    *file_size = (size_t)ftell(fp);
    *file_data = malloc(*file_size);
    if (!*file_data) { fclose(fp); return false; }
    fseek(fp, 0, SEEK_SET);
    (void)fread(*file_data, 1, *file_size, fp);
    fclose(fp);
    return true;
}
bool libspdm_write_output_file(const char *file_name, const void *data, size_t sz)
{ (void)file_name; (void)data; (void)sz; return false; }
void libspdm_dump_hex_str(const uint8_t *buf, size_t sz)
{ (void)buf; (void)sz; }

/* ──── context creation ─────────────────────────────────────────────────── */
static libspdm_context_t *create_context(void)
{
    libspdm_context_t *ctx;
    void *scratch;
    size_t scratch_size;

    ctx = malloc(libspdm_get_context_size());
    assert(ctx != NULL);
    libspdm_init_context(ctx);
    libspdm_register_device_buffer_func(ctx,
        LIBSPDM_MAX_SPDM_MSG_SIZE, LIBSPDM_MAX_SPDM_MSG_SIZE,
        acq_sender, rel_sender, acq_receiver, rel_receiver);
    ctx->local_context.capability.max_spdm_msg_size = LIBSPDM_MAX_SPDM_MSG_SIZE;
    scratch_size = libspdm_get_sizeof_required_scratch_buffer(ctx);
    scratch = malloc(scratch_size);
    assert(scratch != NULL);
    libspdm_set_scratch_buffer(ctx, scratch, scratch_size);
    return ctx;
}

/* ──── main ─────────────────────────────────────────────────────────────── */
int main(void)
{
    libspdm_context_t *ctx;
    libspdm_return_t   status;
    uint8_t            req_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    uint8_t            resp_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t             req_size;
    size_t             resp_size;
    uint8_t           *ptr;
    void              *pub_key_data = NULL;
    size_t             pub_key_size  = 0;
    spdm_get_encapsulated_request_request_t get_encap_req;

    printf("=== BUG-1 Reproduction: partial state reset after encap error ===\n");
    printf("File: libspdm_rsp_encap_response.c:509-515\n");
    printf("Invariant: NoPartialAuthState (response_state=NORMAL => cur_op=0)\n\n");

    /* ── context setup (BASIC_PK variant: PUB_KEY_ID_CAP, no cert chain) ── */
    ctx = create_context();
    ctx->connection_info.version =
        (uint16_t)(SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT);
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.algorithm.base_hash_algo     = USE_HASH_ALGO;
    ctx->connection_info.algorithm.base_asym_algo     = USE_ASYM_ALGO;
    ctx->connection_info.algorithm.req_base_asym_alg  = USE_REQ_ASYM;
    ctx->connection_info.algorithm.req_pqc_asym_alg   = 0;

    /* Responder (local) caps */
    ctx->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCAP_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP  |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MUT_AUTH_CAP;

    /* Requester (peer) caps — BASIC_PK: PUB_KEY_ID_CAP is set */
    ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCAP_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP  |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_PUB_KEY_ID_CAP;

    /* Provision requester's public key (needed for CHALLENGE signing context) */
    libspdm_read_requester_public_key(USE_REQ_ASYM, &pub_key_data, &pub_key_size);
    if (pub_key_data == NULL) {
        printf("SETUP ERROR: could not read requester public key\n");
        return 2;
    }
    ctx->local_context.peer_public_key_provision      = pub_key_data;
    ctx->local_context.peer_public_key_provision_size = pub_key_size;
    ctx->encap_context.req_slot_id = 0xFF;  /* required for BASIC_PK */

    libspdm_reset_message_mut_b(ctx);
    libspdm_reset_message_mut_c(ctx);

    /* ── Step 1: init encap state ────────────────────────────────────────── */
    libspdm_init_basic_mut_auth_encap_state(ctx);

    printf("After init:\n");
    printf("  current_request_op_code = 0x%02x (expected 0x00)\n",
           ctx->encap_context.current_request_op_code);
    printf("  response_state          = %d  (expected PROCESSING_ENCAP=%d)\n",
           ctx->response_state, LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP);

    if (ctx->encap_context.current_request_op_code != 0) {
        printf("SETUP ERROR: cur_op must be 0 after init\n");
        return 2;
    }
    if (ctx->response_state != LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP) {
        printf("SETUP ERROR: expected RS_PROCESSING_ENCAP after init\n");
        return 2;
    }

    /* ── Step 2: GET_ENCAPSULATED_REQUEST ────────────────────────────────── */
    memset(&get_encap_req, 0, sizeof(get_encap_req));
    get_encap_req.header.spdm_version           = SPDM_MESSAGE_VERSION_11;
    get_encap_req.header.request_response_code  = SPDM_GET_ENCAPSULATED_REQUEST;

    resp_size = sizeof(resp_buf);
    status = libspdm_get_response_encapsulated_request(ctx,
        sizeof(get_encap_req), &get_encap_req, &resp_size, resp_buf);
    if (status != LIBSPDM_STATUS_SUCCESS) {
        printf("SETUP ERROR: GET_ENCAP_REQ failed status=0x%x\n", (unsigned)status);
        return 2;
    }

    printf("\nAfter GET_ENCAP_REQ:\n");
    printf("  current_request_op_code = 0x%02x (expected SPDM_CHALLENGE=0x%02x)\n",
           ctx->encap_context.current_request_op_code, SPDM_CHALLENGE);
    printf("  response_state          = %d  (expected PROCESSING_ENCAP=%d)\n",
           ctx->response_state, LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP);

    if (ctx->encap_context.current_request_op_code != SPDM_CHALLENGE) {
        printf("SETUP ERROR: expected cur_op=SPDM_CHALLENGE after GET_ENCAP_REQ\n");
        return 2;
    }

    /* ── Step 3: DELIVER_ENCAPSULATED_RESPONSE with wrong code ──────────── */
    /* We send SPDM_DIGESTS where SPDM_CHALLENGE_AUTH is expected.
     * libspdm_process_encap_response_challenge_auth() will return INVALID_MSG_FIELD.
     * This is NOT LIBSPDM_STATUS_NOT_READY_PEER, so the partial-reset path fires:
     *   response_state := NORMAL           ← correct
     *   current_request_op_code stays  ← BUG (should be zeroed)
     */
    ptr = req_buf;
    {
        spdm_deliver_encapsulated_response_request_t *hdr =
            (spdm_deliver_encapsulated_response_request_t *)ptr;
        hdr->header.spdm_version           = SPDM_MESSAGE_VERSION_11;
        hdr->header.request_response_code  = SPDM_DELIVER_ENCAPSULATED_RESPONSE;
        hdr->header.param1                 = ctx->encap_context.request_id; /* must match */
        hdr->header.param2                 = 0;
        ptr += sizeof(spdm_deliver_encapsulated_response_request_t);
    }
    {
        /* Wrong response code: SPDM_DIGESTS instead of SPDM_CHALLENGE_AUTH */
        spdm_message_header_t *bad_rsp = (spdm_message_header_t *)ptr;
        bad_rsp->spdm_version           = SPDM_MESSAGE_VERSION_11;
        bad_rsp->request_response_code  = SPDM_DIGESTS;  /* wrong; expects SPDM_CHALLENGE_AUTH */
        bad_rsp->param1                 = 0;
        bad_rsp->param2                 = 0;
        ptr += sizeof(spdm_message_header_t);
    }
    req_size  = (size_t)(ptr - req_buf);
    resp_size = sizeof(resp_buf);

    status = libspdm_get_response_encapsulated_response_ack(ctx,
        req_size, req_buf, &resp_size, resp_buf);
    /* The function returns LIBSPDM_STATUS_SUCCESS: it generates an error response
     * internally. The bug is observable in the context state, not the return code. */
    printf("\nAfter DELIVER (wrong code, triggers error path at :509-515):\n");
    printf("  return status           = 0x%x  (LIBSPDM_STATUS_SUCCESS expected)\n",
           (unsigned)status);
    printf("  current_request_op_code = 0x%02x  (expected 0x00 if correct; BUG if non-zero)\n",
           ctx->encap_context.current_request_op_code);
    printf("  response_state          = %d  (expected NORMAL=%d)\n",
           ctx->response_state, LIBSPDM_RESPONSE_STATE_NORMAL);

    /* ── BUG check: NoPartialAuthState violated ──────────────────────────── */
    bool rsp_normal  = (ctx->response_state == LIBSPDM_RESPONSE_STATE_NORMAL);
    bool op_nonzero  = (ctx->encap_context.current_request_op_code != 0);

    if (rsp_normal && op_nonzero) {
        printf("\n[RESULT] BUG CONFIRMED\n");
        printf("  NoPartialAuthState VIOLATED:\n");
        printf("  response_state = NORMAL (%d)\n", ctx->response_state);
        printf("  current_request_op_code = 0x%02x (expected 0x00)\n",
               ctx->encap_context.current_request_op_code);
        printf("  Root cause: libspdm_rsp_encap_response.c:509-515 resets\n");
        printf("  response_state but omits:\n");
        printf("    spdm_context->encap_context.current_request_op_code = 0x00;\n");
        printf("  Fix: add that line at :510 and :389.\n");
        free(pub_key_data);
        return 1;   /* BUG CONFIRMED */
    }

    printf("\n[RESULT] REPRODUCTION FAILED — state is consistent.\n");
    printf("  Bug may have been fixed, or test setup is incorrect.\n");
    free(pub_key_data);
    return 0;
}
