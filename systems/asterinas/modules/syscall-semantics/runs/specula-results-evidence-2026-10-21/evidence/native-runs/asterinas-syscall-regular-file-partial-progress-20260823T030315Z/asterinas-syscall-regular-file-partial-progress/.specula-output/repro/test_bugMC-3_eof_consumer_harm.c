// SPDX-License-Identifier: MPL-2.0
//
// MC-3 challenge payload (Agent B).  Agent A proved the syscall modifies buffer
// bytes past its return value.  This payload asks the two questions that decide
// the *consequence* bar, and adds a negative control for the mechanism:
//
//   C1  Does an ordinary application pattern -- read a short/old-format record
//       over pre-filled defaults, keep the defaults for the bytes the file does
//       not have -- silently get wrong values?
//   C2  Does readv clobber a *live, unrelated* application object that the
//       second iovec points at, even though the return value excludes it?
//   C3  Are the extra bytes zeros, or resurrected pre-truncate file content?
//       (zeros = contract defect; stale = disclosure of deleted data)
//   C4  Negative control: on a page-aligned file the cache capacity equals the
//       file size, so nothing past EOF may be touched.  If C4 also clobbered,
//       the test would be measuring something other than the cited mechanism
//       (page-aligned page-cache capacity > logical EOF).
//   C5  Counterexample case verbatim, for continuity with the MC trace.
//
// Public syscalls only (open/pwrite/ftruncate/pread/preadv/fstat).  Level 0.
//
// Usage: mc3_consumer <directory-on-the-filesystem-under-test>

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>

#define FILL 0x5a

static int wrong_outcomes;   /* application-level wrong results */
static int control_failures; /* negative control tripped */

static int make_file(const char *dir, const char *base, const void *data,
		     size_t data_len, size_t final_size)
{
	char path[512];
	snprintf(path, sizeof(path), "%s/%s", dir, base);
	unlink(path);

	int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
	if (fd < 0) {
		printf("FATAL: open(%s): %s\n", path, strerror(errno));
		exit(2);
	}
	if (data_len && pwrite(fd, data, data_len, 0) != (ssize_t)data_len) {
		printf("FATAL: pwrite(%s): %s\n", path, strerror(errno));
		exit(2);
	}
	if (final_size != data_len && ftruncate(fd, (off_t)final_size) != 0) {
		printf("FATAL: ftruncate(%s): %s\n", path, strerror(errno));
		exit(2);
	}
	struct stat st;
	if (fstat(fd, &st) != 0 || (size_t)st.st_size != final_size) {
		printf("FATAL: unexpected size for %s\n", path);
		exit(2);
	}
	return fd;
}

/* ------------------------------------------------------------------ */
/* C1: old-format record read over caller-supplied defaults.           */

struct cfg {
	uint32_t magic;
	uint32_t version;
	uint32_t timeout_ms; /* not present in the v1 on-disk record */
	uint32_t retries;    /* not present in the v1 on-disk record */
	char name[48];       /* not present in the v1 on-disk record */
};

static void case1_defaults(const char *dir)
{
	uint32_t v1_record[2] = { 0xC0FFEEu, 1u }; /* 8-byte v1 file */
	int fd = make_file(dir, "mc3c_cfg", v1_record, sizeof(v1_record),
			   sizeof(v1_record));

	struct cfg c;
	memset(&c, 0, sizeof(c));
	c.timeout_ms = 5000;
	c.retries = 3;
	strcpy(c.name, "default-profile");

	ssize_t n = pread(fd, &c, sizeof(c), 0);
	close(fd);

	int ok = (n == (ssize_t)sizeof(v1_record)) && c.magic == 0xC0FFEEu &&
		 c.version == 1u && c.timeout_ms == 5000 && c.retries == 3 &&
		 strcmp(c.name, "default-profile") == 0;

	printf("[C1 defaults survive a short record] ret=%zd (expected 8) "
	       "timeout_ms=%u (expected 5000) retries=%u (expected 3) "
	       "name=\"%s\" (expected \"default-profile\") -> %s\n",
	       n, c.timeout_ms, c.retries, c.name, ok ? "OK" : "WRONG_OUTCOME");
	if (!ok)
		wrong_outcomes++;
}

/* ------------------------------------------------------------------ */
/* C2: readv's later iovec points at a live, unrelated object.         */

struct session {
	uint32_t magic;
	char payload[60];
};

static struct session live_session;

static void case2_readv_live_object(const char *dir)
{
	int fd = make_file(dir, "mc3c_rv", "AB", 2, 2);

	live_session.magic = 0xABCD1234u;
	memset(live_session.payload, 'L', sizeof(live_session.payload));

	char hdr[2];
	memset(hdr, FILL, sizeof(hdr));

	struct iovec iov[2];
	iov[0].iov_base = hdr;
	iov[0].iov_len = sizeof(hdr);
	iov[1].iov_base = &live_session;
	iov[1].iov_len = sizeof(live_session);

	ssize_t n = preadv(fd, iov, 2, 1);
	close(fd);

	size_t payload_intact = 0;
	for (size_t i = 0; i < sizeof(live_session.payload); i++)
		if (live_session.payload[i] == 'L')
			payload_intact++;

	int ok = (n == 1) && live_session.magic == 0xABCD1234u &&
		 payload_intact == sizeof(live_session.payload);

	printf("[C2 readv leaves a live object alone] ret=%zd (expected 1) "
	       "magic=0x%08x (expected 0xabcd1234) payload_intact=%zu/60 "
	       "-> %s\n",
	       n, live_session.magic, payload_intact,
	       ok ? "OK" : "WRONG_OUTCOME");
	if (!ok)
		wrong_outcomes++;
}

/* ------------------------------------------------------------------ */
/* C3: what lands past EOF -- zeros or pre-truncate content?           */

static void case3_zero_or_stale(const char *dir)
{
	char *pattern = malloc(4096);
	if (!pattern) {
		printf("FATAL: malloc\n");
		exit(2);
	}
	memset(pattern, 'P', 4096);
	int fd = make_file(dir, "mc3c_stale", pattern, 4096, 10);
	free(pattern);

	static char buf[4096];
	memset(buf, FILL, sizeof(buf));
	ssize_t n = pread(fd, buf, sizeof(buf), 0);
	close(fd);

	size_t untouched = 0, zeroed = 0, stale = 0, other = 0;
	for (size_t i = 10; i < sizeof(buf); i++) {
		if (buf[i] == (char)FILL)
			untouched++;
		else if (buf[i] == 0)
			zeroed++;
		else if (buf[i] == 'P')
			stale++;
		else
			other++;
	}

	printf("[C3 past-EOF window after truncate] ret=%zd (expected 10) "
	       "untouched=%zu zeroed=%zu stale_pre_truncate=%zu other=%zu "
	       "-> %s\n",
	       n, untouched, zeroed, stale, other,
	       (untouched == sizeof(buf) - 10)
		       ? "OK"
		       : (stale || other ? "DELETED_DATA_DISCLOSED"
					 : "ZEROED_PAST_RETURN"));
	if (untouched != sizeof(buf) - 10)
		wrong_outcomes++;
}

/* ------------------------------------------------------------------ */
/* C4: negative control -- page-aligned file, capacity == file size.   */

static void case4_negative_control(const char *dir)
{
	char *pattern = malloc(4096);
	if (!pattern) {
		printf("FATAL: malloc\n");
		exit(2);
	}
	memset(pattern, 'Q', 4096);
	int fd = make_file(dir, "mc3c_ctl", pattern, 4096, 4096);
	free(pattern);

	static char buf[8192];
	memset(buf, FILL, sizeof(buf));
	ssize_t n = pread(fd, buf, sizeof(buf), 0);
	close(fd);

	size_t clobbered = 0;
	for (size_t i = 4096; i < sizeof(buf); i++)
		if (buf[i] != (char)FILL)
			clobbered++;

	int ok = (n == 4096) && clobbered == 0;
	printf("[C4 control: page-aligned file, cap == EOF] ret=%zd "
	       "(expected 4096) clobbered_past_eof=%zu (expected 0) -> %s\n",
	       n, clobbered, ok ? "OK" : "CONTROL_TRIPPED");
	if (!ok)
		control_failures++;
}

/* ------------------------------------------------------------------ */
/* C5: the counterexample action verbatim.                             */

static void case5_counterexample(const char *dir)
{
	int fd = make_file(dir, "mc3c_ce", "AB", 2, 2);
	static char buf[64];
	memset(buf, FILL, sizeof(buf));
	ssize_t n = pread(fd, buf, sizeof(buf), 1);
	close(fd);

	size_t clobbered = 0;
	for (size_t i = 1; i < sizeof(buf); i++)
		if (buf[i] != (char)FILL)
			clobbered++;

	printf("[C5 CE: pread(off=1,len=64,size=2)] ret=%zd (expected 1) "
	       "modified_past_return=%zu (expected 0) -> %s\n",
	       n, clobbered, (n == 1 && clobbered == 0) ? "OK" : "VIOLATION");
	if (n != 1 || clobbered != 0)
		wrong_outcomes++;
}

int main(int argc, char **argv)
{
	const char *dir = (argc > 1) ? argv[1] : "/tmp";

	printf("MC-3 challenge: filesystem under test = %s\n", dir);
	case1_defaults(dir);
	case2_readv_live_object(dir);
	case3_zero_or_stale(dir);
	case4_negative_control(dir);
	case5_counterexample(dir);

	printf("MC3C_SUMMARY wrong_outcomes=%d control_failures=%d\n",
	       wrong_outcomes, control_failures);
	if (wrong_outcomes == 0 && control_failures == 0)
		printf("MC3C_RESULT MATCHES_LINUX\n");
	else
		printf("MC3C_RESULT DIVERGES_FROM_LINUX\n");
	printf("MC3C_SCENARIO_DONE\n");
	fflush(stdout);
	return 0;
}
