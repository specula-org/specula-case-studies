// SPDX-License-Identifier: MPL-2.0
//
// Reproduction test for finding MC-2: "RamFS and exFAT Cached Reads Copy
// Beyond Logical EOF" (MC config MC_hunt_s2_unbounded_read.cfg, invariant
// MCNoReadPastEOF, counterexample spec/output/MC_hunt_s2_unbounded_read_bfs.out).
//
// Mechanism under test: RamInode::read_at (kernel/core/src/fs/fs_impls/ramfs/
// fs.rs:704) and ExfatInode::read_at (kernel/core/src/fs/fs_impls/exfat/
// inode.rs:649) compute an EOF-clipped return value but pass the ORIGINAL,
// unrestricted destination VmWriter into PageCache::read. The page cache
// capacity is page-aligned and exceeds logical EOF (page_cache/mod.rs:181
// documents this), and Vmo::read (page_cache/vmo/mod.rs:534) clips its copy
// only against that capacity. A read whose request range crosses logical EOF
// therefore copies page-cache bytes from beyond EOF into the user buffer PAST
// the count returned to userspace. In the MC counterexample shape — pread64
// at offset == file_size — the syscall returns 0 while writing up to
// (capacity - file_size) bytes of the user's buffer.
//
// The ext2 adapter is the in-tree correct control: ext2/inode/file.rs limits
// the writer (writer.limit(read_len)) before entering the page cache.
//
// Escalation level 0: public syscalls only (open/write/read/pread/lseek),
// single thread, fully deterministic — no fault injection, no timing help,
// no source modification. Linux contract (the oracle): read/pread may write
// only the bytes [0, returned count) of the user buffer; the tail beyond the
// count must be left untouched.
//
// Output protocol: raw write() (no stdio buffering), one MC2_* line per fact,
// every phase in a forked child so a crash in one phase cannot take down the
// remaining phases. The host-Linux run of this same binary must print
// CLEAN for every phase; the bug is only what the Asterinas guest adds.

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define FILE_LEN 3072 /* deliberately not page-aligned */
#define BUF_LEN 4096
#define EOF_REQ 2048 /* pread count at EOF; clobber stays inside [0, capacity-FILE_LEN) */
#define SENTINEL 0xA5
#define MC2_VERSION 1

static long page_size;

static void wr(const char *s, size_t len)
{
	ssize_t w;

	while (len > 0) {
		w = write(1, s, len);
		if (w <= 0)
			_exit(99);
		s += w;
		len -= (size_t)w;
	}
}

static void out(const char *s)
{
	wr(s, strlen(s));
}

static void out_num(long long v)
{
	char b[32];
	int i = (int)sizeof(b) - 1;
	int neg = v < 0;

	b[i--] = '\0';
	if (v == 0)
		b[i--] = '0';
	while (v != 0 && i >= 0) {
		int d = neg ? -(int)(v % 10) : (int)(v % 10);

		b[i--] = (char)('0' + d);
		v /= 10;
	}
	if (neg && i >= 0)
		b[i--] = '-';
	i++;
	wr(&b[i], strlen(&b[i]));
}

static void die(const char *what)
{
	out("MC2_SETUP_ERROR ");
	out(what);
	out(": errno=");
	out_num(errno);
	out("\n");
	_exit(98);
}

/* Aperiodic content pattern so correct data is distinguishable from clobber. */
static unsigned char pat(size_t i)
{
	return (unsigned char)(((uint64_t)i * 2654435761u) >> 24);
}

/* Create a FILE_LEN-byte pattern-filled regular file at `path`. */
static void make_file(const char *path)
{
	unsigned char data[FILE_LEN];
	int fd;
	size_t done;

	for (size_t i = 0; i < FILE_LEN; i++)
		data[i] = pat(i);
	unlink(path);
	fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0600);
	if (fd < 0)
		die("open test file");
	done = 0;
	while (done < FILE_LEN) {
		ssize_t w = write(fd, data + done, FILE_LEN - done);

		if (w <= 0)
			die("write test file");
		done += (size_t)w;
	}
	if (close(fd) < 0)
		die("close test file");
}

/*
 * Scan region buf[region_lo..region_hi) for bytes changed away from the
 * sentinel; print the count, the first changed offset, and how many of the
 * changed bytes are zeros.
 */
static void report_tail(const char *fs, const char *op, const unsigned char *buf,
			size_t region_lo, size_t region_hi)
{
	size_t clobbered = 0, zeros = 0, first_off = 0;
	int seen = 0;

	for (size_t i = region_lo; i < region_hi; i++) {
		if (buf[i] != SENTINEL) {
			if (!seen) {
				first_off = i;
				seen = 1;
			}
			clobbered++;
			if (buf[i] == 0)
				zeros++;
		}
	}
	out("MC2_TAIL ");
	out(fs);
	out(" ");
	out(op);
	out(" region=");
	out_num((long long)region_lo);
	wr("..", 2);
	out_num((long long)region_hi);
	out(" clobbered=");
	out_num((long long)clobbered);
	out(" first_off=");
	out_num((long long)first_off);
	out(" zero_bytes=");
	out_num((long long)zeros);
	out("\n");
	out("MC2_VERDICT ");
	out(fs);
	out(" ");
	out(op);
	out(clobbered ? " BUG\n" : " CLEAN\n");
}

/* Phase 1 shape: short read at offset 0 crossing EOF. */
static void phase_short_read(const char *fs, const char *path)
{
	unsigned char buf[BUF_LEN];
	ssize_t n;
	size_t bad = 0;
	int fd = open(path, O_RDONLY);

	if (fd < 0)
		die("open short_read");
	memset(buf, SENTINEL, sizeof(buf));
	n = read(fd, buf, BUF_LEN);
	if (n < 0)
		die("read short_read");
	/* Data within the returned count must match the file pattern. */
	for (ssize_t i = 0; i < n; i++)
		if (buf[i] != pat((size_t)i))
			bad++;
	out("MC2_CASE fs=");
	out(fs);
	out(" op=short_read ret=");
	out_num((long long)n);
	out(" expected=");
	out_num(FILE_LEN);
	out(" data_ok=");
	out_num(bad == 0 ? 1 : 0);
	out("\n");
	if (n > 0)
		report_tail(fs, "short_read", buf, (size_t)n, BUF_LEN);
	else
		report_tail(fs, "short_read", buf, 0, BUF_LEN);
	close(fd);
}

/*
 * Phase 2 shape (the MC counterexample): pread64 at offset == file_size.
 * Linux returns 0 and touches nothing; the buggy adapters copy
 * (cache_capacity - file_size) bytes from beyond EOF into buf[0..).
 */
static void phase_eof_pread(const char *fs, const char *path)
{
	unsigned char buf[EOF_REQ];
	ssize_t n;
	int fd = open(path, O_RDONLY);

	if (fd < 0)
		die("open eof_pread");
	memset(buf, SENTINEL, sizeof(buf));
	n = pread(fd, buf, EOF_REQ, FILE_LEN);
	if (n < 0)
		die("pread eof_pread");
	out("MC2_CASE fs=");
	out(fs);
	out(" op=eof_pread ret=");
	out_num((long long)n);
	out(" expected=0\n");
	report_tail(fs, "eof_pread", buf, 0, EOF_REQ);
	close(fd);
}

struct fs_spec {
	const char *name;
	const char *path;
	int usable;
};

int main(void)
{
	struct fs_spec fss[3];
	pid_t pid;
	int status;

	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0)
		page_size = 4096;

	fss[0].name = "ramfs";
	fss[0].path = "/tmp/mc2_asterinas_ramfs.bin";
	fss[0].usable = access("/tmp", W_OK | R_OK) == 0;
	fss[1].name = "exfat";
	fss[1].path = "/exfat/mc2_repro.bin";
	fss[1].usable = access("/exfat", W_OK | R_OK) == 0;
	fss[2].name = "ext2";
	fss[2].path = "/ext2/mc2_repro.bin";
	fss[2].usable = access("/ext2", W_OK | R_OK) == 0;

	out("MC2_BEGIN v");
	out_num(MC2_VERSION);
	out("\n");
	out("MC2_SETUP page_size=");
	out_num(page_size);
	out(" file_len=");
	out_num(FILE_LEN);
	out(" exfat=");
	out_num(fss[1].usable);
	out(" ext2=");
	out_num(fss[2].usable);
	out("\n");

	for (int i = 0; i < 3; i++) {
		if (!fss[i].usable) {
			out("MC2_SKIP fs=");
			out(fss[i].name);
			out("\n");
			continue;
		}
		make_file(fss[i].path);
		/* Each phase in a forked child: isolate crashes, keep going. */
		for (int ph = 0; ph < 2; ph++) {
			pid = fork();
			if (pid < 0)
				die("fork");
			if (pid == 0) {
				if (ph == 0)
					phase_short_read(fss[i].name, fss[i].path);
				else
					phase_eof_pread(fss[i].name, fss[i].path);
				_exit(0);
			}
			if (waitpid(pid, &status, 0) < 0)
				die("waitpid");
			if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
				out("MC2_PHASE_CRASH fs=");
				out(fss[i].name);
				out(" phase=");
				out_num(ph);
				out(" status=");
				out_num(status);
				out("\n");
			}
		}
		unlink(fss[i].path);
	}

	out("MC2_REPRO_DONE");
	return 0;
}
