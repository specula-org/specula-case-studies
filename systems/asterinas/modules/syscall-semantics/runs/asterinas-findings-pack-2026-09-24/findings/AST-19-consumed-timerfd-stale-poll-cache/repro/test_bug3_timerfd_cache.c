// SPDX-License-Identifier: MPL-2.0

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/poll.h>
#include <sys/timerfd.h>
#include <unistd.h>

int main(void)
{
    struct itimerspec timer = { 0 };
    struct pollfd poll_fd;
    uint64_t ticks;
    int timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);

    if (timer_fd < 0)
        return EXIT_FAILURE;
    timer.it_value.tv_nsec = 1000000;
    if (timerfd_settime(timer_fd, 0, &timer, NULL) < 0)
        return EXIT_FAILURE;
    poll_fd = (struct pollfd){ .fd = timer_fd, .events = POLLIN };
    if (poll(&poll_fd, 1, 1000) != 1 || (poll_fd.revents & POLLIN) == 0 ||
        read(timer_fd, &ticks, sizeof(ticks)) != (ssize_t)sizeof(ticks) || ticks == 0)
        return EXIT_FAILURE;
    poll_fd.revents = 0;
    if (poll(&poll_fd, 1, 0) != 0 || poll_fd.revents != 0) {
        printf("SPECULA_REGRESSION_FAIL timerfd_cache: consumed timerfd remained readable\n");
        return EXIT_FAILURE;
    }
    printf("SPECULA_REGRESSION_PASS timerfd_cache\n");
    return EXIT_SUCCESS;
}
