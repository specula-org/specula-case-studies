// CR-1 regression: a captured read must retain pipe A across close/reuse of
// its descriptor; dup2 replacement and CLOEXEC exec cutover retain OFD identity.

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct reader_state {
    int fd;
    int started_fd;
    atomic_int done;
    ssize_t result;
    int error;
    char byte;
};

struct capture_stats {
    int old_object;
    int raced_ebadf;
    int raced_new_object;
    int errors;
};

static void sleep_ms(long milliseconds)
{
    struct timespec pause = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (milliseconds % 1000) * 1000 * 1000,
    };

    while (nanosleep(&pause, &pause) == -1 && errno == EINTR) {
    }
}

static int expect_byte(int fd, char expected, const char *label)
{
    char actual = '\0';
    ssize_t nread = read(fd, &actual, sizeof(actual));

    if (nread != 1 || actual != expected) {
        fprintf(stderr,
                "CR-1 FAIL: %s expected %c, got nread=%ld byte=%c errno=%d\\n",
                label, expected, (long)nread, actual, errno);
        return -1;
    }
    return 0;
}

static void *blocking_reader(void *arg)
{
    struct reader_state *state = arg;
    char started = 'S';

    if (write(state->started_fd, &started, sizeof(started)) != 1) {
        state->result = -1;
        state->error = errno;
        atomic_store_explicit(&state->done, 1, memory_order_release);
        return NULL;
    }

    errno = 0;
    state->result = read(state->fd, &state->byte, sizeof(state->byte));
    state->error = errno;
    atomic_store_explicit(&state->done, 1, memory_order_release);
    return NULL;
}

/*
 * This uses only public operations. A result of 'O' proves that the reader
 * captured pipe A before its numeric descriptor was closed and reused for B.
 * A result of 'N' or EBADF is a scheduling race before capture, not evidence
 * of redirection, so it is reported separately.
 */
static int capture_attempt(int capture_delay_ms, struct capture_stats *stats)
{
    int old_pipe[2] = { -1, -1 };
    int new_pipe[2] = { -1, -1 };
    int started_pipe[2] = { -1, -1 };
    pthread_t thread;
    struct reader_state state = {
        .fd = -1,
        .started_fd = -1,
        .done = ATOMIC_VAR_INIT(0),
        .result = -1,
        .error = 0,
        .byte = '\0',
    };
    char started;
    int capture_fd;
    int created_thread = 0;
    int rc = -1;

    if (pipe(old_pipe) == -1 || pipe(new_pipe) == -1 || pipe(started_pipe) == -1) {
        fprintf(stderr, "CR-1 FAIL: pipe setup errno=%d\\n", errno);
        goto out;
    }

    state.fd = old_pipe[0];
    state.started_fd = started_pipe[1];
    if (pthread_create(&thread, NULL, blocking_reader, &state) != 0) {
        fprintf(stderr, "CR-1 FAIL: pthread_create\\n");
        goto out;
    }
    created_thread = 1;

    if (read(started_pipe[0], &started, sizeof(started)) != 1 || started != 'S') {
        fprintf(stderr, "CR-1 FAIL: reader start handshake errno=%d\\n", errno);
        goto out;
    }

    if (capture_delay_ms > 0) {
        sleep_ms(capture_delay_ms);
    }

    capture_fd = old_pipe[0];
    if (close(capture_fd) == -1 || dup2(new_pipe[0], capture_fd) != capture_fd) {
        fprintf(stderr, "CR-1 FAIL: close/reuse errno=%d\\n", errno);
        goto out;
    }
    old_pipe[0] = -1;

    if (write(new_pipe[1], "N", 1) != 1) {
        fprintf(stderr, "CR-1 FAIL: write to replacement pipe errno=%d\\n", errno);
        goto out;
    }

    if (capture_delay_ms > 0) {
        sleep_ms(2);
    }

    if (!atomic_load_explicit(&state.done, memory_order_acquire)
        && write(old_pipe[1], "O", 1) != 1) {
        fprintf(stderr, "CR-1 FAIL: write to captured pipe errno=%d\\n", errno);
        goto out;
    }

    if (pthread_join(thread, NULL) != 0) {
        fprintf(stderr, "CR-1 FAIL: pthread_join\\n");
        goto out;
    }
    created_thread = 0;

    if (state.result == 1 && state.byte == 'O') {
        stats->old_object++;
        rc = 0;
    } else if (state.result == 1 && state.byte == 'N') {
        stats->raced_new_object++;
        rc = 0;
    } else if (state.result == -1 && state.error == EBADF) {
        stats->raced_ebadf++;
        rc = 0;
    } else {
        fprintf(stderr,
                "CR-1 FAIL: reader returned nread=%ld byte=%c errno=%d\\n",
                (long)state.result, state.byte, state.error);
        stats->errors++;
    }

out:
    if (created_thread) {
        /* Wake a correctly captured reader before joining it. */
        if (old_pipe[1] != -1) {
            ssize_t wake_result = write(old_pipe[1], "O", 1);

            (void)wake_result;
        }
        (void)pthread_join(thread, NULL);
    }
    if (old_pipe[0] != -1) {
        (void)close(old_pipe[0]);
    }
    if (old_pipe[1] != -1) {
        (void)close(old_pipe[1]);
    }
    if (new_pipe[0] != -1) {
        (void)close(new_pipe[0]);
    }
    if (new_pipe[1] != -1) {
        (void)close(new_pipe[1]);
    }
    if (started_pipe[0] != -1) {
        (void)close(started_pipe[0]);
    }
    if (started_pipe[1] != -1) {
        (void)close(started_pipe[1]);
    }
    return rc;
}

static int test_captured_read(void)
{
    struct capture_stats level0 = { 0 };
    struct capture_stats level1 = { 0 };
    int i;

    /* Level 0: black-box, no deliberate delay. */
    for (i = 0; i < 16; i++) {
        if (capture_attempt(0, &level0) != 0) {
            return -1;
        }
    }
    printf("CAPTURE L0 old=%d raced_ebadf=%d raced_new=%d errors=%d\\n",
           level0.old_object, level0.raced_ebadf, level0.raced_new_object, level0.errors);

    /* Level 1: timing assistance only; system logic is unchanged. */
    for (i = 0; i < 16; i++) {
        if (capture_attempt(20, &level1) != 0) {
            return -1;
        }
    }
    printf("CAPTURE L1 old=%d raced_ebadf=%d raced_new=%d errors=%d\\n",
           level1.old_object, level1.raced_ebadf, level1.raced_new_object, level1.errors);

    if (level1.old_object == 0 || level1.errors != 0) {
        fprintf(stderr, "CR-1 FAIL: could not establish a captured-read sample\\n");
        return -1;
    }
    return 0;
}

static int test_dup_replace_and_reuse(void)
{
    int pipe_a[2] = { -1, -1 };
    int pipe_b[2] = { -1, -1 };
    int pipe_c[2] = { -1, -1 };
    const int target = 100;
    int keep_b = -1;
    int rc = -1;

    if (pipe(pipe_a) == -1 || pipe(pipe_b) == -1 || pipe(pipe_c) == -1) {
        fprintf(stderr, "CR-1 FAIL: dup test pipe setup errno=%d\\n", errno);
        goto out;
    }
    if (dup2(pipe_b[0], target) != target) {
        fprintf(stderr, "CR-1 FAIL: install B at target errno=%d\\n", errno);
        goto out;
    }
    keep_b = dup(target);
    if (keep_b == -1 || close(pipe_b[0]) == -1) {
        fprintf(stderr, "CR-1 FAIL: preserve B duplicate errno=%d\\n", errno);
        goto out;
    }
    pipe_b[0] = -1;

    if (dup2(pipe_a[0], target) != target || close(pipe_a[0]) == -1) {
        fprintf(stderr, "CR-1 FAIL: replace target with A errno=%d\\n", errno);
        goto out;
    }
    pipe_a[0] = -1;
    if (write(pipe_a[1], "A", 1) != 1 || expect_byte(target, 'A', "replaced target") != 0) {
        goto out;
    }
    if (write(pipe_b[1], "B", 1) != 1 || expect_byte(keep_b, 'B', "retained displaced OFD") != 0) {
        goto out;
    }

    if (close(target) == -1 || dup2(pipe_c[0], target) != target) {
        fprintf(stderr, "CR-1 FAIL: final close/reuse errno=%d\\n", errno);
        goto out;
    }
    if (write(pipe_c[1], "C", 1) != 1 || expect_byte(target, 'C', "reused target") != 0) {
        goto out;
    }

    printf("DUP-REPLACE PASS target=%d retained_b=%d\\n", target, keep_b);
    rc = 0;

out:
    (void)close(target);
    if (keep_b != -1) {
        (void)close(keep_b);
    }
    if (pipe_a[0] != -1) {
        (void)close(pipe_a[0]);
    }
    if (pipe_a[1] != -1) {
        (void)close(pipe_a[1]);
    }
    if (pipe_b[0] != -1) {
        (void)close(pipe_b[0]);
    }
    if (pipe_b[1] != -1) {
        (void)close(pipe_b[1]);
    }
    if (pipe_c[0] != -1) {
        (void)close(pipe_c[0]);
    }
    if (pipe_c[1] != -1) {
        (void)close(pipe_c[1]);
    }
    return rc;
}

static int parse_fd(const char *value)
{
    char *end = NULL;
    long parsed = strtol(value, &end, 10);

    if (*value == '\0' || *end != '\0' || parsed < 0 || parsed > 1023) {
        return -1;
    }
    return (int)parsed;
}

static int exec_child(int argc, char **argv)
{
    char byte = '\0';
    int close_fd;
    int keep_fd;
    int writer_fd;

    if (argc != 5) {
        fprintf(stderr, "CR-1 FAIL: exec child argument count\\n");
        return 1;
    }
    close_fd = parse_fd(argv[2]);
    keep_fd = parse_fd(argv[3]);
    writer_fd = parse_fd(argv[4]);
    if (close_fd < 0 || keep_fd < 0 || writer_fd < 0) {
        fprintf(stderr, "CR-1 FAIL: exec child descriptor argument\\n");
        return 1;
    }

    errno = 0;
    if (fcntl(close_fd, F_GETFD) != -1 || errno != EBADF) {
        fprintf(stderr, "CR-1 FAIL: CLOEXEC descriptor survived errno=%d\\n", errno);
        return 1;
    }
    if (fcntl(keep_fd, F_GETFD) == -1) {
        fprintf(stderr, "CR-1 FAIL: non-CLOEXEC duplicate lost errno=%d\\n", errno);
        return 1;
    }
    if (read(keep_fd, &byte, 1) != 1 || byte != 'E') {
        fprintf(stderr, "CR-1 FAIL: retained OFD pre-exec byte=%c errno=%d\\n", byte, errno);
        return 1;
    }
    if (write(writer_fd, "F", 1) != 1 || read(keep_fd, &byte, 1) != 1 || byte != 'F') {
        fprintf(stderr, "CR-1 FAIL: retained OFD post-exec byte=%c errno=%d\\n", byte, errno);
        return 1;
    }

    printf("EXEC-CUTOVER PASS closed=%d kept=%d\\n", close_fd, keep_fd);
    printf("CR-1 RESULT: PASS (captured and surviving descriptors kept their OFDs)\\n");
    return 0;
}

static int test_exec_cutover(const char *self_path)
{
    int data_pipe[2] = { -1, -1 };
    const int close_fd = 100;
    const int keep_fd = 101;
    const int writer_fd = 102;
    char close_arg[16];
    char keep_arg[16];
    char writer_arg[16];
    char *const child_argv[] = {
        (char *)self_path,
        "--exec-child",
        close_arg,
        keep_arg,
        writer_arg,
        NULL,
    };

    if (pipe(data_pipe) == -1
        || dup2(data_pipe[0], close_fd) != close_fd
        || dup2(close_fd, keep_fd) != keep_fd
        || dup2(data_pipe[1], writer_fd) != writer_fd
        || close(data_pipe[0]) == -1
        || close(data_pipe[1]) == -1) {
        fprintf(stderr, "CR-1 FAIL: exec setup errno=%d\\n", errno);
        return -1;
    }
    if (fcntl(close_fd, F_SETFD, FD_CLOEXEC) == -1 || write(writer_fd, "E", 1) != 1) {
        fprintf(stderr, "CR-1 FAIL: CLOEXEC setup errno=%d\\n", errno);
        return -1;
    }

    (void)snprintf(close_arg, sizeof(close_arg), "%d", close_fd);
    (void)snprintf(keep_arg, sizeof(keep_arg), "%d", keep_fd);
    (void)snprintf(writer_arg, sizeof(writer_arg), "%d", writer_fd);
    execv(self_path, child_argv);
    fprintf(stderr, "CR-1 FAIL: execv(%s) errno=%d\\n", self_path, errno);
    return -1;
}

int main(int argc, char **argv)
{
    (void)signal(SIGPIPE, SIG_IGN);
    (void)setvbuf(stdout, NULL, _IONBF, 0);

    if (argc > 1 && strcmp(argv[1], "--exec-child") == 0) {
        return exec_child(argc, argv);
    }

    printf("CR-1 OFD identity regression start\\n");
    if (test_captured_read() != 0 || test_dup_replace_and_reuse() != 0) {
        return 1;
    }
    return test_exec_cutover(argv[0]) == 0 ? 0 : 1;
}
