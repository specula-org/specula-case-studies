#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/timerfd.h>
#include <unistd.h>

static int fail(const char *step)
{
    fprintf(stderr, "MC4B_FAIL step=%s errno=%d (%s)\n", step, errno, strerror(errno));
    return 2;
}

int main(void)
{
    struct itimerspec timer = { 0 };
    struct pollfd poll_fd = { .events = POLLIN };
    uint64_t ticks = 0;
    int fd;
    int initial_poll;
    int post_read_poll;
    int zero_poll;
    int second_errno;
    short timed_revents;
    short zero_revents;
    ssize_t first_read;
    ssize_t second_read;

    fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0)
        return fail("timerfd_create");

    timer.it_value.tv_nsec = 100 * 1000 * 1000;
    if (timerfd_settime(fd, 0, &timer, NULL) < 0)
        return fail("timerfd_settime");

    poll_fd.fd = fd;
    printf("MC4B_LEVEL=0 public-api one-shot timerfd/poll/read\n");

    initial_poll = poll(&poll_fd, 1, 3000);
    printf("MC4B_INITIAL poll=%d revents=0x%x\n", initial_poll,
           (unsigned short)poll_fd.revents);
    if (initial_poll != 1 || (poll_fd.revents & POLLIN) == 0) {
        errno = ETIMEDOUT;
        return fail("initial_poll");
    }

    first_read = read(fd, &ticks, sizeof(ticks));
    printf("MC4B_CONSUME bytes=%zd ticks=%" PRIu64 " errno=%d\n", first_read, ticks, errno);
    if (first_read != (ssize_t)sizeof(ticks) || ticks == 0) {
        errno = EIO;
        return fail("consume");
    }

    /* A one-shot timer has no future producer. A correct poll waits out this timeout. */
    poll_fd.revents = 0;
    post_read_poll = poll(&poll_fd, 1, 75);
    timed_revents = poll_fd.revents;
    printf("MC4B_POST_READ_TIMED_POLL poll=%d revents=0x%x\n", post_read_poll,
           (unsigned short)timed_revents);

    errno = 0;
    second_read = read(fd, &ticks, sizeof(ticks));
    second_errno = errno;
    printf("MC4B_POST_READ bytes=%zd errno=%d (%s)\n", second_read, second_errno,
           strerror(second_errno));

    poll_fd.revents = 0;
    zero_poll = poll(&poll_fd, 1, 0);
    zero_revents = poll_fd.revents;
    printf("MC4B_POST_READ_ZERO_POLL poll=%d revents=0x%x\n", zero_poll,
           (unsigned short)zero_revents);
    close(fd);

    if (post_read_poll == 1 && (timed_revents & POLLIN) != 0 && second_read == -1 &&
        second_errno == EAGAIN && zero_poll == 1 && (zero_revents & POLLIN) != 0) {
        printf("MC4B_BUG_TRIGGERED timed_poll_reported_readiness_then_read_eagain\n");
        return 0;
    }

    printf("MC4B_NO_STALE_READINESS timed_poll=%d zero_poll=%d\n", post_read_poll, zero_poll);
    return 1;
}
