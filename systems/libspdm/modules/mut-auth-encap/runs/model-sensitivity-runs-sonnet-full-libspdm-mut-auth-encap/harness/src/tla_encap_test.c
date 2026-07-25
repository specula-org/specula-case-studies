/**
 * tla_encap_test.c — trace harness for libspdm encapsulated mutual auth.
 *
 * Generates NDJSON trace files consumed by the TLA+ trace validator.
 * Exercises 4 scenarios: BASIC_CERT, BASIC_PK, error path, not-ready path.
 *
 * Build: see CMakeLists.txt alongside this file.
 * Run:   harness/run.sh  (sets LIBSPDM_TRACE_DIR and invokes the binary)
 */

#define TLA_TRACE_DEFINE_GLOBALS

#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_common_lib.h"
#include "tla_trace.h"
#include "spdm_device_secret_lib_internal.h"
#include "hal/library/requester/reqasymsignlib.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

/* ──── stubs for spdm_device_secret_lib_sample helpers ────────────────── */
bool libspdm_read_input_file(const char *file_name, void **file_data, size_t *file_size)
{
    FILE *fp = fopen(file_name, "rb");
    if (!fp) { *file_data = NULL; return false; }
    fseek(fp, 0, SEEK_END);
    *file_size = (size_t)ftell(fp);
    *file_data = malloc(*file_size);
    if (!*file_data) { fclose(fp); return false; }
    fseek(fp, 0, SEEK_SET);
    if (fread(*file_data, 1, *file_size, fp) != *file_size) {
        free(*file_data); fclose(fp); return false;
    }
    fclose(fp);
    return true;
}
bool libspdm_write_output_file(const char *file_name, const void *file_data, size_t file_size)
{
    FILE *fp = fopen(file_name, "wb");
    if (!fp) return false;
    (void)fwrite(file_data, 1, file_size, fp);
    fclose(fp);
    return true;
}
void libspdm_dump_hex_str(const uint8_t *buffer, size_t buffer_size)
{
    size_t i;
    for (i = 0; i < buffer_size; i++) printf("%02x", buffer[i]);
}

/* ────────────────────────────── algorithm config ───────────────────────── */

#define USE_HASH_ALGO   SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256
#define USE_ASYM_ALGO   SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048
#define USE_REQ_ASYM    SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048

/* Fallbacks for constants that are gated behind build-time options. */
#ifndef LIBSPDM_MAX_SPDM_MSG_SIZE
#define LIBSPDM_MAX_SPDM_MSG_SIZE 0x1200
#endif
#ifndef LIBSPDM_MAX_CERT_CHAIN_SIZE
#define LIBSPDM_MAX_CERT_CHAIN_SIZE 0x1000
#endif

/* ────────────────────────────── device buffer callbacks ────────────────── */

static uint8_t  g_sender_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
static uint8_t  g_receiver_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
static bool     g_sender_acquired   = false;
static bool     g_receiver_acquired = false;

static libspdm_return_t acquire_sender(void *ctx, void **msg)
{
    (void)ctx;
    *msg = g_sender_buf;
    g_sender_acquired = true;
    return LIBSPDM_STATUS_SUCCESS;
}
static void release_sender(void *ctx, const void *msg)
{
    (void)ctx; (void)msg;
    g_sender_acquired = false;
}
static libspdm_return_t acquire_receiver(void *ctx, void **msg)
{
    (void)ctx;
    *msg = g_receiver_buf;
    g_receiver_acquired = true;
    return LIBSPDM_STATUS_SUCCESS;
}
static void release_receiver(void *ctx, const void *msg)
{
    (void)ctx; (void)msg;
    g_receiver_acquired = false;
}

/* ────────────────────────────── context helpers ────────────────────────── */

static libspdm_context_t *create_context(void)
{
    libspdm_context_t *ctx;
    void *scratch;
    size_t scratch_size;

    ctx = (libspdm_context_t *)malloc(libspdm_get_context_size());
    assert(ctx != NULL);
    libspdm_init_context(ctx);

    libspdm_register_device_buffer_func(ctx,
        LIBSPDM_MAX_SPDM_MSG_SIZE, LIBSPDM_MAX_SPDM_MSG_SIZE,
        acquire_sender, release_sender,
        acquire_receiver, release_receiver);

    /* max_spdm_msg_size must be set before libspdm_get_sizeof_required_scratch_buffer. */
    ctx->local_context.capability.max_spdm_msg_size = LIBSPDM_MAX_SPDM_MSG_SIZE;

    scratch_size = libspdm_get_sizeof_required_scratch_buffer(ctx);
    scratch = malloc(scratch_size);
    assert(scratch != NULL);
    libspdm_set_scratch_buffer(ctx, scratch, scratch_size);

    return ctx;
}

/* Set common SPDM v1.1 fields on a context. */
static void setup_common(libspdm_context_t *ctx, bool pub_key_id)
{
    ctx->connection_info.version =
        (uint16_t)(SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT);
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;

    ctx->connection_info.algorithm.base_hash_algo = USE_HASH_ALGO;
    ctx->connection_info.algorithm.base_asym_algo  = USE_ASYM_ALGO;
    ctx->connection_info.algorithm.req_base_asym_alg = USE_REQ_ASYM;
    ctx->connection_info.algorithm.req_pqc_asym_alg  = 0;

    /* Local (Responder) caps */
    ctx->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCAP_CAP  |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP   |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP   |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MUT_AUTH_CAP;

    /* Peer (Requester) caps */
    ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCAP_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP  |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP;

    if (pub_key_id) {
        ctx->connection_info.capability.flags |=
            SPDM_GET_CAPABILITIES_REQUEST_FLAGS_PUB_KEY_ID_CAP;
    }
}

/* Build a minimal valid DELIVER_ENCAPSULATED_RESPONSE header in buf. */
static size_t build_deliver_hdr(uint8_t *buf, uint8_t req_id)
{
    spdm_deliver_encapsulated_response_request_t *hdr =
        (spdm_deliver_encapsulated_response_request_t *)buf;
    hdr->header.spdm_version = SPDM_MESSAGE_VERSION_11;
    hdr->header.request_response_code = SPDM_DELIVER_ENCAPSULATED_RESPONSE;
    hdr->header.param1 = req_id;
    hdr->header.param2 = 0;
    return sizeof(spdm_deliver_encapsulated_response_request_t);
}

/* ────────────────────────────── trace scenarios ────────────────────────── */

/**
 * trace_basic_cert — BASIC_CERT full flow:
 *   init_encap_state → get_encapsulated_request → deliver_encap_digests
 *   → deliver_encap_certificate → deliver_encap_challenge_auth
 */
static void trace_basic_cert(const char *out_path)
{
    libspdm_context_t   *ctx;
    void                *req_cert_data   = NULL;
    size_t               req_cert_size   = 0;
    void                *req_cert_hash   = NULL;
    size_t               req_cert_hash_sz= 0;
    const uint8_t       *root_cert       = NULL;
    size_t               root_cert_size  = 0;
    uint8_t              req_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    uint8_t              resp_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t               resp_size;
    libspdm_return_t     status;
    uint8_t             *ptr;
    size_t               req_size;
    size_t               sig_size;
    size_t               hash_size;
    spdm_get_encapsulated_request_request_t get_encap_req;
    spdm_digest_response_t   *digest_rsp;
    spdm_certificate_response_t *cert_rsp;
    spdm_challenge_auth_response_t *chal_auth_rsp;

    g_tla_trace_file = fopen(out_path, "w");
    assert(g_tla_trace_file != NULL);

    ctx = create_context();
    setup_common(ctx, false);  /* BASIC_CERT: no PUB_KEY_ID_CAP */
    ctx->encap_context.req_slot_id = 0;

    /* Allocate mut_auth_cert_chain_buffer (required for BASIC_CERT) */
    ctx->mut_auth_cert_chain_buffer = malloc(LIBSPDM_MAX_CERT_CHAIN_SIZE);
    assert(ctx->mut_auth_cert_chain_buffer != NULL);
    ctx->mut_auth_cert_chain_buffer_max_size = LIBSPDM_MAX_CERT_CHAIN_SIZE;
    ctx->mut_auth_cert_chain_buffer_size = 0;

    /* Load Requester cert chain */
    libspdm_read_requester_public_certificate_chain(USE_HASH_ALGO, USE_REQ_ASYM,
        &req_cert_data, &req_cert_size, &req_cert_hash, &req_cert_hash_sz);
    assert(req_cert_data != NULL);

    /* Extract root cert for authority verification */
    hash_size = libspdm_get_hash_size(USE_HASH_ALGO);
    libspdm_x509_get_cert_from_cert_chain(
        (uint8_t *)req_cert_data + sizeof(spdm_cert_chain_t) + hash_size,
        req_cert_size - sizeof(spdm_cert_chain_t) - hash_size,
        0, &root_cert, &root_cert_size);
    ctx->local_context.peer_root_cert_provision[0]      = root_cert;
    ctx->local_context.peer_root_cert_provision_size[0] = root_cert_size;

    libspdm_reset_message_mut_b(ctx);
    libspdm_reset_message_mut_c(ctx);

    /* ── Step 1: init_encap_state ─────────────────────────────────────── */
    libspdm_init_basic_mut_auth_encap_state(ctx);

    /* ── Step 2: GET_ENCAP_REQ → ENCAPSULATED_REQUEST(GET_DIGESTS) ──── */
    memset(&get_encap_req, 0, sizeof(get_encap_req));
    get_encap_req.header.spdm_version = SPDM_MESSAGE_VERSION_11;
    get_encap_req.header.request_response_code = SPDM_GET_ENCAPSULATED_REQUEST;

    resp_size = sizeof(resp_buf);
    status = libspdm_get_response_encapsulated_request(ctx,
        sizeof(get_encap_req), &get_encap_req, &resp_size, resp_buf);
    assert(status == LIBSPDM_STATUS_SUCCESS);

    /* ── Step 3: DELIVER(DIGESTS) ─────────────────────────────────────── */
    ptr = req_buf;
    ptr += build_deliver_hdr(ptr, ctx->encap_context.request_id);

    digest_rsp = (spdm_digest_response_t *)ptr;
    digest_rsp->header.spdm_version            = SPDM_MESSAGE_VERSION_11;
    digest_rsp->header.request_response_code   = SPDM_DIGESTS;
    digest_rsp->header.param1                  = 0;
    digest_rsp->header.param2                  = (1 << 0);  /* slot 0 present */
    ptr += sizeof(spdm_digest_response_t);

    /* Digest = SHA256(requester cert chain) */
    libspdm_hash_all(USE_HASH_ALGO, req_cert_data, req_cert_size, ptr);
    ptr += hash_size;

    req_size  = (size_t)(ptr - req_buf);
    resp_size = sizeof(resp_buf);
    status = libspdm_get_response_encapsulated_response_ack(ctx,
        req_size, req_buf, &resp_size, resp_buf);
    assert(status == LIBSPDM_STATUS_SUCCESS);

    /* ── Step 4: DELIVER(CERTIFICATE) one-shot ───────────────────────── */
    ptr = req_buf;
    ptr += build_deliver_hdr(ptr, ctx->encap_context.request_id);

    cert_rsp = (spdm_certificate_response_t *)ptr;
    cert_rsp->header.spdm_version          = SPDM_MESSAGE_VERSION_11;
    cert_rsp->header.request_response_code = SPDM_CERTIFICATE;
    cert_rsp->header.param1                = 0;   /* slot 0 */
    cert_rsp->header.param2                = 0;
    cert_rsp->portion_length               = (uint16_t)req_cert_size;
    cert_rsp->remainder_length             = 0;   /* one-shot */
    ptr += sizeof(spdm_certificate_response_t);
    memcpy(ptr, req_cert_data, req_cert_size);
    ptr += req_cert_size;

    req_size  = (size_t)(ptr - req_buf);
    resp_size = sizeof(resp_buf);
    status = libspdm_get_response_encapsulated_response_ack(ctx,
        req_size, req_buf, &resp_size, resp_buf);
    assert(status == LIBSPDM_STATUS_SUCCESS);

    /* ── Step 5: DELIVER(CHALLENGE_AUTH) ────────────────────────────── */
    sig_size = libspdm_get_asym_signature_size(USE_REQ_ASYM);
    {
        size_t body_size = sizeof(spdm_challenge_auth_response_t) +
                           hash_size + SPDM_NONCE_SIZE + sizeof(uint16_t);

        ptr = req_buf;
        ptr += build_deliver_hdr(ptr, ctx->encap_context.request_id);

        chal_auth_rsp = (spdm_challenge_auth_response_t *)ptr;
        chal_auth_rsp->header.spdm_version          = SPDM_MESSAGE_VERSION_11;
        chal_auth_rsp->header.request_response_code = SPDM_CHALLENGE_AUTH;
        chal_auth_rsp->header.param1                = 0;          /* slot 0 */
        chal_auth_rsp->header.param2                = (1 << 0);   /* slot 0 in SlotMask */

        uint8_t *body = (uint8_t *)(chal_auth_rsp + 1);

        /* cert_chain_hash = SHA256(requester cert chain) */
        libspdm_hash_all(USE_HASH_ALGO, req_cert_data, req_cert_size, body);
        body += hash_size;

        libspdm_get_random_number(SPDM_NONCE_SIZE, body);
        body += SPDM_NONCE_SIZE;

        libspdm_write_uint16(body, 0);  /* opaque_length = 0 */
        body += sizeof(uint16_t);

        /* Sign over Hash(message_mut_c || CHALLENGE_AUTH_body).
         * message_mut_c already contains the CHALLENGE request appended by
         * libspdm_get_encap_request_challenge.  We duplicate the running hash
         * context, feed the response body into the copy, finalise it, and sign
         * the resulting hash (is_data_hash=true). */
        {
            void *dup_ctx = libspdm_hash_new(USE_HASH_ALGO);
            uint8_t m1m2_hash[LIBSPDM_MAX_HASH_SIZE];
            size_t m1m2_hash_size = hash_size;
            bool ok;

            assert(ctx->transcript.digest_context_mut_m1m2 != NULL);
            ok = libspdm_hash_duplicate(USE_HASH_ALGO,
                                        ctx->transcript.digest_context_mut_m1m2, dup_ctx);
            assert(ok);
            ok = libspdm_hash_update(USE_HASH_ALGO, dup_ctx,
                                     (const uint8_t *)chal_auth_rsp, body_size);
            assert(ok);
            ok = libspdm_hash_final(USE_HASH_ALGO, dup_ctx, m1m2_hash);
            assert(ok);
            libspdm_hash_free(USE_HASH_ALGO, dup_ctx);

            libspdm_requester_data_sign(ctx,
                (spdm_version_number_t)(SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT),
                0, SPDM_CHALLENGE_AUTH,
                USE_REQ_ASYM, 0, USE_HASH_ALGO,
                true,
                m1m2_hash, m1m2_hash_size,
                body, &sig_size);
        }
        body += sig_size;

        req_size  = (size_t)(body - req_buf);
        resp_size = sizeof(resp_buf);
        status = libspdm_get_response_encapsulated_response_ack(ctx,
            req_size, req_buf, &resp_size, resp_buf);
        assert(status == LIBSPDM_STATUS_SUCCESS);
    }

    fclose(g_tla_trace_file);
    g_tla_trace_file = NULL;

    free(req_cert_data);
    /* req_cert_hash points into req_cert_data, not a separate allocation */
    free(ctx->mut_auth_cert_chain_buffer);
    free(ctx);

    printf("[PASS] trace_basic_cert -> %s\n", out_path);
}

/**
 * trace_basic_pk — BASIC_PK flow (public key provisioned, no cert chain):
 *   init_encap_state → get_encapsulated_request → deliver_encap_challenge_auth
 */
static void trace_basic_pk(const char *out_path)
{
    libspdm_context_t  *ctx;
    void               *pub_key_data = NULL;
    size_t              pub_key_size = 0;
    uint8_t             req_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    uint8_t             resp_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t              resp_size;
    libspdm_return_t    status;
    uint8_t            *ptr;
    size_t              req_size;
    size_t              sig_size;
    size_t              hash_size;
    spdm_get_encapsulated_request_request_t get_encap_req;
    spdm_challenge_auth_response_t *chal_auth_rsp;

    g_tla_trace_file = fopen(out_path, "w");
    assert(g_tla_trace_file != NULL);

    ctx = create_context();
    setup_common(ctx, true);  /* BASIC_PK: PUB_KEY_ID_CAP set */
    ctx->encap_context.req_slot_id = 0xFF;

    /* Provision Requester public key */
    libspdm_read_requester_public_key(USE_REQ_ASYM, &pub_key_data, &pub_key_size);
    assert(pub_key_data != NULL);
    ctx->local_context.peer_public_key_provision      = pub_key_data;
    ctx->local_context.peer_public_key_provision_size = pub_key_size;

    libspdm_reset_message_mut_b(ctx);
    libspdm_reset_message_mut_c(ctx);

    hash_size = libspdm_get_hash_size(USE_HASH_ALGO);

    /* ── Step 1: init_encap_state ─────────────────────────────────────── */
    libspdm_init_basic_mut_auth_encap_state(ctx);

    /* ── Step 2: GET_ENCAP_REQ → ENCAPSULATED_REQUEST(CHALLENGE) ─────── */
    memset(&get_encap_req, 0, sizeof(get_encap_req));
    get_encap_req.header.spdm_version = SPDM_MESSAGE_VERSION_11;
    get_encap_req.header.request_response_code = SPDM_GET_ENCAPSULATED_REQUEST;

    resp_size = sizeof(resp_buf);
    status = libspdm_get_response_encapsulated_request(ctx,
        sizeof(get_encap_req), &get_encap_req, &resp_size, resp_buf);
    assert(status == LIBSPDM_STATUS_SUCCESS);

    /* ── Step 3: DELIVER(CHALLENGE_AUTH) with PUB_KEY_ID path ─────────── */
    sig_size = libspdm_get_asym_signature_size(USE_REQ_ASYM);
    {
        size_t body_size = sizeof(spdm_challenge_auth_response_t) +
                           hash_size + SPDM_NONCE_SIZE + sizeof(uint16_t);

        ptr = req_buf;
        ptr += build_deliver_hdr(ptr, ctx->encap_context.request_id);

        chal_auth_rsp = (spdm_challenge_auth_response_t *)ptr;
        chal_auth_rsp->header.spdm_version          = SPDM_MESSAGE_VERSION_11;
        chal_auth_rsp->header.request_response_code = SPDM_CHALLENGE_AUTH;
        /* param1: SLOT_ID bits = 0xF for public-key case */
        chal_auth_rsp->header.param1 =
            (0xFF & SPDM_CHALLENGE_AUTH_RESPONSE_ATTRIBUTE_SLOT_ID_MASK);
        chal_auth_rsp->header.param2 = 0;  /* SlotMask = 0 for pub-key */

        uint8_t *body = (uint8_t *)(chal_auth_rsp + 1);

        /* cert_chain_hash = SHA256(requester public key) */
        libspdm_hash_all(USE_HASH_ALGO, pub_key_data, pub_key_size, body);
        body += hash_size;

        libspdm_get_random_number(SPDM_NONCE_SIZE, body);
        body += SPDM_NONCE_SIZE;

        libspdm_write_uint16(body, 0);
        body += sizeof(uint16_t);

        /* Sign over Hash(message_mut_c || CHALLENGE_AUTH_body) — same approach as BASIC_CERT. */
        {
            void *dup_ctx = libspdm_hash_new(USE_HASH_ALGO);
            uint8_t m1m2_hash[LIBSPDM_MAX_HASH_SIZE];
            size_t m1m2_hash_size = hash_size;
            bool ok;

            assert(ctx->transcript.digest_context_mut_m1m2 != NULL);
            ok = libspdm_hash_duplicate(USE_HASH_ALGO,
                                        ctx->transcript.digest_context_mut_m1m2, dup_ctx);
            assert(ok);
            ok = libspdm_hash_update(USE_HASH_ALGO, dup_ctx,
                                     (const uint8_t *)chal_auth_rsp, body_size);
            assert(ok);
            ok = libspdm_hash_final(USE_HASH_ALGO, dup_ctx, m1m2_hash);
            assert(ok);
            libspdm_hash_free(USE_HASH_ALGO, dup_ctx);

            libspdm_requester_data_sign(ctx,
                (spdm_version_number_t)(SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT),
                0, SPDM_CHALLENGE_AUTH,
                USE_REQ_ASYM, 0, USE_HASH_ALGO,
                true,
                m1m2_hash, m1m2_hash_size,
                body, &sig_size);
        }
        body += sig_size;

        req_size  = (size_t)(body - req_buf);
        resp_size = sizeof(resp_buf);
        status = libspdm_get_response_encapsulated_response_ack(ctx,
            req_size, req_buf, &resp_size, resp_buf);
        assert(status == LIBSPDM_STATUS_SUCCESS);
    }

    fclose(g_tla_trace_file);
    g_tla_trace_file = NULL;

    free(pub_key_data);
    free(ctx);

    printf("[PASS] trace_basic_pk -> %s\n", out_path);
}

/**
 * trace_encap_error — error path:
 *   init_encap_state → get_encapsulated_request → encap_error
 *   (Requester delivers an invalid response code)
 */
static void trace_encap_error(const char *out_path)
{
    libspdm_context_t  *ctx;
    uint8_t             req_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    uint8_t             resp_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t              resp_size;
    libspdm_return_t    status;
    uint8_t            *ptr;
    size_t              req_size;
    spdm_get_encapsulated_request_request_t get_encap_req;
    spdm_message_header_t *bad_rsp;

    g_tla_trace_file = fopen(out_path, "w");
    assert(g_tla_trace_file != NULL);

    ctx = create_context();
    setup_common(ctx, false);  /* BASIC_CERT-style context for the init */
    ctx->encap_context.req_slot_id = 0;

    ctx->mut_auth_cert_chain_buffer = malloc(LIBSPDM_MAX_CERT_CHAIN_SIZE);
    assert(ctx->mut_auth_cert_chain_buffer != NULL);
    ctx->mut_auth_cert_chain_buffer_max_size = LIBSPDM_MAX_CERT_CHAIN_SIZE;
    ctx->mut_auth_cert_chain_buffer_size = 0;

    libspdm_reset_message_mut_b(ctx);
    libspdm_reset_message_mut_c(ctx);

    /* ── Step 1: init_encap_state ─────────────────────────────────────── */
    libspdm_init_basic_mut_auth_encap_state(ctx);

    /* ── Step 2: GET_ENCAP_REQ ─────────────────────────────────────────── */
    memset(&get_encap_req, 0, sizeof(get_encap_req));
    get_encap_req.header.spdm_version = SPDM_MESSAGE_VERSION_11;
    get_encap_req.header.request_response_code = SPDM_GET_ENCAPSULATED_REQUEST;

    resp_size = sizeof(resp_buf);
    status = libspdm_get_response_encapsulated_request(ctx,
        sizeof(get_encap_req), &get_encap_req, &resp_size, resp_buf);
    assert(status == LIBSPDM_STATUS_SUCCESS);

    /* ── Step 3: DELIVER with wrong response code → encap_error ────────── */
    ptr = req_buf;
    ptr += build_deliver_hdr(ptr, ctx->encap_context.request_id);

    /* Send a CHALLENGE_AUTH where DIGESTS is expected — wrong code */
    bad_rsp = (spdm_message_header_t *)ptr;
    bad_rsp->spdm_version          = SPDM_MESSAGE_VERSION_11;
    bad_rsp->request_response_code = SPDM_CHALLENGE_AUTH;  /* wrong for GET_DIGESTS */
    bad_rsp->param1                = 0;
    bad_rsp->param2                = 0;
    ptr += sizeof(spdm_message_header_t) + 4;  /* minimal body */

    req_size  = (size_t)(ptr - req_buf);
    resp_size = sizeof(resp_buf);
    /* This call is expected to fail (returns error response, not LIBSPDM_STATUS_SUCCESS).
     * The encap_error trace event was already emitted before the error response is generated. */
    status = libspdm_get_response_encapsulated_response_ack(ctx,
        req_size, req_buf, &resp_size, resp_buf);
    /* status may be SUCCESS (error response generated) or error — either is fine here */
    (void)status;

    fclose(g_tla_trace_file);
    g_tla_trace_file = NULL;

    free(ctx->mut_auth_cert_chain_buffer);
    free(ctx);

    printf("[PASS] trace_encap_error -> %s\n", out_path);
}

/**
 * trace_encap_not_ready — not-ready path:
 *   init_encap_state → get_encapsulated_request → encap_not_ready
 *   (Requester delivers ERROR(RESPONSE_NOT_READY))
 */
static void trace_encap_not_ready(const char *out_path)
{
    libspdm_context_t  *ctx;
    uint8_t             req_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    uint8_t             resp_buf[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t              resp_size;
    libspdm_return_t    status;
    uint8_t            *ptr;
    size_t              req_size;
    spdm_get_encapsulated_request_request_t get_encap_req;
    spdm_error_response_t *err_rsp;

    g_tla_trace_file = fopen(out_path, "w");
    assert(g_tla_trace_file != NULL);

    ctx = create_context();
    setup_common(ctx, false);
    ctx->encap_context.req_slot_id = 0;

    ctx->mut_auth_cert_chain_buffer = malloc(LIBSPDM_MAX_CERT_CHAIN_SIZE);
    assert(ctx->mut_auth_cert_chain_buffer != NULL);
    ctx->mut_auth_cert_chain_buffer_max_size = LIBSPDM_MAX_CERT_CHAIN_SIZE;
    ctx->mut_auth_cert_chain_buffer_size = 0;

    libspdm_reset_message_mut_b(ctx);
    libspdm_reset_message_mut_c(ctx);

    /* ── Step 1: init_encap_state ─────────────────────────────────────── */
    libspdm_init_basic_mut_auth_encap_state(ctx);

    /* ── Step 2: GET_ENCAP_REQ ─────────────────────────────────────────── */
    memset(&get_encap_req, 0, sizeof(get_encap_req));
    get_encap_req.header.spdm_version = SPDM_MESSAGE_VERSION_11;
    get_encap_req.header.request_response_code = SPDM_GET_ENCAPSULATED_REQUEST;

    resp_size = sizeof(resp_buf);
    status = libspdm_get_response_encapsulated_request(ctx,
        sizeof(get_encap_req), &get_encap_req, &resp_size, resp_buf);
    assert(status == LIBSPDM_STATUS_SUCCESS);

    /* ── Step 3: DELIVER with ERROR(NOT_READY) → encap_not_ready ──────── */
    ptr = req_buf;
    ptr += build_deliver_hdr(ptr, ctx->encap_context.request_id);

    err_rsp = (spdm_error_response_t *)ptr;
    err_rsp->header.spdm_version          = SPDM_MESSAGE_VERSION_11;
    err_rsp->header.request_response_code = SPDM_ERROR;
    err_rsp->header.param1                = SPDM_ERROR_CODE_RESPONSE_NOT_READY;
    err_rsp->header.param2                = 0;
    ptr += sizeof(spdm_error_response_t);

    req_size  = (size_t)(ptr - req_buf);
    resp_size = sizeof(resp_buf);
    status = libspdm_get_response_encapsulated_response_ack(ctx,
        req_size, req_buf, &resp_size, resp_buf);
    assert(status == LIBSPDM_STATUS_SUCCESS);

    fclose(g_tla_trace_file);
    g_tla_trace_file = NULL;

    free(ctx->mut_auth_cert_chain_buffer);
    free(ctx);

    printf("[PASS] trace_encap_not_ready -> %s\n", out_path);
}

/* ─────────────────────────────────── main ──────────────────────────────── */

int main(int argc, char *argv[])
{
    const char *out_dir = ".";

    if (argc >= 2) {
        out_dir = argv[1];
    }

    /* Build output paths */
    char path_basic_cert[512];
    char path_basic_pk[512];
    char path_encap_error[512];
    char path_not_ready[512];

    snprintf(path_basic_cert,   sizeof(path_basic_cert),   "%s/trace_basic_cert.ndjson",   out_dir);
    snprintf(path_basic_pk,     sizeof(path_basic_pk),     "%s/trace_basic_pk.ndjson",     out_dir);
    snprintf(path_encap_error,  sizeof(path_encap_error),  "%s/trace_encap_error.ndjson",  out_dir);
    snprintf(path_not_ready,    sizeof(path_not_ready),    "%s/trace_encap_not_ready.ndjson", out_dir);

    printf("Running TLA+ trace collection scenarios...\n");
    trace_basic_cert(path_basic_cert);
    trace_basic_pk(path_basic_pk);
    trace_encap_error(path_encap_error);
    trace_encap_not_ready(path_not_ready);
    printf("Done. Traces written to %s/\n", out_dir);
    return 0;
}
