// SPDX-License-Identifier: MPL-2.0

#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

static int fail(const char *stage)
{
	printf("MC2_CHALLENGE_FAIL stage=%s errno=%d\n", stage, errno);
	return EXIT_FAILURE;
}

__attribute__((noinline)) static struct epoll_event *bad_event_buffer(void)
{
	volatile uintptr_t address = 1;

	return (struct epoll_event *)address;
}

int main(void)
{
	const uint64_t token = UINT64_C(0x4d43325f45464155);
	const uint64_t value = 1;
	struct epoll_event interest = {
		.events = EPOLLIN | EPOLLONESHOT,
		.data.u64 = token,
	};
	struct epoll_event event = { 0 };
	int epfd;
	int eventfd_fd;
	int fault_errno;
	int first;
	int retry;
	int retry_errno;
	int rearmed;

	eventfd_fd = eventfd(0, EFD_NONBLOCK);
	if (eventfd_fd < 0)
		return fail("eventfd");
	epfd = epoll_create1(0);
	if (epfd < 0)
		return fail("epoll_create1");
	if (epoll_ctl(epfd, EPOLL_CTL_ADD, eventfd_fd, &interest) < 0)
		return fail("epoll_ctl_add");
	if (write(eventfd_fd, &value, sizeof(value)) != (ssize_t)sizeof(value))
		return fail("eventfd_write");

	errno = 0;
	first = epoll_wait(epfd, bad_event_buffer(), 1, 0);
	fault_errno = errno;
	if (first != -1 || fault_errno != EFAULT) {
		errno = fault_errno;
		return fail("expected_efault");
	}

	errno = 0;
	retry = epoll_wait(epfd, &event, 1, 0);
	retry_errno = errno;
	if (retry == 1 && (event.events & EPOLLIN) != 0 && event.data.u64 == token) {
		printf("MC2_CONTROL_PASS first=-1/EFAULT retry=1 token=%" PRIx64 "\n", token);
		return EXIT_SUCCESS;
	}
	if (retry != 0) {
		errno = retry_errno;
		return fail("retry_not_empty_or_redelivered");
	}

	if (epoll_ctl(epfd, EPOLL_CTL_MOD, eventfd_fd, &interest) < 0)
		return fail("epoll_ctl_mod");
	event = (struct epoll_event){ 0 };
	rearmed = epoll_wait(epfd, &event, 1, 0);
	if (rearmed != 1 || (event.events & EPOLLIN) == 0 || event.data.u64 != token)
		return fail("rearm_did_not_restore_ready_event");

	printf("MC2_REPRO first=-1/EFAULT retry=0 rearm=1 token=%" PRIx64 "\n", token);
	return EXIT_FAILURE;
}
