/* SPDX-License-Identifier: GPL-2.0-or-later
 * Trace-only instrumentation for iccpd.  No trace metadata is serialized on
 * ICCP or mclagsyncd sockets and none of these hooks influences protocol
 * guards or state transitions.
 */
#ifndef ICCPD_TLA_TRACE_H
#define ICCPD_TLA_TRACE_H

#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>
#include <unistd.h>

struct CSM;
struct LocalInterface;
struct PeerInterface;

enum tla_trace_write_mode {
    TLA_TRACE_WRITE_NORMAL = 0,
    TLA_TRACE_WRITE_PARTIAL,
    TLA_TRACE_WRITE_HEADER_PARTIAL,
    TLA_TRACE_WRITE_FAILED,
};

#ifdef ICCPD_TLA_TRACE

int tla_trace_open(const char *path, struct CSM *n1, struct CSM *n2);
void tla_trace_close(void);
bool tla_trace_is_open(void);

void tla_trace_register_lag(struct CSM *csm, struct LocalInterface *lif,
                            struct PeerInterface *pif);
void tla_trace_set_write_mode(struct CSM *csm,
                              enum tla_trace_write_mode mode);
ssize_t tla_trace_write(struct CSM *csm, int fd, const void *buf,
                        size_t count);

void tla_trace_prepare_event(struct CSM *csm, const char *event,
                             const char *context, const char *kind,
                             int version, int generation, bool up);
void tla_trace_record_send_result(struct CSM *csm, ssize_t rc,
                                  size_t expected);
void tla_trace_emit_recorded_send_result(struct CSM *csm);
void tla_trace_send_result(struct CSM *csm, ssize_t rc, size_t expected);

void tla_trace_event(struct CSM *csm, const char *event);
void tla_trace_event_bool(struct CSM *csm, const char *event, bool value);
void tla_trace_event_version(struct CSM *csm, const char *event, int version);

/* Transport read hooks.  They preserve the split Corrupt/ReadError actions. */
void tla_trace_partial_header(struct CSM *csm);
void tla_trace_body_retry(struct CSM *csm);
void tla_trace_read_error(struct CSM *csm);
bool tla_trace_disconnect_prelogged(struct CSM *csm);

/* Test-controller/supervisor hooks for actions with no in-process boundary. */
void tla_trace_supervisor_event(struct CSM *csm, const char *event);

#else

static inline int tla_trace_open(const char *path, struct CSM *n1,
                                 struct CSM *n2)
{ (void)path; (void)n1; (void)n2; return 0; }
static inline void tla_trace_close(void) {}
static inline bool tla_trace_is_open(void) { return false; }
static inline void tla_trace_register_lag(struct CSM *csm,
        struct LocalInterface *lif, struct PeerInterface *pif)
{ (void)csm; (void)lif; (void)pif; }
static inline void tla_trace_set_write_mode(struct CSM *csm,
        enum tla_trace_write_mode mode) { (void)csm; (void)mode; }
static inline ssize_t tla_trace_write(struct CSM *csm, int fd,
        const void *buf, size_t count)
{ (void)csm; return write(fd, buf, count); }
static inline void tla_trace_prepare_event(struct CSM *csm,
        const char *event, const char *context, const char *kind,
        int version, int generation, bool up)
{ (void)csm; (void)event; (void)context; (void)kind; (void)version;
  (void)generation; (void)up; }
static inline void tla_trace_record_send_result(struct CSM *csm,
        ssize_t rc, size_t expected)
{ (void)csm; (void)rc; (void)expected; }
static inline void tla_trace_emit_recorded_send_result(struct CSM *csm)
{ (void)csm; }
static inline void tla_trace_send_result(struct CSM *csm, ssize_t rc,
        size_t expected) { (void)csm; (void)rc; (void)expected; }
static inline void tla_trace_event(struct CSM *csm, const char *event)
{ (void)csm; (void)event; }
static inline void tla_trace_event_bool(struct CSM *csm, const char *event,
        bool value) { (void)csm; (void)event; (void)value; }
static inline void tla_trace_event_version(struct CSM *csm,
        const char *event, int version)
{ (void)csm; (void)event; (void)version; }
static inline void tla_trace_partial_header(struct CSM *csm) { (void)csm; }
static inline void tla_trace_body_retry(struct CSM *csm) { (void)csm; }
static inline void tla_trace_read_error(struct CSM *csm) { (void)csm; }
static inline bool tla_trace_disconnect_prelogged(struct CSM *csm)
{ (void)csm; return false; }
static inline void tla_trace_supervisor_event(struct CSM *csm,
        const char *event) { (void)csm; (void)event; }

#endif /* ICCPD_TLA_TRACE */
#endif /* ICCPD_TLA_TRACE_H */
