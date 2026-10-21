// SPDX-License-Identifier: MPL-2.0
//
// test_bugMC-8 — ramfs zero-progress failed write publishes the full requested extent.
//
// Level 0 (pure black-box, public API only):
//   1. seed a 2-byte file on the ramfs root (initramfs unpacks into RamFs::new_rootfs)
//   2. pwrite64(fd, bad, 2, 2) where `bad` is a PROT_NONE page — the source is
//      inaccessible from the very first byte, so the copy makes zero progress and the
//      syscall must fail with EFAULT
//   3. observe the file afterwards via fstat + pread
//
// Correct behavior (Linux v6.12 ramfs, generic_perform_write: i_size is only advanced
// by write_end after bytes were actually copied): the failed write leaves size = 2 and
// pread at offset 2 hits EOF.
//
// Buggy behavior (RamInode::write_at publishes inode_meta.size and resizes the page
// cache BEFORE page_cache.write): size = 4 and pread delivers two zero bytes that no
// successful syscall ever wrote.
//
// An ext2 file at /mnt_ext2 is used as a same-syscall control: ext2 copies first and
// publishes the size only on success, so the same sequence must leave size = 2 there.
//
// Runs as /init (static, no libc runtime deps beyond syscalls). Prints one
// "MC8_RESULT: ..." verdict line per backend, then "SPECULA_EXIT <status>" and powers
// off, following the harness convention in harness/src/init.c.

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>

static int bug_present;   /* -1 unknown, 0 absent, 1 present */
static int test_ran;

/* Returns 1 if the failed write left the file extended, 0 if size stayed 2,
 * -1 on test-harness error. */
static int probe_backend(const char *path, const char *tag)
{
	char rb[8];
	struct stat st;
	ssize_t w, r;
	void *bad;
	int fd, e;

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		printf("[%s] open(%s) failed: %s\n", tag, path, strerror(errno));
		return -1;
	}
	if (write(fd, "hi", 2) != 2) {
		printf("[%s] seed write failed: %s\n", tag, strerror(errno));
		close(fd);
		return -1;
	}
	if (fstat(fd, &st) == 0)
		printf("[%s] size after seed write = %lld (expect 2)\n", tag,
		       (long long)st.st_size);

	bad = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (bad == MAP_FAILED) {
		printf("[%s] mmap(PROT_NONE) failed: %s\n", tag, strerror(errno));
		close(fd);
		return -1;
	}

	/* The trigger: extending write at EOF from an inaccessible source. */
	errno = 0;
	w = pwrite(fd, bad, 2, 2);
	e = errno;
	printf("[%s] pwrite(PROT_NONE buf, 2, off=2) = %zd errno=%d (%s)\n",
	       tag, w, e, strerror(e));

	memset(rb, 0x41, sizeof(rb)); /* poison with 'A' so real bytes stand out */
	if (fstat(fd, &st) != 0) {
		printf("[%s] fstat failed: %s\n", tag, strerror(errno));
		close(fd);
		return -1;
	}
	r = pread(fd, rb, 4, 0);
	printf("[%s] size after failed write = %lld | pread(4, off=0) = %zd "
	       "bytes = %02x %02x %02x %02x (\"%c%c%c%c\")\n",
	       tag, (long long)st.st_size, r,
	       (unsigned char)rb[0], (unsigned char)rb[1],
	       (unsigned char)rb[2], (unsigned char)rb[3],
	       rb[0] >= 32 && rb[0] < 127 ? rb[0] : '.',
	       rb[1] >= 32 && rb[1] < 127 ? rb[1] : '.',
	       rb[2] >= 32 && rb[2] < 127 ? rb[2] : '.',
	       rb[3] >= 32 && rb[3] < 127 ? rb[3] : '.');

	/* Positive control: a good buffer at the same offset must extend. */
	{
		struct stat st2;
		ssize_t w2 = pwrite(fd, "XY", 2, 2);
		int e2 = errno;
		fstat(fd, &st2);
		printf("[%s] control pwrite(good buf, 2, off=2) = %zd errno=%d, "
		       "size now %lld (expect 2 written, size 4)\n",
		       tag, w2, w2 < 0 ? e2 : 0, (long long)st2.st_size);
	}

	munmap(bad, 4096);
	close(fd);
	unlink(path);

	if (w != -1 || e != EFAULT) {
		printf("[%s] unexpected write outcome (wanted -1/EFAULT); "
		       "cannot judge size semantics\n", tag);
		return -1;
	}
	return st.st_size > 2;
}

int main(void)
{
	struct utsname uts;
	int ramfs_ret, ext2_ret = -1;

	setvbuf(stdout, NULL, _IONBF, 0);
	uname(&uts);
	printf("MC-8 repro: zero-progress EFAULT extending write on ramfs\n");
	printf("kernel: %s %s %s\n", uts.sysname, uts.release, uts.machine);

	/* 1. ramfs: the initramfs root IS ramfs (RamFs::new_rootfs). */
	ramfs_ret = probe_backend("/mc8_ramfs_file", "ramfs");

	/* 2. ext2 control on the harness disk image, same syscall sequence. */
	mkdir("/mnt_ext2", 0755);
	if (mount("/dev/vda", "/mnt_ext2", "ext2", 0, NULL) == 0) {
		ext2_ret = probe_backend("/mnt_ext2/mc8_ext2_file", "ext2");
		umount("/mnt_ext2");
	} else {
		printf("[ext2] mount /dev/vda failed: %s (control skipped)\n",
		       strerror(errno));
	}

	test_ran = 1;
	if (ramfs_ret < 0) {
		printf("MC8_RESULT: INCONCLUSIVE (ramfs probe errored)\n");
		bug_present = -1;
	} else if (ramfs_ret == 1) {
		printf("MC8_RESULT: BUG PRESENT — failed zero-progress write left "
		       "the ramfs file extended with zero-filled bytes\n");
		bug_present = 1;
	} else {
		printf("MC8_RESULT: BUG ABSENT — ramfs kept size 2 after EFAULT\n");
		bug_present = 0;
	}
	if (ext2_ret >= 0)
		printf("MC8_CONTROL_EXT2: %s (same sequence on ext2 %s)\n",
		       ext2_ret ? "EXTENDED" : "SIZE UNCHANGED",
		       ext2_ret ? "also extended — divergence claim weakened"
				: "left size unchanged, matching Linux semantics");

	printf("SPECULA_EXIT %d\n", bug_present < 0 ? 1 : 0);
	sync();
	reboot(RB_POWER_OFF);
	return bug_present < 0 ? 1 : 0;
}
