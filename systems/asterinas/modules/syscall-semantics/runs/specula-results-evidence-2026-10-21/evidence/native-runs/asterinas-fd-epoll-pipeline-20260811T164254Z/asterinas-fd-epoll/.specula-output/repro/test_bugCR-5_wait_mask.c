// SPDX-License-Identifier: MPL-2.0
//
// CR-5: exercise readiness, timeout, and temporary signal-mask arbitration
// through the Linux ABI.  The priority case uses only scheduling APIs to delay
// the woken waiter; it does not modify the kernel or inject kernel state.

#define _GNU_SOURCE

#include <errno.h>
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
#include <poll.h>

enum api_kind {
	API_EPOLL_WAIT,
	API_EPOLL_PWAIT,
	API_PPOLL,
	API_PSELECT6,
};

struct api_result {
	int ret;
	int err;
	int ready;
};

static volatile sig_atomic_t sigusr1_count;

static const char *api_name(enum api_kind api)
{
	switch (api) {
	case API_EPOLL_WAIT:
		return "epoll_wait";
	case API_EPOLL_PWAIT:
		return "epoll_pwait";
	case API_PPOLL:
		return "ppoll";
	case API_PSELECT6:
		return "pselect6";
	}
	return "unknown";
}

static int api_uses_mask(enum api_kind api)
{
	return api != API_EPOLL_WAIT;
}

static void fail(const char *phase, enum api_kind api, const char *reason,
		 int *failures)
{
	printf("CR5_FAIL phase=%s api=%s reason=%s\n", phase, api_name(api), reason);
	(*failures)++;
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

static int add_ms(struct timespec start, long milliseconds, struct timespec *out)
{
	out->tv_sec = start.tv_sec + milliseconds / 1000;
	out->tv_nsec = start.tv_nsec + (milliseconds % 1000) * 1000000L;
	if (out->tv_nsec >= 1000000000L) {
		out->tv_sec++;
		out->tv_nsec -= 1000000000L;
	}
	return 0;
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

static int write_exact(int fd, const void *buf, size_t len)
{
	const char *cursor = buf;

	while (len > 0) {
		ssize_t written = write(fd, cursor, len);

		if (written < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		cursor += written;
		len -= (size_t)written;
	}
	return 0;
}

static int read_exact(int fd, void *buf, size_t len)
{
	char *cursor = buf;

	while (len > 0) {
		ssize_t read_len = read(fd, cursor, len);

		if (read_len == 0)
			return -1;
		if (read_len < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		cursor += read_len;
		len -= (size_t)read_len;
	}
	return 0;
}

static int mask_blocks_sigusr1(void)
{
	sigset_t mask;

	if (sigprocmask(SIG_SETMASK, NULL, &mask) < 0)
		return 0;
	return sigismember(&mask, SIGUSR1) == 1;
}

static int block_sigusr1(sigset_t *blocked, sigset_t *temporary)
{
	sigemptyset(blocked);
	sigaddset(blocked, SIGUSR1);
	sigemptyset(temporary);
	return sigprocmask(SIG_SETMASK, blocked, NULL);
}

static struct api_result wait_once(enum api_kind api, int fd, int timeout_ms,
					   const sigset_t *temporary)
{
	struct api_result result = { .ret = -1, .err = 0, .ready = 0 };
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
		struct pollfd pollfd = {
			.fd = fd,
			.events = POLLIN,
		};

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

static void sigusr1_handler(int unused)
{
	(void)unused;
	sigusr1_count++;
}

static int install_handler(void)
{
	struct sigaction action;

	memset(&action, 0, sizeof(action));
	action.sa_handler = sigusr1_handler;
	sigemptyset(&action.sa_mask);
	return sigaction(SIGUSR1, &action, NULL);
}

static void run_timeout_control(enum api_kind api, const sigset_t *temporary,
				int *failures)
{
	int pipefd[2];
	struct api_result result;
	int mask_ok;

	if (pipe(pipefd) < 0) {
		fail("timeout", api, "pipe", failures);
		return;
	}
	result = wait_once(api, pipefd[0], 100, temporary);
	mask_ok = mask_blocks_sigusr1();
	printf("CR5_CASE phase=timeout api=%s ret=%d errno=%d ready=%d mask_blocked=%d\n",
	       api_name(api), result.ret, result.err, result.ready, mask_ok);
	if (result.ret != 0 || result.ready || !mask_ok)
		fail("timeout", api, "expected_timeout", failures);
	close(pipefd[0]);
	close(pipefd[1]);
}

static void run_ready_control(enum api_kind api, const sigset_t *temporary,
			      int *failures)
{
	int pipefd[2];
	pid_t child;
	struct api_result result;
	int mask_ok;

	if (pipe(pipefd) < 0) {
		fail("ready", api, "pipe", failures);
		return;
	}
	child = fork();
	if (child < 0) {
		fail("ready", api, "fork", failures);
		close(pipefd[0]);
		close(pipefd[1]);
		return;
	}
	if (child == 0) {
		sleep_ms(20);
		(void)write_exact(pipefd[1], "r", 1);
		_exit(0);
	}
	result = wait_once(api, pipefd[0], 250, temporary);
	mask_ok = mask_blocks_sigusr1();
	printf("CR5_CASE phase=ready api=%s ret=%d errno=%d ready=%d mask_blocked=%d\n",
	       api_name(api), result.ret, result.err, result.ready, mask_ok);
	if (result.ret != 1 || !result.ready || !mask_ok)
		fail("ready", api, "expected_readiness", failures);
	waitpid(child, NULL, 0);
	close(pipefd[0]);
	close(pipefd[1]);
}

static void run_signal_control(enum api_kind api, const sigset_t *temporary,
			       int *failures)
{
	int pipefd[2];
	pid_t child;
	struct api_result result;
	sig_atomic_t before_handler;
	int mask_ok;

	if (!api_uses_mask(api))
		return;
	if (pipe(pipefd) < 0) {
		fail("signal", api, "pipe", failures);
		return;
	}
	child = fork();
	if (child < 0) {
		fail("signal", api, "fork", failures);
		close(pipefd[0]);
		close(pipefd[1]);
		return;
	}
	if (child == 0) {
		sleep_ms(20);
		(void)kill(getppid(), SIGUSR1);
		_exit(0);
	}
	before_handler = sigusr1_count;
	result = wait_once(api, pipefd[0], 250, temporary);
	mask_ok = mask_blocks_sigusr1();
	printf("CR5_CASE phase=signal api=%s ret=%d errno=%d ready=%d handler_delta=%d mask_blocked=%d\n",
	       api_name(api), result.ret, result.err, result.ready,
	       (int)(sigusr1_count - before_handler), mask_ok);
	if (result.ret != -1 || result.err != EINTR || result.ready ||
	    sigusr1_count != before_handler + 1 || !mask_ok)
		fail("signal", api, "unexpected_terminal_result", failures);
	waitpid(child, NULL, 0);
	close(pipefd[0]);
	close(pipefd[1]);
}

static int pin_to_cpu_zero(void)
{
	cpu_set_t cpus;

	CPU_ZERO(&cpus);
	CPU_SET(0, &cpus);
	return sched_setaffinity(0, sizeof(cpus), &cpus);
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

static int set_fifo_max(void)
{
	struct sched_param param = { 0 };
	int maximum = sched_get_priority_max(SCHED_FIFO);

	if (maximum < 1)
		return -1;
	param.sched_priority = maximum - 1;
	return sched_setscheduler(0, SCHED_FIFO, &param);
}

static void restore_scheduler(void)
{
	struct sched_param param = { 0 };

	(void)sched_setscheduler(0, SCHED_OTHER, &param);
}

static void run_priority_case(enum api_kind api, const sigset_t *temporary,
			      int *failures)
{
	const int timeout_ms = 200;
	int data_pipe[2];
	int ready_pipe[2];
	int go_pipe[2];
	int timestamp_pipe[2];
	pid_t child;
	char token;
	struct timespec started;
	struct timespec deadline;
	struct timespec wrote_at;
	struct timespec returned_at;
	struct api_result result;
	struct api_result probe;
	int mask_ok;
	int pre_deadline;
	int returned_late;
	int child_status;

	if (pipe(data_pipe) < 0 || pipe(ready_pipe) < 0 || pipe(go_pipe) < 0 ||
	    pipe(timestamp_pipe) < 0) {
		fail("priority", api, "pipe", failures);
		return;
	}
	if (pin_to_cpu_zero() < 0) {
		printf("CR5_PRIORITY_SKIP api=%s errno=%d reason=affinity_unavailable\n",
		       api_name(api), errno);
		goto out;
	}
	child = fork();
	if (child < 0) {
		fail("priority", api, "fork", failures);
		goto out;
	}
	if (child == 0) {
		if (pin_to_cpu_zero() < 0 || write_exact(ready_pipe[1], "r", 1) < 0 ||
		    read_exact(go_pipe[0], &token, 1) < 0) {
			_exit(2);
		}
		/* Let the parent install its poller before this child becomes FIFO. */
		sleep_ms(30);
		if (set_fifo_max() < 0) {
			printf("CR5_PRIORITY_SKIP api=%s errno=%d reason=sched_fifo_unavailable\n",
			       api_name(api), errno);
			_exit(77);
		}
		clock_gettime(CLOCK_MONOTONIC, &wrote_at);
		if (write_exact(timestamp_pipe[1], &wrote_at, sizeof(wrote_at)) < 0 ||
		    write_exact(data_pipe[1], "r", 1) < 0) {
			restore_scheduler();
			_exit(3);
		}
		/* Keep the woken lower-priority waiter off this CPU past its deadline. */
		busy_for_ms(350);
		restore_scheduler();
		_exit(0);
	}
	if (read_exact(ready_pipe[0], &token, 1) < 0) {
		fail("priority", api, "child_not_ready", failures);
		waitpid(child, NULL, 0);
		goto out;
	}
	clock_gettime(CLOCK_MONOTONIC, &started);
	add_ms(started, timeout_ms, &deadline);
	if (write_exact(go_pipe[1], "g", 1) < 0) {
		fail("priority", api, "start_child", failures);
		waitpid(child, NULL, 0);
		goto out;
	}
	result = wait_once(api, data_pipe[0], timeout_ms, temporary);
	clock_gettime(CLOCK_MONOTONIC, &returned_at);
	waitpid(child, &child_status, 0);
	if (WIFEXITED(child_status) && WEXITSTATUS(child_status) == 77) {
		printf("CR5_PRIORITY_SKIP api=%s errno=%d reason=sched_fifo_unavailable\n",
		       api_name(api), EPERM);
		goto out;
	}
	if (!WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0) {
		fail("priority", api, "priority_child", failures);
		goto out;
	}
	if (read_exact(timestamp_pipe[0], &wrote_at, sizeof(wrote_at)) < 0) {
		fail("priority", api, "missing_write_timestamp", failures);
		goto out;
	}
	mask_ok = mask_blocks_sigusr1();
	probe = wait_once(api, data_pipe[0], 0, temporary);
	pre_deadline = before(wrote_at, deadline);
	returned_late = elapsed_ms(started, returned_at) > timeout_ms + 100;
	printf("CR5_PRIORITY api=%s ret=%d errno=%d ready=%d post_ret=%d post_errno=%d "
	       "post_ready=%d before_deadline=%d returned_after_deadline=%d elapsed_ms=%ld "
	       "mask_blocked=%d\n",
	       api_name(api), result.ret, result.err, result.ready, probe.ret, probe.err,
	       probe.ready, pre_deadline, returned_late, elapsed_ms(started, returned_at),
	       mask_ok);
	if (result.ret == 0 && !result.ready && pre_deadline && probe.ret == 1 &&
	    probe.ready && returned_late && mask_ok) {
		printf("CR5_ANOMALY api=%s timeout_bypassed_priority_deferred_readiness\n",
		       api_name(api));
		(*failures)++;
	} else if (result.ret != 1 || !result.ready || !mask_ok) {
		fail("priority", api, "unexpected_terminal_result", failures);
	}

out:
	close(data_pipe[0]);
	close(data_pipe[1]);
	close(ready_pipe[0]);
	close(ready_pipe[1]);
	close(go_pipe[0]);
	close(go_pipe[1]);
	close(timestamp_pipe[0]);
	close(timestamp_pipe[1]);
}

int main(void)
{
	const enum api_kind apis[] = {
		API_EPOLL_WAIT,
		API_EPOLL_PWAIT,
		API_PPOLL,
		API_PSELECT6,
	};
	sigset_t blocked;
	sigset_t temporary;
	int failures = 0;
	unsigned int i;

	setvbuf(stdout, NULL, _IONBF, 0);
	if (install_handler() < 0 || block_sigusr1(&blocked, &temporary) < 0) {
		perror("CR5 setup");
		return EXIT_FAILURE;
	}

	printf("CR5_LEVEL0 timeout controls begin\n");
	for (i = 0; i < sizeof(apis) / sizeof(apis[0]); i++) {
		run_timeout_control(apis[i], &temporary, &failures);
		(void)sigprocmask(SIG_SETMASK, &blocked, NULL);
	}

	printf("CR5_LEVEL0 readiness controls begin\n");
	for (i = 0; i < sizeof(apis) / sizeof(apis[0]); i++) {
		run_ready_control(apis[i], &temporary, &failures);
		(void)sigprocmask(SIG_SETMASK, &blocked, NULL);
	}

	printf("CR5_LEVEL0 signal controls begin\n");
	for (i = 0; i < sizeof(apis) / sizeof(apis[0]); i++) {
		run_signal_control(apis[i], &temporary, &failures);
		(void)sigprocmask(SIG_SETMASK, &blocked, NULL);
	}

	printf("CR5_LEVEL1 priority-deferred timeout arbitration begin\n");
	for (i = 0; i < sizeof(apis) / sizeof(apis[0]); i++) {
		run_priority_case(apis[i], &temporary, &failures);
		(void)sigprocmask(SIG_SETMASK, &blocked, NULL);
	}

	printf("CR5_RESULT %s failures=%d\n", failures == 0 ? "PASS" : "FAIL", failures);
	return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
