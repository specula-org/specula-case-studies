// SPDX-License-Identifier: MPL-2.0
// Level 0 CR-4 probe: register from one thread, then direct a blocked signal
// to the separate epoll_wait/read thread before it calls epoll_wait.
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

enum {
    ITERATIONS = 8,
    BUG_EXIT = 42,
};

struct run {
    int epfd;
    int sfd;
    int ready_write;
    int go_read;
    int iteration;
    int outcome;
    int epoll_rc;
    int epoll_errno;
    uint32_t epoll_events;
    int epoll_retry_rc;
    int epoll_retry_errno;
    uint32_t epoll_retry_events;
    ssize_t read_rc;
    int read_errno;
    uint32_t signo;
};

static void fail_errno(const char *stage)
{
    fprintf(stderr, "CR4_ERROR stage=%s errno=%d (%s)\n", stage, errno,
            strerror(errno));
    exit(EXIT_FAILURE);
}

static void fail_code(const char *stage, int code)
{
    fprintf(stderr, "CR4_ERROR stage=%s code=%d (%s)\n", stage, code,
            strerror(code));
    exit(EXIT_FAILURE);
}

static void *waiter(void *arg)
{
    struct run *run = arg;
    char token;
    struct epoll_event event = { 0 };
    struct signalfd_siginfo info = { 0 };

    if (write(run->ready_write, "R", 1) != 1) {
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

    if (run->epoll_rc == 0) {
        memset(&event, 0, sizeof(event));
        errno = 0;
        run->epoll_retry_rc = epoll_wait(run->epfd, &event, 1, 100);
        run->epoll_retry_errno = errno;
        run->epoll_retry_events = event.events;
    } else {
        run->epoll_retry_rc = -2;
    }

    errno = 0;
    run->read_rc = read(run->sfd, &info, sizeof(info));
    run->read_errno = errno;
    run->signo = info.ssi_signo;

    if (run->epoll_rc == 1 && (run->epoll_events & EPOLLIN) != 0 &&
        run->read_rc == (ssize_t)sizeof(info) && run->signo == SIGUSR1) {
        run->outcome = EXIT_SUCCESS;
    } else if (run->epoll_rc == 0 && run->epoll_retry_rc == 0 &&
               run->read_rc == (ssize_t)sizeof(info) &&
               run->signo == SIGUSR1) {
        run->outcome = BUG_EXIT;
    } else if (run->epoll_rc == 0 && run->epoll_retry_rc == 1 &&
               (run->epoll_retry_events & EPOLLIN) != 0 &&
               run->read_rc == (ssize_t)sizeof(info) &&
               run->signo == SIGUSR1) {
        run->outcome = BUG_EXIT + 1;
    } else {
        run->outcome = EXIT_FAILURE;
    }
    return NULL;
}

int main(void)
{
    sigset_t mask;
    struct epoll_event registration = {
        .events = EPOLLIN,
        .data.u64 = UINT64_C(0x435234),
    };
    int sfd;
    int epfd;

    if (sigemptyset(&mask) != 0 || sigaddset(&mask, SIGUSR1) != 0)
        fail_errno("block_sigusr1");
    int pthread_error = pthread_sigmask(SIG_BLOCK, &mask, NULL);
    if (pthread_error != 0)
        fail_code("pthread_sigmask", pthread_error);

    sfd = signalfd(-1, &mask, SFD_NONBLOCK | SFD_CLOEXEC);
    if (sfd < 0)
        fail_errno("signalfd");
    epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0)
        fail_errno("epoll_create1");
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, sfd, &registration) != 0)
        fail_errno("epoll_ctl_add_from_registration_thread");

    for (int iteration = 0; iteration < ITERATIONS; iteration++) {
        int ready_pipe[2];
        int go_pipe[2];
        char token;
        pthread_t thread;
        struct run run = {
            .epfd = epfd,
            .sfd = sfd,
            .iteration = iteration,
            .outcome = EXIT_FAILURE,
        };

        if (pipe(ready_pipe) != 0 || pipe(go_pipe) != 0)
            fail_errno("pipe");
        run.ready_write = ready_pipe[1];
        run.go_read = go_pipe[0];

        pthread_error = pthread_create(&thread, NULL, waiter, &run);
        if (pthread_error != 0)
            fail_code("pthread_create_wait_thread", pthread_error);
        if (read(ready_pipe[0], &token, 1) != 1)
            fail_errno("waiter_ready");

        // The public pthread_kill API queues SIGUSR1 to the future reader.
        // The ready/go handoff ensures this occurs before epoll_wait, without
        // any sleep, failpoint, injected state, or source modification.
        pthread_error = pthread_kill(thread, SIGUSR1);
        if (pthread_error != 0)
            fail_code("pthread_kill_wait_thread", pthread_error);
        if (write(go_pipe[1], "G", 1) != 1)
            fail_errno("release_waiter");
        pthread_error = pthread_join(thread, NULL);
        if (pthread_error != 0)
            fail_code("pthread_join_waiter", pthread_error);

        printf("CR4 iteration=%d epoll_rc=%d epoll_errno=%d epoll_events=0x%x "
               "epoll_retry_rc=%d epoll_retry_errno=%d epoll_retry_events=0x%x "
               "read_rc=%zd read_errno=%d signo=%u outcome=%d\n",
               run.iteration, run.epoll_rc, run.epoll_errno, run.epoll_events,
               run.epoll_retry_rc, run.epoll_retry_errno, run.epoll_retry_events,
               run.read_rc, run.read_errno, run.signo, run.outcome);

        close(ready_pipe[0]);
        close(ready_pipe[1]);
        close(go_pipe[0]);
        close(go_pipe[1]);

        if (run.outcome == BUG_EXIT) {
            printf("CR4_RESULT=PERSISTENT_MISS: two epoll_wait calls timed out "
                   "while the same thread directly read its pending SIGUSR1 "
                   "from signalfd\n");
            close(epfd);
            close(sfd);
            return BUG_EXIT;
        }
        if (run.outcome == BUG_EXIT + 1) {
            printf("CR4_RESULT=DELAYED_WAKEUP: first epoll_wait timed out, "
                   "but a repeat wait observed the same pending SIGUSR1\n");
            close(epfd);
            close(sfd);
            return BUG_EXIT + 1;
        }
        if (run.outcome != EXIT_SUCCESS) {
            printf("CR4_RESULT=PREREQUISITE_FAILURE\n");
            close(epfd);
            close(sfd);
            return EXIT_FAILURE;
        }
    }

    printf("CR4_RESULT=NO_MISS: epoll_wait observed the waiter-thread signal "
           "before its direct signalfd read\n");
    close(epfd);
    close(sfd);
    return EXIT_SUCCESS;
}
