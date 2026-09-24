// AST-05 minimal: on ramfs/tmpfs, read()/pread() past logical EOF must not touch the
// caller buffer beyond the returned byte count.
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int tail_intact(const char *buf, size_t from, size_t to) {
	for (size_t i = from; i < to; i++) if ((unsigned char)buf[i] != 0xAA) return 0;
	return 1;
}

int main(int argc, char **argv) {
	const char *path = argc > 1 ? argv[1] : "/min_ast05.bin";
	int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	write(fd, "hi", 2);                                    // size = 2
	int bugs = 0;
	char buf[64];

	// 1. pread at offset 1, len 64: must return 1 and leave buf[1..64) alone
	memset(buf, 0xAA, sizeof(buf));
	ssize_t r = pread(fd, buf, sizeof(buf), 1);
	printf("pread(off=1,len=64): ret=%zd (expected 1) tail_intact=%d (expected 1)\n",
	       r, tail_intact(buf, 1, sizeof(buf)));
	bugs += r != 1 || !tail_intact(buf, 1, sizeof(buf));

	// 2. pread exactly at EOF: must return 0 and leave the whole buffer alone
	memset(buf, 0xAA, sizeof(buf));
	r = pread(fd, buf, sizeof(buf), 2);
	printf("pread(off=EOF,len=64): ret=%zd (expected 0) buffer_intact=%d (expected 1)\n",
	       r, tail_intact(buf, 0, sizeof(buf)));
	bugs += r != 0 || !tail_intact(buf, 0, sizeof(buf));

	close(fd); unlink(path);
	printf("MIN_AST05 %s\n", bugs ? "BUG" : "OK");
	return 0;
}
