// SPDX-License-Identifier: MPL-2.0

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/poll.h>
#include <sys/timerfd.h>
#include <unistd.h>

int main(void)
{
    const int attempts = 2000;
    int zero_then_ready = 0;
    int attempt;

    for (attempt = 0; attempt < attempts; attempt++) {
        struct itimerspec timer = { 0 };
        struct pollfd poll_fd;
        uint64_t ticks;
        int timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
        int result;

        if (timer_fd < 0)
            return EXIT_FAILURE;
        timer.it_value.tv_nsec = 1000000;
        if (timerfd_settime(timer_fd, 0, &timer, NULL) < 0)
            return EXIT_FAILURE;
        poll_fd = (struct pollfd){ .fd = timer_fd, .events = POLLIN };
        result = poll(&poll_fd, 1, 1);
        if (result == 1 && (poll_fd.revents & POLLIN) != 0) {
            if (read(timer_fd, &ticks, sizeof(ticks)) != (ssize_t)sizeof(ticks))
                return EXIT_FAILURE;
        } else if (result == 0) {
            if (read(timer_fd, &ticks, sizeof(ticks)) == (ssize_t)sizeof(ticks))
                zero_then_ready++;
        } else {
            return EXIT_FAILURE;
        }
        if (close(timer_fd) < 0)
            return EXIT_FAILURE;
    }
    if (zero_then_ready != 0) {
        printf("SPECULA_REGRESSION_FAIL poll_timeout_race: %d/%d timeout returns were immediately readable\n",
               zero_then_ready, attempts);
        return EXIT_FAILURE;
    }
    printf("SPECULA_REGRESSION_PASS poll_timeout_race\n");
    return EXIT_SUCCESS;
}
