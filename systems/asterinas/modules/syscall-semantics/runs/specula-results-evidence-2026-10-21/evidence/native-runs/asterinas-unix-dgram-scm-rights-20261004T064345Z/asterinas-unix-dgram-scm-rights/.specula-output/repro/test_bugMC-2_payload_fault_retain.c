/*
 * Reproduction test for finding MC-2 (AST-36): "Ordinary payload faults
 * retain the datagram".
 *
 * Contract under test (invariant PayloadFaultConsumptionMatchesLinux, Linux
 * v6.16.5 __unix_dgram_recvmsg): an ORDINARY (non-PEEK) recvmsg on an
 * AF_UNIX SOCK_DGRAM socket whose payload copy faults with EFAULT must have
 * CONSUMED the datagram (Linux unlinks the skb before the payload copy and
 * frees it on fault, releasing its SCM_RIGHTS references). A faulting
 * MSG_PEEK must RETAIN the datagram in both implementations.
 *
 * Asterinas try_recv (kernel/core/src/net/socket/unix/datagram/message.rs,
 * upstream pin 0c6053709 line 195: `let len = writer.write(...)?;`) returns
 * from the failed payload copy BEFORE the dequeue at line 202, so the
 * datagram and its SCM_RIGHTS references stay queued for a retry.
 *
 * This maps 1:1 to the MC counterexample in
 * spec/output/validation-20261010T015405Z/MC_hunt_AST36.log:
 *   send message1 with rights <<fileA, fileB, fileA, fileB>>
 *   -> ordinary recv with payloadGood=FALSE -> EFAULT, faultRetained=TRUE
 *   -> queue still holds message1 (Asterinas) / consumed (Linux).
 *
 * The program is self-contained and runs in two environments:
 *   - as the init process (PID 1) inside the Asterinas guest (bootstrap
 *     below mounts devtmpfs and opens the console), and
 *   - as an ordinary process on a Linux host (the same-program control).
 *
 * It prints one JSON line per observation and a final MC2_RESULT line:
 *   ordinary_fault_retained  1 = retry after the ordinary fault delivered
 *                              the same datagram (Asterinas behavior,
 *                              violates the Linux contract);
 *                            0 = retry found the queue empty (Linux: the
 *                              fault consumed the datagram).
 *   peek_fault_retained      1 = retry after a faulting MSG_PEEK delivered
 *                              the datagram (correct in both).
 *   invariant_matches_linux  1 iff ordinary_fault_retained==0 and
 *                            peek_fault_retained==1.
 *
 * Exit code 0 means every step of the scenario ran and behaved internally
 * consistently (the faulting call returned EFAULT, control output was
 * untouched by it, no FDs were installed by it); the MC2_RESULT line carries
 * the platform verdict.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/uio.h>
#include <unistd.h>

#define CHECK(expr)                                                        \
    do {                                                                   \
        if ((long)(expr) < 0) {                                            \
            perror(#expr);                                                 \
            _exit(90);                                                     \
        }                                                                  \
    } while (0)

#define RIGHTS_COUNT 4

static int is_asterinas;

/* Bitmap of open fds in [0, 64). */
static uint64_t fd_snapshot(void)
{
    uint64_t mask = 0;
    for (int fd = 0; fd < 64; ++fd)
        if (fcntl(fd, F_GETFD) >= 0)
            mask |= 1ULL << fd;
    return mask;
}

static int popcount_new(uint64_t before, uint64_t after)
{
    int n = 0;
    uint64_t diff = after & ~before;
    while (diff) {
        n += diff & 1;
        diff >>= 1;
    }
    return n;
}

static void bootstrap(void)
{
    if (getpid() != 1)
        return;
    mkdir("/dev", 0755);
    mkdir("/tmp", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    int fd = open("/dev/console", O_RDWR);
    if (fd >= 0) {
        for (int i = 0; i < 3; ++i)
            dup2(fd, i);
        if (fd > 2)
            close(fd);
    }
    setvbuf(stdout, NULL, _IONBF, 0);
}

struct obs {
    int fault_ret, fault_errno;
    int control_touched;      /* faulting call wrote control bytes */
    int fault_installed_fds;  /* faulting call installed FDs */
    int retry_ret, retry_errno;
    int retained;             /* retry delivered the same datagram */
    int fds_delivered;
    int markers_ok;           /* delivered FDs name A,B,A,B */
    int post_retry_empty;     /* queue empty after the retry */
};

/*
 * One full scenario on a fresh socketpair: send one datagram carrying
 * SCM_RIGHTS {A, B, A, B}; receive once with a faulting payload buffer
 * (ordinary or PEEK); retry with a good buffer; account for everything.
 */
static void scenario(const char *kind, int use_peek, struct obs *o)
{
    memset(o, 0, sizeof(*o));

    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv));

    /* Two ordinary files as the transferred objects, marked 'A' and 'B'. */
    char path[64];
    snprintf(path, sizeof(path), "/tmp/mc2-%d-A", getpid());
    int fa = open(path, O_CREAT | O_RDWR | O_EXCL, 0600);
    CHECK(fa);
    CHECK(unlink(path));
    CHECK(write(fa, "A", 1) == 1 ? 0 : -1);
    snprintf(path, sizeof(path), "/tmp/mc2-%d-B", getpid());
    int fb = open(path, O_CREAT | O_RDWR | O_EXCL, 0600);
    CHECK(fb);
    CHECK(unlink(path));
    CHECK(write(fb, "B", 1) == 1 ? 0 : -1);

    /* Send: one nonempty payload byte + SCM_RIGHTS {fa, fb, fa, fb}. */
    char payload = 'x';
    char send_ctl[CMSG_SPACE(RIGHTS_COUNT * sizeof(int))] __attribute__((aligned(8)));
    memset(send_ctl, 0, sizeof(send_ctl));
    struct cmsghdr *sh = (struct cmsghdr *)send_ctl;
    sh->cmsg_level = SOL_SOCKET;
    sh->cmsg_type = SCM_RIGHTS;
    sh->cmsg_len = CMSG_LEN(RIGHTS_COUNT * sizeof(int));
    int rights[RIGHTS_COUNT] = { fa, fb, fa, fb };
    memcpy(CMSG_DATA(sh), rights, sizeof(rights));
    struct iovec sov = { &payload, 1 };
    struct msghdr smsg = {
        .msg_iov = &sov, .msg_iovlen = 1,
        .msg_control = send_ctl, .msg_controllen = sizeof(send_ctl),
    };
    CHECK(sendmsg(sv[0], &smsg, 0) != 1 ? -1 : 0);

    /* Faulting payload page: mapped, readable, NOT writable, so the kernel
     * payload copy faults mid-copy while the iovec metadata stays valid. */
    char *fault_page = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(fault_page == MAP_FAILED ? -1 : 0);
    fault_page[0] = 0x5a;
    CHECK(mprotect(fault_page, 4096, PROT_READ));

    /* Attempt 1: faulting payload, valid writable control buffer. */
    unsigned char ctl1[CMSG_SPACE(RIGHTS_COUNT * sizeof(int))] __attribute__((aligned(8)));
    memset(ctl1, 0xa5, sizeof(ctl1));
    struct iovec iov1 = { fault_page, 1 };
    struct msghdr rmsg1 = {
        .msg_iov = &iov1, .msg_iovlen = 1,
        .msg_control = ctl1, .msg_controllen = sizeof(ctl1),
    };
    uint64_t fds_before = fd_snapshot();
    errno = 0;
    o->fault_ret = recvmsg(sv[1], &rmsg1, use_peek ? MSG_PEEK : 0);
    o->fault_errno = errno;
    for (size_t i = 0; i < sizeof(ctl1); ++i)
        if (ctl1[i] != 0xa5) {
            o->control_touched = 1;
            break;
        }
    o->fault_installed_fds = popcount_new(fds_before, fd_snapshot());

    /* Attempt 2: good payload buffer, ordinary receive. */
    char good = 0;
    unsigned char ctl2[CMSG_SPACE(RIGHTS_COUNT * sizeof(int))] __attribute__((aligned(8)));
    memset(ctl2, 0xa5, sizeof(ctl2));
    struct iovec iov2 = { &good, 1 };
    struct msghdr rmsg2 = {
        .msg_iov = &iov2, .msg_iovlen = 1,
        .msg_control = ctl2, .msg_controllen = sizeof(ctl2),
    };
    errno = 0;
    o->retry_ret = recvmsg(sv[1], &rmsg2, 0);
    o->retry_errno = errno;

    int delivered_fds[RIGHTS_COUNT];
    if (o->retry_ret == 1 && good == 'x') {
        o->retained = 1;
        struct cmsghdr *rh = CMSG_FIRSTHDR(&rmsg2);
        if (rh && rh->cmsg_level == SOL_SOCKET && rh->cmsg_type == SCM_RIGHTS) {
            int n = (int)((rh->cmsg_len - CMSG_LEN(0)) / sizeof(int));
            if (n > RIGHTS_COUNT)
                n = RIGHTS_COUNT;
            o->fds_delivered = n;
            memcpy(delivered_fds, CMSG_DATA(rh), (size_t)n * sizeof(int));
            /* Each delivered FD must name the captured object: A,B,A,B. */
            o->markers_ok = 1;
            for (int i = 0; i < n; ++i) {
                char marker = 0;
                if (pread(delivered_fds[i], &marker, 1, 0) != 1 ||
                    marker != (i % 2 == 0 ? 'A' : 'B'))
                    o->markers_ok = 0;
            }
            for (int i = 0; i < n; ++i)
                close(delivered_fds[i]);
        }
        /* The retained message must be consumed exactly once. */
        char extra = 0;
        struct iovec iov3 = { &extra, 1 };
        struct msghdr rmsg3 = { .msg_iov = &iov3, .msg_iovlen = 1 };
        errno = 0;
        if (recvmsg(sv[1], &rmsg3, 0) == -1 && errno == EAGAIN)
            o->post_retry_empty = 1;
    } else if (o->retry_ret == -1 && o->retry_errno == EAGAIN) {
        /* Linux: the ordinary fault consumed the datagram. */
        o->post_retry_empty = 1;
    }

    printf("MC2_SCENARIO {\"kind\":\"%s\",\"fault\":{\"ret\":%d,\"errno\":%d},"
           "\"control_touched\":%d,\"fault_installed_fds\":%d,"
           "\"retry\":{\"ret\":%d,\"errno\":%d},\"retained\":%d,"
           "\"fds_delivered\":%d,\"markers_ok\":%d,\"post_retry_empty\":%d}\n",
           kind, o->fault_ret, o->fault_errno, o->control_touched,
           o->fault_installed_fds, o->retry_ret, o->retry_errno, o->retained,
           o->fds_delivered, o->markers_ok, o->post_retry_empty);

    CHECK(munmap(fault_page, 4096));
    CHECK(close(sv[0]));
    CHECK(close(sv[1]));
    CHECK(close(fa));
    CHECK(close(fb));
}

int main(void)
{
    bootstrap();

    struct utsname name;
    CHECK(uname(&name));
    is_asterinas = strcmp(name.sysname, "Linux") != 0;
    printf("MC2_SYS {\"sysname\":\"%s\",\"release\":\"%s\",\"machine\":\"%s\"}\n",
           name.sysname, name.release, name.machine);

    struct obs ord, peek;
    scenario("ordinary", 0, &ord);
    scenario("peek", 1, &peek);

    /* Internal consistency: the faulting calls must have failed with EFAULT
     * without touching control output or installing FDs, or the scenario
     * itself is broken and proves nothing. */
    int consistent = ord.fault_ret == -1 && ord.fault_errno == EFAULT &&
                     ord.control_touched == 0 && ord.fault_installed_fds == 0 &&
                     peek.fault_ret == -1 && peek.fault_errno == EFAULT &&
                     peek.control_touched == 0 && peek.fault_installed_fds == 0;

    int invariant_matches_linux = (ord.retained == 0 && peek.retained == 1 &&
                                   ord.post_retry_empty && peek.post_retry_empty &&
                                   peek.markers_ok);

    printf("MC2_RESULT ordinary_fault_retained=%d peek_fault_retained=%d "
           "invariant_matches_linux=%d consistent=%d\n",
           ord.retained, peek.retained, invariant_matches_linux, consistent);

    /* No FD leaks: everything opened or received must be closed by now. */
    for (int fd = 3; fd < 64; ++fd) {
        if (fcntl(fd, F_GETFD) >= 0) {
            printf("MC2_LEAK fd=%d\n", fd);
            close(fd);
        }
    }

    if (getpid() == 1)
        reboot(RB_POWER_OFF);
    return consistent ? 0 : 1;
}
