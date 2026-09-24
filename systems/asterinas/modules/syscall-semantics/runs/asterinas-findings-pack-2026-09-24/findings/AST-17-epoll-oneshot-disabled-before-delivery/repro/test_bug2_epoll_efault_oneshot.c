// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

__attribute__((noinline)) static struct epoll_event *bad_events(void)
{
    volatile uintptr_t address = 1;

    return (struct epoll_event *)address;
}

int main(void)
{
    struct epoll_event add = { .events = EPOLLIN | EPOLLONESHOT, .data.u64 = 2 };
    struct epoll_event event;
    uint64_t one = 1;
    int epfd = epoll_create1(0);
    int efd = eventfd(0, EFD_NONBLOCK);

    if (epfd < 0 || efd < 0 || epoll_ctl(epfd, EPOLL_CTL_ADD, efd, &add) < 0 ||
        write(efd, &one, sizeof(one)) != (ssize_t)sizeof(one))
        return EXIT_FAILURE;
    errno = 0;
    if (epoll_wait(epfd, bad_events(), 1, 0) != -1 || errno != EFAULT)
        return EXIT_FAILURE;
    if (epoll_wait(epfd, &event, 1, 0) != 1 || (event.events & EPOLLIN) == 0) {
        printf("SPECULA_REGRESSION_FAIL copyout_oneshot: ready event was not retained after EFAULT\n");
        return EXIT_FAILURE;
    }
    printf("SPECULA_REGRESSION_PASS copyout_oneshot\n");
    return EXIT_SUCCESS;
}
