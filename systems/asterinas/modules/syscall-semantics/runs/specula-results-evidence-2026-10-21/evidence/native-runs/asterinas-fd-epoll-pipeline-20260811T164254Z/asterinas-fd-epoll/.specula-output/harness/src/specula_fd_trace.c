// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/syscall.h>
#include <sys/timerfd.h>
#include <unistd.h>

#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif

enum scenario {
	SCENARIO_CONCURRENT_FCNTL,
	SCENARIO_DUP_REPLACE_FLAGS,
	SCENARIO_CLOSE_REUSE,
	SCENARIO_READINESS_EPOLL,
};

static pthread_barrier_t phase_barrier;
static atomic_uint concurrent_ready;
static enum scenario selected_scenario;

static __attribute__((noreturn)) void fail(int code)
{
	_exit(code);
}

static void require(int condition, int code)
{
	if (!condition)
		fail(code);
}

static void pin_to_cpu(int cpu, int code)
{
	cpu_set_t set;

	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	require(sched_setaffinity(0, sizeof(set), &set) == 0, code);
}

static void wait_at_barrier(int code)
{
	int ret = pthread_barrier_wait(&phase_barrier);

	require(ret == 0 || ret == PTHREAD_BARRIER_SERIAL_THREAD, code);
}

static void wait_for_concurrent_start(void)
{
	atomic_fetch_add_explicit(&concurrent_ready, 1, memory_order_release);
	while (atomic_load_explicit(&concurrent_ready, memory_order_acquire) !=
	       2)
		;
}

static void create_model_objects(void)
{
	sigset_t empty_mask;
	int fd;

	for (fd = 0; fd < 3; fd++)
		close(fd);

	fd = timerfd_create(CLOCK_MONOTONIC, 0);
	require(fd == 0, 10);
	require(sigemptyset(&empty_mask) == 0, 11);
	fd = signalfd(-1, &empty_mask, 0);
	require(fd == 1, 12);
	fd = eventfd(0, 0);
	require(fd == 2, 13);
	fd = epoll_create1(0);
	require(fd == 3, 14);
	fd = epoll_create1(0);
	require(fd == 4, 15);
}

static void *actor_two(void *unused)
{
	(void)unused;
	pin_to_cpu(1, 20);
	require(prctl(PR_SET_NAME, "specula-t2", 0, 0, 0) == 0, 21);
	if (selected_scenario == SCENARIO_CONCURRENT_FCNTL)
		wait_for_concurrent_start();
	else
		wait_at_barrier(22);

	if (selected_scenario == SCENARIO_CONCURRENT_FCNTL)
		require(fcntl(0, F_SETFL, O_NONBLOCK) == 0, 23);

	wait_at_barrier(24);
	return NULL;
}

static void run_dup_replace_flags(void)
{
	require(dup2(0, 0) == 0, 30);
	require(dup3(0, 2, O_CLOEXEC) == 2, 31);
	require(fcntl(0, F_SETFD, 0) == 0, 32);
}

static void run_close_reuse(void)
{
	require(close(2) == 0, 40);
	require(dup(0) == 2, 41);
	require(syscall(SYS_close_range, 0U, 2U, CLOSE_RANGE_CLOEXEC) == 0, 42);
}

static void run_readiness_epoll(void)
{
	struct epoll_event event = {
		.events = EPOLLIN,
		.data.u64 = 0x53504543554c41ULL,
	};
	sigset_t signal_mask;
	uint64_t value = 1;

	require(sigemptyset(&signal_mask) == 0, 50);
	require(sigaddset(&signal_mask, SIGUSR1) == 0, 51);
	require(signalfd(1, &signal_mask, 0) == 1, 52);
	require(write(2, &value, sizeof(value)) == (ssize_t)sizeof(value), 53);
	require(read(2, &value, sizeof(value)) == (ssize_t)sizeof(value), 54);
	require(value == 1, 55);
	require(epoll_ctl(3, EPOLL_CTL_ADD, 2, &event) == 0, 56);
	require(epoll_ctl(3, EPOLL_CTL_ADD, 4, &event) == 0, 57);
}

static enum scenario parse_scenario(const char *name)
{
	if (strcmp(name, "concurrent_fcntl") == 0)
		return SCENARIO_CONCURRENT_FCNTL;
	if (strcmp(name, "dup_replace_flags") == 0)
		return SCENARIO_DUP_REPLACE_FLAGS;
	if (strcmp(name, "close_reuse") == 0)
		return SCENARIO_CLOSE_REUSE;
	if (strcmp(name, "readiness_epoll") == 0)
		return SCENARIO_READINESS_EPOLL;
	fail(60);
}

int main(int argc, char **argv)
{
	pthread_t thread;

	require(argc == 2, 1);
	selected_scenario = parse_scenario(argv[1]);
	pin_to_cpu(0, 2);
	create_model_objects();
	require(prctl(PR_SET_NAME, "specula-t1", 0, 0, 0) == 0, 3);
	require(pthread_barrier_init(&phase_barrier, NULL, 2) == 0, 4);
	require(pthread_create(&thread, NULL, actor_two, NULL) == 0, 5);
	if (selected_scenario == SCENARIO_CONCURRENT_FCNTL)
		wait_for_concurrent_start();
	else
		wait_at_barrier(6);

	switch (selected_scenario) {
	case SCENARIO_CONCURRENT_FCNTL:
		require(fcntl(0, F_SETFL, O_NONBLOCK) == 0, 70);
		break;
	case SCENARIO_DUP_REPLACE_FLAGS:
		run_dup_replace_flags();
		break;
	case SCENARIO_CLOSE_REUSE:
		run_close_reuse();
		break;
	case SCENARIO_READINESS_EPOLL:
		run_readiness_epoll();
		break;
	}

	wait_at_barrier(7);
	require(pthread_join(thread, NULL) == 0, 8);
	require(pthread_barrier_destroy(&phase_barrier) == 0, 9);
	require(prctl(PR_SET_NAME, "specula-flush", 0, 0, 0) == 0, 80);
	return EXIT_SUCCESS;
}
