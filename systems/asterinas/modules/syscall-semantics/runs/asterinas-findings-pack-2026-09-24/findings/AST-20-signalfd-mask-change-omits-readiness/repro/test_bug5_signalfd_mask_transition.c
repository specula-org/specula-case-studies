// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/signalfd.h>
#include <unistd.h>

int main(void)
{
    sigset_t blocked;
    sigset_t empty;
    struct epoll_event add = { .events = EPOLLIN, .data.u64 = 5 };
    struct epoll_event event;
    int epfd;
    int signal_fd;

    if (sigemptyset(&blocked) < 0 || sigaddset(&blocked, SIGUSR1) < 0 ||
        sigemptyset(&empty) < 0 || sigprocmask(SIG_BLOCK, &blocked, NULL) < 0)
        return EXIT_FAILURE;
    signal_fd = signalfd(-1, &empty, SFD_NONBLOCK);
    epfd = epoll_create1(0);
    if (signal_fd < 0 || epfd < 0 || epoll_ctl(epfd, EPOLL_CTL_ADD, signal_fd, &add) < 0 ||
        kill(getpid(), SIGUSR1) < 0 || epoll_wait(epfd, &event, 1, 0) != 0 ||
        signalfd(signal_fd, &blocked, SFD_NONBLOCK) != signal_fd)
        return EXIT_FAILURE;
    if (epoll_wait(epfd, &event, 1, 100) != 1 || (event.events & EPOLLIN) == 0) {
        printf("SPECULA_REGRESSION_FAIL signalfd_mask_transition: mask update did not publish pending signal readiness\n");
        return EXIT_FAILURE;
    }
    printf("SPECULA_REGRESSION_PASS signalfd_mask_transition\n");
    return EXIT_SUCCESS;
}
