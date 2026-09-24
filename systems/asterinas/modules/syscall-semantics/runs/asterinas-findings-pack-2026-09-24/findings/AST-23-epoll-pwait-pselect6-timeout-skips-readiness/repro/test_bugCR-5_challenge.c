// SPDX-License-Identifier: MPL-2.0
//
// CR-5 challenger control. A blocked low-priority waiter is made runnable by
// a pipe write well before its deadline, then cannot run until the writer
// exits. Linux and Asterinas can run the same public-ABI sequence.

#define _GNU_SOURCE

#include <errno.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum api_kind {
	API_EPOLL_WAIT,
	API_EPOLL_PWAIT,
	API_PPOLL,
	API_PSELECT,
};

struct wait_result {
	int ret;
	int err;
	int ready;
};

struct write_times {
	struct timespec before;
	struct timespec after;
};

static const char *api_name(enum api_kind api)
{
	switch (api) {
	case API_EPOLL_WAIT:
		return "epoll_wait";
	case API_EPOLL_PWAIT:
		return "epoll_pwait";
	case API_PPOLL:
		return "ppoll";
	case API_PSELECT:
		return "pselect";
	}
	return "unknown";
}

static int write_exact(int fd, const void *buf, size_t len)
{
	const char *pos = buf;

	while (len > 0) {
		ssize_t n = write(fd, pos, len);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		pos += n;
		len -= (size_t)n;
	}
	return 0;
}

static int read_exact(int fd, void *buf, size_t len)
{
	char *pos = buf;

	while (len > 0) {
		ssize_t n = read(fd, pos, len);

		if (n == 0)
			return -1;
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		pos += n;
		len -= (size_t)n;
	}
	return 0;
}

static void sleep_ms(long milliseconds)
{
	struct timespec delay = {
		.tv_sec = milliseconds / 1000,
		.tv_nsec = (milliseconds % 1000) * 1000000L,
	};

	while (nanosleep(&delay, &delay) < 0 && errno == EINTR)
		;
}

static int before(struct timespec left, struct timespec right)
{
	return left.tv_sec < right.tv_sec ||
	       (left.tv_sec == right.tv_sec && left.tv_nsec < right.tv_nsec);
}

static long elapsed_ms(struct timespec start, struct timespec end)
{
	return (end.tv_sec - start.tv_sec) * 1000L +
	       (end.tv_nsec - start.tv_nsec) / 1000000L;
}

static struct timespec add_ms(struct timespec start, long milliseconds)
{
	struct timespec result = {
		.tv_sec = start.tv_sec + milliseconds / 1000,
		.tv_nsec = start.tv_nsec + (milliseconds % 1000) * 1000000L,
	};

	if (result.tv_nsec >= 1000000000L) {
		result.tv_sec++;
		result.tv_nsec -= 1000000000L;
	}
	return result;
}

static int mask_blocks_sigusr1(void)
{
	sigset_t mask;

	if (sigprocmask(SIG_SETMASK, NULL, &mask) < 0)
		return 0;
	return sigismember(&mask, SIGUSR1) == 1;
}

static struct wait_result wait_once(enum api_kind api, int fd, int timeout_ms,
					    const sigset_t *temporary)
{
	struct wait_result result = { .ret = -1, .err = 0, .ready = 0 };
	struct timespec timeout = {
		.tv_sec = timeout_ms / 1000,
		.tv_nsec = (timeout_ms % 1000) * 1000000L,
	};

	if (api == API_EPOLL_WAIT || api == API_EPOLL_PWAIT) {
		struct epoll_event registration = {
			.events = EPOLLIN,
			.data.fd = fd,
		};
		struct epoll_event event;
		int epfd = epoll_create1(0);

		if (epfd < 0) {
			result.err = errno;
			return result;
		}
		if (epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &registration) < 0) {
			result.err = errno;
			close(epfd);
			return result;
		}
		errno = 0;
		if (api == API_EPOLL_WAIT)
			result.ret = epoll_wait(epfd, &event, 1, timeout_ms);
		else
			result.ret = epoll_pwait(epfd, &event, 1, timeout_ms, temporary);
		result.err = errno;
		result.ready = result.ret > 0 && event.data.fd == fd &&
			       (event.events & EPOLLIN) != 0;
		close(epfd);
		return result;
	}

	if (api == API_PPOLL) {
		struct pollfd pollfd = { .fd = fd, .events = POLLIN };

		errno = 0;
		result.ret = ppoll(&pollfd, 1, &timeout, temporary);
		result.err = errno;
		result.ready = result.ret > 0 && (pollfd.revents & POLLIN) != 0;
		return result;
	}

	{
		fd_set readfds;

		FD_ZERO(&readfds);
		FD_SET(fd, &readfds);
		errno = 0;
		result.ret = pselect(fd + 1, &readfds, NULL, NULL, &timeout, temporary);
		result.err = errno;
		result.ready = result.ret > 0 && FD_ISSET(fd, &readfds);
	}
	return result;
}

static int choose_and_set_one_cpu(void)
{
	cpu_set_t allowed;
	cpu_set_t one;
	int cpu;

	if (sched_getaffinity(0, sizeof(allowed), &allowed) < 0)
		return -1;
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (!CPU_ISSET(cpu, &allowed))
			continue;
		CPU_ZERO(&one);
		CPU_SET(cpu, &one);
		return sched_setaffinity(0, sizeof(one), &one);
	}
	errno = EINVAL;
	return -1;
}

static void busy_for_ms(long milliseconds)
{
	struct timespec start;
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &start);
	do {
		clock_gettime(CLOCK_MONOTONIC, &now);
	} while (elapsed_ms(start, now) < milliseconds);
}

static int set_idle_policy(void)
{
	struct sched_param param = { 0 };

	return sched_setscheduler(0, SCHED_IDLE, &param);
}

static int run_case(enum api_kind api, const sigset_t *temporary)
{
	const int timeout_ms = 300;
	int data_pipe[2];
	int ready_pipe[2];
	int go_pipe[2];
	int stamp_pipe[2];
	pid_t writer;
	char token;
	struct timespec start;
	struct timespec deadline;
	struct timespec returned;
	struct write_times write_times;
	struct wait_result result;
	struct wait_result probe;
	int writer_status;
	int write_finished_in_time;
	int returned_late;
	int mask_restored;
	int failure = 0;

	if (pipe(data_pipe) < 0 || pipe(ready_pipe) < 0 || pipe(go_pipe) < 0 ||
	    pipe(stamp_pipe) < 0) {
		perror("CR5_CHALLENGE pipe");
		return 1;
	}
	if (choose_and_set_one_cpu() < 0) {
		printf("CR5_CHALLENGE_SKIP api=%s reason=affinity errno=%d\n",
		       api_name(api), errno);
		return 0;
	}

	writer = fork();
	if (writer < 0) {
		perror("CR5_CHALLENGE fork");
		return 1;
	}
	if (writer == 0) {
		struct write_times times;

		if (choose_and_set_one_cpu() < 0 ||
		    write_exact(ready_pipe[1], "r", 1) < 0 ||
		    read_exact(go_pipe[0], &token, 1) < 0)
			_exit(2);

		/* The idle waiter is the only other runnable task during this delay. */
		sleep_ms(80);
		clock_gettime(CLOCK_MONOTONIC, &times.before);
		if (write_exact(data_pipe[1], "r", 1) < 0)
			_exit(3);
		clock_gettime(CLOCK_MONOTONIC, &times.after);
		if (write_exact(stamp_pipe[1], &times, sizeof(times)) < 0)
			_exit(4);

		/* Keep a normal-priority task runnable past the waiter's deadline. */
		busy_for_ms(500);
		_exit(0);
	}

	if (read_exact(ready_pipe[0], &token, 1) < 0) {
		perror("CR5_CHALLENGE ready");
		return 1;
	}
	clock_gettime(CLOCK_MONOTONIC, &start);
	deadline = add_ms(start, timeout_ms);
	if (set_idle_policy() < 0) {
		printf("CR5_CHALLENGE_SKIP api=%s reason=sched_idle errno=%d\n",
		       api_name(api), errno);
		return 0;
	}
	if (write_exact(go_pipe[1], "g", 1) < 0) {
		perror("CR5_CHALLENGE go");
		return 1;
	}

	result = wait_once(api, data_pipe[0], timeout_ms, temporary);
	clock_gettime(CLOCK_MONOTONIC, &returned);
	if (waitpid(writer, &writer_status, 0) < 0 ||
	    read_exact(stamp_pipe[0], &write_times, sizeof(write_times)) < 0) {
		perror("CR5_CHALLENGE collect");
		return 1;
	}

	mask_restored = mask_blocks_sigusr1();
	probe = wait_once(api, data_pipe[0], 0, temporary);
	write_finished_in_time = before(write_times.after, deadline);
	returned_late = elapsed_ms(start, returned) > timeout_ms + 150;
	printf("CR5_CHALLENGE api=%s ret=%d errno=%d ready=%d probe_ret=%d probe_ready=%d "
	       "write_finished_before_deadline=%d returned_late=%d elapsed_ms=%ld "
	       "mask_restored=%d writer_ok=%d\n",
	       api_name(api), result.ret, result.err, result.ready, probe.ret, probe.ready,
	       write_finished_in_time, returned_late, elapsed_ms(start, returned),
	       mask_restored, WIFEXITED(writer_status) && WEXITSTATUS(writer_status) == 0);

	if (!write_finished_in_time || !returned_late || !mask_restored ||
	    !WIFEXITED(writer_status) || WEXITSTATUS(writer_status) != 0) {
		printf("CR5_CHALLENGE_INCONCLUSIVE api=%s\n", api_name(api));
		return 1;
	}
	if (result.ret != 1 || !result.ready) {
		printf("CR5_CHALLENGE_TIMEOUT_AFTER_READY api=%s\n", api_name(api));
		failure = 1;
	}
	return failure;
}

static int run_worker(enum api_kind api, const sigset_t *temporary)
{
	pid_t worker = fork();
	int status;

	if (worker < 0) {
		perror("CR5_CHALLENGE worker");
		return 1;
	}
	if (worker == 0)
		_exit(run_case(api, temporary));
	if (waitpid(worker, &status, 0) < 0 || !WIFEXITED(status))
		return 1;
	return WEXITSTATUS(status);
}

int main(void)
{
	const enum api_kind apis[] = {
		API_EPOLL_WAIT,
		API_EPOLL_PWAIT,
		API_PPOLL,
		API_PSELECT,
	};
	sigset_t blocked;
	sigset_t temporary;
	int failures = 0;
	size_t index;

	setvbuf(stdout, NULL, _IONBF, 0);
	sigemptyset(&blocked);
	sigaddset(&blocked, SIGUSR1);
	sigemptyset(&temporary);
	if (sigprocmask(SIG_SETMASK, &blocked, NULL) < 0) {
		perror("CR5_CHALLENGE sigprocmask");
		return EXIT_FAILURE;
	}

	for (index = 0; index < sizeof(apis) / sizeof(apis[0]); index++) {
		failures += run_worker(apis[index], &temporary);
		if (sigprocmask(SIG_SETMASK, &blocked, NULL) < 0)
			return EXIT_FAILURE;
	}
	printf("CR5_CHALLENGE_RESULT %s failures=%d\n",
	       failures == 0 ? "PASS" : "FAIL", failures);
	return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
