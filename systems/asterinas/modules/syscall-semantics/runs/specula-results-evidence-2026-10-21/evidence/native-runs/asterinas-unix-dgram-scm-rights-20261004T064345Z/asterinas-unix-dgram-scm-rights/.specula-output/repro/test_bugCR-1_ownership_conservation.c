// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding CR-1:
//   "Captured object ownership survives descriptor reuse and release"
//
// The finding hypothesizes an ownership-accounting break in the AF_UNIX
// SOCK_DGRAM SCM_RIGHTS pipeline: a captured file reference either vanishes
// (premature drop -> freed object behind a delivered fd) or gains an
// unexplained owner (leak -> object never released) across capture, enqueue
// move, PEEK clone, ordinary-receive move, installation clone, temporary
// release, FD removal/drop, or final queue disposal.
//
// This is a Level 0 black-box test: public APIs only (socketpair, open,
// sendmsg, recvmsg, close, pipe2, fstat, read, lseek, fork). No fault
// injection, no private debug interfaces, no timing tricks.
//
// Each case fixes the expected (correct) outcome from the Linux control run
// of this same binary. Observable failure modes for the hypothesized defect:
//   - wrong object behind a delivered fd (fstat st_dev/st_ino or content
//     mismatch), or a dead object (read/fstat failure, garbage, panic);
//   - a leaked owner showing up as a pipe read end that never sees EOF
//     (EAGAIN forever instead of read()==0 after every writer fd is gone);
//   - kernel panic/hang during queue disposal or sender-table drop.
//
// Output protocol (parsed by the runner):
//   CR1_CASE <n> <name> PASS|FAIL <detail>
//   CR1_DONE <fail_count>
// As PID 1 in the Asterinas initramfs the binary powers the machine off at
// the end; on Linux it just exits with the failure count.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <pthread.h>
#include <unistd.h>

static int failures;
static int verbose;

static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
}

static void case_result(int id, const char *name, int ok, const char *detail)
{
	if (!ok)
		failures++;
	say("CR1_CASE %d %s %s %s", id, name, ok ? "PASS" : "FAIL",
	    detail ? detail : "");
}

// Returns fd, or -1 with the reason reported.
static int xopen(const char *path, int flags, int id, const char *name)
{
	int fd = open(path, flags, 0600);
	if (fd < 0)
		case_result(id, name, 0, "open failed");
	return fd;
}

// Writes `len` bytes of `data` to `path` through a private fd.
static int write_file(const char *path, const void *data, size_t len)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return -1;
	ssize_t n = write(fd, data, len);
	int err = errno;
	close(fd);
	if (n != (ssize_t)len) {
		errno = n < 0 ? err : EIO;
		return -1;
	}
	return 0;
}

// Send `nfds` descriptors over `sock` with a short payload.
static int send_rights(int sock, const int *fds, int nfds, const void *data,
		       size_t len)
{
	char buf[CMSG_SPACE(sizeof(int) * 8)];
	memset(buf, 0, sizeof(buf));

	struct iovec iov = { (void *)data, len };
	struct msghdr msg;
	memset(&msg, 0, sizeof(msg));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = buf;
	msg.msg_controllen = CMSG_SPACE(sizeof(int) * nfds);

	struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
	cmsg->cmsg_level = SOL_SOCKET;
	cmsg->cmsg_type = SCM_RIGHTS;
	cmsg->cmsg_len = CMSG_LEN(sizeof(int) * nfds);
	memcpy(CMSG_DATA(cmsg), fds, sizeof(int) * nfds);

	ssize_t r = sendmsg(sock, &msg, 0);
	if (r < 0)
		return -1;
	return (int)r;
}

// Receive one message; returns payload length (>=0) and fills fds[] (up to
// max), *got_fds, and *flags_out. Returns -1 on error (errno preserved).
static int recv_rights(int sock, int *fds, int max, int *got_fds,
		       void *data, size_t len, int *flags_out, int peek)
{
	char buf[CMSG_SPACE(sizeof(int) * 8)];
	memset(buf, 0, sizeof(buf));

	struct iovec iov = { data, len };
	struct msghdr msg;
	memset(&msg, 0, sizeof(msg));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = buf;
	msg.msg_controllen = sizeof(buf);

	ssize_t r = recvmsg(sock, &msg, peek ? MSG_PEEK : 0);
	if (r < 0)
		return -1;
	if (flags_out)
		*flags_out = msg.msg_flags;
	*got_fds = 0;
	for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
		if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
			size_t bytes = c->cmsg_len - CMSG_LEN(0);
			size_t count = bytes / sizeof(int);
			for (size_t i = 0; i < count && *got_fds < max; i++)
				memcpy(&fds[(*got_fds)++],
				       (char *)CMSG_DATA(c) + i * sizeof(int),
				       sizeof(int));
		}
	}
	return (int)r;
}

// The leak probe: with every writer of `rfd` gone, a nonblocking read must
// return 0 (EOF). EAGAIN means some owner still holds the write end.
static int pipe_eof_seen(int rfd)
{
	char c;
	for (int spin = 0; spin < 3; spin++) {
		ssize_t r = read(rfd, &c, 1);
		if (r == 0)
			return 1;
		if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
			return 0;
		usleep(20000); // tolerate asynchronous release
	}
	return 0;
}

struct id {
	dev_t dev;
	ino_t ino;
};

static int same_file(int fd, const struct id *want)
{
	struct stat st;
	if (fstat(fd, &st) < 0)
		return 0;
	return st.st_dev == want->dev && st.st_ino == want->ino;
}

static int file_id(int fd, struct id *out)
{
	struct stat st;
	if (fstat(fd, &st) < 0)
		return -1;
	out->dev = st.st_dev;
	out->ino = st.st_ino;
	return 0;
}

// Reads the whole file from offset 0 and compares with `expect`.
static int content_matches(int fd, const char *expect, size_t len)
{
	char got[256];
	if (lseek(fd, 0, SEEK_SET) < 0)
		return 0;
	size_t done = 0;
	while (done < len) {
		ssize_t r = read(fd, got + done, len - done);
		if (r <= 0)
			return 0;
		done += (size_t)r;
	}
	return memcmp(got, expect, len) == 0;
}

static const char *F1_TEXT = "CR1-file-one-payload";
static const char *F2_TEXT = "CR1-file-two-payload";

static void setup_pid1(void)
{
	if (getpid() != 1)
		return;
	mkdir("/dev", 0755);
	mkdir("/tmp", 0755);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	int fd = open("/dev/console", O_RDWR);
	if (fd >= 0) {
		for (int i = 0; i < 3; ++i)
			dup2(fd, i);
		if (fd > 2)
			close(fd);
	}
	setvbuf(stdout, NULL, _IONBF, 0);
}

// Case 1: capture survives sender close. The delivered fd must name the
// captured file object (identity + content), not a freed or recycled one.
static void case1(void)
{
	const int id = 1;
	const char *name = "send-close-recv-identity";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	if (write_file("/tmp/cr1_f1", F1_TEXT, strlen(F1_TEXT)) < 0) {
		case_result(id, name, 0, "write /tmp/cr1_f1 failed");
		return;
	}
	int a = xopen("/tmp/cr1_f1", O_RDONLY, id, name);
	if (a < 0)
		return;
	struct id want;
	if (file_id(a, &want) < 0) {
		case_result(id, name, 0, "fstat sender fd failed");
		close(a);
		return;
	}
	if (send_rights(sv[0], &a, 1, "one", 3) < 0) {
		case_result(id, name, 0, "sendmsg failed");
		close(a);
		return;
	}
	close(a); // sender drops its reference while the message is queued

	int fds[8], got = 0, fl = 0;
	char payload[32];
	int r = recv_rights(sv[1], fds, 8, &got, payload, sizeof(payload), &fl, 0);
	int ok = r == 3 && got == 1 && fds[0] >= 0 &&
		 same_file(fds[0], &want) &&
		 content_matches(fds[0], F1_TEXT, strlen(F1_TEXT));
	char detail[128];
	if (ok) {
		snprintf(detail, sizeof(detail), "delivered fd %d names sender file",
			 fds[0]);
	} else {
		snprintf(detail, sizeof(detail),
			 "recv r=%d errno=%d got=%d identity_or_content=%d", r,
			 errno, got,
			 got >= 1 ? (int)same_file(fds[0], &want) : -1);
	}
	if (got >= 1)
		close(fds[0]);
	close(sv[0]);
	close(sv[1]);
	case_result(id, name, ok, detail);
}

// Case 2: descriptor-number reuse after send. The sender's old number is
// forced onto a different file with dup2 before the receive; the delivered
// fd must still name the originally captured object.
static void case2(void)
{
	const int id = 2;
	const char *name = "fd-number-reuse-after-send";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	if (write_file("/tmp/cr1_f1", F1_TEXT, strlen(F1_TEXT)) < 0 ||
	    write_file("/tmp/cr1_f2", F2_TEXT, strlen(F2_TEXT)) < 0) {
		case_result(id, name, 0, "write fixtures failed");
		return;
	}
	int a = xopen("/tmp/cr1_f1", O_RDONLY, id, name);
	if (a < 0)
		return;
	struct id want, other;
	file_id(a, &want);
	if (send_rights(sv[0], &a, 1, "two", 3) < 0) {
		case_result(id, name, 0, "sendmsg failed");
		close(a);
		return;
	}
	close(a);

	// Put a different object behind the sender's old number.
	int b = open("/tmp/cr1_f2", O_RDONLY);
	if (b < 0) {
		case_result(id, name, 0, "reuse setup failed");
		return;
	}
	if (b != a) {
		if (dup2(b, a) < 0) {
			case_result(id, name, 0, "dup2 failed");
			close(b);
			return;
		}
		close(b);
	}
	if (file_id(a, &other) < 0 || other.ino == want.ino) {
		case_result(id, name, 0, "reuse setup: number does not name a different file");
		close(a);
		return;
	}

	int fds[8], got = 0, fl = 0;
	char payload[32];
	int r = recv_rights(sv[1], fds, 8, &got, payload, sizeof(payload), &fl, 0);
	int ok = r == 3 && got == 1 && same_file(fds[0], &want) &&
		 !same_file(fds[0], &other) &&
		 content_matches(fds[0], F1_TEXT, strlen(F1_TEXT));
	char detail[160];
	if (ok) {
		snprintf(detail, sizeof(detail),
			 "delivered fd names captured file, not reused number %d", a);
	} else {
		struct stat st;
		ino_t got_ino = got >= 1 && fstat(fds[0], &st) == 0 ? st.st_ino : 0;
		snprintf(detail, sizeof(detail),
			 "recv r=%d errno=%d got=%d delivered_ino=%llu want_ino=%llu",
			 r, errno, got, (unsigned long long)got_ino,
			 (unsigned long long)want.ino);
	}
	if (got >= 1)
		close(fds[0]);
	close(a);
	close(sv[0]);
	close(sv[1]);
	case_result(id, name, ok, detail);
}

// Case 3: PEEK clones the queued references without consuming the message;
// a later ordinary receive delivers the same object exactly once more.
static void case3(void)
{
	const int id = 3;
	const char *name = "peek-clone-then-recv";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	int a = xopen("/tmp/cr1_f1", O_RDONLY, id, name);
	if (a < 0)
		return;
	struct id want;
	file_id(a, &want);
	if (send_rights(sv[0], &a, 1, "thr", 3) < 0) {
		case_result(id, name, 0, "sendmsg failed");
		close(a);
		return;
	}
	close(a);

	int fds[8], got = 0, fl = 0;
	char payload[32];
	// PEEK: message must stay in the queue.
	int r1 = recv_rights(sv[1], fds, 8, &got, payload, sizeof(payload), &fl, 1);
	int peek_ok = r1 == 3 && got == 1 && same_file(fds[0], &want);
	int peek_fd = got >= 1 ? fds[0] : -1;

	int fds2[8], got2 = 0, fl2 = 0;
	int r2 = recv_rights(sv[1], fds2, 8, &got2, payload, sizeof(payload), &fl2, 0);
	int recv_ok = r2 == 3 && got2 == 1 && same_file(fds2[0], &want) &&
		      content_matches(fds2[0], F1_TEXT, strlen(F1_TEXT));

	// Message consumed exactly once: next receive is EAGAIN.
	errno = 0;
	int r3 = recv_rights(sv[1], fds, 8, &got, payload, sizeof(payload), NULL, 0);
	int drained = r3 < 0 && (errno == EAGAIN || errno == EWOULDBLOCK);

	int ok = peek_ok && recv_ok && drained;
	char detail[192];
	if (ok) {
		snprintf(detail, sizeof(detail),
			 "peek fd %d and recv fd %d both name captured file; queue empty after",
			 peek_fd, fds2[0]);
	} else {
		snprintf(detail, sizeof(detail),
			 "peek r=%d got=%d ok=%d; recv r=%d got=%d ok=%d; drain r=%d errno=%d",
			 r1, got, peek_ok, r2, got2, recv_ok, r3, errno);
	}
	if (peek_fd >= 0)
		close(peek_fd);
	if (got2 >= 1)
		close(fds2[0]);
	close(sv[0]);
	close(sv[1]);
	case_result(id, name, ok, detail);
}

// Case 4: multiple and duplicated descriptors in one message; each entry
// must be delivered as its own reference to the right object.
static void case4(void)
{
	const int id = 4;
	const char *name = "duplicate-fds-one-message";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	int b1 = xopen("/tmp/cr1_f1", O_RDONLY, id, name);
	int b2 = xopen("/tmp/cr1_f2", O_RDONLY, id, name);
	if (b1 < 0 || b2 < 0)
		return;
	struct id id1, id2;
	file_id(b1, &id1);
	file_id(b2, &id2);
	int sent[3] = { b1, b2, b1 };
	if (send_rights(sv[0], sent, 3, "dup", 3) < 0) {
		case_result(id, name, 0, "sendmsg failed");
		close(b1);
		close(b2);
		return;
	}
	close(b1);
	close(b2);

	int fds[8], got = 0, fl = 0;
	char payload[32];
	int r = recv_rights(sv[1], fds, 8, &got, payload, sizeof(payload), &fl, 0);
	int ok = r == 3 && got == 3 && same_file(fds[0], &id1) &&
		 same_file(fds[1], &id2) && same_file(fds[2], &id1);
	char detail[128];
	snprintf(detail, sizeof(detail), "recv r=%d got=%d mapping_ok=%d", r, got,
		 ok);
	for (int i = 0; i < got; i++)
		close(fds[i]);
	close(sv[0]);
	close(sv[1]);
	case_result(id, name, ok, detail);
}

// Case 5: queue disposal releases queued references. The pipe write end is
// passed and never received; closing the receiving socket must drop the
// queued reference, so the read end must see EOF.
static void case5(void)
{
	const int id = 5;
	const char *name = "disposal-releases-queued-ref";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	int p[2];
	if (pipe2(p, O_NONBLOCK) < 0) {
		case_result(id, name, 0, "pipe2 failed");
		return;
	}
	if (send_rights(sv[0], &p[1], 1, "dsp", 3) < 0) {
		case_result(id, name, 0, "sendmsg failed");
		close(p[0]);
		close(p[1]);
		return;
	}
	close(p[1]);     // sender reference gone; only the queue holds one
	close(sv[1]);    // queue disposal without receiving
	close(sv[0]);

	int ok = pipe_eof_seen(p[0]);
	close(p[0]);
	case_result(id, name, ok,
		    ok ? "read end saw EOF after queue disposal"
		       : "read end never saw EOF: queued reference leaked");
}

// Case 6: full receive cycle releases the temporary reference. The delivered
// fd is closed by the receiver; after that no owner may remain.
static void case6(void)
{
	const int id = 6;
	const char *name = "recv-cycle-releases-ref";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	int p[2];
	if (pipe2(p, O_NONBLOCK) < 0) {
		case_result(id, name, 0, "pipe2 failed");
		return;
	}
	if (send_rights(sv[0], &p[1], 1, "cyc", 3) < 0) {
		case_result(id, name, 0, "sendmsg failed");
		close(p[0]);
		close(p[1]);
		return;
	}
	close(p[1]);
	int fds[8], got = 0, fl = 0;
	char payload[32];
	int r = recv_rights(sv[1], fds, 8, &got, payload, sizeof(payload), &fl, 0);
	int ok = r == 3 && got == 1;
	if (ok) {
		close(fds[0]); // the last owner of the write end
		ok = pipe_eof_seen(p[0]);
	}
	char detail[128];
	snprintf(detail, sizeof(detail), "recv r=%d got=%d eof=%d", r, got, ok);
	close(p[0]);
	close(sv[0]);
	close(sv[1]);
	case_result(id, name, ok, detail);
}

// Case 7: disposing a queue that holds regular-file messages keeps the
// kernel alive and serving later requests.
static void case7(void)
{
	const int id = 7;
	const char *name = "disposal-liveness";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	int a = xopen("/tmp/cr1_f1", O_RDONLY, id, name);
	if (a < 0)
		return;
	for (int i = 0; i < 8; i++) {
		if (send_rights(sv[0], &a, 1, "lv", 2) < 0) {
			case_result(id, name, 0, "sendmsg in fill loop failed");
			close(a);
			return;
		}
	}
	close(a);
	close(sv[1]); // dispose eight queued references at once
	close(sv[0]);

	// Liveness: a fresh round trip still delivers the right object.
	int sv2[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv2) < 0) {
		case_result(id, name, 0, "second socketpair failed");
		return;
	}
	int b = open("/tmp/cr1_f1", O_RDONLY);
	if (b < 0) {
		case_result(id, name, 0, "reopen failed");
		close(sv2[0]);
		close(sv2[1]);
		return;
	}
	struct id want;
	file_id(b, &want);
	int ok = send_rights(sv2[0], &b, 1, "ag", 2) == 2;
	close(b);
	int fds[8], got = 0, fl = 0;
	char payload[32];
	int r = recv_rights(sv2[1], fds, 8, &got, payload, sizeof(payload), &fl, 0);
	ok = ok && r == 2 && got == 1 && same_file(fds[0], &want);
	if (got >= 1)
		close(fds[0]);
	close(sv2[0]);
	close(sv2[1]);
	case_result(id, name, ok,
		    ok ? "kernel alive and correct after disposal"
		       : "round trip after disposal broken");
}

// Case 8: capture and installation in different file tables (separate
// processes). The sender closes its fd and exits while the message is
// queued; the parent must receive an fd naming the sender's object.
static void case8(void)
{
	const int id = 8;
	const char *name = "cross-process-tables";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	const char *path = "/tmp/cr1_f3";
	const char *text = "CR1-cross-process-payload";
	if (write_file(path, text, strlen(text)) < 0) {
		case_result(id, name, 0, "write /tmp/cr1_f3 failed");
		return;
	}

	pid_t pid = fork();
	if (pid < 0) {
		case_result(id, name, 0, "fork failed");
		return;
	}
	if (pid == 0) {
		// Child: own file table entry for the object, then drop it
		// entirely by exiting while the message stays queued.
		close(sv[1]);
		int fd = open(path, O_RDONLY);
		if (fd < 0)
			_exit(42);
		struct stat st;
		if (fstat(fd, &st) < 0)
			_exit(43);
		char msg[64];
		int len = snprintf(msg, sizeof(msg), "ino=%llu",
				   (unsigned long long)st.st_ino);
		if (send_rights(sv[0], &fd, 1, msg, len + 1) < 0)
			_exit(44);
		close(fd);
		close(sv[0]);
		_exit(0);
	}
	close(sv[0]);
	int wstatus = 0;
	waitpid(pid, &wstatus, 0);
	if (!WIFEXITED(wstatus) || WEXITSTATUS(wstatus) != 0) {
		char detail[96];
		snprintf(detail, sizeof(detail), "child exited status=%d",
			 WIFEXITED(wstatus) ? WEXITSTATUS(wstatus) : -1);
		case_result(id, name, 0, detail);
		close(sv[1]);
		return;
	}

	int fds[8], got = 0, fl = 0;
	char payload[64];
	memset(payload, 0, sizeof(payload));
	int r = recv_rights(sv[1], fds, 8, &got, payload, sizeof(payload), &fl, 0);
	unsigned long long child_ino = 0;
	if (r > 0)
		sscanf(payload, "ino=%llu", &child_ino);
	struct stat st;
	int ok = r > 0 && got == 1 && fstat(fds[0], &st) == 0 &&
		 (unsigned long long)st.st_ino == child_ino &&
		 content_matches(fds[0], text, strlen(text));
	char detail[192];
	if (ok) {
		snprintf(detail, sizeof(detail),
			 "delivered fd names child's object ino=%llu after child exit",
			 child_ino);
	} else {
		unsigned long long got_ino =
			got >= 1 && fstat(fds[0], &st) == 0
				? (unsigned long long)st.st_ino
				: 0;
		snprintf(detail, sizeof(detail),
			 "r=%d errno=%d got=%d delivered_ino=%llu child_ino=%llu",
			 r, errno, got, got_ino, child_ino);
	}
	if (got >= 1)
		close(fds[0]);
	close(sv[1]);
	case_result(id, name, ok, detail);
}

// Case 9: temporary release on a failed send. Filling the queue forces an
// EAGAIN sendmsg whose captured references must be released (not kept, not
// double-dropped); draining the queue must then leave no owner.
static void case9(void)
{
	const int id = 9;
	const char *name = "eagain-temporary-release";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	int p[2];
	if (pipe2(p, O_NONBLOCK) < 0) {
		case_result(id, name, 0, "pipe2 failed");
		return;
	}
	char body[1000];
	memset(body, 'x', sizeof(body));
	int sent = 0, eagain = 0;
	for (int i = 0; i < 2000; i++) {
		if (send_rights(sv[0], &p[1], 1, body, sizeof(body)) < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				eagain = 1;
				break;
			}
			case_result(id, name, 0, "unexpected sendmsg error");
			goto out;
		}
		sent++;
	}
	if (!eagain || sent == 0) {
		char detail[96];
		snprintf(detail, sizeof(detail),
			 "queue never filled: sent=%d eagain=%d", sent, eagain);
		case_result(id, name, 0, detail);
		goto out;
	}
	close(p[1]); // sender reference gone
	p[1] = -1;

	// Drain every queued message, dropping each delivered reference.
	int drained = 0;
	for (;;) {
		int fds[8], got = 0, fl = 0;
		char payload[1100];
		int r = recv_rights(sv[1], fds, 8, &got, payload, sizeof(payload),
				    &fl, 0);
		if (r < 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK)
				goto out_fail;
			break;
		}
		for (int i = 0; i < got; i++)
			close(fds[i]);
		drained++;
	}
	{
		int ok = drained == sent && pipe_eof_seen(p[0]);
		char detail[128];
		snprintf(detail, sizeof(detail),
			 "sent=%d drained=%d eof=%d", sent, drained,
			 pipe_eof_seen(p[0]));
		close(p[0]);
		close(sv[0]);
		close(sv[1]);
		case_result(id, name, ok, detail);
		return;
	}
out_fail:
	close(p[0]);
	close(p[1]);
	close(sv[0]);
	close(sv[1]);
	case_result(id, name, 0, "drain failed");
	return;
out:
	close(p[0]);
	close(p[1]);
	close(sv[0]);
	close(sv[1]);
}

// Case 10: receive with a NULL control buffer consumes the message and must
// release the references (no fd is delivered; the pipe must reach EOF).
static void case10(void)
{
	const int id = 10;
	const char *name = "null-control-releases-refs";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	int p[2];
	if (pipe2(p, O_NONBLOCK) < 0) {
		case_result(id, name, 0, "pipe2 failed");
		return;
	}
	if (send_rights(sv[0], &p[1], 1, "nul", 3) < 0) {
		case_result(id, name, 0, "sendmsg failed");
		close(p[0]);
		close(p[1]);
		return;
	}
	close(p[1]);

	char payload[32];
	struct iovec iov = { payload, 3 };
	struct msghdr msg;
	memset(&msg, 0, sizeof(msg));
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = NULL; // no control buffer: no fds can be delivered
	msg.msg_controllen = 0;
	errno = 0;
	ssize_t r = recvmsg(sv[1], &msg, 0);
	int ok = r == 3 && (msg.msg_flags & MSG_CTRUNC);
	if (ok)
		ok = pipe_eof_seen(p[0]);
	char detail[128];
	snprintf(detail, sizeof(detail), "recv=%zd errno=%d flags=%#x eof=%d", r,
		 errno, msg.msg_flags, ok);
	close(p[0]);
	close(sv[0]);
	close(sv[1]);
	case_result(id, name, ok, detail);
}

struct race_round {
	int sock;
	int fd;
	volatile int stop;
};

// Sender thread: send the fd until told to stop or the fd is closed.
static void *race_sender(void *arg)
{
	struct race_round *r = arg;
	while (!r->stop) {
		if (send_rights(r->sock, &r->fd, 1, "rc", 2) < 0)
			break; // EBADF: the closer won this round
	}
	return NULL;
}

// Case 11: sender close racing capture. A sender thread repeatedly sends
// the same descriptor while another thread closes it. Every message that
// was successfully sent must later deliver a live fd naming the captured
// object; the losing side must simply fail with EBADF. FD close vs. use
// races are explicitly allowed by close(2), so the only observable correct
// outcomes are: delivered fd names F, or the send failed.
static void case11(void)
{
	const int id = 11;
	const char *name = "racing-close-vs-capture";
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK, 0, sv) < 0) {
		case_result(id, name, 0, "socketpair failed");
		return;
	}
	if (write_file("/tmp/cr1_f1", F1_TEXT, strlen(F1_TEXT)) < 0) {
		case_result(id, name, 0, "write fixture failed");
		return;
	}
	struct id want;
	{
		int fd = open("/tmp/cr1_f1", O_RDONLY);
		if (fd < 0 || file_id(fd, &want) < 0) {
			case_result(id, name, 0, "fixture open failed");
			if (fd >= 0)
				close(fd);
			return;
		}
		close(fd);
	}

	int rounds_ok = 1;
	for (int round = 0; round < 40 && rounds_ok; round++) {
		int a = open("/tmp/cr1_f1", O_RDONLY);
		if (a < 0) {
			rounds_ok = 0;
			break;
		}
		struct race_round rr = { .sock = sv[0], .fd = a, .stop = 0 };
		pthread_t sender;
		if (pthread_create(&sender, NULL, race_sender, &rr) != 0) {
			close(a);
			rounds_ok = 0;
			break;
		}
		usleep(200); // let the race window be hit from both sides
		rr.stop = 1;
		close(a); // races with in-flight captures of the same fd
		pthread_join(sender, NULL);
	}
	close(sv[0]);

	// Every delivered fd must name the captured file; the queue must drain.
	int delivered = 0, bad = 0;
	for (;;) {
		int fds[8], got = 0, fl = 0;
		char payload[32];
		int r = recv_rights(sv[1], fds, 8, &got, payload, sizeof(payload),
				    &fl, 0);
		if (r < 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK)
				bad = 1;
			break;
		}
		for (int i = 0; i < got; i++) {
			if (!same_file(fds[i], &want))
				bad = 1;
			close(fds[i]);
			delivered++;
		}
	}
	close(sv[1]);
	int ok = rounds_ok && !bad && delivered > 0;
	char detail[128];
	snprintf(detail, sizeof(detail), "rounds_ok=%d bad=%d delivered=%d",
		 rounds_ok, bad, delivered);
	case_result(id, name, ok, detail);
}

int main(void)
{
	setup_pid1();
	if (getpid() != 1)
		setvbuf(stdout, NULL, _IONBF, 0);
	if (verbose)
		say("CR1 start");

	case1();
	case2();
	case3();
	case4();
	case5();
	case6();
	case7();
	case8();
	case9();
	case10();
	case11();

	say("CR1_DONE %d", failures);
	if (getpid() == 1)
		reboot(RB_POWER_OFF);
	return failures ? 1 : 0;
}
