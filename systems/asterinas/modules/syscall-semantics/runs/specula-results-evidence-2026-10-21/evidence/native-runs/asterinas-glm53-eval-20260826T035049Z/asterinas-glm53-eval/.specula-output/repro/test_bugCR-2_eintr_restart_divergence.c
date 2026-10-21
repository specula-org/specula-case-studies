// SPDX-License-Identifier: MPL-2.0
//
// CR-2 reproduction: readv/writev (and pread64/pwrite64) lack the
// EINTR-to-ERESTARTSYS restart translation that read/write have.
//
// Contract under test (Linux-visible behavior, signal(7) + readv(2)):
//   - read()/readv() on an empty pipe, interrupted by a signal whose handler
//     was installed with SA_RESTART, is transparently RESTARTED by the
//     kernel: it returns the data once it arrives, never EINTR.
//   - write()/writev() on a full pipe, same scenario: restarted, returns
//     once the reader drains, never EINTR.
//   - pread64/pwrite64 on regular files never block interruptibly on the
//     local file systems (no EINTR producer exists), so their missing
//     translation is latent; this test only sanity-checks that positional
//     I/O itself works.
//
// Escalation level: 0 (pure black-box public syscalls: pipe, fcntl, fork,
// kill, sigaction-SA_RESTART, read/readv/write/writev/pread64 via raw
// syscall()). The child's sleep(1) calls only order the events; no state
// injection, no source modification, no mocks.
//
// Same binary runs on Linux (control) and in the Asterinas guest.
// Prints "CR2_REPRO_DONE" at the end. CR2_RESULT: PASS = Linux contract
// holds; FAIL = the divergence (raw EINTR despite SA_RESTART) was observed.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t g_signal_count;

static void sigusr1_handler(int signo)
{
	(void)signo;
	g_signal_count++;
}

static long raw_read(int fd, void *buf, size_t n)
{
	return syscall(SYS_read, fd, buf, n);
}

static long raw_write(int fd, const void *buf, size_t n)
{
	return syscall(SYS_write, fd, buf, n);
}

static long raw_readv(int fd, struct iovec *iov, int cnt)
{
	return syscall(SYS_readv, fd, iov, cnt);
}

static long raw_writev(int fd, struct iovec *iov, int cnt)
{
	return syscall(SYS_writev, fd, iov, cnt);
}

static long raw_pread64(int fd, void *buf, size_t n, off_t off)
{
	return syscall(SYS_pread64, fd, buf, n, off);
}

static int total_checks;
static int failed_checks;

/* Expectation: with SA_RESTART the call must NOT fail with EINTR; it must
 * complete with the byte after the helper supplies/drains it. */
static void check_restart(const char *what, long ret, int err,
			  sig_atomic_t sig_before)
{
	int ok = (ret == 1) && (g_signal_count > sig_before);

	total_checks++;
	if (!ok)
		failed_checks++;

	if (ok) {
		printf("CR2 %3d %-52s: PASS (ret=%ld signals=%d)\n",
		       total_checks, what, ret, (int)(g_signal_count - sig_before));
	} else {
		printf("CR2 %3d %-52s: FAIL (ret=%ld errno=%d (%s) signals=%d)\n",
		       total_checks, what, ret, err, strerror(err),
		       (int)(g_signal_count - sig_before));
	}
}

/* Child: sleep 1s (parent blocks in its syscall), signal the parent,
 * sleep another second, then perform the follow-up action. */
static void child_signal_then(int parent_pid, void (*action)(int), int fd)
{
	sleep(1);
	if (kill(parent_pid, SIGUSR1) < 0)
		_exit(3);
	sleep(1);
	if (action)
		action(fd);
	_exit(0);
}

static void action_write_byte(int fd)
{
	ssize_t n = write(fd, "A", 1);
	(void)n;
}

static void action_drain_pipe(int fd)
{
	/* Drain everything currently buffered; the reader end is the
	 * child's fd. Set it non-blocking so the drain terminates. */
	int flags = fcntl(fd, F_GETFL);
	if (flags >= 0)
		(void)!fcntl(fd, F_SETFL, flags | O_NONBLOCK);
	static char sink[65536];
	for (;;) {
		ssize_t n = read(fd, sink, sizeof(sink));
		if (n <= 0)
			break;
	}
}

static void reap(pid_t pid)
{
	int status = 0;
	pid_t r = waitpid(pid, &status, 0);
	(void)r;
	if (!(WIFEXITED(status) && WEXITSTATUS(status) == 0))
		printf("CR2 note: helper child status=0x%x\n", status);
}

/* ---- Tests on the READ side (empty pipe) ---- */

static void test_read_empty_pipe(void)
{
	int fds[2];
	char byte = 0;
	if (pipe(fds) < 0) {
		printf("CR2 pipe() failed errno=%d\n", errno);
		failed_checks++;
		return;
	}
	pid_t parent = getpid();
	pid_t child = fork();
	if (child == 0) {
		close(fds[0]);
		child_signal_then(parent, action_write_byte, fds[1]);
	}
	close(fds[1]);
	sig_atomic_t before = g_signal_count;
	long ret = raw_read(fds[0], &byte, 1);
	int err = errno;
	check_restart("read()  empty pipe restarted (control)", ret, err, before);
	reap(child);
	close(fds[0]);
}

static void test_readv_empty_pipe(void)
{
	int fds[2];
	char byte = 0;
	if (pipe(fds) < 0) {
		printf("CR2 pipe() failed errno=%d\n", errno);
		failed_checks++;
		return;
	}
	pid_t parent = getpid();
	pid_t child = fork();
	if (child == 0) {
		close(fds[0]);
		child_signal_then(parent, action_write_byte, fds[1]);
	}
	close(fds[1]);
	struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
	sig_atomic_t before = g_signal_count;
	long ret = raw_readv(fds[0], &iov, 1);
	int err = errno;
	check_restart("readv() empty pipe must restart (SA_RESTART)", ret, err, before);
	reap(child);
	close(fds[0]);
}

/* ---- Tests on the WRITE side (full pipe) ---- */

/* Fill the pipe via non-blocking writes until EAGAIN, then restore
 * blocking mode on the write end. Returns 0 on success. */
static int fill_pipe(int wfd)
{
	if (fcntl(wfd, F_SETFL, O_NONBLOCK) < 0) {
		printf("CR2 note: F_SETFL O_NONBLOCK on pipe failed errno=%d (%s)\n",
		       errno, strerror(errno));
		return -1;
	}
	static char chunk[4096];
	memset(chunk, 'F', sizeof(chunk));
	for (;;) {
		ssize_t n = write(wfd, chunk, sizeof(chunk));
		if (n < 0) {
			if (errno == EAGAIN)
				break;
			printf("CR2 note: pipe fill write errno=%d\n", errno);
			return -1;
		}
	}
	if (fcntl(wfd, F_SETFL, 0) < 0) {
		printf("CR2 note: F_SETFL blocking on pipe failed errno=%d (%s)\n",
		       errno, strerror(errno));
		return -1;
	}
	return 0;
}

static void test_write_full_pipe(void)
{
	int fds[2];
	if (pipe(fds) < 0) {
		printf("CR2 pipe() failed errno=%d\n", errno);
		failed_checks++;
		return;
	}
	if (fill_pipe(fds[1]) < 0) {
		total_checks++;
		failed_checks++;
		printf("CR2 %3d %-52s: FAIL (could not fill pipe)\n", total_checks,
		       "write()  full pipe restarted (control)");
		close(fds[0]);
		close(fds[1]);
		return;
	}
	pid_t parent = getpid();
	pid_t child = fork();
	if (child == 0) {
		close(fds[1]);
		child_signal_then(parent, action_drain_pipe, fds[0]);
	}
	char byte = 'B';
	sig_atomic_t before = g_signal_count;
	long ret = raw_write(fds[1], &byte, 1);
	int err = errno;
	check_restart("write()  full pipe restarted (control)", ret, err, before);
	reap(child);
	close(fds[0]);
	close(fds[1]);
}

static void test_writev_full_pipe(void)
{
	int fds[2];
	if (pipe(fds) < 0) {
		printf("CR2 pipe() failed errno=%d\n", errno);
		failed_checks++;
		return;
	}
	if (fill_pipe(fds[1]) < 0) {
		total_checks++;
		failed_checks++;
		printf("CR2 %3d %-52s: FAIL (could not fill pipe)\n", total_checks,
		       "writev() full pipe must restart (SA_RESTART)");
		close(fds[0]);
		close(fds[1]);
		return;
	}
	pid_t parent = getpid();
	pid_t child = fork();
	if (child == 0) {
		close(fds[1]);
		child_signal_then(parent, action_drain_pipe, fds[0]);
	}
	char byte = 'B';
	struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
	sig_atomic_t before = g_signal_count;
	long ret = raw_writev(fds[1], &iov, 1);
	int err = errno;
	check_restart("writev() full pipe must restart (SA_RESTART)", ret, err, before);
	reap(child);
	close(fds[0]);
	close(fds[1]);
}

/* ---- Positional I/O sanity + latency note ---- */

static void test_pread64_sanity(void)
{
	const char *path = "/tmp/cr2_pread_sanity.bin";
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) {
		printf("CR2 open(%s) failed errno=%d\n", path, errno);
		failed_checks++;
		return;
	}
	ssize_t w = write(fd, "cr2data", 7);
	(void)w;
	char buf[8] = { 0 };
	long ret = raw_pread64(fd, buf, 7, 0);
	total_checks++;
	int ok = (ret == 7) && (memcmp(buf, "cr2data", 7) == 0);
	if (!ok)
		failed_checks++;
	printf("CR2 %3d %-52s: %s (ret=%ld)\n", total_checks,
	       "pread64() works on regular file (sanity)", ok ? "PASS" : "FAIL", ret);
	close(fd);
	unlink(path);
	printf("CR2 info: local regular files have no interruptible wait in their\n"
	       "CR2 info: read/write paths, so pread64/pwrite64 cannot receive EINTR\n"
	       "CR2 info: today; their missing translation is latent (no live trigger).\n");
}

int main(void)
{
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = sigusr1_handler;
	action.sa_flags = SA_RESTART;
	if (sigemptyset(&action.sa_mask) < 0 || sigaction(SIGUSR1, &action, NULL) < 0) {
		printf("CR2 sigaction failed errno=%d\n", errno);
		printf("CR2_REPRO_DONE\n");
		return 1;
	}

	test_read_empty_pipe();   /* control: translated path restarts */
	test_readv_empty_pipe();  /* bug candidate 1 */
	test_write_full_pipe();   /* control: translated path restarts */
	test_writev_full_pipe();  /* bug candidate 2 */
	test_pread64_sanity();    /* positional sanity + latency note */

	printf("CR2_RESULT: %s (%d checks, %d failed)\n",
	       failed_checks ? "FAIL" : "PASS", total_checks, failed_checks);
	printf("CR2_REPRO_DONE\n");
	return 0;
}
