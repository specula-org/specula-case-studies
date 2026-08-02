/*
 * MC-2 Level-2 reproduction.
 *
 * This links the unmodified iccpd production sources and drives their normal
 * public scheduler receive callback plus mlacp_fsm_transit() over a real TCP
 * connection.  The only injected precondition is the established/exchange
 * state and each need_to_sync edge from counterexample States 2 and 4.
 */

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "app_csm.h"
#include "iccp_csm.h"
#include "mlacp_fsm.h"
#include "mlacp_tlv.h"
#include "msg_format.h"
#include "scheduler.h"
#include "system.h"

struct frame_info {
    uint16_t tlv_type;
    uint16_t request_number;
    uint16_t flags;
    size_t total_len;
};

static void fail(const char *what)
{
    fprintf(stderr, "FAIL: %s (errno=%d: %s)\n", what, errno,
            strerror(errno));
    exit(1);
}

static void check(bool condition, const char *what)
{
    if (!condition) {
        errno = 0;
        fail(what);
    }
}

static void make_tcp_pair(int pair[2])
{
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);
    int listener;
    int one = 1;

    listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listener < 0)
        fail("socket(listener)");
    if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0)
        fail("setsockopt(listener)");

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) < 0)
        fail("bind(listener)");
    if (listen(listener, 1) < 0)
        fail("listen(listener)");
    if (getsockname(listener, (struct sockaddr *)&addr, &addr_len) < 0)
        fail("getsockname(listener)");

    pair[0] = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (pair[0] < 0)
        fail("socket(client)");
    if (connect(pair[0], (struct sockaddr *)&addr, sizeof(addr)) < 0)
        fail("connect(client)");

    pair[1] = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
    if (pair[1] < 0)
        fail("accept(listener)");
    close(listener);
}

static void init_established_csm(struct CSM *csm, int fd, int mlag_id,
                                 stp_role_type_et role, uint8_t node_id)
{
    memset(csm, 0, sizeof(*csm));
    iccp_csm_init(csm);
    csm->sock_fd = fd;
    csm->mlag_id = mlag_id;
    csm->role_type = role;
    csm->current_state = ICCP_OPERATIONAL;
    csm->app_csm.current_state = APP_OPERATIONAL;
    csm->keepalive_time = 3600;
    csm->session_timeout = 10;
    csm->heartbeat_send_time = time(NULL);
    csm->heartbeat_update_time = time(NULL);
    MLACP(csm).current_state = MLACP_STATE_EXCHANGE;
    MLACP(csm).wait_for_sync_data = 0;
    MLACP(csm).need_to_sync = 0;
    MLACP(csm).node_id = node_id;
}

static int wait_readable(int fd, int timeout_ms)
{
    struct pollfd pfd = {
        .fd = fd,
        .events = POLLIN,
    };
    int rc;

    do {
        rc = poll(&pfd, 1, timeout_ms);
    } while (rc < 0 && errno == EINTR);
    if (rc < 0)
        fail("poll");
    return rc > 0 && (pfd.revents & POLLIN) != 0;
}

static struct frame_info peek_frame(int fd, int timeout_ms)
{
    uint8_t header_buf[sizeof(LDPHdr)];
    uint8_t frame[CSM_BUFFER_SIZE];
    const LDPHdr *ldp;
    const ICCParameter *parameter;
    struct frame_info info;
    size_t total_len;
    ssize_t got;

    memset(&info, 0, sizeof(info));
    info.request_number = UINT16_MAX;
    info.flags = UINT16_MAX;

    check(wait_readable(fd, timeout_ms), "timed out waiting for ICCP frame");
    got = recv(fd, header_buf, sizeof(header_buf), MSG_PEEK | MSG_WAITALL);
    if (got != (ssize_t)sizeof(header_buf))
        fail("peek LDP header");

    ldp = (const LDPHdr *)header_buf;
    total_len = (size_t)ntohs(ldp->msg_len)
                + MSG_L_INCLUD_U_BIT_MSG_T_L_FIELDS;
    check(total_len >= sizeof(ICCHdr) + sizeof(ICCParameter),
          "invalid short ICCP frame");
    check(total_len <= sizeof(frame), "ICCP frame exceeds CSM buffer");

    got = recv(fd, frame, total_len, MSG_PEEK | MSG_WAITALL);
    if (got != (ssize_t)total_len)
        fail("peek complete ICCP frame");

    parameter = (const ICCParameter *)&frame[sizeof(ICCHdr)];
    info.tlv_type = ntohs(parameter->type);
    info.total_len = total_len;
    if (info.tlv_type == TLV_T_MLACP_SYNC_REQUEST) {
        const mLACPSyncReqTLV *request =
            (const mLACPSyncReqTLV *)&frame[sizeof(ICCHdr)];
        info.request_number = ntohs(request->req_num);
    } else if (info.tlv_type == TLV_T_MLACP_SYNC_DATA) {
        const mLACPSyncDataTLV *data =
            (const mLACPSyncDataTLV *)&frame[sizeof(ICCHdr)];
        info.request_number = ntohs(data->req_num);
        info.flags = ntohs(data->flags);
    }
    return info;
}

static void receive_one_normal_frame(struct CSM *csm)
{
    int rc = scheduler_csm_read_callback(csm);

    check(rc == 1, "production scheduler receive callback rejected frame");
    mlacp_fsm_transit(csm);
}

static void format_mac(const uint8_t id[ETHER_ADDR_LEN], char out[18])
{
    snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x",
             id[0], id[1], id[2], id[3], id[4], id[5]);
}

static void read_syncd_system_id(int fd, uint8_t id[ETHER_ADDR_LEN])
{
    struct IccpSyncdHDr header;
    uint8_t body[256];
    size_t body_len;
    size_t pos = 0;
    ssize_t got;
    bool found = false;
    unsigned messages = 0;

    while (!found && messages++ < 8) {
        check(wait_readable(fd, 1000),
              "mclagsyncd did not receive system ID");
        got = recv(fd, &header, sizeof(header), MSG_WAITALL);
        if (got != (ssize_t)sizeof(header))
            fail("read mclagsyncd header");
        check(header.len >= sizeof(header), "short mclagsyncd message");
        body_len = (size_t)header.len - sizeof(header);
        check(body_len <= sizeof(body), "oversized mclagsyncd message");
        got = recv(fd, body, body_len, MSG_WAITALL);
        if (got != (ssize_t)body_len)
            fail("read mclagsyncd body");
        if (header.type != MCLAG_MSG_TYPE_SET_ICCP_SYSTEM_ID)
            continue;

        pos = 0;
        while (pos + sizeof(mclag_sub_option_hdr_t) <= body_len) {
            const mclag_sub_option_hdr_t *option =
                (const mclag_sub_option_hdr_t *)&body[pos];
            size_t option_len = sizeof(*option) + option->op_len;

            check(pos + option_len <= body_len,
                  "invalid mclagsyncd sub-option");
            if (option->op_type == MCLAG_SUB_OPTION_TYPE_SYSTEM_ID) {
                check(option->op_len == ETHER_ADDR_LEN,
                      "invalid mclagsyncd system ID length");
                memcpy(id, option->data, ETHER_ADDR_LEN);
                found = true;
            }
            pos += option_len;
        }
    }
    check(found, "mclagsyncd system ID option missing");
}

int main(void)
{
    static const uint8_t snapshot_one[ETHER_ADDR_LEN] =
        {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
    static const uint8_t snapshot_two[ETHER_ADDR_LEN] =
        {0x02, 0x00, 0x00, 0x00, 0x00, 0x02};
    struct System *sys;
    struct CSM requester;
    struct CSM responder;
    struct frame_info request_one;
    struct frame_info request_two;
    struct frame_info response;
    uint8_t consumer_id[ETHER_ADDR_LEN];
    char consumer_text[18];
    char current_text[18];
    int peer_tcp[2];
    int syncd_pair[2];
    unsigned response_frames = 0;
    uint16_t start_number = UINT16_MAX;
    uint16_t end_number = UINT16_MAX;

    printf("LEVEL 2: inject admissible CE States 2/4 (established need_to_sync edges); use real TCP + production scheduler/FSM\n");

    sys = system_get_instance();
    check(sys != NULL, "system_get_instance");
    make_tcp_pair(peer_tcp);
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, syncd_pair) < 0)
        fail("socketpair(mclagsyncd)");

    init_established_csm(&requester, peer_tcp[0], 101, STP_ROLE_STANDBY, 1);
    init_established_csm(&responder, peer_tcp[1], 102, STP_ROLE_ACTIVE, 2);
    memcpy(MLACP((&responder)).system_id, snapshot_one, ETHER_ADDR_LEN);
    MLACP((&responder)).system_priority = 100;

    /* Counterexample State 2: first established resync request. */
    MLACP((&requester)).need_to_sync = 1;
    mlacp_fsm_transit(&requester);
    request_one = peek_frame(responder.sock_fd, 1000);
    check(request_one.tlv_type == TLV_T_MLACP_SYNC_REQUEST,
          "first outbound frame is not Sync Request");

    /* Counterexample State 4: a second edge before response one is read. */
    MLACP((&requester)).need_to_sync = 1;
    mlacp_fsm_transit(&requester);
    printf("REQUESTS: two resync sends completed before responder read request 1; wait_for_sync_data=%u\n",
           MLACP((&requester)).wait_for_sync_data);

    receive_one_normal_frame(&responder);
    printf("WIRE request 1: req_num=%u; responder state after full response=%s\n",
           request_one.request_number, mlacp_state(&responder));

    /*
     * Snapshot changes after response one is serialized and before request two.
     * This mirrors scheduler.c:528-531: a normal interface-MAC observation
     * replaces system_id and raises system_config_changed.
     */
    memcpy(MLACP((&responder)).system_id, snapshot_two, ETHER_ADDR_LEN);
    MLACP((&responder)).system_priority = 200;
    MLACP((&responder)).system_config_changed = 1;
    request_two = peek_frame(responder.sock_fd, 1000);
    check(request_two.tlv_type == TLV_T_MLACP_SYNC_REQUEST,
          "second outbound frame is not Sync Request");
    printf("WIRE request 2: req_num=%u; latest peer snapshot is 02:00:00:00:00:02; system_config_changed=%u\n",
           request_two.request_number,
           MLACP((&responder)).system_config_changed);

    check(request_one.request_number == 0 && request_two.request_number == 0,
          "requests unexpectedly have distinct nonzero correlation IDs");
    check(MLACP((&requester)).wait_for_sync_data == 0,
          "established request unexpectedly serialized on wait_for_sync_data");

    /* Observe the real downstream mclagsyncd consumer of response one. */
    sys->sync_fd = syncd_pair[0];
    for (;;) {
        response = peek_frame(requester.sock_fd, 1000);
        ++response_frames;
        if (response.tlv_type == TLV_T_MLACP_SYNC_DATA) {
            printf("RESPONSE 1 envelope: %s req_num=%u\n",
                   response.flags == 0 ? "START" : "END",
                   response.request_number);
            if (response.flags == 0)
                start_number = response.request_number;
            if (response.flags == 1)
                end_number = response.request_number;
        }
        receive_one_normal_frame(&requester);
        if (response.tlv_type == TLV_T_MLACP_SYNC_DATA
            && response.flags == 1)
            break;
    }

    read_syncd_system_id(syncd_pair[1], consumer_id);
    format_mac(consumer_id, consumer_text);
    format_mac(MLACP((&requester)).remote_system.system_id, current_text);
    printf("REAL CONSUMER mclagsyncd: applied response-1 system_id=%s\n",
           consumer_text);
    printf("REQUESTER remote_system after response 1: id=%s priority=%u frames=%u\n",
           current_text, MLACP((&requester)).remote_system.system_priority,
           response_frames);

    check(start_number == 0 && end_number == 0,
          "response envelope unexpectedly correlated with a nonzero request");
    check(memcmp(consumer_id, snapshot_one, ETHER_ADDR_LEN) == 0,
          "mclagsyncd did not observe response-one snapshot");
    check(memcmp(MLACP((&requester)).remote_system.system_id,
                 snapshot_one, ETHER_ADDR_LEN) == 0,
          "requester did not apply response-one snapshot");

    /* Production's separate responder-state defect now consumes request 2. */
    receive_one_normal_frame(&responder);
    check(MLACP((&responder)).current_state == MLACP_STATE_ERROR,
          "expected established responder transition to ERROR did not fire");
    check(MLACP((&responder)).system_config_changed == 1,
          "ERROR state unexpectedly sent the reachable pending system update");
    check(!wait_readable(requester.sock_fd, 250),
          "unexpected second synchronization response was emitted");
    check(!wait_readable(syncd_pair[1], 100),
          "unexpected second mclagsyncd update was emitted");
    check(memcmp(MLACP((&requester)).remote_system.system_id,
                 snapshot_one, ETHER_ADDR_LEN) == 0,
          "response-one state did not remain after request two was consumed");

    printf("SECOND RESPONSE: absent; production responder remains %s and consumes request 2 without replying\n",
           mlacp_state(&responder));
    printf("CONTROL: latest snapshot 02:00:00:00:00:02 was not observed by requester or mclagsyncd\n");
    printf("MASK PROVED: req_num=0/no outstanding guard is real, but MC-2 live harm cannot be isolated: mlacp_sync_send_all_info_handler's separate EXCHANGE->ERROR transition carries the stale-state consequence\n");

    close(peer_tcp[0]);
    close(peer_tcp[1]);
    close(syncd_pair[0]);
    close(syncd_pair[1]);
    return 0;
}
