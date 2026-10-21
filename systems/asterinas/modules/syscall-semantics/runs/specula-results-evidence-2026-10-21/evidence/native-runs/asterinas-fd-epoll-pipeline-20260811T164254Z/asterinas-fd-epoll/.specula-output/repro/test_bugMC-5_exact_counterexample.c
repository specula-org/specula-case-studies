// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/signalfd.h>
#include <poll.h>
#include <unistd.h>

static int fail(const char *step)
{
    fprintf(stderr, "MC5_CE_FAIL step=%s errno=%d\n", step, errno);
    return EXIT_FAILURE;
}

/*
 * Match MC_hunt_s4_mask_transition's order: a process signal is already
 * pending before the empty-mask signalfd is added to epoll.  The update is
 * then the only transition between registration and the observed wait.
 */
int main(void)
{
    sigset_t blocked;
    sigset_t empty;
    struct epoll_event interest = { .events = EPOLLIN | EPOLLET, .data.u64 = 0x4d43354345 };
    struct epoll_event delivered = { 0 };
    struct signalfd_siginfo info = { 0 };
    struct pollfd direct_poll = { .fd = -1, .events = POLLIN };
    int epfd;
    int signal_fd;
    int rc;

    puts("MC5_CE_LEVEL=0 queue-before-register public sequence");
    if (sigemptyset(&blocked) < 0 || sigaddset(&blocked, SIGUSR1) < 0)
        return fail("construct blocked mask");
    if (sigemptyset(&empty) < 0)
        return fail("construct empty mask");
    if (sigprocmask(SIG_BLOCK, &blocked, NULL) < 0)
        return fail("block SIGUSR1");

    signal_fd = signalfd(-1, &empty, SFD_NONBLOCK);
    if (signal_fd < 0)
        return fail("signalfd create");
    if (kill(getpid(), SIGUSR1) < 0)
        return fail("queue SIGUSR1 before epoll registration");

    epfd = epoll_create1(0);
    if (epfd < 0)
        return fail("epoll create");
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, signal_fd, &interest) < 0)
        return fail("epoll add after pending signal");

    /* Corresponds to the counterexample's empty-ready-set wait registration. */
    rc = epoll_wait(epfd, &delivered, 1, 0);
    printf("MC5_CE_PREUPDATE_EPOLL_WAIT=%d events=0x%x\n", rc,
           delivered.events);
    if (rc != 0) {
        errno = 0;
        return fail("empty-mask epoll wait unexpectedly reported readiness");
    }
    delivered = (struct epoll_event){ 0 };

    if (signalfd(signal_fd, &blocked, SFD_NONBLOCK) != signal_fd)
        return fail("signalfd mask update");

    rc = epoll_wait(epfd, &delivered, 1, 250);
    printf("MC5_CE_POSTUPDATE_EPOLL_WAIT=%d events=0x%x\n", rc,
           delivered.events);
    if (rc < 0)
        return fail("post-update epoll wait");

    if (rc == 1 && (delivered.events & EPOLLIN) != 0) {
        puts("MC5_CE_NO_FAILURE epoll published pending-signal readiness");
        return EXIT_SUCCESS;
    }
    if (rc != 0) {
        errno = 0;
        return fail("post-update epoll returned unexpected event set");
    }

    direct_poll.fd = signal_fd;
    rc = poll(&direct_poll, 1, 0);
    printf("MC5_CE_DIRECT_POLL=%d revents=0x%x\n", rc, direct_poll.revents);
    if (rc != 1 || (direct_poll.revents & POLLIN) == 0) {
        errno = 0;
        return fail("updated signalfd was not synchronously pollable");
    }

    if (read(signal_fd, &info, sizeof(info)) != (ssize_t)sizeof(info))
        return fail("signalfd read after mask update");
    printf("MC5_CE_PENDING_SIGNAL_READ signo=%u\n", info.ssi_signo);
    if (info.ssi_signo != SIGUSR1) {
        errno = 0;
        return fail("wrong pending signal");
    }

    delivered = (struct epoll_event){ 0 };
    if (kill(getpid(), SIGUSR1) < 0)
        return fail("queue control SIGUSR1");
    rc = epoll_wait(epfd, &delivered, 1, 250);
    printf("MC5_CE_CONTROL_POSTQUEUE_EPOLL_WAIT=%d events=0x%x\n", rc,
           delivered.events);
    if (rc != 1 || (delivered.events & EPOLLIN) == 0) {
        errno = 0;
        return fail("fresh signal did not wake the registered epoll interest");
    }

    puts("MC5_CE_REPRODUCED epoll timed out while the mask-updated signalfd was readable");
    return EXIT_FAILURE;
}
