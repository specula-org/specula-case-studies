/*
 * MC-1 / AST-32 reproduction: failed SCM_RIGHTS FD-number publication
 * retains an installed FD in the receiver's file table.
 *
 * Mechanism under test (Asterinas pin 0c6053709):
 *   kernel/core/src/net/socket/unix/ctrl_msg.rs:184 installs each referenced
 *   file into the receiver's file table (table.insert) BEFORE copying the FD
 *   integer to the user control buffer (write_val_observed::<i32> at :203).
 *   When the FD-integer copy faults (PROT_NONE page), the error propagates to
 *   ControlMessage::write_all_to (message_header.rs:115), which swallows it,
 *   reports control length 0 plus MSG_CTRUNC, and lets the syscall succeed.
 *   The just-installed entry is never removed: an fd that was never published
 *   to user space stays open in the receiver's file table (fd leak aliasing
 *   the received file object).  In the mid-list (prefix) fault case, the two
 *   successfully published FD integers are additionally misreported: the
 *   reported msg_controllen is 0 instead of the delivered prefix length
 *   (Linux v6.15 scm_detach_fds reports CMSG_SPACE(i * sizeof(int)) = 24 for
 *   2 of 4 delivered FDs, and never installs the failed entry because it
 *   orders reserve -> put_user -> fd_install with put_unused_fd on failure).
 *
 * The test runs both as the static init inside the Asterinas guest (serial
 * console) and as an ordinary process on Linux, and prints one JSON line per
 * step so the two kernels can be compared directly:
 *
 *   MC1_SYSTEM, MC1_PROBE, MC1_PEEK_FIRST_FAULT, MC1_PEEK_RETRY,
 *   MC1_ORD_FIRST_FAULT, MC1_ORD_PREFIX_FAULT, MC1_RESULT, MC1_DONE.
 *
 * Trigger (all public APIs, no failpoints, no source patch):
 *   1. socketpair(AF_UNIX, SOCK_DGRAM|SOCK_NONBLOCK); send one SCM_RIGHTS
 *      cmsg carrying 4 fds [A, B, A, B] plus a 1-byte payload.
 *   2. Map a 2-page region and mprotect page 2 PROT_NONE.  Place the 32-byte
 *      control buffer so the 16-byte cmsghdr lands in page 1 and an FD
 *      integer lands in page 2 (the kernel's copy_to_user then returns
 *      EFAULT while writing the FD number, after the file was installed).
 *   3. recvmsg with MSG_PEEK (message retained) or flags 0 (consumed).
 *
 * Layouts:
 *   ENTRY_FAULT  control buffer at page1_end - 16: cmsghdr fits exactly,
 *                the first FD integer (offset 16) faults.
 *   PREFIX_FAULT control buffer at page1_end - 24: FD0 and FD1 integers are
 *                writable, FD2 (offset 24) faults.
 *
 * Detection (no /proc needed): SlotVec::put and Linux alloc_fd both allocate
 * the LOWEST free fd number, so a probe open/close predicts the number the
 * leaked entry occupies.  After the faulting recvmsg, fcntl(pred, F_GETFD)
 * succeeding proves the entry was installed although no number was published,
 * and pread(pred) proves it aliases the message's first file object.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <unistd.h>

#define PAGE1_SENTINEL 0xcc /* memset pattern: unwritten buffer bytes */
#define PROBE_PATH "/tmp/ast32_probe"
#define FILE_A_PATH "/tmp/ast32_A"
#define FILE_B_PATH "/tmp/ast32_B"
#define FILE_A_CONTENT "AAAAAAAAAAAAAAAA" /* 16 bytes */
#define FILE_B_CONTENT "BBBBBBBBBBBBBBBB" /* 16 bytes */
#define NSENT_FDS 4 /* fds carried by the SCM_RIGHTS cmsg: {A, B, A, B} */
#define SCAN_WINDOW 8 /* fd slots scanned above pred for leak accounting */

/* Fault layouts: which FD integer write hits the PROT_NONE page. */
#define ENTRY_FAULT 0 /* first FD integer faults */
#define PREFIX_FAULT 1 /* FD0, FD1 writable; FD2 faults */

static long psz;
static char *fault_region;

struct recv_result {
    ssize_t ret;
    int err;
    size_t reported_len; /* msghdr.msg_controllen as updated by the kernel */
    int ctrunc;          /* MSG_CTRUNC in msg_flags */
    int leaked;          /* fcntl(pred, F_GETFD) succeeds after the call */
    int new_fds;         /* fds open in [pred, pred + SCAN_WINDOW) */
    int wrote_fd0;       /* FD integers actually present in the user buffer */
    int wrote_fd1;       /* (-1 when unreadable or not written) */
};

static void die_errno(const char *step)
{
    printf("MC1_ERROR {\"step\":\"%s\",\"errno\":%d}\n", step, errno);
    exit(2);
}

static void die_plain(const char *step)
{
    printf("MC1_ERROR {\"step\":\"%s\"}\n", step);
    exit(2);
}

/*
 * Open and close a scratch file to learn the lowest free fd number.  Both
 * Asterinas SlotVec::put and Linux alloc_fd hand out the lowest free slot, so
 * the number returned here is the number a subsequent install would occupy.
 */
static int probe_lowest_free_fd(void)
{
    int fd = open(PROBE_PATH, O_RDWR | O_CREAT, 0600);
    if (fd < 0)
        return -1;
    close(fd);
    return fd;
}

/* Close every open fd in [lo, lo + SCAN_WINDOW). */
static void close_scan_window(int lo)
{
    for (int fd = lo; fd < lo + SCAN_WINDOW; fd++) {
        if (fcntl(fd, F_GETFD) != -1)
            close(fd);
    }
}

/*
 * Send one datagram carrying an SCM_RIGHTS cmsg with fds {a, b, a, b} and a
 * 1-byte payload.  Returns the sendmsg result (1 on success).
 */
static ssize_t send_rights(int sockfd, int a, int b)
{
    char payload = 'Q';
    char control[CMSG_SPACE(NSENT_FDS * sizeof(int))];
    memset(control, 0, sizeof(control));

    struct iovec iov = { .iov_base = &payload, .iov_len = 1 };
    struct msghdr mh = {
        .msg_name = NULL,
        .msg_namelen = 0,
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = control,
        .msg_controllen = sizeof(control),
        .msg_flags = 0,
    };
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&mh);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(NSENT_FDS * sizeof(int));
    int fds[NSENT_FDS] = { a, b, a, b };
    memcpy(CMSG_DATA(cmsg), fds, sizeof(fds));

    ssize_t ret = sendmsg(sockfd, &mh, 0);
    if (ret < 0)
        die_errno("sendmsg");
    return ret;
}

/*
 * One faulting recvmsg.  Places the 32-byte control buffer at the end of
 * page 1 so the cmsghdr (16 bytes) is writable but an FD integer write
 * crosses into the PROT_NONE page 2.  Records everything observable about
 * the call, including whether `pred` (the predicted lowest free fd) became
 * open without its number ever being published.
 */
static int do_faulting_recv(int sockfd, int layout, int flags, int pred,
                            struct recv_result *res)
{
    /*
     * ENTRY_FAULT:  buffer at page1_end - 16 -> FD0 (offset 16) faults.
     * PREFIX_FAULT: buffer at page1_end - 24 -> FD2 (offset 24) faults.
     */
    char *cmsg_buf = fault_region + psz - 24 + (layout == ENTRY_FAULT ? 8 : 0);

    /* Re-stamp the writable landing zone with the sentinel pattern. */
    memset(fault_region + psz - 64, PAGE1_SENTINEL, 64);

    char payload_buf[64];
    struct iovec iov = { .iov_base = payload_buf, .iov_len = sizeof(payload_buf) };
    struct msghdr mh = {
        .msg_name = NULL,
        .msg_namelen = 0,
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = cmsg_buf,
        .msg_controllen = 32, /* capacity for the cmsghdr + 4 FD integers */
        .msg_flags = 0,
    };

    errno = 0;
    ssize_t ret = recvmsg(sockfd, &mh, flags);

    res->ret = ret;
    res->err = (ret < 0) ? errno : 0;
    res->reported_len = mh.msg_controllen;
    res->ctrunc = !!(mh.msg_flags & MSG_CTRUNC);

    /* The bug: pred is open after the call although no number was published. */
    res->leaked = (fcntl(pred, F_GETFD) != -1);

    res->new_fds = 0;
    for (int fd = pred; fd < pred + SCAN_WINDOW; fd++) {
        if (fcntl(fd, F_GETFD) != -1)
            res->new_fds++;
    }

    /*
     * Read back the FD integers the kernel actually wrote into the user
     * buffer.  Only safe when the whole [cmsg_buf + 16, cmsg_buf + 24)
     * window lies in mapped memory (PREFIX_FAULT); a value is accepted only
     * if it looks like a freshly installed fd (in [0, pred + SCAN_WINDOW)).
     */
    res->wrote_fd0 = -1;
    res->wrote_fd1 = -1;
    if (fault_region + psz >= cmsg_buf + 24) {
        int v0;
        int v1;
        memcpy(&v0, cmsg_buf + 16, sizeof(v0));
        memcpy(&v1, cmsg_buf + 20, sizeof(v1));
        if (v0 >= 0 && v0 < pred + SCAN_WINDOW)
            res->wrote_fd0 = v0;
        if (v1 >= 0 && v1 < pred + SCAN_WINDOW)
            res->wrote_fd1 = v1;
    }
    return 0;
}

int main(void)
{
    struct utsname uts;
    if (uname(&uts) < 0)
        die_errno("uname");
    printf("MC1_SYSTEM {\"sysname\":\"%s\",\"release\":\"%s\",\"machine\":\"%s\"}\n",
           uts.sysname, uts.release, uts.machine);

    /* Two-page fault region: page 1 writable, page 2 PROT_NONE. */
    psz = sysconf(_SC_PAGESIZE);
    fault_region = mmap(NULL, (size_t)psz * 2, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (fault_region == MAP_FAILED)
        die_errno("mmap");
    memset(fault_region, PAGE1_SENTINEL, (size_t)psz * 2);
    if (mprotect(fault_region + psz, (size_t)psz, PROT_NONE) < 0)
        die_errno("mprotect");

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0)
        die_errno("socketpair");

    /* Create the two payload files, then reopen them at offset 0. */
    int fd = open(FILE_A_PATH, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0)
        die_errno("create A");
    if (write(fd, FILE_A_CONTENT, 16) != 16)
        die_plain("write A");
    close(fd);
    fd = open(FILE_B_PATH, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0)
        die_errno("create B");
    if (write(fd, FILE_B_CONTENT, 16) != 16)
        die_plain("write B");
    close(fd);

    int fd_a = open(FILE_A_PATH, O_RDWR);
    int fd_b = open(FILE_B_PATH, O_RDWR);
    if (fd_a < 0 || fd_b < 0)
        die_plain("open A/B");

    /* Predict the fd number a fresh install would occupy. */
    int p1 = probe_lowest_free_fd();
    int p2 = probe_lowest_free_fd();
    printf("MC1_PROBE {\"pred\":%d,\"reused\":%d}\n", p1, p1 == p2);
    if (p1 < 0 || p1 != p2)
        die_plain("probe consistency");

    /*
     * Case 1: MSG_PEEK receive whose first FD-integer write faults.  On
     * Asterinas the entry is installed before the number copy, so `pred`
     * must be open afterwards even though msg_controllen reports 0.  PEEK
     * retains the message, so a clean retry must still deliver all 4 fds.
     */
    if (send_rights(sv[0], fd_a, fd_b) != 1)
        die_plain("send case1");
    struct recv_result res1;
    int pred1 = probe_lowest_free_fd();
    do_faulting_recv(sv[1], ENTRY_FAULT, MSG_PEEK, pred1, &res1);

    char leak_content[9] = "";
    if (res1.leaked) {
        char buf[8];
        memset(buf, 0, sizeof(buf));
        ssize_t n = pread(pred1, buf, 4, 0);
        if (n > 0)
            snprintf(leak_content, sizeof(leak_content), "%.*s", 8, buf);
    }
    printf("MC1_PEEK_FIRST_FAULT "
           "{\"ret\":%zd,\"err\":%d,\"reported_len\":%zu,\"ctrunc\":%d,"
           "\"pred\":%d,\"leaked\":%d,\"new_fds\":%d,\"leak_content\":\"%s\"}\n",
           res1.ret, res1.err, res1.reported_len, res1.ctrunc, pred1,
           res1.leaked, res1.new_fds, leak_content);
    close_scan_window(pred1);

    /* Clean retry: the PEEK must have retained the message. */
    char good_control[64];
    char retry_payload[64];
    memset(good_control, PAGE1_SENTINEL, sizeof(good_control));
    struct iovec retry_iov = {
        .iov_base = retry_payload,
        .iov_len = sizeof(retry_payload),
    };
    struct msghdr rmh = {
        .msg_iov = &retry_iov,
        .msg_iovlen = 1,
        .msg_control = good_control,
        .msg_controllen = 32,
    };
    int delivered = 0;
    int retry_fds[NSENT_FDS] = { -1, -1, -1, -1 };
    if (recvmsg(sv[1], &rmh, 0) >= 0 && rmh.msg_controllen > 15) {
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&rmh);
        if (cmsg != NULL && cmsg->cmsg_level == SOL_SOCKET) {
            delivered = (int)((cmsg->cmsg_len - 16) / 4);
            if (delivered > NSENT_FDS)
                delivered = NSENT_FDS;
            memcpy(retry_fds, CMSG_DATA(cmsg), NSENT_FDS * sizeof(int));
        }
    }
    printf("MC1_PEEK_RETRY {\"delivered\":%d}\n", delivered);
    for (int i = 0; i < delivered; i++) {
        if (retry_fds[i] >= 0 && fcntl(retry_fds[i], F_GETFD) != -1)
            close(retry_fds[i]);
    }
    if (delivered != NSENT_FDS)
        printf("MC1_NOTE {\"what\":\"peek retry did not deliver 4 fds\"}\n");

    /*
     * Case 2: ordinary (consuming) receive, first FD-integer write faults.
     */
    if (send_rights(sv[0], fd_a, fd_b) != 1)
        die_plain("send case2");
    struct recv_result res2;
    int pred2 = probe_lowest_free_fd();
    do_faulting_recv(sv[1], ENTRY_FAULT, 0, pred2, &res2);
    if (res2.leaked)
        printf("MC1_NOTE {\"what\":\"ordinary first-fault also leaked\"}\n");
    printf("MC1_ORD_FIRST_FAULT "
           "{\"ret\":%zd,\"err\":%d,\"reported_len\":%zu,\"ctrunc\":%d,"
           "\"pred\":%d,\"leaked\":%d,\"new_fds\":%d}\n",
           res2.ret, res2.err, res2.reported_len, res2.ctrunc, pred2,
           res2.leaked, res2.new_fds);
    close_scan_window(pred2);

    /*
     * Case 3: ordinary receive, prefix fault (FD0, FD1 published, FD2
     * faults).  Asterinas installs the failed third entry too and reports
     * control length 0; Linux installs nothing for the failed entry and
     * reports the delivered prefix (CMSG_SPACE(2 * 4) = 24).
     */
    if (send_rights(sv[0], fd_a, fd_b) != 1)
        die_plain("send case3");
    struct recv_result res3;
    int pred3 = probe_lowest_free_fd();
    do_faulting_recv(sv[1], PREFIX_FAULT, 0, pred3, &res3);
    printf("MC1_ORD_PREFIX_FAULT "
           "{\"ret\":%zd,\"err\":%d,\"reported_len\":%zu,\"ctrunc\":%d,"
           "\"pred\":%d,\"new_fds\":%d,\"wrote_fd0\":%d,\"wrote_fd1\":%d}\n",
           res3.ret, res3.err, res3.reported_len, res3.ctrunc, pred3,
           res3.new_fds, res3.wrote_fd0, res3.wrote_fd1);
    close_scan_window(pred3);

    int peek_leak = res1.leaked;
    int ord_leak = res2.leaked;
    int peek_retained = (delivered == NSENT_FDS);
    int prefix_installed = res3.new_fds;
    int prefix_published = (res3.wrote_fd0 == pred3) + (res3.wrote_fd1 == pred3 + 1);
    size_t prefix_reported_len = res3.reported_len;

    /* All three faulting calls returned the payload with MSG_CTRUNC set. */
    int consistent = (res1.ret == 1 && res1.ctrunc) &&
                     (res2.ret == 1 && res2.ctrunc) &&
                     (res3.ret == 1 && res3.ctrunc);

    /* Linux semantics: no leaked entry on a failed number copy, and the
     * delivered prefix is reported with its own length (24 for 2 of 4). */
    size_t prefix_linux = (size_t)CMSG_SPACE(2 * sizeof(int));
    int matches_linux = !peek_leak && !ord_leak &&
                        prefix_reported_len == prefix_linux &&
                        prefix_installed == prefix_published;

    printf("MC1_RESULT "
           "{\"peek_leak\":%d,\"ord_leak\":%d,\"peek_retained\":%d,"
           "\"prefix_installed\":%d,\"prefix_published\":%d,"
           "\"prefix_reported_len\":%zu,\"consistent\":%d,"
           "\"invariant_matches_linux\":%d}\n",
           peek_leak, ord_leak, peek_retained, prefix_installed,
           prefix_published, prefix_reported_len, consistent, matches_linux);

    int exit_code = consistent ? 0 : 1;
    printf("MC1_DONE %d\n", exit_code);

    /* As PID 1 inside the guest, power the machine off; a no-op on Linux. */
    if (getpid() == 1)
        reboot(RB_POWER_OFF);
    return exit_code;
}
