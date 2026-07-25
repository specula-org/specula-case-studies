#include "tla_trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    const char *trace_file = "/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-secured-message/traces/test_trace_module.ndjson";
    tla_state_t state = {0};

    printf("Testing trace module...\n");

    /* Initialize trace output */
    tla_trace_init(trace_file);

    /* Set up state */
    state.session_state = 1;  /* HANDSHAKING */
    state.request_seq_num = 0;
    state.response_seq_num = 0;
    state.sequence_number_endian = 2;  /* LITTLE_DEC_BOTH */
    state.endian_determined_at = -1;
    state.key_update_phase = 0;  /* IDLE */
    state.backup_valid = false;
    state.application_secret = "key_0";
    state.application_secret_backup = NULL;
    state.secrets_cleared = false;

    /* Test 1: TransitionToEstablished */
    printf("Emitting transition_to_established...\n");
    tla_trace_emit_transition_to_established("requester", "sid_0", 1, 2, false);

    /* Test 2: CompleteZeroization */
    printf("Emitting complete_zeroization...\n");
    state.session_state = 2;  /* ESTABLISHED */
    tla_trace_emit_complete_zeroization("requester", "sid_0", &state, false, true);

    /* Test 3: EncodeSecuredMessage */
    printf("Emitting encode_message...\n");
    state.request_seq_num = 0;
    tla_trace_emit_encode_message("requester", "sid_0", &state, 0, 1, "key_0", NULL, 0, 34);
    state.request_seq_num = 1;

    /* Test 4: AttemptDecodeFirstEndian */
    printf("Emitting decode_first_endian...\n");
    state.response_seq_num = 1;
    state.sequence_number_endian = 2;
    tla_trace_emit_decode_first_endian("requester", "sid_0", &state, 0, 1, 2, 0, 1, true);
    state.sequence_number_endian = 0;  /* LITTLE_LITTLE after determination */

    /* Test 5: InitiateKeyUpdate */
    printf("Emitting initiate_key_update...\n");
    state.key_update_phase = 0;  /* IDLE */
    state.backup_valid = false;
    tla_trace_emit_initiate_key_update("requester", "sid_0", &state, 0, 1, true, "key_0", "key_v1");
    state.key_update_phase = 1;  /* PENDING */
    state.backup_valid = true;
    state.application_secret = "key_v1";
    state.application_secret_backup = "key_0";

    /* Test 6: ConfirmKeyUpdate */
    printf("Emitting confirm_key_update...\n");
    tla_trace_emit_confirm_key_update("requester", "sid_0", &state, 1, 2, true, false);
    state.key_update_phase = 2;  /* CONFIRMED */
    state.backup_valid = false;
    state.application_secret_backup = NULL;

    /* Test 7: RollbackToBackupKey */
    printf("Emitting rollback_backup_key...\n");
    state.key_update_phase = 1;  /* PENDING (reset for rollback demo) */
    state.backup_valid = true;
    state.application_secret = "key_v1";
    state.application_secret_backup = "key_0";
    tla_trace_emit_rollback_backup_key("requester", "sid_0", &state, 1, 0, "key_v1", "key_0", true);

    /* Shutdown */
    tla_trace_shutdown();

    printf("\nTrace file written to: %s\n", trace_file);
    printf("To verify, run: cat %s\n", trace_file);

    return 0;
}
