// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/poll.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static int fail(const char *scenario, const char *message)
{
	printf("SPECULA_REGRESSION_FAIL %s: %s (errno=%d)\n", scenario, message,
	       errno);
	return EXIT_FAILURE;
}

__attribute__((noinline)) static struct epoll_event *inaccessible_events(void)
{
	volatile uintptr_t address = 1;

	return (struct epoll_event *)address;
}

static int expect_epoll_redelivery(int flags, const char *scenario)
{
	const uint64_t token = 0x53504543554c41ULL;
	struct epoll_event add_event = {
		.events = EPOLLIN | flags,
		.data.u64 = token,
	};
	struct epoll_event delivered_event;
	struct epoll_event *bad_events = inaccessible_events();
	uint64_t value = 1;
	int epfd;
	int event_fd;
	int ret;

	event_fd = eventfd(0, EFD_NONBLOCK);
	if (event_fd < 0)
		return fail(scenario, "eventfd");
	epfd = epoll_create1(0);
	if (epfd < 0)
		return fail(scenario, "epoll_create1");
	if (epoll_ctl(epfd, EPOLL_CTL_ADD, event_fd, &add_event) < 0)
		return fail(scenario, "epoll_ctl add");
	if (write(event_fd, &value, sizeof(value)) != (ssize_t)sizeof(value))
		return fail(scenario, "eventfd write");

	errno = 0;
	ret = epoll_wait(epfd, bad_events, 1, 0);
	if (ret != -1 || errno != EFAULT)
		return fail(scenario, "first epoll_wait did not fail with EFAULT");

	errno = 0;
	ret = epoll_wait(epfd, &delivered_event, 1, 0);
	if (ret != 1 || (delivered_event.events & EPOLLIN) == 0 ||
	    delivered_event.data.u64 != token)
		return fail(scenario, "ready event was not retained after EFAULT");

	printf("SPECULA_REGRESSION_PASS %s\n", scenario);
	return EXIT_SUCCESS;
}

static int test_timerfd_cache(void)
{
	const char *scenario = "timerfd_cache";
	struct itimerspec timer = { 0 };
	struct pollfd poll_fd;
	uint64_t ticks;
	int timer_fd;
	int ret;

	timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
	if (timer_fd < 0)
		return fail(scenario, "timerfd_create");
	timer.it_value.tv_nsec = 1000000;
	if (timerfd_settime(timer_fd, 0, &timer, NULL) < 0)
		return fail(scenario, "timerfd_settime");

	poll_fd.fd = timer_fd;
	poll_fd.events = POLLIN;
	poll_fd.revents = 0;
	ret = poll(&poll_fd, 1, 1000);
	if (ret != 1 || (poll_fd.revents & POLLIN) == 0)
		return fail(scenario, "timerfd did not become readable");
	if (read(timer_fd, &ticks, sizeof(ticks)) != (ssize_t)sizeof(ticks) || ticks == 0)
		return fail(scenario, "timerfd read");

	poll_fd.revents = 0;
	ret = poll(&poll_fd, 1, 0);
	if (ret != 0 || poll_fd.revents != 0)
		return fail(scenario, "consumed timerfd remained readable");

	printf("SPECULA_REGRESSION_PASS %s\n", scenario);
	return EXIT_SUCCESS;
}

static int test_poll_timeout_race(void)
{
	const char *scenario = "poll_timeout_race";
	const int attempts = 2000;
	int zero_then_ready = 0;
	int attempt;

	for (attempt = 0; attempt < attempts; attempt++) {
		struct itimerspec timer = { 0 };
		struct pollfd poll_fd;
		uint64_t ticks;
		int timer_fd;
		int ret;

		timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
		if (timer_fd < 0)
			return fail(scenario, "timerfd_create");
		timer.it_value.tv_nsec = 1000000;
		if (timerfd_settime(timer_fd, 0, &timer, NULL) < 0)
			return fail(scenario, "timerfd_settime");

		poll_fd.fd = timer_fd;
		poll_fd.events = POLLIN;
		poll_fd.revents = 0;
		ret = poll(&poll_fd, 1, 1);
		if (ret == 1 && (poll_fd.revents & POLLIN) != 0) {
			if (read(timer_fd, &ticks, sizeof(ticks)) != (ssize_t)sizeof(ticks))
				return fail(scenario, "reported readiness could not be consumed");
		} else if (ret == 0) {
			if (read(timer_fd, &ticks, sizeof(ticks)) == (ssize_t)sizeof(ticks))
				zero_then_ready++;
		} else {
			return fail(scenario, "unexpected poll result");
		}
		if (close(timer_fd) < 0)
			return fail(scenario, "close timerfd");
	}

	if (zero_then_ready != 0) {
		printf("SPECULA_REGRESSION_FAIL %s: %d/%d timeout returns were immediately readable\n",
		       scenario, zero_then_ready, attempts);
		return EXIT_FAILURE;
	}

	printf("SPECULA_REGRESSION_PASS %s\n", scenario);
	return EXIT_SUCCESS;
}

static int fdinfo_has_target(int epfd, int targetfd, int *has_target)
{
	char path[64];
	char buf[4096];
	char *entry;
	ssize_t len;
	int fd;

	if (snprintf(path, sizeof(path), "/proc/self/fdinfo/%d", epfd) >=
	    (int)sizeof(path))
		return -1;
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	len = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (len < 0)
		return -1;
	buf[len] = '\0';
	*has_target = 0;
	entry = buf;
	while ((entry = strstr(entry, "tfd:")) != NULL) {
		int found_fd;

		if (sscanf(entry, "tfd: %d", &found_fd) == 1 && found_fd == targetfd) {
			*has_target = 1;
			break;
		}
		entry += strlen("tfd:");
	}
	return 0;
}

static int test_dead_interest(void)
{
	const char *scenario = "dead_interest";
	struct epoll_event event = { .events = EPOLLIN, .data.u64 = 1 };
	int has_target;
	int epfd;
	int event_fd;

	event_fd = eventfd(0, EFD_NONBLOCK);
	if (event_fd < 0)
		return fail(scenario, "eventfd");
	epfd = epoll_create1(0);
	if (epfd < 0)
		return fail(scenario, "epoll_create1");
	if (epoll_ctl(epfd, EPOLL_CTL_ADD, event_fd, &event) < 0)
		return fail(scenario, "epoll_ctl add");
	if (fdinfo_has_target(epfd, event_fd, &has_target) < 0 || !has_target)
		return fail(scenario, "initial fdinfo entry unavailable");
	if (close(event_fd) < 0)
		return fail(scenario, "close watched fd");
	if (fdinfo_has_target(epfd, event_fd, &has_target) < 0)
		return fail(scenario, "post-close fdinfo unavailable");
	if (has_target)
		return fail(scenario, "closed file remains in epoll interest list");

	printf("SPECULA_REGRESSION_PASS %s\n", scenario);
	return EXIT_SUCCESS;
}

static int test_signalfd_mask_transition(void)
{
	const char *scenario = "signalfd_mask_transition";
	sigset_t blocked;
	sigset_t empty;
	struct epoll_event event = { .events = EPOLLIN, .data.u64 = 2 };
	struct epoll_event delivered_event;
	int epfd;
	int signal_fd;
	int ret;

	if (sigemptyset(&blocked) < 0 || sigaddset(&blocked, SIGUSR1) < 0)
		return fail(scenario, "construct signal mask");
	if (sigemptyset(&empty) < 0)
		return fail(scenario, "construct empty signal mask");
	if (sigprocmask(SIG_BLOCK, &blocked, NULL) < 0)
		return fail(scenario, "block SIGUSR1");

	signal_fd = signalfd(-1, &empty, SFD_NONBLOCK);
	if (signal_fd < 0)
		return fail(scenario, "signalfd create");
	epfd = epoll_create1(0);
	if (epfd < 0)
		return fail(scenario, "epoll_create1");
	if (epoll_ctl(epfd, EPOLL_CTL_ADD, signal_fd, &event) < 0)
		return fail(scenario, "epoll_ctl add");
	if (kill(getpid(), SIGUSR1) < 0)
		return fail(scenario, "queue SIGUSR1");

	/* Consume the wake caused by queuing a signal that the old mask excludes. */
	ret = epoll_wait(epfd, &delivered_event, 1, 0);
	if (ret != 0)
		return fail(scenario, "empty signalfd mask reported an event");
	if (signalfd(signal_fd, &blocked, SFD_NONBLOCK) != signal_fd)
		return fail(scenario, "signalfd mask update");

	ret = epoll_wait(epfd, &delivered_event, 1, 100);
	if (ret != 1 || (delivered_event.events & EPOLLIN) == 0)
		return fail(scenario, "mask update did not publish pending signal readiness");

	printf("SPECULA_REGRESSION_PASS %s\n", scenario);
	return EXIT_SUCCESS;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s CASE\n", argv[0]);
		return EXIT_FAILURE;
	}
	if (strcmp(argv[1], "copyout_et") == 0)
		return expect_epoll_redelivery(EPOLLET, argv[1]);
	if (strcmp(argv[1], "copyout_oneshot") == 0)
		return expect_epoll_redelivery(EPOLLONESHOT, argv[1]);
	if (strcmp(argv[1], "timerfd_cache") == 0)
		return test_timerfd_cache();
	if (strcmp(argv[1], "poll_timeout_race") == 0)
		return test_poll_timeout_race();
	if (strcmp(argv[1], "dead_interest") == 0)
		return test_dead_interest();
	if (strcmp(argv[1], "signalfd_mask_transition") == 0)
		return test_signalfd_mask_transition();
	return fail(argv[1], "unknown case");
}
