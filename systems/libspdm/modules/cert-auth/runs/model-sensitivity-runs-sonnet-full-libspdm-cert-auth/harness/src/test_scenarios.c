/*
 * test_scenarios.c — libspdm CHALLENGE auth TLA+ trace harness
 *
 * Standalone executable: no cmocka, no external test framework.
 * Bidirectional loopback transport: requester send_message drives
 * libspdm_responder_dispatch_message on the responder in-process.
 *
 * Scenarios:
 *   1. happy_path  — full VCA → GetDigests → GetCertificate → Challenge
 *   2. no_cert_challenge — VCA → GetDigests → Challenge (skip GetCertificate)
 *
 * Build: see harness/CMakeLists.txt
 * Run: run.sh from build directory; must be executed from unit_test/sample_key/
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>

#include "hal/base.h"
#include "hal/library/memlib.h"
#include "library/spdm_requester_lib.h"
#include "library/spdm_responder_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "internal/libspdm_common_lib.h"
#include "spdm_device_secret_lib_internal.h"

#include "tla_trace.h"

/* ─── algorithms ─────────────────────────────────────────────────────────── */
#define TEST_HASH_ALGO   SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256
#define TEST_ASYM_ALGO   SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256

/* Required by spdm_device_secret_lib_sample read functions */
uint32_t m_libspdm_use_hash_algo = TEST_HASH_ALGO;
uint32_t m_libspdm_use_asym_algo = TEST_ASYM_ALGO;
uint16_t m_libspdm_use_req_asym_algo = SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048;

/* ─── transport sizes ────────────────────────────────────────────────────── */
#define TRANSPORT_HEADER_SIZE  LIBSPDM_TEST_TRANSPORT_HEADER_SIZE
#define TRANSPORT_TAIL_SIZE    LIBSPDM_TEST_TRANSPORT_TAIL_SIZE
#define MAX_MSG_SIZE           0x1200

#define POOL_SIZE (MAX_MSG_SIZE + TRANSPORT_HEADER_SIZE + TRANSPORT_TAIL_SIZE + 64)
#define TRANSFER_BUF_SIZE POOL_SIZE

/* ─── global state for loopback transport ────────────────────────────────── */
static uint8_t  g_req_transfer[TRANSFER_BUF_SIZE];
static size_t   g_req_transfer_size;
static uint8_t  g_rsp_transfer[TRANSFER_BUF_SIZE];
static size_t   g_rsp_transfer_size;

/* separate buffer pools for req and rsp contexts */
static uint8_t  g_req_pool[POOL_SIZE];
static uint8_t  g_rsp_pool[POOL_SIZE];
static bool     g_req_pool_sender_busy;
static bool     g_rsp_pool_sender_busy;
static bool     g_req_pool_receiver_busy;
static bool     g_rsp_pool_receiver_busy;

/* forward declaration for req_send_message */
static void    *g_rsp_ctx;

/* ─── requester buffer management ────────────────────────────────────────── */
static libspdm_return_t req_acquire_sender_buffer(void *ctx, void **ptr)
{
    (void)ctx;
    g_req_pool_sender_busy = true;
    *ptr = g_req_pool;
    return LIBSPDM_STATUS_SUCCESS;
}

static void req_release_sender_buffer(void *ctx, const void *ptr)
{
    (void)ctx; (void)ptr;
    g_req_pool_sender_busy = false;
}

static libspdm_return_t req_acquire_receiver_buffer(void *ctx, void **ptr)
{
    (void)ctx;
    g_req_pool_receiver_busy = true;
    *ptr = g_req_pool;
    return LIBSPDM_STATUS_SUCCESS;
}

static void req_release_receiver_buffer(void *ctx, const void *ptr)
{
    (void)ctx; (void)ptr;
    g_req_pool_receiver_busy = false;
}

/* ─── responder buffer management ────────────────────────────────────────── */
static libspdm_return_t rsp_acquire_sender_buffer(void *ctx, void **ptr)
{
    (void)ctx;
    g_rsp_pool_sender_busy = true;
    *ptr = g_rsp_pool;
    return LIBSPDM_STATUS_SUCCESS;
}

static void rsp_release_sender_buffer(void *ctx, const void *ptr)
{
    (void)ctx; (void)ptr;
    g_rsp_pool_sender_busy = false;
}

static libspdm_return_t rsp_acquire_receiver_buffer(void *ctx, void **ptr)
{
    (void)ctx;
    g_rsp_pool_receiver_busy = true;
    *ptr = g_rsp_pool;
    return LIBSPDM_STATUS_SUCCESS;
}

static void rsp_release_receiver_buffer(void *ctx, const void *ptr)
{
    (void)ctx; (void)ptr;
    g_rsp_pool_receiver_busy = false;
}

/* ─── transport callbacks ────────────────────────────────────────────────── */

static int g_send_depth = 0;

/* Requester send: store request, drive responder dispatch, return */
static libspdm_return_t req_send_message(void *ctx, size_t req_size,
                                          const void *req, uint64_t timeout)
{
    libspdm_return_t status;
    (void)ctx; (void)timeout;

    g_send_depth++;
    if (g_send_depth > 20) {
        fprintf(stderr, "[harness] DEPTH LIMIT - aborting\n");
        abort();
    }

    if (req_size > sizeof(g_req_transfer)) {
        fprintf(stderr, "[harness] req_send_message: message too large (%zu)\n", req_size);
        g_send_depth--;
        return LIBSPDM_STATUS_SEND_FAIL;
    }
    memcpy(g_req_transfer, req, req_size);
    g_req_transfer_size = req_size;

    status = libspdm_responder_dispatch_message(g_rsp_ctx);
    g_send_depth--;
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[harness] dispatch_message failed: 0x%x\n", (unsigned)status);
        return LIBSPDM_STATUS_SEND_FAIL;
    }
    return LIBSPDM_STATUS_SUCCESS;
}

/* Requester receive: return the stored response */
static libspdm_return_t req_receive_message(void *ctx, size_t *rsp_size,
                                             void **rsp, uint64_t timeout)
{
    (void)ctx; (void)timeout;
    *rsp      = g_rsp_transfer;
    *rsp_size = g_rsp_transfer_size;
    return LIBSPDM_STATUS_SUCCESS;
}

/* Responder receive: return the stored request */
static libspdm_return_t rsp_receive_message(void *ctx, size_t *req_size,
                                             void **req, uint64_t timeout)
{
    (void)ctx; (void)timeout;
    *req      = g_req_transfer;
    *req_size = g_req_transfer_size;
    return LIBSPDM_STATUS_SUCCESS;
}

/* Responder send: store the response */
static libspdm_return_t rsp_send_message(void *ctx, size_t rsp_size,
                                          const void *rsp, uint64_t timeout)
{
    (void)ctx; (void)timeout;
    if (rsp_size > sizeof(g_rsp_transfer)) {
        fprintf(stderr, "[harness] rsp_send_message: response too large (%zu)\n", rsp_size);
        return LIBSPDM_STATUS_SEND_FAIL;
    }
    memcpy(g_rsp_transfer, rsp, rsp_size);
    g_rsp_transfer_size = rsp_size;
    return LIBSPDM_STATUS_SUCCESS;
}

/* ─── context setup ──────────────────────────────────────────────────────── */

static void *alloc_context(void)
{
    void *ctx = malloc(libspdm_get_context_size());
    if (!ctx) { fprintf(stderr, "OOM\n"); exit(1); }
    return ctx;
}

static void *alloc_scratch(void *ctx)
{
    size_t sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    void *buf = malloc(sz);
    if (!buf) { fprintf(stderr, "OOM scratch\n"); exit(1); }
    libspdm_set_scratch_buffer(ctx, buf, sz);
    return buf;
}

static void setup_requester(void *req_ctx,
                             const void *root_cert, size_t root_cert_size)
{
    libspdm_data_parameter_t param;
    uint32_t cap_flags;
    uint16_t spdm_version;
    uint32_t hash_algo;
    uint32_t asym_algo;
    uint16_t dhe_algo;
    uint16_t aead_algo;
    uint16_t key_sched;

    libspdm_init_context(req_ctx);

    libspdm_register_device_io_func(req_ctx, req_send_message, req_receive_message);
    libspdm_register_transport_layer_func(req_ctx,
                                          MAX_MSG_SIZE,
                                          TRANSPORT_HEADER_SIZE,
                                          TRANSPORT_TAIL_SIZE,
                                          libspdm_transport_test_encode_message,
                                          libspdm_transport_test_decode_message);
    libspdm_register_device_buffer_func(req_ctx,
                                        POOL_SIZE, POOL_SIZE,
                                        req_acquire_sender_buffer,
                                        req_release_sender_buffer,
                                        req_acquire_receiver_buffer,
                                        req_release_receiver_buffer);

    memset(&param, 0, sizeof(param));
    param.location = LIBSPDM_DATA_LOCATION_LOCAL;

    spdm_version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    libspdm_set_data(req_ctx, LIBSPDM_DATA_SPDM_VERSION, &param,
                     &spdm_version, sizeof(spdm_version));

    cap_flags = SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
                SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP;
    libspdm_set_data(req_ctx, LIBSPDM_DATA_CAPABILITY_FLAGS, &param,
                     &cap_flags, sizeof(cap_flags));

    hash_algo = TEST_HASH_ALGO;
    libspdm_set_data(req_ctx, LIBSPDM_DATA_BASE_HASH_ALGO, &param,
                     &hash_algo, sizeof(hash_algo));

    asym_algo = TEST_ASYM_ALGO;
    libspdm_set_data(req_ctx, LIBSPDM_DATA_BASE_ASYM_ALGO, &param,
                     &asym_algo, sizeof(asym_algo));

    dhe_algo = SPDM_ALGORITHMS_DHE_NAMED_GROUP_SECP_256_R1;
    libspdm_set_data(req_ctx, LIBSPDM_DATA_DHE_NAME_GROUP, &param,
                     &dhe_algo, sizeof(dhe_algo));

    aead_algo = SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM;
    libspdm_set_data(req_ctx, LIBSPDM_DATA_AEAD_CIPHER_SUITE, &param,
                     &aead_algo, sizeof(aead_algo));

    key_sched = SPDM_ALGORITHMS_KEY_SCHEDULE_SPDM;
    libspdm_set_data(req_ctx, LIBSPDM_DATA_KEY_SCHEDULE, &param,
                     &key_sched, sizeof(key_sched));

    /* tell requester to trust responder's cert chain */
    libspdm_set_data(req_ctx, LIBSPDM_DATA_PEER_PUBLIC_ROOT_CERT, &param,
                     (void *)(uintptr_t)root_cert, root_cert_size);
}

static void setup_responder(void *rsp_ctx,
                             const void *cert_chain, size_t cert_chain_size)
{
    libspdm_data_parameter_t param;
    uint32_t cap_flags;
    uint16_t spdm_version;
    uint32_t hash_algo;
    uint32_t asym_algo;
    uint16_t dhe_algo;
    uint16_t aead_algo;
    uint16_t key_sched;

    libspdm_init_context(rsp_ctx);

    libspdm_register_device_io_func(rsp_ctx, rsp_send_message, rsp_receive_message);
    libspdm_register_transport_layer_func(rsp_ctx,
                                          MAX_MSG_SIZE,
                                          TRANSPORT_HEADER_SIZE,
                                          TRANSPORT_TAIL_SIZE,
                                          libspdm_transport_test_encode_message,
                                          libspdm_transport_test_decode_message);
    libspdm_register_device_buffer_func(rsp_ctx,
                                        POOL_SIZE, POOL_SIZE,
                                        rsp_acquire_sender_buffer,
                                        rsp_release_sender_buffer,
                                        rsp_acquire_receiver_buffer,
                                        rsp_release_receiver_buffer);

    memset(&param, 0, sizeof(param));
    param.location = LIBSPDM_DATA_LOCATION_LOCAL;

    spdm_version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    libspdm_set_data(rsp_ctx, LIBSPDM_DATA_SPDM_VERSION, &param,
                     &spdm_version, sizeof(spdm_version));

    cap_flags = SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
                SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP;
    libspdm_set_data(rsp_ctx, LIBSPDM_DATA_CAPABILITY_FLAGS, &param,
                     &cap_flags, sizeof(cap_flags));

    hash_algo = TEST_HASH_ALGO;
    libspdm_set_data(rsp_ctx, LIBSPDM_DATA_BASE_HASH_ALGO, &param,
                     &hash_algo, sizeof(hash_algo));

    asym_algo = TEST_ASYM_ALGO;
    libspdm_set_data(rsp_ctx, LIBSPDM_DATA_BASE_ASYM_ALGO, &param,
                     &asym_algo, sizeof(asym_algo));

    dhe_algo = SPDM_ALGORITHMS_DHE_NAMED_GROUP_SECP_256_R1;
    libspdm_set_data(rsp_ctx, LIBSPDM_DATA_DHE_NAME_GROUP, &param,
                     &dhe_algo, sizeof(dhe_algo));

    aead_algo = SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM;
    libspdm_set_data(rsp_ctx, LIBSPDM_DATA_AEAD_CIPHER_SUITE, &param,
                     &aead_algo, sizeof(aead_algo));

    key_sched = SPDM_ALGORITHMS_KEY_SCHEDULE_SPDM;
    libspdm_set_data(rsp_ctx, LIBSPDM_DATA_KEY_SCHEDULE, &param,
                     &key_sched, sizeof(key_sched));

    /* provide responder's cert chain on slot 0 */
    /* additional_data[0] = slot_id */
    param.additional_data[0] = 0;
    libspdm_set_data(rsp_ctx, LIBSPDM_DATA_LOCAL_PUBLIC_CERT_CHAIN, &param,
                     (void *)(uintptr_t)cert_chain, cert_chain_size);
}

/* ─── scenario helpers ───────────────────────────────────────────────────── */

typedef struct {
    void   *req_ctx;
    void   *req_scratch;
    void   *rsp_ctx;
    void   *rsp_scratch;
    void   *cert_chain;
    size_t  cert_chain_size;
    void   *root_cert;
    size_t  root_cert_size;
} scenario_ctx_t;

static void scenario_init(scenario_ctx_t *s)
{
    bool ok;

    /* load certs (reads from ecp256/ relative to CWD) */
    ok = libspdm_read_responder_public_certificate_chain(
             TEST_HASH_ALGO, TEST_ASYM_ALGO,
             &s->cert_chain, &s->cert_chain_size, NULL, NULL);
    if (!ok) {
        fprintf(stderr, "[harness] Failed to load responder cert chain. "
                "Run from unit_test/sample_key/\n");
        exit(1);
    }

    ok = libspdm_read_responder_root_public_certificate(
             TEST_HASH_ALGO, TEST_ASYM_ALGO,
             &s->root_cert, &s->root_cert_size, NULL, NULL);
    if (!ok) {
        fprintf(stderr, "[harness] Failed to load responder root cert.\n");
        exit(1);
    }

    s->req_ctx = alloc_context();
    s->rsp_ctx = alloc_context();
    g_rsp_ctx  = s->rsp_ctx;

    setup_requester(s->req_ctx, s->root_cert, s->root_cert_size);
    setup_responder(s->rsp_ctx, s->cert_chain, s->cert_chain_size);

    s->req_scratch = alloc_scratch(s->req_ctx);
    s->rsp_scratch = alloc_scratch(s->rsp_ctx);

    /* reset pool busy flags */
    g_req_pool_sender_busy   = false;
    g_req_pool_receiver_busy = false;
    g_rsp_pool_sender_busy   = false;
    g_rsp_pool_receiver_busy = false;
}

static void scenario_cleanup(scenario_ctx_t *s)
{
    free(s->cert_chain);
    free(s->root_cert);
    free(s->req_scratch);
    free(s->rsp_scratch);
    free(s->req_ctx);
    free(s->rsp_ctx);
    g_rsp_ctx = NULL;
}

/* ─── Scenario 1: happy path ─────────────────────────────────────────────── */

static void run_happy_path(const char *trace_path)
{
    scenario_ctx_t s;
    libspdm_return_t status;
    uint8_t slot_mask;
    uint8_t cert_buf[0x2000];
    size_t  cert_size;
    uint8_t meas_hash[64];

    printf("[harness] scenario: happy_path → %s\n", trace_path);

    scenario_init(&s);
    tla_trace_init(trace_path);

    /* VCA: Version + Capabilities + Algorithms → emits "negotiate" */
    status = libspdm_init_connection(s.req_ctx, false);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[harness] init_connection failed: 0x%x\n", (unsigned)status);
        goto done;
    }
    printf("[harness]   init_connection OK\n");

    /* GetDigests → emits req_get_digests, rsp_get_digests, req_digests_recv */
    slot_mask = 0;
    status = libspdm_get_digest(s.req_ctx, NULL, &slot_mask, NULL);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[harness] get_digest failed: 0x%x\n", (unsigned)status);
        goto done;
    }
    printf("[harness]   get_digest OK slot_mask=0x%02x\n", slot_mask);

    /* GetCertificate slot 0 → emits req_get_certificate, rsp_get_certificate, req_certificate_recv */
    cert_size = sizeof(cert_buf);
    status = libspdm_get_certificate(s.req_ctx, NULL, 0, &cert_size, cert_buf);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[harness] get_certificate failed: 0x%x\n", (unsigned)status);
        goto done;
    }
    printf("[harness]   get_certificate OK cert_size=%zu\n", cert_size);

    /* Challenge slot 0 → emits req_challenge, rsp_challenge_auth, req_challenge_auth_recv */
    status = libspdm_challenge(s.req_ctx, NULL, 0,
                               SPDM_CHALLENGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH,
                               meas_hash, &slot_mask);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[harness] challenge failed: 0x%x\n", (unsigned)status);
        goto done;
    }
    printf("[harness]   challenge OK slot_mask=0x%02x\n", slot_mask);

done:
    tla_trace_close();
    scenario_cleanup(&s);
    printf("[harness] happy_path done\n");
}

/* ─── Scenario 2: challenge without cert fetch (F2 weak precondition) ─────── */

static void run_no_cert_challenge(const char *trace_path)
{
    scenario_ctx_t s;
    libspdm_return_t status;
    uint8_t slot_mask;
    uint8_t meas_hash[64];

    printf("[harness] scenario: no_cert_challenge → %s\n", trace_path);

    scenario_init(&s);
    tla_trace_init(trace_path);

    /* VCA */
    status = libspdm_init_connection(s.req_ctx, false);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[harness] init_connection failed: 0x%x\n", (unsigned)status);
        goto done;
    }
    printf("[harness]   init_connection OK\n");

    /* GetDigests (advance state to AFTER_DIGESTS) */
    slot_mask = 0;
    status = libspdm_get_digest(s.req_ctx, NULL, &slot_mask, NULL);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[harness] get_digest failed: 0x%x\n", (unsigned)status);
        goto done;
    }
    printf("[harness]   get_digest OK slot_mask=0x%02x\n", slot_mask);

    /* Challenge directly (no GetCertificate) — F2: weak precondition */
    status = libspdm_challenge(s.req_ctx, NULL, 0,
                               SPDM_CHALLENGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH,
                               meas_hash, &slot_mask);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        /* expected: cert hash verification will fail since no cert was fetched */
        fprintf(stderr, "[harness] challenge (no cert) returned: 0x%x (expected failure)\n",
                (unsigned)status);
    } else {
        printf("[harness]   challenge (no cert) returned SUCCESS — bug triggered\n");
    }
    printf("[harness]   no_cert_challenge attempted\n");

done:
    tla_trace_close();
    scenario_cleanup(&s);
    printf("[harness] no_cert_challenge done\n");
}

/* ─── main ───────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    const char *trace_dir = "../traces";

    if (argc >= 2) {
        trace_dir = argv[1];
    }

    /* Construct trace file paths */
    char happy_path_trace[512];
    char no_cert_trace[512];
    snprintf(happy_path_trace, sizeof(happy_path_trace),
             "%s/happy_path.ndjson", trace_dir);
    snprintf(no_cert_trace, sizeof(no_cert_trace),
             "%s/no_cert_challenge.ndjson", trace_dir);

    printf("[harness] Writing traces to: %s/\n", trace_dir);

    run_happy_path(happy_path_trace);
    run_no_cert_challenge(no_cert_trace);

    printf("[harness] All scenarios complete.\n");
    return 0;
}
