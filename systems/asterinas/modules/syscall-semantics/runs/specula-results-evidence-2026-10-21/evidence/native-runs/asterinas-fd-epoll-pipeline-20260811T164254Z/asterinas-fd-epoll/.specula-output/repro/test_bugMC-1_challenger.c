// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

/* Keep the bad address opaque to the compiler and exercise epoll_wait's EFAULT path. */
__attribute__((noinline)) static struct epoll_event *inaccessible_events(void)
{
    volatile uintptr_t address = 1;

    return (struct epoll_event *)address;
}

static int run_copyout_case(const char *name, uint32_t flags, int expected_second)
{
    const uint64_t token = 0x4d43312d43484c4cULL;
    struct epoll_event add = {
        .events = EPOLLIN | flags,
        .data.u64 = token,
    };
    struct epoll_event received = { 0 };
    uint64_t one = 1;
    uint64_t unread = 0;
    int epfd;
    int efd;
    int first;
    int first_errno;
    int second;
    int second_errno;
    ssize_t read_result;

    epfd = epoll_create1(0);
    efd = eventfd(0, EFD_NONBLOCK);
    if (epfd < 0 || efd < 0 ||
        epoll_ctl(epfd, EPOLL_CTL_ADD, efd, &add) < 0 ||
        write(efd, &one, sizeof(one)) != (ssize_t)sizeof(one)) {
        perror(name);
        return EXIT_FAILURE;
    }

    errno = 0;
    first = epoll_wait(epfd, inaccessible_events(), 1, 0);
    first_errno = errno;

    errno = 0;
    second = epoll_wait(epfd, &received, 1, 0);
    second_errno = errno;

    errno = 0;
    read_result = read(efd, &unread, sizeof(unread));
    printf("MC1_CASE name=%s first=%d first_errno=%d second=%d second_errno=%d "
           "events=0x%x data=0x%llx eventfd_read=%zd unread=%llu\n",
           name, first, first_errno, second, second_errno, received.events,
           (unsigned long long)received.data.u64, read_result,
           (unsigned long long)unread);

    close(efd);
    close(epfd);

    if (first != -1 || first_errno != EFAULT)
        return EXIT_FAILURE;
    if (second != expected_second)
        return EXIT_FAILURE;
    if (expected_second == 1 &&
        ((received.events & EPOLLIN) == 0 || received.data.u64 != token))
        return EXIT_FAILURE;
    if (read_result != (ssize_t)sizeof(unread) || unread != 1)
        return EXIT_FAILURE;
    return EXIT_SUCCESS;
}

static int run_successful_et_control(void)
{
    struct epoll_event add = { .events = EPOLLIN | EPOLLET, .data.u64 = 7 };
    struct epoll_event received = { 0 };
    uint64_t one = 1;
    int epfd = epoll_create1(0);
    int efd = eventfd(0, EFD_NONBLOCK);
    int first;
    int second;

    if (epfd < 0 || efd < 0 ||
        epoll_ctl(epfd, EPOLL_CTL_ADD, efd, &add) < 0 ||
        write(efd, &one, sizeof(one)) != (ssize_t)sizeof(one)) {
        perror("successful_et_control");
        return EXIT_FAILURE;
    }

    first = epoll_wait(epfd, &received, 1, 0);
    second = epoll_wait(epfd, &received, 1, 0);
    printf("MC1_CONTROL name=successful_et first=%d second=%d\n", first, second);
    close(efd);
    close(epfd);
    return first == 1 && second == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

int main(void)
{
    int failed = 0;

    failed |= run_copyout_case("edge_after_efault", EPOLLET, 1) != EXIT_SUCCESS;
    failed |= run_copyout_case("level_after_efault", 0, 1) != EXIT_SUCCESS;
    failed |= run_successful_et_control() != EXIT_SUCCESS;
    if (failed) {
        puts("MC1_CHALLENGER_FAIL");
        return EXIT_FAILURE;
    }

    puts("MC1_CHALLENGER_PASS");
    return EXIT_SUCCESS;
}
