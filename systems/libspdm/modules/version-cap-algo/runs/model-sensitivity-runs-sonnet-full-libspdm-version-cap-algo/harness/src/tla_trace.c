/* Must precede all system headers to enable POSIX clock_gettime / struct timespec */
#define _POSIX_C_SOURCE 200809L

/**
 * TLA+ trace emission for libspdm VCA harness.
 *
 * Each emit writes one NDJSON line with "tag":"trace" (required by Trace.tla).
 * The trace file is opened with tla_trace_open() and closed with tla_trace_close().
 * All calls outside an open/close window are silently discarded.
 */
#include "tla_trace.h"
#include <stdio.h>
#include <time.h>
#include <string.h>

/* Capability flag bit-to-name table (matches base.tla AllCapFlags constants) */
typedef struct { uint32_t bit; const char *name; } cap_flag_entry_t;
static const cap_flag_entry_t g_cap_flags[] = {
    { 0x00000002, "CERT_CAP"                      },
    { 0x00000004, "CHAL_CAP"                      },
    { 0x00000008, "MEAS_CAP"                      }, /* meas_cap == 1 */
    { 0x00000010, "MEAS_CAP_SIG"                  }, /* meas_cap == 2 */
    { 0x00000040, "ENCRYPT_CAP"                   },
    { 0x00000080, "MAC_CAP"                       },
    { 0x00000100, "MUT_AUTH_CAP"                  },
    { 0x00000200, "KEY_EX_CAP"                    },
    { 0x00000400, "PSK_CAP_1"                     },
    { 0x00000800, "PSK_CAP_2"                     },
    { 0x00001000, "ENCAP_CAP"                     },
    { 0x00002000, "HBEAT_CAP"                     },
    { 0x00004000, "KEY_UPD_CAP"                   },
    { 0x00008000, "HANDSHAKE_IN_THE_CLEAR_CAP"    },
    { 0x00010000, "PUB_KEY_ID_CAP"                },
    { 0x01000000, "MEL_CAP"                       },
    { 0, NULL }
};

static FILE *g_trace_file = NULL;

/* Monotonic timestamp in nanoseconds */
static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

void tla_trace_open(const char *filename) {
    if (g_trace_file) {
        fclose(g_trace_file);
    }
    g_trace_file = fopen(filename, "w");
}

void tla_trace_close(void) {
    if (g_trace_file) {
        fflush(g_trace_file);
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
}

/* --- helpers --- */

static const char *conn_state_str(uint32_t s) {
    switch (s) {
    case 0: return "NOT_STARTED";
    case 1: return "AFTER_VERSION";
    case 2: return "AFTER_CAPS";
    case 3: return "NEGOTIATED";
    default: return "NOT_STARTED";
    }
}

static const char *version_str(uint8_t vb) {
    switch (vb) {
    case 0x10: return "1.0";
    case 0x11: return "1.1";
    case 0x12: return "1.2";
    case 0x13: return "1.3";
    case 0x14: return "1.4";
    default:   return "1.0";
    }
}

/* Write cap flags as JSON array: ["CERT_CAP","KEY_EX_CAP",...] */
static void write_cap_flags(FILE *f, uint32_t flags) {
    fputc('[', f);
    int first = 1;
    for (int i = 0; g_cap_flags[i].name != NULL; i++) {
        if (flags & g_cap_flags[i].bit) {
            if (!first) fputc(',', f);
            fprintf(f, "\"%s\"", g_cap_flags[i].name);
            first = 0;
        }
    }
    fputc(']', f);
}

/* Write alg_types as JSON object with six ALG_* keys */
static void write_alg_types(FILE *f, uint32_t mask) {
    fprintf(f, "{\"ALG_DHE\":%s,\"ALG_AEAD\":%s,\"ALG_REQ_ASYM\":%s,"
               "\"ALG_KEY_SCHEDULE\":%s,\"ALG_REQ_PQC_ASYM\":%s,\"ALG_KEM\":%s}",
            (mask & TLA_ALG_DHE)          ? "true" : "false",
            (mask & TLA_ALG_AEAD)         ? "true" : "false",
            (mask & TLA_ALG_REQ_ASYM)     ? "true" : "false",
            (mask & TLA_ALG_KEY_SCHEDULE) ? "true" : "false",
            (mask & TLA_ALG_REQ_PQC_ASYM) ? "true" : "false",
            (mask & TLA_ALG_KEM)          ? "true" : "false");
}

/* --- VERSION phase --- */

void tla_trace_req_send_get_version(uint32_t conn_state) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"req_send_get_version\","
        "\"conn_state\":\"%s\","
        "\"req_appended_version\":true,\"rsp_appended_version\":false}\n",
        (unsigned long long)now_ns(), conn_state_str(conn_state));
    fflush(g_trace_file);
}

void tla_trace_rsp_handle_get_version(uint32_t conn_state, uint8_t offered_ver_byte) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_handle_get_version\","
        "\"offered_version\":\"%s\","
        "\"conn_state\":\"%s\","
        "\"req_appended_version\":true,\"rsp_appended_version\":true}\n",
        (unsigned long long)now_ns(),
        version_str(offered_ver_byte),
        conn_state_str(conn_state));
    fflush(g_trace_file);
}

void tla_trace_req_handle_version(uint32_t conn_state, uint8_t negotiated_ver_byte) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"req_handle_version\","
        "\"negotiated_version\":\"%s\","
        "\"conn_state\":\"%s\","
        "\"rsp_appended_version\":true}\n",
        (unsigned long long)now_ns(),
        version_str(negotiated_ver_byte),
        conn_state_str(conn_state));
    fflush(g_trace_file);
}

/* --- CAPABILITIES phase --- */

void tla_trace_req_send_get_capabilities(uint32_t conn_state, uint32_t req_cap_flags) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"req_send_get_capabilities\","
        "\"conn_state\":\"%s\","
        "\"req_cap_flags\":",
        (unsigned long long)now_ns(), conn_state_str(conn_state));
    write_cap_flags(g_trace_file, req_cap_flags);
    fprintf(g_trace_file, ",\"req_appended_capabilities\":true,\"rsp_appended_capabilities\":false}\n");
    fflush(g_trace_file);
}

void tla_trace_rsp_handle_get_capabilities(uint32_t conn_state,
                                            uint32_t req_cap_flags,
                                            uint32_t rsp_cap_flags) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_handle_get_capabilities\","
        "\"conn_state\":\"%s\","
        "\"req_cap_flags\":",
        (unsigned long long)now_ns(), conn_state_str(conn_state));
    write_cap_flags(g_trace_file, req_cap_flags);
    fprintf(g_trace_file, ",\"rsp_cap_flags\":");
    write_cap_flags(g_trace_file, rsp_cap_flags);
    fprintf(g_trace_file, ",\"req_appended_capabilities\":true,\"rsp_appended_capabilities\":true}\n");
    fflush(g_trace_file);
}

void tla_trace_req_handle_capabilities(uint32_t conn_state, uint32_t rsp_cap_flags) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"req_handle_capabilities\","
        "\"conn_state\":\"%s\","
        "\"rsp_cap_flags\":",
        (unsigned long long)now_ns(), conn_state_str(conn_state));
    write_cap_flags(g_trace_file, rsp_cap_flags);
    fprintf(g_trace_file, ",\"rsp_appended_capabilities\":true}\n");
    fflush(g_trace_file);
}

void tla_trace_rsp_error_capabilities(uint32_t conn_state) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_error_capabilities\","
        "\"conn_state\":\"%s\","
        "\"req_appended_capabilities\":true,\"rsp_appended_capabilities\":false}\n",
        (unsigned long long)now_ns(), conn_state_str(conn_state));
    fflush(g_trace_file);
}

/* --- ALGORITHMS phase --- */

void tla_trace_req_send_negotiate_algorithms(uint32_t conn_state, uint32_t req_alg_types_mask) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"req_send_negotiate_algorithms\","
        "\"conn_state\":\"%s\","
        "\"req_alg_types\":",
        (unsigned long long)now_ns(), conn_state_str(conn_state));
    write_alg_types(g_trace_file, req_alg_types_mask);
    fprintf(g_trace_file, ",\"req_appended_algorithms\":true,\"rsp_appended_algorithms\":false}\n");
    fflush(g_trace_file);
}

void tla_trace_rsp_handle_negotiate_algorithms(uint32_t conn_state,
                                                uint32_t base_hash_algo,
                                                uint32_t base_asym_algo,
                                                uint32_t measurement_spec,
                                                uint32_t measurement_hash_algo,
                                                uint32_t dhe_algo,
                                                uint32_t aead_algo,
                                                uint32_t req_asym_algo,
                                                uint32_t key_schedule_algo,
                                                uint32_t rsp_alg_types_mask) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_handle_negotiate_algorithms\","
        "\"conn_state\":\"%s\","
        "\"base_hash_algo\":%u,\"base_asym_algo\":%u,"
        "\"measurement_spec\":%u,\"measurement_hash_algo\":%u,"
        "\"dhe_algo\":%u,\"aead_algo\":%u,"
        "\"req_asym_algo\":%u,\"key_schedule_algo\":%u,"
        "\"rsp_alg_types\":",
        (unsigned long long)now_ns(), conn_state_str(conn_state),
        base_hash_algo, base_asym_algo,
        measurement_spec, measurement_hash_algo,
        dhe_algo, aead_algo,
        req_asym_algo, key_schedule_algo);
    write_alg_types(g_trace_file, rsp_alg_types_mask);
    fprintf(g_trace_file, ",\"req_appended_algorithms\":true,\"rsp_appended_algorithms\":true}\n");
    fflush(g_trace_file);
}

void tla_trace_req_handle_algorithms(uint32_t conn_state,
                                      uint32_t base_hash_algo,
                                      uint32_t base_asym_algo,
                                      uint32_t measurement_spec,
                                      uint32_t measurement_hash_algo,
                                      uint32_t rsp_alg_types_mask) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"req_handle_algorithms\","
        "\"conn_state\":\"%s\","
        "\"base_hash_algo\":%u,\"base_asym_algo\":%u,"
        "\"measurement_spec\":%u,\"measurement_hash_algo\":%u,"
        "\"rsp_alg_types\":",
        (unsigned long long)now_ns(), conn_state_str(conn_state),
        base_hash_algo, base_asym_algo,
        measurement_spec, measurement_hash_algo);
    write_alg_types(g_trace_file, rsp_alg_types_mask);
    fprintf(g_trace_file, ",\"rsp_appended_algorithms\":true}\n");
    fflush(g_trace_file);
}

void tla_trace_rsp_error_algorithms(uint32_t conn_state) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_error_algorithms\","
        "\"conn_state\":\"%s\","
        "\"req_appended_algorithms\":true,\"rsp_appended_algorithms\":false}\n",
        (unsigned long long)now_ns(), conn_state_str(conn_state));
    fflush(g_trace_file);
}

/* --- Context reset (called explicitly from test code) --- */

void tla_trace_context_reset(uint32_t conn_state_before) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"context_reset\","
        "\"conn_state\":\"%s\"}\n",
        (unsigned long long)now_ns(), conn_state_str(conn_state_before));
    fflush(g_trace_file);
}
