/**
 * Global variable definitions for the TLA+ trace module.
 * Link exactly one translation unit with this file.
 */
#ifdef TLA_TRACE_ENABLED
#include <stdio.h>
#include <stdint.h>
FILE *g_tla_trace_fp = NULL;
uint32_t g_tla_last_session_raw_id = 0;
#endif
