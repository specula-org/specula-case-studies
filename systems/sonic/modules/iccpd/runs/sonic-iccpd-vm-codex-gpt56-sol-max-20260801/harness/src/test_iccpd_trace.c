/* SPDX-License-Identifier: GPL-2.0-or-later
 * Real-code trace scenarios for SONiC iccpd.  The controller supplies local
 * socketpair peers and a local syncd endpoint; protocol preparation, writes,
 * epoll receive, mLACP dispatch, disconnect, and LAG handling are production
 * iccpd functions.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "app_csm.h"
#include "iccp_csm.h"
#include "iccp_netlink.h"
#include "mlacp_fsm.h"
#include "mlacp_link_handler.h"
#include "port.h"
#include "scheduler.h"
#include "system.h"
#include "tla_trace.h"

extern void mlacp_sync_send_warmboot_flag(void);

struct fixture {
    struct System *sys;
    struct CSM *n1;
    struct CSM *n2;
    int peer_socket[2];
    int syncd_socket[2];
};

static void fail(const char *what)
{
    fprintf(stderr, "trace scenario failed: %s (errno=%d: %s)\n",
            what, errno, strerror(errno));
    exit(1);
}

static void require_true(bool condition, const char *what)
{
    if (!condition)
        fail(what);
}

static void set_operational(struct CSM *csm, int fd,
                            MLACP_APP_STATE_E mlacp_state)
{
    time_t now = time(NULL);

    csm->sock_fd = fd;
    csm->current_state = ICCP_OPERATIONAL;
    csm->app_csm.current_state = APP_OPERATIONAL;
    MLACP(csm).current_state = mlacp_state;
    MLACP(csm).sync_state = MLACP_SYNC_DONE;
    MLACP(csm).need_to_sync = 0;
    MLACP(csm).wait_for_sync_data = 0;
    csm->heartbeat_send_time = now;
    csm->heartbeat_update_time = now;
    csm->session_timeout = 0;
    csm->iccp_info.icc_rg_id = 100;
}

static void register_receive_fd(struct fixture *fx, struct CSM *receiver)
{
    struct epoll_event event;

    fx->sys->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (fx->sys->epoll_fd < 0)
        fail("epoll_create1");

    memset(&event, 0, sizeof(event));
    event.data.fd = receiver->sock_fd;
    event.events = EPOLLIN;
    if (epoll_ctl(fx->sys->epoll_fd, EPOLL_CTL_ADD,
                  receiver->sock_fd, &event) < 0)
        fail("epoll_ctl add peer socket");

    FD_ZERO(&fx->sys->readfd);
    FD_SET(receiver->sock_fd, &fx->sys->readfd);
    fx->sys->readfd_count = 1;
}

static void move_socketpair_above_system_fds(int pair[2], int first_fd)
{
    int moved[2];

    moved[0] = fcntl(pair[0], F_DUPFD_CLOEXEC, first_fd);
    if (moved[0] < 0)
        fail("dup first socketpair endpoint");
    moved[1] = fcntl(pair[1], F_DUPFD_CLOEXEC, first_fd + 1);
    if (moved[1] < 0)
        fail("dup second socketpair endpoint");
    close(pair[0]);
    close(pair[1]);
    pair[0] = moved[0];
    pair[1] = moved[1];
}

static void fixture_init(struct fixture *fx, const char *trace_path)
{
    memset(fx, 0, sizeof(*fx));
    fx->peer_socket[0] = fx->peer_socket[1] = -1;
    fx->syncd_socket[0] = fx->syncd_socket[1] = -1;

    fx->sys = system_get_instance();
    require_true(fx->sys != NULL, "system_get_instance");

    fx->n1 = system_create_csm();
    fx->n2 = system_create_csm();
    require_true(fx->n1 != NULL && fx->n2 != NULL, "system_create_csm pair");

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fx->peer_socket) < 0)
        fail("peer socketpair");
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fx->syncd_socket) < 0)
        fail("syncd socketpair");
    /* system_init retains some failed low-numbered event descriptors.  Keep
     * controller sockets outside that descriptor range so iccp_handle_events
     * dispatches them through the real peer-socket branch. */
    move_socketpair_above_system_fds(fx->peer_socket, 100);
    move_socketpair_above_system_fds(fx->syncd_socket, 110);

    set_operational(fx->n1, fx->peer_socket[0], MLACP_STATE_EXCHANGE);
    /* Stage2 keeps the receiver out of the global warmboot sender loop. */
    set_operational(fx->n2, fx->peer_socket[1], MLACP_STATE_STAGE2);
    fx->sys->sync_fd = fx->syncd_socket[0];
    register_receive_fd(fx, fx->n2);

    if (tla_trace_open(trace_path, fx->n1, fx->n2) < 0)
        fail("tla_trace_open");
}

static void send_one_warmboot(struct fixture *fx,
                              enum tla_trace_write_mode mode)
{
    tla_trace_set_write_mode(fx->n1, mode);
    mlacp_sync_send_warmboot_flag();
    MLACP(fx->n2).current_state = MLACP_STATE_EXCHANGE;
}

static void scenario_warmboot_full(const char *trace_path)
{
    struct fixture fx;

    fixture_init(&fx, trace_path);
    send_one_warmboot(&fx, TLA_TRACE_WRITE_NORMAL);

    require_true(iccp_handle_events(fx.sys) == 0,
                 "iccp_handle_events full warmboot");
    mlacp_fsm_transit(fx.n2);
    require_true(fx.n2->peer_warm_reboot_time != 0,
                 "production warmboot TLV update");

    scheduler_session_disconnect_handler(fx.n2);
    require_true(fx.n2->sock_fd < 0, "production disconnect cleanup");
    tla_trace_close();
}

static void scenario_warmboot_partial(const char *trace_path)
{
    struct fixture fx;

    fixture_init(&fx, trace_path);
    send_one_warmboot(&fx, TLA_TRACE_WRITE_PARTIAL);
    if (shutdown(fx.n1->sock_fd, SHUT_WR) < 0)
        fail("shutdown partial writer");

    require_true(iccp_handle_events(fx.sys) == 0,
                 "iccp_handle_events partial warmboot");
    require_true(fx.n2->sock_fd < 0,
                 "partial body read reaches production disconnect");
    tla_trace_close();
}

static void scenario_warmboot_failed(const char *trace_path)
{
    struct fixture fx;

    fixture_init(&fx, trace_path);
    send_one_warmboot(&fx, TLA_TRACE_WRITE_FAILED);
    require_true(fx.n1->sock_fd > 0,
                 "failed write leaves production session descriptor intact");

    /* A second real caller attempt injects only four header bytes.  This
     * reaches the distinct production blocking-header/read-error boundary. */
    MLACP(fx.n2).current_state = MLACP_STATE_STAGE2;
    send_one_warmboot(&fx, TLA_TRACE_WRITE_HEADER_PARTIAL);
    if (shutdown(fx.n1->sock_fd, SHUT_WR) < 0)
        fail("shutdown header-partial writer");
    require_true(iccp_handle_events(fx.sys) == 0,
                 "iccp_handle_events partial header");
    require_true(fx.n2->sock_fd < 0,
                 "partial header reaches production disconnect");
    tla_trace_close();
}

static void scenario_portchannel_down(const char *trace_path)
{
    struct fixture fx;
    struct LocalInterface *lif;
    struct LocalInterface *lif_fail;
    struct PeerInterface *pif;
    struct PeerInterface *pif_fail;

    fixture_init(&fx, trace_path);
    MLACP(fx.n2).current_state = MLACP_STATE_EXCHANGE;

    lif = local_if_create(100, "PortChannel100", IF_T_PORT_CHANNEL,
                          PORT_STATE_UP);
    require_true(lif != NULL, "local_if_create PortChannel100");
    require_true(mlacp_bind_local_if(fx.n1, lif) == 0,
                 "mlacp_bind_local_if PortChannel100");
    pif = peer_if_create(fx.n1, 100, IF_T_PORT_CHANNEL);
    require_true(pif != NULL, "peer_if_create PortChannel100");
    snprintf(pif->name, sizeof(pif->name), "%s", "PortChannel100");

    lif->po_active = 1;
    lif->changed = 0;
    lif->isolate_to_peer_link = 1;
    lif->is_traffic_disable = false;
    pif->po_active = 1;
    tla_trace_register_lag(fx.n1, lif, pif);

    mlacp_portchannel_state_handler(fx.n1, lif, 0);
    require_true(!lif->po_active && lif->changed,
                 "real PortChannel state mutation");
    require_true(lif->is_traffic_disable,
                 "real syncd traffic-disable success bookkeeping");

    /* Keep the positive syncd descriptor but close its peer so the second
     * node observes a real failed sidecar write (EPIPE), not a fake return. */
    close(fx.syncd_socket[1]);
    fx.syncd_socket[1] = -1;
    lif_fail = local_if_create(200, "PortChannel200", IF_T_PORT_CHANNEL,
                               PORT_STATE_UP);
    require_true(lif_fail != NULL, "local_if_create PortChannel200");
    require_true(mlacp_bind_local_if(fx.n2, lif_fail) == 0,
                 "mlacp_bind_local_if PortChannel200");
    pif_fail = peer_if_create(fx.n2, 200, IF_T_PORT_CHANNEL);
    require_true(pif_fail != NULL, "peer_if_create PortChannel200");
    snprintf(pif_fail->name, sizeof(pif_fail->name), "%s", "PortChannel200");
    lif_fail->po_active = 1;
    lif_fail->changed = 0;
    lif_fail->isolate_to_peer_link = 1;
    lif_fail->is_traffic_disable = false;
    pif_fail->po_active = 1;
    tla_trace_register_lag(fx.n2, lif_fail, pif_fail);

    mlacp_portchannel_state_handler(fx.n2, lif_fail, 0);
    require_true(!lif_fail->po_active && lif_fail->changed,
                 "real failed-side PortChannel state mutation");
    require_true(!lif_fail->is_traffic_disable,
                 "failed syncd write leaves traffic bookkeeping unchanged");
    tla_trace_close();
}

int main(int argc, char **argv)
{
    const char *scenario;
    const char *trace_path;

    if (argc != 3) {
        fprintf(stderr, "usage: %s SCENARIO TRACE_FILE\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    scenario = argv[1];
    trace_path = argv[2];

    if (strcmp(scenario, "warmboot_full") == 0)
        scenario_warmboot_full(trace_path);
    else if (strcmp(scenario, "warmboot_partial") == 0)
        scenario_warmboot_partial(trace_path);
    else if (strcmp(scenario, "warmboot_failed") == 0)
        scenario_warmboot_failed(trace_path);
    else if (strcmp(scenario, "portchannel_down") == 0)
        scenario_portchannel_down(trace_path);
    else {
        fprintf(stderr, "unknown scenario: %s\n", scenario);
        return 2;
    }

    printf("scenario %s wrote %s\n", scenario, trace_path);
    return 0;
}
