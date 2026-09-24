// SPDX-License-Identifier: MPL-2.0

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

static int fdinfo_has_target(int epfd, int targetfd)
{
    char path[64];
    char buf[4096];
    char *entry;
    ssize_t len;
    int fd;

    if (snprintf(path, sizeof(path), "/proc/self/fdinfo/%d", epfd) >= (int)sizeof(path))
        return -1;
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;
    len = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (len < 0)
        return -1;
    buf[len] = '\0';
    entry = buf;
    while ((entry = strstr(entry, "tfd:")) != NULL) {
        int found_fd;

        if (sscanf(entry, "tfd: %d", &found_fd) == 1 && found_fd == targetfd)
            return 1;
        entry += strlen("tfd:");
    }
    return 0;
}

int main(void)
{
    struct epoll_event event = { .events = EPOLLIN, .data.u64 = 4 };
    int epfd = epoll_create1(0);
    int efd = eventfd(0, EFD_NONBLOCK);

    if (epfd < 0 || efd < 0 || epoll_ctl(epfd, EPOLL_CTL_ADD, efd, &event) < 0 ||
        fdinfo_has_target(epfd, efd) != 1 || close(efd) < 0)
        return EXIT_FAILURE;
    if (fdinfo_has_target(epfd, efd) != 0) {
        printf("SPECULA_REGRESSION_FAIL dead_interest: closed file remains in epoll interest list\n");
        return EXIT_FAILURE;
    }
    printf("SPECULA_REGRESSION_PASS dead_interest\n");
    return EXIT_SUCCESS;
}
