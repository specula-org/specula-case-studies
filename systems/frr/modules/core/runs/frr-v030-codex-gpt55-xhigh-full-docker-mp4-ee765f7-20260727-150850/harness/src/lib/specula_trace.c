// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Specula trace emission for Zebra route-realization validation.
 *
 * This module is dormant unless SPECULA_TRACE_FILE is set. It uses stable,
 * bounded identifiers for the traced prefix subset so Trace.tla does not have
 * to observe unrelated connected/kernel route contexts from the topotest.
 */

#include <zebra.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "lib/specula_trace.h"

#define SPECULA_MAX_PREFIXES 2
#define SPECULA_MAX_CTX 1024
#define SPECULA_MAX_LINE 4096
#define SPECULA_NOTIFY_FILE_MAX 16384

struct specula_route {
	char configured[PREFIX2STR_BUFFER];
	char symbol[3];
	bool configured_p;
	bool pending_meta;
	bool rnh_registered;
	bool rnh_attached;
	bool pending_rnh_resolve;
	uint32_t table;
	uint32_t gen;
	uint32_t attrs;
	uint32_t selected_fib;
	uint32_t dplane_seq;
	uint32_t bgp_selected_gen;
	uint32_t pending_meta_table;
	uint8_t pending_meta_qindex;
};

struct specula_ctx {
	bool used;
	bool provider_done;
	const void *ptr;
	int pidx;
	uint32_t id;
	uint32_t table;
	uint32_t gen;
	uint32_t seq;
	uint32_t old_seq;
	uint32_t attrs;
	char op[16];
	char status[16];
};

struct specula_notify {
	bool used;
	int pidx;
	uint32_t id;
	uint32_t cause_gen;
	char note[32];
};

static pthread_mutex_t specula_lock = PTHREAD_MUTEX_INITIALIZER;
static bool specula_inited;
static bool specula_enabled;
static int specula_fd = -1;
static char specula_trace_path[512];
static char specula_notify_path[512];
static struct specula_route specula_routes[SPECULA_MAX_PREFIXES];
static struct specula_ctx specula_ctxs[SPECULA_MAX_CTX];
static struct specula_notify specula_notifies[SPECULA_MAX_CTX];
static uint32_t specula_next_ctx_id = 1;
static uint32_t specula_next_seq = 1;

static void specula_strlcpy(char *dst, const char *src, size_t size)
{
	if (size == 0)
		return;
	if (!src)
		src = "";
	snprintf(dst, size, "%s", src);
}

static void specula_init_locked(void)
{
	const char *path;
	const char *p1;
	const char *p2;
	const char *notify_path;

	if (specula_inited)
		return;
	specula_inited = true;

	path = getenv("SPECULA_TRACE_FILE");
	if (!path || !path[0])
		return;

	specula_strlcpy(specula_trace_path, path, sizeof(specula_trace_path));
	specula_fd = open(specula_trace_path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC,
			 0644);
	if (specula_fd < 0)
		return;
	(void)fchmod(specula_fd, 0666);

	p1 = getenv("SPECULA_PREFIX_P1");
	p2 = getenv("SPECULA_PREFIX_P2");
	if (!p1 || !p1[0])
		p1 = "10.0.0.0/24";
	if (!p2 || !p2[0])
		p2 = "10.0.0.0/8";

	specula_strlcpy(specula_routes[0].configured, p1,
		       sizeof(specula_routes[0].configured));
	specula_strlcpy(specula_routes[0].symbol, "p1",
		       sizeof(specula_routes[0].symbol));
	specula_routes[0].configured_p = true;

	specula_strlcpy(specula_routes[1].configured, p2,
		       sizeof(specula_routes[1].configured));
	specula_strlcpy(specula_routes[1].symbol, "p2",
		       sizeof(specula_routes[1].symbol));
	specula_routes[1].configured_p = true;

	notify_path = getenv("SPECULA_NOTIFY_STATE");
	if (notify_path && notify_path[0])
		specula_strlcpy(specula_notify_path, notify_path,
			       sizeof(specula_notify_path));

	specula_enabled = true;
}

static bool specula_ready_locked(void)
{
	specula_init_locked();
	return specula_enabled && specula_fd >= 0;
}

static int specula_prefix_index_locked(const struct prefix *p)
{
	char buf[PREFIX2STR_BUFFER];
	int i;

	if (!p)
		return -1;

	prefix2str(p, buf, sizeof(buf));
	for (i = 0; i < SPECULA_MAX_PREFIXES; i++) {
		if (specula_routes[i].configured_p &&
		    strcmp(buf, specula_routes[i].configured) == 0)
			return i;
	}
	return -1;
}

static uint32_t specula_table_norm(uint32_t table)
{
	return table <= 1024 ? table : 0;
}

static void specula_write_locked(const char *line, size_t len)
{
	if (specula_fd < 0)
		return;

	(void)flock(specula_fd, LOCK_EX);
	(void)write(specula_fd, line, len);
	(void)flock(specula_fd, LOCK_UN);
}

static const char *specula_bool(bool value)
{
	return value ? "true" : "false";
}

static struct specula_ctx *specula_find_ctx_locked(const void *ptr)
{
	int i;

	if (!ptr)
		return NULL;
	for (i = 0; i < SPECULA_MAX_CTX; i++) {
		if (specula_ctxs[i].used && specula_ctxs[i].ptr == ptr)
			return &specula_ctxs[i];
	}
	return NULL;
}

static struct specula_ctx *specula_alloc_ctx_locked(const void *ptr)
{
	int i;
	struct specula_ctx *ctx = specula_find_ctx_locked(ptr);

	if (ctx)
		return ctx;

	for (i = 0; i < SPECULA_MAX_CTX; i++) {
		if (!specula_ctxs[i].used) {
			memset(&specula_ctxs[i], 0, sizeof(specula_ctxs[i]));
			specula_ctxs[i].used = true;
			specula_ctxs[i].ptr = ptr;
			return &specula_ctxs[i];
		}
	}
	return NULL;
}

static void specula_emit_locked(const char *name, int pidx,
				const struct specula_ctx *ctx,
				uint32_t table, uint32_t gen, const char *op,
				uint32_t seq, uint32_t old_seq,
				const char *status, uint32_t attrs, bool stale,
				bool kernel_touched, uint32_t qindex,
				uint32_t notify_id, const char *note,
				uint32_t cause_gen, const char *extra_fmt, ...)
{
	char line[SPECULA_MAX_LINE];
	char extra[512] = "";
	struct timespec ts;
	int n;
	va_list ap;
	uint32_t ctx_id = ctx ? ctx->id : 0;
	const char *prefix = pidx >= 0 ? specula_routes[pidx].symbol : "p1";

	if (extra_fmt && extra_fmt[0]) {
		va_start(ap, extra_fmt);
		vsnprintf(extra, sizeof(extra), extra_fmt, ap);
		va_end(ap);
	}

	clock_gettime(CLOCK_REALTIME, &ts);

	n = snprintf(line, sizeof(line),
		     "{\"tag\":\"frr_route_realization\","
		     "\"ts\":\"%lld.%09ld\","
		     "\"event\":{\"name\":\"%s\","
		     "\"prefix\":\"%s\",\"owner\":\"bgp0\","
		     "\"table\":%u,\"gen\":%u,"
		     "\"ctxId\":%u,\"op\":\"%s\","
		     "\"seq\":%u,\"oldSeq\":%u,"
		     "\"status\":\"%s\",\"attrs\":%u,"
		     "\"stale\":%s,\"kernelTouched\":%s,"
		     "\"notifyId\":%u,\"note\":\"%s\","
		     "\"causeGen\":%u,\"qindex\":%u%s,"
		     "\"state\":{}}}\n",
		     (long long)ts.tv_sec, ts.tv_nsec, name, prefix,
		     specula_table_norm(table), gen, ctx_id, op ? op : "none",
		     seq, old_seq, status ? status : "none", attrs,
		     specula_bool(stale), specula_bool(kernel_touched),
		     notify_id, note ? note : "none", cause_gen, qindex, extra);

	if (n > 0) {
		if ((size_t)n >= sizeof(line))
			n = sizeof(line) - 1;
		specula_write_locked(line, (size_t)n);
	}
}

static void specula_emit_route_locked(const char *name, int pidx, uint32_t table,
				      uint32_t qindex)
{
	struct specula_route *rt = &specula_routes[pidx];

	specula_emit_locked(name, pidx, NULL, table, rt->gen, "none", 0, 0,
			    "none", rt->attrs, false, false, qindex, 0, "none",
			    rt->gen, NULL);
}

static void specula_flush_meta_locked(int pidx)
{
	struct specula_route *rt = &specula_routes[pidx];

	if (!rt->pending_meta)
		return;

	rt->pending_meta = false;
	specula_emit_route_locked("rib_meta_queue_add", pidx,
				  rt->pending_meta_table,
				  rt->pending_meta_qindex);
}

static void specula_flush_rnh_resolve_locked(int pidx)
{
	struct specula_route *rt = &specula_routes[pidx];

	if (!rt->pending_rnh_resolve || !rt->rnh_attached)
		return;

	rt->pending_rnh_resolve = false;
	specula_emit_route_locked("zebra_rnh_resolve_nexthop_entry", pidx,
				  rt->table, 0);
}

static struct specula_notify *specula_save_notify_locked(int pidx,
							uint32_t id,
							uint32_t cause_gen,
							const char *note)
{
	int i;

	for (i = 0; i < SPECULA_MAX_CTX; i++) {
		if (!specula_notifies[i].used) {
			specula_notifies[i].used = true;
			specula_notifies[i].pidx = pidx;
			specula_notifies[i].id = id;
			specula_notifies[i].cause_gen = cause_gen;
			specula_strlcpy(specula_notifies[i].note, note,
				       sizeof(specula_notifies[i].note));
			return &specula_notifies[i];
		}
	}
	return NULL;
}

static struct specula_notify *specula_find_notify_locked(int pidx,
							const char *note)
{
	int i;

	for (i = 0; i < SPECULA_MAX_CTX; i++) {
		if (specula_notifies[i].used && specula_notifies[i].pidx == pidx &&
		    strcmp(specula_notifies[i].note, note) == 0)
			return &specula_notifies[i];
	}
	return NULL;
}

static void specula_notify_sidecar_append_locked(int pidx,
						 const struct specula_notify *n)
{
	int fd;
	char line[128];
	int len;

	if (!n || !specula_notify_path[0])
		return;

	fd = open(specula_notify_path, O_CREAT | O_RDWR | O_APPEND | O_CLOEXEC,
		  0644);
	if (fd < 0)
		return;

	(void)flock(fd, LOCK_EX);
	len = snprintf(line, sizeof(line), "%s %s %u %u 0\n",
		       specula_routes[pidx].symbol, n->note, n->id,
		       n->cause_gen);
	if (len > 0)
		(void)write(fd, line, (size_t)len);
	(void)flock(fd, LOCK_UN);
	close(fd);
}

static bool specula_notify_sidecar_take_locked(int pidx, const char *note,
					       uint32_t *id, uint32_t *cause_gen)
{
	int fd;
	ssize_t nr;
	char buf[SPECULA_NOTIFY_FILE_MAX + 1];
	char out[SPECULA_NOTIFY_FILE_MAX + 1];
	char *saveptr = NULL;
	char *line;
	size_t out_len = 0;
	bool found = false;

	if (!specula_notify_path[0])
		return false;

	fd = open(specula_notify_path, O_CREAT | O_RDWR | O_CLOEXEC, 0644);
	if (fd < 0)
		return false;

	(void)flock(fd, LOCK_EX);
	nr = read(fd, buf, SPECULA_NOTIFY_FILE_MAX);
	if (nr < 0)
		nr = 0;
	buf[nr] = '\0';

	line = strtok_r(buf, "\n", &saveptr);
	while (line) {
		char sym[16], line_note[32];
		unsigned int line_id, line_gen, used;
		bool consume = false;

		if (sscanf(line, "%15s %31s %u %u %u", sym, line_note,
			   &line_id, &line_gen, &used) == 5) {
			if (!found && used == 0 &&
			    strcmp(sym, specula_routes[pidx].symbol) == 0 &&
			    strcmp(line_note, note) == 0) {
				*id = line_id;
				*cause_gen = line_gen;
				used = 1;
				found = true;
				consume = true;
			}
			out_len += snprintf(out + out_len, sizeof(out) - out_len,
					    "%s %s %u %u %u\n", sym, line_note,
					    line_id, line_gen, used);
		} else {
			out_len += snprintf(out + out_len, sizeof(out) - out_len,
					    "%s\n", line);
		}
		if (out_len >= sizeof(out))
			break;
		(void)consume;
		line = strtok_r(NULL, "\n", &saveptr);
	}

	if (found) {
		(void)ftruncate(fd, 0);
		(void)lseek(fd, 0, SEEK_SET);
		(void)write(fd, out, out_len);
	}

	(void)flock(fd, LOCK_UN);
	close(fd);
	return found;
}

void specula_trace_bgp_zebra_route_install(const struct prefix *p, bool install)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked() && install) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0) {
			specula_routes[pidx].bgp_selected_gen++;
			specula_emit_locked("bgp_zebra_route_install", pidx, NULL,
					    specula_routes[pidx].table,
					    specula_routes[pidx].bgp_selected_gen,
					    "none", 0, 0, "none",
					    specula_routes[pidx].attrs, false,
					    false, 0, 0, "none",
					    specula_routes[pidx].bgp_selected_gen,
					    NULL);
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_bgp_handle_route_announcement(const struct prefix *p,
						 bool install,
						 int send_status)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked() && install) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0) {
			const char *event = send_status < 0
						    ? "ZapiSendFail"
						    : "bgp_handle_route_announcements_to_zebra";

			specula_emit_locked(event, pidx, NULL,
					    specula_routes[pidx].table,
					    specula_routes[pidx].bgp_selected_gen,
					    "none", 0, 0,
					    send_status < 0 ? "failure" : "success",
					    specula_routes[pidx].attrs, false,
					    false, 0, 0, "none",
					    specula_routes[pidx].bgp_selected_gen,
					    NULL);
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_zread_route_notify_request(bool notify)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked() && notify)
		specula_emit_locked("zread_route_notify_request", 0, NULL, 0, 0,
				    "none", 0, 0, "none", 0, false, false, 0,
				    0, "none", 0, NULL);
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_rib_addnode(const struct prefix *p, uint32_t table,
			       int route_type, uint16_t instance)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0) {
			specula_routes[pidx].table = specula_table_norm(table);
			specula_routes[pidx].gen++;
			specula_routes[pidx].attrs =
				(specula_routes[pidx].attrs + 1) % 2;
			specula_emit_route_locked("rib_addnode", pidx, table, 0);
			specula_flush_meta_locked(pidx);
		}
	}
	(void)route_type;
	(void)instance;
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_rib_delnode(const struct prefix *p, uint32_t table,
			       int route_type, uint16_t instance)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0) {
			specula_emit_route_locked("rib_delnode", pidx, table, 0);
			specula_flush_meta_locked(pidx);
		}
	}
	(void)route_type;
	(void)instance;
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_rib_meta_queue_add(const struct prefix *p, uint32_t table,
				      int route_type, uint16_t instance,
				      uint8_t qindex)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0) {
			struct specula_route *rt = &specula_routes[pidx];

			if (rt->pending_meta)
				specula_flush_meta_locked(pidx);
			rt->pending_meta = true;
			rt->pending_meta_table = table;
			rt->pending_meta_qindex = qindex;
		}
	}
	(void)route_type;
	(void)instance;
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_meta_queue_process(const struct prefix *p, uint32_t table,
				      int route_type, uint16_t instance,
				      uint8_t qindex)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0) {
			specula_flush_meta_locked(pidx);
			specula_emit_route_locked("meta_queue_process", pidx,
						 table, qindex);
		}
	}
	(void)route_type;
	(void)instance;
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_rib_process(const struct prefix *p, uint32_t table,
			       int route_type, uint16_t instance)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0) {
			specula_flush_meta_locked(pidx);
			specula_emit_route_locked("rib_process", pidx, table, 0);
		}
	}
	(void)route_type;
	(void)instance;
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_rib_install_kernel(const struct prefix *p, uint32_t table,
				      int route_type, uint16_t instance)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0) {
			specula_routes[pidx].selected_fib = specula_routes[pidx].gen;
			specula_emit_route_locked("rib_install_kernel", pidx, table,
						 0);
		}
	}
	(void)route_type;
	(void)instance;
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_rib_uninstall_kernel(const struct prefix *p, uint32_t table,
					int route_type, uint16_t instance)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0)
			specula_emit_route_locked("rib_uninstall_kernel", pidx,
						 table, 0);
	}
	(void)route_type;
	(void)instance;
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_dplane_ctx_route_init(const void *ptr, const struct prefix *p,
					 uint32_t table, const char *op,
					 int route_type, uint16_t instance,
					 uint32_t real_seq,
					 uint32_t real_old_seq)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);
		struct specula_ctx *ctx;

		if (pidx >= 0 && specula_routes[pidx].gen > 0) {
			ctx = specula_alloc_ctx_locked(ptr);
			if (ctx) {
				memset(ctx, 0, sizeof(*ctx));
				ctx->used = true;
				ctx->ptr = ptr;
				ctx->pidx = pidx;
				ctx->id = specula_next_ctx_id++;
				ctx->seq = specula_next_seq++;
				ctx->old_seq = specula_routes[pidx].dplane_seq;
				ctx->table = specula_table_norm(table);
				ctx->gen = specula_routes[pidx].gen;
				ctx->attrs = specula_routes[pidx].attrs;
				specula_strlcpy(ctx->op, op, sizeof(ctx->op));
				specula_strlcpy(ctx->status, "pending",
					       sizeof(ctx->status));
				specula_routes[pidx].dplane_seq = ctx->seq;
				specula_emit_locked(
					"dplane_ctx_route_init", pidx, ctx, table,
					ctx->gen, ctx->op, ctx->seq, ctx->old_seq,
					"pending", ctx->attrs, false, false, 0, 0,
					"none", ctx->gen,
					",\"realSeq\":%u,\"realOldSeq\":%u",
					real_seq, real_old_seq);
			}
		}
	}
	(void)route_type;
	(void)instance;
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_dplane_update_enqueue(const void *ptr, bool ok)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		struct specula_ctx *ctx = specula_find_ctx_locked(ptr);

		if (ctx) {
			specula_emit_locked(
				ok ? "dplane_update_enqueue"
				   : "dplane_update_enqueue_failure",
				ctx->pidx, ctx, ctx->table, ctx->gen, ctx->op,
				ctx->seq, ctx->old_seq, ok ? "pending" : "failure",
				ctx->attrs, false, false, 0, 0, "none", ctx->gen,
				NULL);
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_dplane_thread_loop_to_provider(const void *ptr)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		struct specula_ctx *ctx = specula_find_ctx_locked(ptr);

		if (ctx)
			specula_emit_locked("dplane_thread_loop_to_provider",
					    ctx->pidx, ctx, ctx->table, ctx->gen,
					    ctx->op, ctx->seq, ctx->old_seq,
					    "pending", ctx->attrs, false, false, 0,
					    0, "none", ctx->gen, NULL);
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_kernel_result(const void *ptr, const char *status,
				 bool kernel_touched, bool skip_kernel)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		struct specula_ctx *ctx = specula_find_ctx_locked(ptr);
		const char *event = NULL;

		if (ctx) {
			specula_strlcpy(ctx->status, status, sizeof(ctx->status));
			if (skip_kernel && strcmp(ctx->op, "update") == 0) {
				event = "kernel_dplane_process_func_skip_kernel";
			} else if (strcmp(status, "failure") == 0) {
				event = "kernel_dplane_process_func_failure";
			} else if (strcmp(ctx->op, "install") == 0 ||
				   strcmp(ctx->op, "update") == 0) {
				event = "kernel_dplane_process_func_success";
			}

			if (event) {
				ctx->provider_done = true;
				specula_emit_locked(event, ctx->pidx, ctx, ctx->table,
						    ctx->gen, ctx->op, ctx->seq,
						    ctx->old_seq, status, ctx->attrs,
						    false, kernel_touched, 0, 0,
						    "none", ctx->gen, NULL);
			}
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_dplane_thread_loop_result(const void *ptr)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		struct specula_ctx *ctx = specula_find_ctx_locked(ptr);

		if (ctx && ctx->provider_done)
			specula_emit_locked("dplane_thread_loop_result", ctx->pidx,
					    ctx, ctx->table, ctx->gen, ctx->op,
					    ctx->seq, ctx->old_seq, ctx->status,
					    ctx->attrs, false, false, 0, 0, "none",
					    ctx->gen, NULL);
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_rib_process_result(const void *ptr, const char *note,
				      const char *status)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		struct specula_ctx *ctx = specula_find_ctx_locked(ptr);

		if (ctx && ctx->provider_done) {
			struct specula_notify *n;

			n = specula_save_notify_locked(ctx->pidx, ctx->id, ctx->gen,
						       note);
			specula_emit_locked("rib_process_result", ctx->pidx, ctx,
					    ctx->table, ctx->gen, ctx->op,
					    ctx->seq, ctx->old_seq, status,
					    ctx->attrs, false, false, 0,
					    n ? n->id : ctx->id, note, ctx->gen,
					    NULL);
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_route_notify_internal(const struct prefix *p, int route_type,
					 uint16_t instance, uint32_t table,
					 const char *note, bool delivered)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);
		struct specula_notify *n;

		if (pidx >= 0) {
			n = specula_find_notify_locked(pidx, note);
			if (n) {
				specula_emit_locked("route_notify_internal", pidx, NULL,
						    table, n->cause_gen, "none", 0,
						    0, "none",
						    specula_routes[pidx].attrs,
						    false, false, 0, n->id, note,
						    n->cause_gen, NULL);
				if (delivered)
					specula_notify_sidecar_append_locked(pidx, n);
				n->used = false;
			}
		}
	}
	(void)route_type;
	(void)instance;
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_bgp_route_notify_owner(const struct prefix *p,
					  const char *note)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);
		uint32_t id = 0;
		uint32_t cause_gen = 0;

		if (pidx >= 0 &&
		    specula_notify_sidecar_take_locked(pidx, note, &id,
						       &cause_gen)) {
			specula_emit_locked("bgp_zebra_route_notify_owner", pidx,
					    NULL, specula_routes[pidx].table,
					    cause_gen, "none", 0, 0, "none",
					    specula_routes[pidx].attrs, false,
					    false, 0, id, note, cause_gen, NULL);
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_zebra_add_rnh(const struct prefix *p)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0) {
			specula_routes[pidx].rnh_registered = true;
			if (specula_routes[pidx].selected_fib != 0)
				specula_routes[pidx].rnh_attached = true;
			specula_emit_route_locked("zebra_add_rnh", pidx,
						 specula_routes[pidx].table, 0);
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_zebra_rnh_store(const struct prefix *p)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0 && specula_routes[pidx].selected_fib != 0) {
			specula_routes[pidx].rnh_attached = true;
			specula_emit_route_locked("zebra_rnh_store_in_routing_table",
						 pidx, specula_routes[pidx].table,
						 0);
			specula_flush_rnh_resolve_locked(pidx);
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_zebra_rnh_resolve(const struct prefix *p)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0 && specula_routes[pidx].selected_fib != 0) {
			if (specula_routes[pidx].rnh_attached)
				specula_emit_route_locked(
					"zebra_rnh_resolve_nexthop_entry", pidx,
					specula_routes[pidx].table, 0);
			else
				specula_routes[pidx].pending_rnh_resolve = true;
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_zebra_send_rnh_update(const struct prefix *p)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked()) {
		int pidx = specula_prefix_index_locked(p);

		if (pidx >= 0 && specula_routes[pidx].selected_fib != 0) {
			specula_flush_rnh_resolve_locked(pidx);
			specula_emit_route_locked("zebra_send_rnh_update", pidx,
						 specula_routes[pidx].table, 0);
		}
	}
	pthread_mutex_unlock(&specula_lock);
}

void specula_trace_zebra_dplane_shutdown(void)
{
	pthread_mutex_lock(&specula_lock);
	if (specula_ready_locked())
		specula_emit_locked("zebra_dplane_shutdown", 0, NULL, 0, 0, "none",
				    0, 0, "none", 0, false, false, 0, 0,
				    "none", 0, NULL);
	pthread_mutex_unlock(&specula_lock);
}
