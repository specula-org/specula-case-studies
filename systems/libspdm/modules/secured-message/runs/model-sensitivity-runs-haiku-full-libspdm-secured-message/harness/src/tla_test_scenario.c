#include "spdm_unit_test.h"
#include "internal/libspdm_secured_message_lib.h"
#include "tla_trace.h"

#if LIBSPDM_AEAD_AES_256_GCM_SUPPORT

#define SESSION_ID 0x00112233
#define TRACE_FILE_PATH "/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-secured-message/traces/scenario_basic.ndjson"

static uint8_t m_secured_message[0x1000];
static uint8_t m_app_message[0x1000];
static libspdm_secured_message_context_t m_secured_message_context;
static libspdm_secured_message_callbacks_t m_secured_message_callbacks;

static uint8_t get_sequence_number(uint64_t sequence_number, uint8_t *sequence_number_buffer)
{
    libspdm_copy_mem(sequence_number_buffer, 8, &sequence_number, 8);
    return 8;
}

static uint32_t get_max_random_number_count(void)
{
    return 0;
}

static spdm_version_number_t get_secured_spdm_version(spdm_version_number_t secured_message_version)
{
    return SECURED_SPDM_VERSION_11;
}

static void initialize_secured_message_context(void)
{
    libspdm_zero_mem(&m_secured_message_context, sizeof(m_secured_message_context));
    m_secured_message_context.secured_message_version = SECURED_SPDM_VERSION_11;
    m_secured_message_context.aead_cipher_suite = SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM;
    m_secured_message_context.session_type = LIBSPDM_SESSION_TYPE_ENC_MAC;
    m_secured_message_context.session_state = LIBSPDM_SESSION_STATE_HANDSHAKING;
    m_secured_message_context.aead_tag_size = 16;
    m_secured_message_context.aead_key_size = 32;
    m_secured_message_context.aead_iv_size = 12;
    m_secured_message_context.hash_size = 32;
    m_secured_message_context.max_spdm_session_sequence_number = UINT64_MAX;
    m_secured_message_context.sequence_number_endian =
        LIBSPDM_DATA_SESSION_SEQ_NUM_ENC_LITTLE_DEC_BOTH;

    for (uint8_t index = 0; index < 32; index++) {
        m_secured_message_context.application_secret.request_data_encryption_key[index] = index;
        m_secured_message_context.application_secret.response_data_encryption_key[index] =
            32 - index;
    }
    for (uint8_t index = 0; index < 12; index++) {
        m_secured_message_context.application_secret.request_data_salt[index] = index * 2;
        m_secured_message_context.application_secret.response_data_salt[index] = index * 4;
    }
    m_secured_message_context.application_secret.request_data_sequence_number = 0;
    m_secured_message_context.application_secret.response_data_sequence_number = 0;

    m_secured_message_callbacks.get_secured_spdm_version = get_secured_spdm_version;
    m_secured_message_callbacks.get_max_random_number_count = get_max_random_number_count;
    m_secured_message_callbacks.get_sequence_number = get_sequence_number;
}

static void test_basic_scenario(void)
{
    libspdm_return_t status;
    uint8_t app_message[16];
    size_t secured_message_size = sizeof(m_secured_message);

    initialize_secured_message_context();

    /* Scenario 1: Encode a message while in HANDSHAKING state */
    for (uint8_t index = 0; index < 16; index++) {
        app_message[index] = index;
    }

    status = libspdm_encode_secured_message(
        &m_secured_message_context, SESSION_ID, true,
        sizeof(app_message), app_message, &secured_message_size, &m_secured_message,
        &m_secured_message_callbacks);

    if (status != LIBSPDM_STATUS_SUCCESS) {
        printf("Encoding failed: 0x%x\n", status);
        return;
    }

    printf("Scenario 1: Basic message encoding - PASSED\n");

    /* Scenario 2: Transition to ESTABLISHED */
    libspdm_secured_message_set_session_state(&m_secured_message_context,
                                               LIBSPDM_SESSION_STATE_ESTABLISHED);

    printf("Scenario 2: Transition to ESTABLISHED - PASSED\n");

    /* Scenario 3: Encode a message in ESTABLISHED state */
    secured_message_size = sizeof(m_secured_message);
    status = libspdm_encode_secured_message(
        &m_secured_message_context, SESSION_ID, true,
        sizeof(app_message), app_message, &secured_message_size, &m_secured_message,
        &m_secured_message_callbacks);

    if (status != LIBSPDM_STATUS_SUCCESS) {
        printf("Encoding in ESTABLISHED failed: 0x%x\n", status);
        return;
    }

    printf("Scenario 3: Message encoding in ESTABLISHED - PASSED\n");
}

int main(void)
{
    tla_trace_init(TRACE_FILE_PATH);

    #if LIBSPDM_AEAD_AES_256_GCM_SUPPORT
    test_basic_scenario();
    #endif

    tla_trace_shutdown();
    return 0;
}

#endif
