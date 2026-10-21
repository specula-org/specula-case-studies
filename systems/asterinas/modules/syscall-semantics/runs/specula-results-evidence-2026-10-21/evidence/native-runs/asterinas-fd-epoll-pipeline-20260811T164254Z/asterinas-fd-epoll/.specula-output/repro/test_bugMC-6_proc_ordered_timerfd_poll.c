// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/poll.h>
#include <sys/syscall.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

enum {
    attempts = 1000,
    poll_timeout_ms = 5,
    source_lead_ns = 500000,
};

struct probe_state {
    int timer_fd;
    pid_t pid;
    long main_tid;
    atomic_bool started;
    atomic_bool stopped;
    atomic_bool main_slept;
    atomic_bool source_armed;
    atomic_bool ready_while_main_slept;
    atomic_int probe_error;
    atomic_llong poll_start_ns;
    atomic_llong ready_ns;
};

static long long monotonic_ns(void)
{
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        perror("clock_gettime");
        exit(EXIT_FAILURE);
    }

    return (long long)now.tv_sec * 1000000000LL + now.tv_nsec;
}

/* Returns 1 only for the kernel's externally reported interruptible sleep state. */
static int main_thread_is_sleeping(const struct probe_state *state)
{
    char path[96];
    char status[512] = { 0 };
    int path_len = snprintf(path, sizeof(path), "/proc/%ld/task/%ld/status",
                            (long)state->pid, state->main_tid);
    if (path_len < 0 || (size_t)path_len >= sizeof(path))
        return -1;

    int status_fd = open(path, O_RDONLY | O_CLOEXEC);
    if (status_fd < 0)
        return -1;

    ssize_t len = read(status_fd, status, sizeof(status) - 1);
    int saved_errno = errno;
    close(status_fd);
    errno = saved_errno;
    if (len < 0)
        return -1;

    return strstr(status, "State:\tS (sleeping)") != NULL;
}

static void *probe_after_poll_registration(void *arg)
{
    struct probe_state *state = arg;
    struct pollfd poll_fd = { .fd = state->timer_fd, .events = POLLIN };

    while (!atomic_load_explicit(&state->started, memory_order_acquire))
        sched_yield();

    long long start = atomic_load_explicit(&state->poll_start_ns, memory_order_acquire);
    long long arm_at = start + (long long)poll_timeout_ms * 1000000LL - source_lead_ns;
    bool slept = false;

    while (!atomic_load_explicit(&state->stopped, memory_order_acquire) &&
           monotonic_ns() < arm_at) {
        int is_sleeping = main_thread_is_sleeping(state);

        if (is_sleeping < 0) {
            atomic_store_explicit(&state->probe_error, errno, memory_order_release);
            return (void *)1;
        }
        if (is_sleeping != 0) {
            slept = true;
            atomic_store_explicit(&state->main_slept, true, memory_order_release);
            break;
        }
    }

    if (!slept || atomic_load_explicit(&state->stopped, memory_order_acquire))
        return NULL;

    struct itimerspec timer = { 0 };
    timer.it_value.tv_sec = arm_at / 1000000000LL;
    timer.it_value.tv_nsec = arm_at % 1000000000LL;
    if (timerfd_settime(state->timer_fd, TFD_TIMER_ABSTIME, &timer, NULL) < 0) {
        atomic_store_explicit(&state->probe_error, errno, memory_order_release);
        return (void *)1;
    }
    atomic_store_explicit(&state->source_armed, true, memory_order_release);

    while (!atomic_load_explicit(&state->stopped, memory_order_acquire)) {
        poll_fd.revents = 0;
        int result = poll(&poll_fd, 1, 0);

        if (result == 1 && (poll_fd.revents & POLLIN) != 0) {
            int is_sleeping = main_thread_is_sleeping(state);

            if (is_sleeping < 0) {
                atomic_store_explicit(&state->probe_error, errno, memory_order_release);
                return (void *)1;
            }
            if (is_sleeping != 0) {
                atomic_store_explicit(&state->ready_ns, monotonic_ns(), memory_order_release);
                atomic_store_explicit(&state->ready_while_main_slept, true,
                                      memory_order_release);
            }
            return NULL;
        }
        if (result != 0) {
            atomic_store_explicit(&state->probe_error, EIO, memory_order_release);
            return (void *)1;
        }
    }

    return NULL;
}

int main(void)
{
    int registration_confirmed = 0;
    int source_armed = 0;
    int ready_before_terminal = 0;
    int boundary_only = 0;

    for (int attempt = 0; attempt < attempts; attempt++) {
        struct pollfd poll_fd;
        struct probe_state state = { 0 };
        pthread_t probe;
        uint64_t ticks = 0;

        state.timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
        if (state.timer_fd < 0) {
            perror("timerfd_create");
            return EXIT_FAILURE;
        }
        state.pid = getpid();
        state.main_tid = syscall(SYS_gettid);

        if (pthread_create(&probe, NULL, probe_after_poll_registration, &state) != 0) {
            perror("pthread_create");
            close(state.timer_fd);
            return EXIT_FAILURE;
        }

        poll_fd = (struct pollfd){ .fd = state.timer_fd, .events = POLLIN };
        atomic_store_explicit(&state.poll_start_ns, monotonic_ns(), memory_order_release);
        atomic_store_explicit(&state.started, true, memory_order_release);
        int result = poll(&poll_fd, 1, poll_timeout_ms);
        long long main_return_ns = monotonic_ns();
        atomic_store_explicit(&state.stopped, true, memory_order_release);

        void *probe_result = NULL;
        if (pthread_join(probe, &probe_result) != 0 || probe_result != NULL) {
            fprintf(stderr, "probe failed errno=%d\n",
                    atomic_load_explicit(&state.probe_error, memory_order_acquire));
            close(state.timer_fd);
            return EXIT_FAILURE;
        }

        if (atomic_load_explicit(&state.main_slept, memory_order_acquire))
            registration_confirmed++;
        if (atomic_load_explicit(&state.source_armed, memory_order_acquire))
            source_armed++;

        ssize_t read_result = -1;
        if (result == 0)
            read_result = read(state.timer_fd, &ticks, sizeof(ticks));

        bool immediate_tick = read_result == (ssize_t)sizeof(ticks);
        bool strict_order =
            atomic_load_explicit(&state.ready_while_main_slept, memory_order_acquire);
        if (strict_order)
            ready_before_terminal++;

        if (result == 0 && immediate_tick && strict_order) {
            long long ready_ns = atomic_load_explicit(&state.ready_ns, memory_order_acquire);
            printf("MC6B_PROC_STRICT_REPRO attempt=%d poll_result=0 ticks=%llu "
                   "ready_lead_ns=%lld\n",
                   attempt, (unsigned long long)ticks, main_return_ns - ready_ns);
            close(state.timer_fd);
            return EXIT_FAILURE;
        }

        if (result == 0 && immediate_tick)
            boundary_only++;
        else if (result != 1 || (poll_fd.revents & POLLIN) == 0) {
            fprintf(stderr, "unexpected poll result=%d revents=0x%x errno=%d\n", result,
                    (unsigned int)poll_fd.revents, errno);
            close(state.timer_fd);
            return EXIT_FAILURE;
        }

        if (close(state.timer_fd) < 0) {
            perror("close");
            return EXIT_FAILURE;
        }
    }

    printf("MC6B_PROC_NO_STRICT_REPRO attempts=%d timeout_ms=%d confirmed=%d armed=%d "
           "ready_while_sleeping=%d boundary_only=%d\n",
           attempts, poll_timeout_ms, registration_confirmed, source_armed,
           ready_before_terminal, boundary_only);
    return EXIT_SUCCESS;
}
