/**
 * tla_trace.c — NDJSON trace emission implementation for libspdm instrumentation.
 * Compiled into the test binary; instrumented library .o files resolve symbols here.
 */

#define _POSIX_C_SOURCE 199309L
#include "tla_trace.h"
#include <stdio.h>
#include <pthread.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>

static FILE            *g_trace_file  = NULL;
static pthread_mutex_t  g_trace_mtx   = PTHREAD_MUTEX_INITIALIZER;
static int              g_msg_m_pairs = 0;

void tla_trace_init(const char *path)
{
    pthread_mutex_lock(&g_trace_mtx);
    if (g_trace_file) {
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
    g_trace_file  = fopen(path, "w");
    g_msg_m_pairs = 0;
    pthread_mutex_unlock(&g_trace_mtx);
}

void tla_trace_emit(const char *event, const char *data_json, const char *post_json)
{
    struct timespec ts;
    long long       ts_ns;

    if (!g_trace_file) return;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    ts_ns = (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;

    pthread_mutex_lock(&g_trace_mtx);
    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"ts\":\"%lld\",\"event\":\"%s\",\"data\":%s,\"post\":%s}\n",
            ts_ns, event, data_json, post_json);
    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_mtx);
}

void tla_trace_fini(void)
{
    pthread_mutex_lock(&g_trace_mtx);
    if (g_trace_file) {
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
    pthread_mutex_unlock(&g_trace_mtx);
}

void tla_trace_incr_pairs(void)
{
    pthread_mutex_lock(&g_trace_mtx);
    g_msg_m_pairs++;
    pthread_mutex_unlock(&g_trace_mtx);
}

void tla_trace_reset_pairs(void)
{
    pthread_mutex_lock(&g_trace_mtx);
    g_msg_m_pairs = 0;
    pthread_mutex_unlock(&g_trace_mtx);
}

int tla_trace_get_pairs(void)
{
    int v;
    pthread_mutex_lock(&g_trace_mtx);
    v = g_msg_m_pairs;
    pthread_mutex_unlock(&g_trace_mtx);
    return v;
}
