// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef _FRR_SPECULA_TRACE_H
#define _FRR_SPECULA_TRACE_H

#include <stdbool.h>
#include <stdint.h>

#include "lib/prefix.h"

#ifdef __cplusplus
extern "C" {
#endif

void specula_trace_bgp_zebra_route_install(const struct prefix *p, bool install);
void specula_trace_bgp_handle_route_announcement(const struct prefix *p,
						 bool install,
						 int send_status);
void specula_trace_zread_route_notify_request(bool notify);

void specula_trace_rib_addnode(const struct prefix *p, uint32_t table,
			       int route_type, uint16_t instance);
void specula_trace_rib_delnode(const struct prefix *p, uint32_t table,
			       int route_type, uint16_t instance);
void specula_trace_rib_meta_queue_add(const struct prefix *p, uint32_t table,
				      int route_type, uint16_t instance,
				      uint8_t qindex);
void specula_trace_meta_queue_process(const struct prefix *p, uint32_t table,
				      int route_type, uint16_t instance,
				      uint8_t qindex);
void specula_trace_rib_process(const struct prefix *p, uint32_t table,
			       int route_type, uint16_t instance);
void specula_trace_rib_install_kernel(const struct prefix *p, uint32_t table,
				      int route_type, uint16_t instance);
void specula_trace_rib_uninstall_kernel(const struct prefix *p, uint32_t table,
					int route_type, uint16_t instance);

void specula_trace_dplane_ctx_route_init(const void *ctx, const struct prefix *p,
					 uint32_t table, const char *op,
					 int route_type, uint16_t instance,
					 uint32_t real_seq,
					 uint32_t real_old_seq);
void specula_trace_dplane_update_enqueue(const void *ctx, bool ok);
void specula_trace_dplane_thread_loop_to_provider(const void *ctx);
void specula_trace_kernel_result(const void *ctx, const char *status,
				 bool kernel_touched, bool skip_kernel);
void specula_trace_dplane_thread_loop_result(const void *ctx);
void specula_trace_rib_process_result(const void *ctx, const char *note,
				      const char *status);

void specula_trace_route_notify_internal(const struct prefix *p, int route_type,
					 uint16_t instance, uint32_t table,
					 const char *note, bool delivered);
void specula_trace_bgp_route_notify_owner(const struct prefix *p,
					  const char *note);

void specula_trace_zebra_add_rnh(const struct prefix *p);
void specula_trace_zebra_rnh_store(const struct prefix *p);
void specula_trace_zebra_rnh_resolve(const struct prefix *p);
void specula_trace_zebra_send_rnh_update(const struct prefix *p);
void specula_trace_zebra_dplane_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* _FRR_SPECULA_TRACE_H */
