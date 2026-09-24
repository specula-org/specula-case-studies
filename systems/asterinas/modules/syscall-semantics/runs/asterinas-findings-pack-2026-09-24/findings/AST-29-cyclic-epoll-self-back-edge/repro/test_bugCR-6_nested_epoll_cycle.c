// CR-6 Level-0 reproduction: public epoll/eventfd syscalls only.
// The acyclic control must complete before the self-edge is attempted.
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

static void fail(const char *stage) {
    fprintf(stderr, "CR6 FAIL stage=%s errno=%d (%s)\n", stage, errno, strerror(errno));
    exit(2);
}

static void add_interest(int epfd, int fd, uint64_t data, const char *stage) {
    struct epoll_event event = {
        .events = EPOLLIN,
        .data.u64 = data,
    };

    if (epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &event) != 0) {
        fail(stage);
    }
}

static void run_acyclic_control(void) {
    const uint64_t outer_data = UINT64_C(0xa11c);
    const uint64_t inner_data = UINT64_C(0xe7fd);
    const uint64_t one = 1;
    struct epoll_event event;
    int outer = epoll_create1(EPOLL_CLOEXEC);
    int inner = epoll_create1(EPOLL_CLOEXEC);
    int efd = eventfd(0, EFD_CLOEXEC);

    if (outer < 0 || inner < 0 || efd < 0) {
        fail("acyclic_create");
    }

    add_interest(inner, efd, inner_data, "acyclic_add_eventfd");
    add_interest(outer, inner, outer_data, "acyclic_add_nested_epoll");
    if (write(efd, &one, sizeof(one)) != (ssize_t)sizeof(one)) {
        fail("acyclic_eventfd_write");
    }

    int ready = epoll_wait(outer, &event, 1, 1000);
    if (ready != 1 || event.data.u64 != outer_data || !(event.events & EPOLLIN)) {
        fprintf(stderr,
                "CR6 FAIL stage=acyclic_wait ready=%d data=%" PRIx64 " events=%x errno=%d (%s)\n",
                ready, event.data.u64, event.events, errno, strerror(errno));
        exit(2);
    }

    printf("CR6 ACYCLIC_CONTROL_OK ready=%d data=%" PRIx64 " events=%x\n",
           ready, event.data.u64, event.events);
    close(efd);
    close(inner);
    close(outer);
}

static int run_self_edge(void) {
    const uint64_t one = 1;
    struct epoll_event event = {
        .events = EPOLLIN,
        .data.u64 = UINT64_C(0x5e1f),
    };
    int epfd = epoll_create1(EPOLL_CLOEXEC);
    int efd = eventfd(0, EFD_CLOEXEC);
    if (epfd < 0 || efd < 0) {
        fail("self_create");
    }

    errno = 0;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, epfd, &event) != 0) {
        printf("CR6 SELF_EDGE_REJECTED errno=%d (%s)\n", errno, strerror(errno));
        return errno == EINVAL ? 0 : 4;
    }

    printf("CR6 SELF_EDGE_ACCEPTED\n");
    add_interest(epfd, efd, UINT64_C(0xe7fd), "self_add_eventfd");
    printf("CR6 SELF_WRITE_BEGIN\n");
    if (write(efd, &one, sizeof(one)) != (ssize_t)sizeof(one)) {
        fail("self_eventfd_write");
    }

    // Reaching this line means the synchronous callback did not deadlock.
    printf("CR6 SELF_WRITE_RETURNED\n");
    return 3;
}

static int run_two_epoll_back_edge(void) {
    const uint64_t one = 1;
    int ep1 = epoll_create1(EPOLL_CLOEXEC);
    int ep2 = epoll_create1(EPOLL_CLOEXEC);
    int efd = eventfd(0, EFD_CLOEXEC);

    if (ep1 < 0 || ep2 < 0 || efd < 0) {
        fail("pair_create");
    }

    add_interest(ep1, ep2, UINT64_C(0xe001), "pair_add_forward_edge");
    errno = 0;
    struct epoll_event event = {
        .events = EPOLLIN,
        .data.u64 = UINT64_C(0xe002),
    };
    if (epoll_ctl(ep2, EPOLL_CTL_ADD, ep1, &event) != 0) {
        printf("CR6 PAIR_BACK_EDGE_REJECTED errno=%d (%s)\n", errno, strerror(errno));
        return errno == ELOOP ? 0 : 4;
    }

    printf("CR6 PAIR_BACK_EDGE_ACCEPTED\n");
    add_interest(ep1, efd, UINT64_C(0xe7fd), "pair_add_eventfd");
    printf("CR6 PAIR_WRITE_BEGIN\n");
    if (write(efd, &one, sizeof(one)) != (ssize_t)sizeof(one)) {
        fail("pair_eventfd_write");
    }

    // Reaching this line means the synchronous callback did not deadlock.
    printf("CR6 PAIR_WRITE_RETURNED\n");
    return 3;
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "self") != 0 && strcmp(argv[1], "pair") != 0)) {
        fprintf(stderr, "usage: %s self|pair\n", argv[0]);
        return 64;
    }

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    printf("CR6 LEVEL0_START mode=%s\n", argv[1]);
    run_acyclic_control();
    return strcmp(argv[1], "self") == 0 ? run_self_edge() : run_two_epoll_back_edge();
}
