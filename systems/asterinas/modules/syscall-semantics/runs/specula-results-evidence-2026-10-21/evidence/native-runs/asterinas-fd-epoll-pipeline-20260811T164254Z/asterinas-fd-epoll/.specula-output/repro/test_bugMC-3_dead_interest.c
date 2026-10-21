// SPDX-License-Identifier: MIT
// Public-API Level 0 reproduction for MC-3.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/reboot.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

static void poweroff_and_exit(int status)
{
    fflush(stdout);
    fflush(stderr);
    syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
            LINUX_REBOOT_CMD_POWER_OFF, NULL);
    _exit(status);
}

static void fail_errno(const char *operation)
{
    fprintf(stderr, "MC-3: ERROR %s: %s\n", operation, strerror(errno));
    poweroff_and_exit(2);
}

int main(void)
{
    struct epoll_event event = {
        .events = EPOLLIN,
        .data.u64 = 0x4d4333,
    };
    char fdinfo_path[64];
    char fdinfo[4096];

    const int epfd = epoll_create1(0);
    if (epfd < 0)
        fail_errno("epoll_create1");

    // eventfd(0) is not readable. EPOLLIN therefore leaves no ready-list entry
    // that could incidentally trigger the implementation's lazy dead-entry scan.
    const int watched_fd = eventfd(0, 0);
    if (watched_fd < 0)
        fail_errno("eventfd");
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, watched_fd, &event) < 0)
        fail_errno("epoll_ctl(EPOLL_CTL_ADD)");
    if (close(watched_fd) < 0)
        fail_errno("close(watched_fd)");

    if (mkdir("/proc", 0555) < 0 && errno != EEXIST)
        fail_errno("mkdir(/proc)");
    if (mount("proc", "/proc", "proc", 0, NULL) < 0 && errno != EBUSY)
        fail_errno("mount(proc)");

    if (snprintf(fdinfo_path, sizeof(fdinfo_path), "/proc/self/fdinfo/%d", epfd) < 0)
        fail_errno("snprintf(fdinfo path)");
    const int fdinfo_fd = open(fdinfo_path, O_RDONLY);
    if (fdinfo_fd < 0)
        fail_errno("open(fdinfo)");
    const ssize_t bytes = read(fdinfo_fd, fdinfo, sizeof(fdinfo) - 1);
    if (bytes < 0)
        fail_errno("read(fdinfo)");
    fdinfo[bytes] = '\0';
    if (close(fdinfo_fd) < 0)
        fail_errno("close(fdinfo)");

    const int serial_fd = open("/dev/ttyS0", O_WRONLY | O_NOCTTY);
    if (serial_fd < 0)
        fail_errno("open(/dev/ttyS0)");

    printf("MC-3: epfd=%d watched_fd=%d after final close\n", epfd, watched_fd);
    printf("MC-3: fdinfo follows\n%s", fdinfo);
    dprintf(serial_fd, "MC-3: epfd=%d watched_fd=%d after final close\n",
            epfd, watched_fd);
    dprintf(serial_fd, "MC-3: fdinfo follows\n%s", fdinfo);
    if (strstr(fdinfo, "tfd:") != NULL) {
        printf("MC-3: REPRODUCED stale interest remains after final close\n");
        dprintf(serial_fd, "MC-3: REPRODUCED stale interest remains after final close\n");
        close(serial_fd);
        poweroff_and_exit(0);
    }

    printf("MC-3: NOT REPRODUCED no stale interest remains\n");
    dprintf(serial_fd, "MC-3: NOT REPRODUCED no stale interest remains\n");
    close(serial_fd);
    poweroff_and_exit(1);
}
