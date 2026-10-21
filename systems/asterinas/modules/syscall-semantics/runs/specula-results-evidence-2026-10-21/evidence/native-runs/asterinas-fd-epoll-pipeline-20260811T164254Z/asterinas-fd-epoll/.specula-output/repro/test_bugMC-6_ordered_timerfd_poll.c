// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/poll.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

enum {
    attempts = 2000,
    timer_delay_ms = 1,
    poll_timeout_ms = 3,
    strict_lead_ns = 500000,
};

struct probe_state {
    int timer_fd;
    atomic_bool start;
    atomic_bool stop;
    atomic_bool main_in_poll;
    atomic_bool ready_seen;
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

static void *probe_readiness(void *arg)
{
    struct probe_state *state = arg;
    struct pollfd poll_fd = { .fd = state->timer_fd, .events = POLLIN };

    while (!atomic_load_explicit(&state->start, memory_order_acquire))
        sched_yield();

    while (!atomic_load_explicit(&state->stop, memory_order_acquire)) {
        poll_fd.revents = 0;
        int result = poll(&poll_fd, 1, 0);

        if (result == 1 && (poll_fd.revents & POLLIN) != 0) {
            long long now = monotonic_ns();

            if (atomic_load_explicit(&state->main_in_poll, memory_order_acquire)) {
                bool expected = false;

                if (atomic_compare_exchange_strong_explicit(
                        &state->ready_seen,
                        &expected,
                        true,
                        memory_order_acq_rel,
                        memory_order_acquire
                    )) {
                    atomic_store_explicit(&state->ready_ns, now, memory_order_release);
                }
            }
        } else if (result != 0) {
            fprintf(stderr, "probe poll result=%d revents=0x%x errno=%d\n", result,
                    (unsigned int)poll_fd.revents, errno);
            return (void *)1;
        }
    }

    return NULL;
}

int main(void)
{
    int boundary_only = 0;
    long long largest_boundary_lead_ns = -1;

    for (int attempt = 0; attempt < attempts; attempt++) {
        struct itimerspec timer = { 0 };
        struct pollfd poll_fd;
        struct probe_state state = { 0 };
        pthread_t probe;
        uint64_t ticks = 0;

        state.timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
        if (state.timer_fd < 0) {
            perror("timerfd_create");
            return EXIT_FAILURE;
        }

        if (pthread_create(&probe, NULL, probe_readiness, &state) != 0) {
            perror("pthread_create");
            close(state.timer_fd);
            return EXIT_FAILURE;
        }

        timer.it_value.tv_nsec = timer_delay_ms * 1000000L;
        if (timerfd_settime(state.timer_fd, 0, &timer, NULL) < 0) {
            perror("timerfd_settime");
            atomic_store_explicit(&state.stop, true, memory_order_release);
            pthread_join(probe, NULL);
            close(state.timer_fd);
            return EXIT_FAILURE;
        }

        atomic_store_explicit(&state.start, true, memory_order_release);
        poll_fd = (struct pollfd){ .fd = state.timer_fd, .events = POLLIN };
        atomic_store_explicit(&state.main_in_poll, true, memory_order_release);
        int result = poll(&poll_fd, 1, poll_timeout_ms);
        long long main_return_ns = monotonic_ns();
        atomic_store_explicit(&state.main_in_poll, false, memory_order_release);
        atomic_store_explicit(&state.stop, true, memory_order_release);

        void *probe_result = NULL;
        if (pthread_join(probe, &probe_result) != 0 || probe_result != NULL) {
            fprintf(stderr, "probe failed\n");
            close(state.timer_fd);
            return EXIT_FAILURE;
        }

        ssize_t read_result = -1;
        if (result == 0)
            read_result = read(state.timer_fd, &ticks, sizeof(ticks));

        bool immediate_tick = read_result == (ssize_t)sizeof(ticks);
        long long ready_ns = atomic_load_explicit(&state.ready_ns, memory_order_acquire);
        bool strict_order = atomic_load_explicit(&state.ready_seen, memory_order_acquire) &&
                            ready_ns + strict_lead_ns < main_return_ns;

        if (result == 0 && immediate_tick && strict_order) {
            printf(
                "MC6B_STRICT_REPRO attempt=%d poll_result=0 ticks=%llu ready_lead_ns=%lld\n",
                attempt,
                (unsigned long long)ticks,
                main_return_ns - ready_ns
            );
            close(state.timer_fd);
            return EXIT_FAILURE;
        }

        if (result == 0 && immediate_tick) {
            long long ready_lead_ns =
                ready_ns == 0 ? -1LL : main_return_ns - ready_ns;

            boundary_only++;
            if (ready_lead_ns > largest_boundary_lead_ns)
                largest_boundary_lead_ns = ready_lead_ns;
        } else if (result != 1 || (poll_fd.revents & POLLIN) == 0) {
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

    printf(
        "MC6B_NO_STRICT_REPRO attempts=%d timer_ms=%d poll_ms=%d boundary_only=%d max_boundary_lead_ns=%lld\n",
        attempts,
        timer_delay_ms,
        poll_timeout_ms,
        boundary_only,
        largest_boundary_lead_ns
    );
    return EXIT_SUCCESS;
}
