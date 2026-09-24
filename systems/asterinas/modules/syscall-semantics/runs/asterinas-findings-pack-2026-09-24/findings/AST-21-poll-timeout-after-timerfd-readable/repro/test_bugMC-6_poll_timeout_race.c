// SPDX-License-Identifier: MPL-2.0

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/poll.h>
#include <sys/timerfd.h>
#include <unistd.h>

int main(void)
{
    const int attempts = 20000;

    for (int attempt = 0; attempt < attempts; attempt++) {
        struct itimerspec timer = { 0 };
        struct pollfd poll_fd;
        uint64_t ticks = 0;
        int timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);

        if (timer_fd < 0) {
            perror("timerfd_create");
            return EXIT_FAILURE;
        }

        timer.it_value.tv_nsec = 1000000;
        if (timerfd_settime(timer_fd, 0, &timer, NULL) < 0) {
            perror("timerfd_settime");
            close(timer_fd);
            return EXIT_FAILURE;
        }

        poll_fd = (struct pollfd){ .fd = timer_fd, .events = POLLIN };
        int result = poll(&poll_fd, 1, 1);

        if (result == 1 && (poll_fd.revents & POLLIN) != 0) {
            if (read(timer_fd, &ticks, sizeof(ticks)) != (ssize_t)sizeof(ticks)) {
                perror("read after ready poll");
                close(timer_fd);
                return EXIT_FAILURE;
            }
        } else if (result == 0) {
            ssize_t read_result = read(timer_fd, &ticks, sizeof(ticks));

            if (read_result == (ssize_t)sizeof(ticks)) {
                printf(
                    "MC6_REPRODUCED attempt=%d poll_result=0 revents=0x%x ticks=%llu\n",
                    attempt,
                    (unsigned int)poll_fd.revents,
                    (unsigned long long)ticks
                );
                close(timer_fd);
                return EXIT_FAILURE;
            }
            if (read_result != -1 || errno != EAGAIN) {
                perror("read after timeout poll");
                close(timer_fd);
                return EXIT_FAILURE;
            }
        } else {
            fprintf(
                stderr,
                "unexpected poll result=%d revents=0x%x errno=%d\n",
                result,
                (unsigned int)poll_fd.revents,
                errno
            );
            close(timer_fd);
            return EXIT_FAILURE;
        }

        if (close(timer_fd) < 0) {
            perror("close");
            return EXIT_FAILURE;
        }
    }

    printf("MC6_NO_REPRO attempts=%d\n", attempts);
    return EXIT_SUCCESS;
}
