#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

static int fail(const char *step)
{
    fprintf(stderr, "MC4_FAIL step=%s errno=%d (%s)\n", step, errno, strerror(errno));
    return 2;
}

int main(void)
{
    struct itimerspec timer = { 0 };
    struct pollfd poll_fd = { 0 };
    uint64_t ticks = 0;
    int stale_polls = 0;
    int fd;
    int ret;
    ssize_t read_ret;

    fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0)
        return fail("timerfd_create");

    timer.it_value.tv_nsec = 100 * 1000 * 1000;
    if (timerfd_settime(fd, 0, &timer, NULL) < 0)
        return fail("timerfd_settime");

    poll_fd.fd = fd;
    poll_fd.events = POLLIN;

    printf("MC4_LEVEL=0 public-api timerfd->poll->read->poll\n");
    ret = poll(&poll_fd, 1, 3000);
    printf("MC4_INITIAL_POLL ret=%d revents=0x%x\n", ret, (unsigned short)poll_fd.revents);
    if (ret != 1 || (poll_fd.revents & POLLIN) == 0) {
        errno = ETIMEDOUT;
        return fail("initial_poll");
    }

    /* Prime the shared Pollee cache while the expiration count is still nonzero. */
    poll_fd.revents = 0;
    ret = poll(&poll_fd, 1, 0);
    printf("MC4_CACHE_PRIME ret=%d revents=0x%x\n", ret, (unsigned short)poll_fd.revents);
    if (ret != 1 || (poll_fd.revents & POLLIN) == 0) {
        errno = EIO;
        return fail("cache_prime");
    }

    read_ret = read(fd, &ticks, sizeof(ticks));
    printf("MC4_CONSUME bytes=%zd ticks=%" PRIu64 " errno=%d\n", read_ret, ticks, errno);
    if (read_ret != (ssize_t)sizeof(ticks) || ticks == 0) {
        errno = EIO;
        return fail("consume");
    }

    for (int index = 0; index < 3; index++) {
        poll_fd.revents = 0;
        ret = poll(&poll_fd, 1, 0);
        printf("MC4_POST_CONSUME_POLL index=%d ret=%d revents=0x%x\n",
               index, ret, (unsigned short)poll_fd.revents);
        if (ret == 1 && (poll_fd.revents & POLLIN) != 0)
            stale_polls++;
    }

    errno = 0;
    read_ret = read(fd, &ticks, sizeof(ticks));
    printf("MC4_POST_CONSUME_READ bytes=%zd errno=%d (%s)\n",
           read_ret, errno, strerror(errno));
    close(fd);

    if (stale_polls == 3 && read_ret == -1 && errno == EAGAIN) {
        printf("MC4_BUG_TRIGGERED stale_polls=%d while_read_is_EAGAIN\n", stale_polls);
        return 0;
    }

    printf("MC4_EXPECTED_NO_STALE_READINESS stale_polls=%d\n", stale_polls);
    return 1;
}
