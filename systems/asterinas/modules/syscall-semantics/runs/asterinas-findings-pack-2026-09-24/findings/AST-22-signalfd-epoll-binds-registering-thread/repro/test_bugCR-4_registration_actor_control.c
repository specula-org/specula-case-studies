// SPDX-License-Identifier: MPL-2.0
// Level-0 control: only the epoll_ctl caller changes from the cross-thread
// probe. The waiter registers the shared signalfd before receiving SIGUSR1.
#define _GNU_SOURCE

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/signalfd.h>
#include <unistd.h>

enum { CONTROL_FAILURE = 43 };

struct run {
    int epfd;
    int sfd;
    int ready_write;
    int go_read;
    int ctl_rc;
    int ctl_errno;
    int epoll_rc;
    int epoll_errno;
    uint32_t epoll_events;
    ssize_t read_rc;
    int read_errno;
    uint32_t signo;
    int outcome;
};

static void fail_errno(const char *stage)
{
    fprintf(stderr, "CR4_CONTROL_ERROR stage=%s errno=%d (%s)\n", stage, errno,
            strerror(errno));
    exit(EXIT_FAILURE);
}

static void fail_code(const char *stage, int code)
{
    fprintf(stderr, "CR4_CONTROL_ERROR stage=%s code=%d (%s)\n", stage, code,
            strerror(code));
    exit(EXIT_FAILURE);
}

static void *waiter(void *arg)
{
    struct run *run = arg;
    struct epoll_event registration = {
        .events = EPOLLIN,
        .data.u64 = UINT64_C(0x43523443),
    };
    struct epoll_event event = { 0 };
    struct signalfd_siginfo info = { 0 };
    char token;

    errno = 0;
    run->ctl_rc = epoll_ctl(run->epfd, EPOLL_CTL_ADD, run->sfd, &registration);
    run->ctl_errno = errno;
    if (write(run->ready_write, "R", 1) != 1) {
        run->outcome = EXIT_FAILURE;
        return NULL;
    }
    if (run->ctl_rc != 0) {
        run->outcome = EXIT_FAILURE;
        return NULL;
    }
    if (read(run->go_read, &token, 1) != 1) {
        run->outcome = EXIT_FAILURE;
        return NULL;
    }

    errno = 0;
    run->epoll_rc = epoll_wait(run->epfd, &event, 1, 100);
    run->epoll_errno = errno;
    run->epoll_events = event.events;

    errno = 0;
    run->read_rc = read(run->sfd, &info, sizeof(info));
    run->read_errno = errno;
    run->signo = info.ssi_signo;

    run->outcome = run->epoll_rc == 1 &&
                   (run->epoll_events & EPOLLIN) != 0 &&
                   run->read_rc == (ssize_t)sizeof(info) &&
                   run->signo == SIGUSR1
                       ? EXIT_SUCCESS
                       : CONTROL_FAILURE;
    return NULL;
}

int main(void)
{
    sigset_t mask;
    int ready_pipe[2];
    int go_pipe[2];
    int sfd;
    int epfd;
    int pthread_error;
    char token;
    pthread_t thread;
    struct run run = {
        .outcome = EXIT_FAILURE,
    };

    if (sigemptyset(&mask) != 0 || sigaddset(&mask, SIGUSR1) != 0)
        fail_errno("block_sigusr1");
    pthread_error = pthread_sigmask(SIG_BLOCK, &mask, NULL);
    if (pthread_error != 0)
        fail_code("pthread_sigmask", pthread_error);

    sfd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
    if (sfd < 0)
        fail_errno("signalfd");
    epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0)
        fail_errno("epoll_create1");
    if (pipe(ready_pipe) != 0 || pipe(go_pipe) != 0)
        fail_errno("pipe");

    run.epfd = epfd;
    run.sfd = sfd;
    run.ready_write = ready_pipe[1];
    run.go_read = go_pipe[0];

    pthread_error = pthread_create(&thread, NULL, waiter, &run);
    if (pthread_error != 0)
        fail_code("pthread_create_waiter", pthread_error);
    if (read(ready_pipe[0], &token, 1) != 1)
        fail_errno("waiter_registered");

    pthread_error = pthread_kill(thread, SIGUSR1);
    if (pthread_error != 0)
        fail_code("pthread_kill_waiter", pthread_error);
    if (write(go_pipe[1], "G", 1) != 1)
        fail_errno("release_waiter");
    pthread_error = pthread_join(thread, NULL);
    if (pthread_error != 0)
        fail_code("pthread_join_waiter", pthread_error);

    printf("CR4_CONTROL ctl_rc=%d ctl_errno=%d epoll_rc=%d epoll_errno=%d "
           "epoll_events=0x%x read_rc=%zd read_errno=%d signo=%u outcome=%d\n",
           run.ctl_rc, run.ctl_errno, run.epoll_rc, run.epoll_errno,
           run.epoll_events, run.read_rc, run.read_errno, run.signo, run.outcome);

    close(ready_pipe[0]);
    close(ready_pipe[1]);
    close(go_pipe[0]);
    close(go_pipe[1]);
    close(epfd);
    close(sfd);

    if (run.outcome == EXIT_SUCCESS) {
        printf("CR4_CONTROL_RESULT=REGISTRATION_ACTOR_OK\n");
        return EXIT_SUCCESS;
    }
    printf("CR4_CONTROL_RESULT=REGISTRATION_ACTOR_FAILED\n");
    return CONTROL_FAILURE;
}
