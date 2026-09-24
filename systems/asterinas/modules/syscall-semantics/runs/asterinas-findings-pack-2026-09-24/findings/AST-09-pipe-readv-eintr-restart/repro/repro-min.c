// Blocking read/readv on an empty pipe and write/writev on a full pipe,
// interrupted by SIGUSR1 whose handler was installed with SA_RESTART.
// Linux restarts all four; Asterinas returns EINTR from readv and writev.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t signals;
static char byte;
static char chunk[4096];

static void handler(int sig)
{
	(void)sig;
	signals++;
}

static ssize_t do_read(int fd)
{
	return read(fd, &byte, 1);
}

static ssize_t do_readv(int fd)
{
	struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
	return readv(fd, &iov, 1);
}

static ssize_t do_write(int fd)
{
	return write(fd, &byte, 1);
}

static ssize_t do_writev(int fd)
{
	struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
	return writev(fd, &iov, 1);
}

// Blocks in `op` on a pipe; the child sends SIGUSR1 after 1 s and lets
// the pipe make progress 1 s later.
static void run(const char *name, int on_full_pipe, ssize_t (*op)(int))
{
	int fds[2];
	pipe(fds);
	if (on_full_pipe) {
		fcntl(fds[1], F_SETFL, O_NONBLOCK);
		while (write(fds[1], chunk, sizeof(chunk)) > 0)
			;
		fcntl(fds[1], F_SETFL, 0);
	}

	signals = 0;
	pid_t parent = getpid();
	pid_t child = fork();
	if (child == 0) {
		sleep(1);
		kill(parent, SIGUSR1);
		sleep(1);
		if (on_full_pipe) {
			fcntl(fds[0], F_SETFL, O_NONBLOCK);
			while (read(fds[0], chunk, sizeof(chunk)) > 0)
				;
		} else {
			write(fds[1], "a", 1);
		}
		_exit(0);
	}

	errno = 0;
	ssize_t ret = op(on_full_pipe ? fds[1] : fds[0]);
	printf("%-7s ret=%zd errno=%d%s%s signals=%d: %s\n", name, ret, errno,
	       ret < 0 ? " " : "", ret < 0 ? strerror(errno) : "",
	       (int)signals, ret == 1 ? "restarted" : "NOT restarted");

	waitpid(child, NULL, 0);
	close(fds[0]);
	close(fds[1]);
}

int main(void)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = handler;
	sa.sa_flags = SA_RESTART;
	sigaction(SIGUSR1, &sa, NULL);

	run("read", 0, do_read);
	run("readv", 0, do_readv);
	run("write", 1, do_write);
	run("writev", 1, do_writev);
	return 0;
}
