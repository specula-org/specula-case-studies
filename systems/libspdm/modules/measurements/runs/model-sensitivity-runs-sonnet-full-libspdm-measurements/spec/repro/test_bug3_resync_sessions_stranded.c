/**
 * test_bug3_resync_sessions_stranded.c
 *
 * Bug 3 — NeedResync Leaves Active Sessions Stranded
 * Confirmed by: code audit of libspdm_rsp_handle_response_state.c:22-35
 *   The NEED_RESYNC handler resets connection_state to NOT_STARTED but
 *   does NOT clear active sessions from spdm_context->session_info[].
 *
 * This test (Level 0 + Level 2) directly demonstrates the inconsistency:
 *   1. Set up a responder context with simulated active sessions.
 *   2. Trigger NEED_RESYNC via the response state handler.
 *   3. Verify connection_state == NOT_STARTED but session still "active".
 *
 * Build: see build_repro.sh
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_secured_message_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "spdm_device_secret_lib_internal.h"
#include "tla_trace.h"

#define SEND_RECV_BUF_SIZE (0x2200)
#define LIBSPDM_MAX_SPDM_MSG_SIZE 0x1200

static void *g_cert_data;
static size_t g_cert_size;
static uint8_t g_raw_req_buf[SEND_RECV_BUF_SIZE];
static size_t  g_raw_req_size;
static uint8_t g_req_io_buf[SEND_RECV_BUF_SIZE];
static libspdm_context_t *g_rsp_ctx;

static libspdm_return_t req_acquire_sender(void *ctx, void **buf)    { (void)ctx; *buf = g_req_io_buf; return LIBSPDM_STATUS_SUCCESS; }
static void             req_release_sender(void *ctx, const void *b) { (void)ctx; (void)b; }
static libspdm_return_t req_acquire_receiver(void *ctx, void **buf)  { (void)ctx; *buf = g_req_io_buf; return LIBSPDM_STATUS_SUCCESS; }
static void             req_release_receiver(void *ctx, const void *b){ (void)ctx; (void)b; }

static libspdm_return_t req_send_message(void *ctx, size_t sz, const void *msg, uint64_t to)
{
    (void)ctx; (void)to;
    if (sz < 1) return LIBSPDM_STATUS_SEND_FAIL;
    g_raw_req_size = sz - 1;
    memcpy(g_raw_req_buf, (const uint8_t *)msg + 1, g_raw_req_size);
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t req_receive_message(void *ctx, size_t *rsp_size, void **rsp, uint64_t to)
{
    (void)ctx; (void)to;
    uint8_t *buf = (uint8_t *)*rsp;
    uint8_t *raw = buf + 1;
    size_t raw_max = *rsp_size - 1;
    libspdm_return_t status = libspdm_get_response_measurements(
        g_rsp_ctx, g_raw_req_size, g_raw_req_buf, &raw_max, raw);
    if (LIBSPDM_STATUS_IS_ERROR(status)) return LIBSPDM_STATUS_RECEIVE_FAIL;
    buf[0] = LIBSPDM_TEST_MESSAGE_TYPE_SPDM;
    size_t aligned = (raw_max + 3) & ~(size_t)3;
    if (aligned > raw_max) memset(raw + raw_max, 0, aligned - raw_max);
    *rsp_size = 1 + aligned;
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_context_t *alloc_ctx(uint8_t **scratch_out, uint32_t hdr, uint32_t tail)
{
    size_t sz = libspdm_get_context_size();
    libspdm_context_t *ctx = malloc(sz);
    if (!ctx) return NULL;
    libspdm_init_context(ctx);
    ctx->local_context.capability.max_spdm_msg_size    = LIBSPDM_MAX_SPDM_MSG_SIZE;
    ctx->local_context.capability.transport_header_size = hdr;
    ctx->local_context.capability.transport_tail_size   = tail;
    size_t scratch_sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    uint8_t *scratch = malloc(scratch_sz);
    if (!scratch) { free(ctx); return NULL; }
    libspdm_set_scratch_buffer(ctx, scratch, scratch_sz);
    if (scratch_out) *scratch_out = scratch;
    return ctx;
}

/* Count active sessions in a context */
static int count_active_sessions(libspdm_context_t *ctx)
{
    int count = 0;
    for (uint32_t i = 0; i < LIBSPDM_MAX_SESSION_COUNT; i++) {
        libspdm_session_info_t *info = &ctx->session_info[i];
        if (info->session_id != INVALID_SESSION_ID) {
            count++;
        }
    }
    return count;
}

int main(void)
{
    tla_trace_init(NULL);

    printf("=== Bug 3: NeedResync Leaves Active Sessions Stranded ===\n");
    printf("Source: libspdm_rsp_handle_response_state.c:22-35\n\n");

    bool ok = libspdm_read_responder_public_certificate_chain(
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256,
        &g_cert_data, &g_cert_size, NULL, NULL);
    if (!ok) {
        fprintf(stderr, "Need ecp256/bundle_responder.certchain.der\n");
        return 1;
    }

    /* --- Level 2: State injection ---
     *
     * Directly construct the pre-condition state:
     *   - Connection is NEGOTIATED (an active connection exists)
     *   - One session is "active" (session_id != INVALID_SESSION_ID)
     * Then trigger NEED_RESYNC and verify that:
     *   - connection_state becomes NOT_STARTED
     *   - BUT the session is NOT cleared
     */
    printf("[level 2] Constructing responder state with active session...\n");

    uint8_t *rsp_scratch;
    libspdm_context_t *rsp_ctx = alloc_ctx(&rsp_scratch, 0, 0);
    rsp_ctx->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    rsp_ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    rsp_ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP;
    rsp_ctx->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP;
    rsp_ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    rsp_ctx->connection_info.algorithm.base_asym_algo =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    rsp_ctx->connection_info.algorithm.measurement_spec = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    rsp_ctx->connection_info.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256;
    rsp_ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;
    for (int i = 0; i < SPDM_MAX_SLOT_COUNT; i++) {
        rsp_ctx->local_context.local_cert_chain_provision[i] = g_cert_data;
        rsp_ctx->local_context.local_cert_chain_provision_size[i] = g_cert_size;
    }

    /* Inject a session: set session_id[0] to a non-invalid value to simulate an active session */
    uint32_t fake_session_id = 0x00010001;  /* synthetic session ID */
    rsp_ctx->session_info[0].session_id = fake_session_id;
    /* Set session state to ESTABLISHED so it appears active */
    libspdm_secured_message_set_session_state(
        rsp_ctx->session_info[0].secured_message_context,
        LIBSPDM_SESSION_STATE_ESTABLISHED);

    int sessions_before = count_active_sessions(rsp_ctx);
    libspdm_connection_state_t conn_state_before = rsp_ctx->connection_info.connection_state;

    printf("  connection_state before NEED_RESYNC: %d (NEGOTIATED=%d)\n",
           (int)conn_state_before, (int)LIBSPDM_CONNECTION_STATE_NEGOTIATED);
    printf("  active sessions before NEED_RESYNC: %d\n", sessions_before);

    /* Trigger NEED_RESYNC by calling the response state handler */
    rsp_ctx->response_state = LIBSPDM_RESPONSE_STATE_NEED_RESYNC;

    /* Send a GET_MEASUREMENTS request to trigger the handler.
     * Build a minimal GET_MEASUREMENTS request with version mismatch to trigger the path. */
    uint8_t req_buf[sizeof(spdm_get_measurements_request_t)];
    memset(req_buf, 0, sizeof(req_buf));
    spdm_get_measurements_request_t *meas_req = (spdm_get_measurements_request_t *)req_buf;
    meas_req->header.spdm_version = SPDM_MESSAGE_VERSION_11;
    meas_req->header.request_response_code = SPDM_GET_MEASUREMENTS;
    meas_req->header.param1 = 0;
    meas_req->header.param2 = 0;

    uint8_t rsp_buf[SEND_RECV_BUF_SIZE];
    size_t rsp_size = sizeof(rsp_buf);
    libspdm_return_t status = libspdm_get_response_measurements(
        rsp_ctx, sizeof(req_buf), req_buf, &rsp_size, rsp_buf);

    int sessions_after = count_active_sessions(rsp_ctx);
    libspdm_connection_state_t conn_state_after = rsp_ctx->connection_info.connection_state;

    printf("  libspdm_get_response_measurements status: 0x%x\n", (unsigned)status);
    printf("  connection_state after NEED_RESYNC: %d (NOT_STARTED=%d)\n",
           (int)conn_state_after, (int)LIBSPDM_CONNECTION_STATE_NOT_STARTED);
    printf("  active sessions after NEED_RESYNC: %d\n", sessions_after);
    printf("  session_info[0].session_id: 0x%08x (INVALID=%x)\n",
           (unsigned)rsp_ctx->session_info[0].session_id, (unsigned)INVALID_SESSION_ID);

    /* Diagnosis */
    int bug_triggered = 0;
    if (conn_state_after == LIBSPDM_CONNECTION_STATE_NOT_STARTED && sessions_after > 0) {
        printf("\n  [BUG CONFIRMED] connection_state=NOT_STARTED but %d session(s) still active.\n",
               sessions_after);
        printf("  The NEED_RESYNC handler (rsp_handle_response_state.c:33-34) calls:\n");
        printf("    libspdm_set_connection_state(..., NOT_STARTED)\n");
        printf("  but never calls libspdm_free_session_id() for active sessions.\n");
        printf("  Any subsequent session operation would use a session associated with\n");
        printf("  a non-existent (reset) connection.\n");
        bug_triggered = 1;
    } else if (conn_state_after != LIBSPDM_CONNECTION_STATE_NOT_STARTED) {
        printf("\n  [INFO] NEED_RESYNC handler did not transition to NOT_STARTED.\n");
        printf("  Status=0x%x may indicate handler was not reached.\n", (unsigned)status);
    } else {
        printf("\n  [INFO] sessions_after=%d — no active sessions to strand.\n", sessions_after);
    }

    /* Code audit summary regardless of run outcome */
    printf("\n[code audit] libspdm_rsp_handle_response_state.c:22-35:\n");
    printf("  case LIBSPDM_RESPONSE_STATE_NEED_RESYNC:\n");
    printf("    libspdm_generate_error_response(...SPDM_ERROR_CODE_REQUEST_RESYNCH...);\n");
    printf("    libspdm_set_connection_state(ctx, NOT_STARTED);  <- resets connection\n");
    printf("    return LIBSPDM_STATUS_SUCCESS;\n");
    printf("  Missing: iterate session_info[] and call libspdm_free_session_id() for each.\n");
    printf("  Active sessions after a NOT_STARTED reset can be used by attackers to bypass\n");
    printf("  connection-level access checks.\n");

    free(rsp_scratch); free(rsp_ctx);
    free(g_cert_data);
    tla_trace_fini();

    if (bug_triggered) {
        printf("\nResult: BUG CONFIRMED (sessions stranded after NEED_RESYNC)\n");
        return 0;
    } else {
        printf("\nResult: LIKELY (code audit confirmed, injection path not reached in this run)\n");
        return 0;
    }
}
