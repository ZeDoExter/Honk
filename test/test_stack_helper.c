/* test_stack_helper.c -- Kernel socket setup helpers for test_stack_discipline.goose.
 * Exercises the unmodified honk_shim.c code paths >= 100,000 times per path.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* Defined in src/shim/honk_shim.c */
extern int32_t honk_worker_init(int32_t port);
extern void honk_set_timeouts(int32_t idle_timeout_ms, int32_t header_timeout_ms);
extern int32_t honk_wait(int32_t *out_fds, uint8_t *out_date29, int32_t timeout_ms);

/* We also provide a small registration helper in honk_shim.c or use a connected
 * socketpair whose server-side fd is registered via a test entry point. */
extern int32_t honk_test_register_fd(int32_t cfd, int32_t with_partial_rx, int32_t force_expired);
extern void honk_test_sweep_now(void);

static int g_sv[2] = {-1, -1};
static int g_eof_sv[2] = {-1, -1};
static int g_unconn_fd = -1;
static char g_oversize_hdr[8400];

int32_t test_helper_init(int32_t port) {
    if (honk_worker_init(port) != 0) return -1;
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0, g_sv) < 0) return -1;
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0, g_eof_sv) < 0) return -1;
    /* Close write end of g_eof_sv so recv(g_eof_sv[0], ...) always returns 0 (EOF) */
    close(g_eof_sv[1]);
    g_eof_sv[1] = -1;

    /* Unconnected TCP socket: recv() on it always returns -1 (ENOTCONN) */
    g_unconn_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (g_unconn_fd < 0) return -1;

    /* Prebuild an 8300-byte HTTP request header (> 8192 byte HONK_MAX_HEADER_SIZE) */
    const char *prefix = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Big: ";
    size_t plen = strlen(prefix);
    memcpy(g_oversize_hdr, prefix, plen);
    memset(g_oversize_hdr + plen, 'A', 8250);
    memcpy(g_oversize_hdr + plen + 8250, "\r\n\r\n", 4);
    g_oversize_hdr[plen + 8254] = '\0';
    return 0;
}

void test_helper_cleanup(void) {
    if (g_sv[0] >= 0) { close(g_sv[0]); g_sv[0] = -1; }
    if (g_sv[1] >= 0) { close(g_sv[1]); g_sv[1] = -1; }
    if (g_eof_sv[0] >= 0) { close(g_eof_sv[0]); g_eof_sv[0] = -1; }
    if (g_unconn_fd >= 0) { close(g_unconn_fd); g_unconn_fd = -1; }
}

static int g_p_cfd = -1;

/* 1. Persistent keep-alive fd for success & EAGAIN tests */
int32_t test_get_persistent_cfd(void) {
    g_p_cfd = dup(g_sv[0]);
    if (g_p_cfd < 0) return -1;
    honk_test_register_fd(g_p_cfd, 0, 0);
    return g_p_cfd;
}

void test_set_persistent_partial_rx(void) {
    honk_test_register_fd(g_p_cfd, 1, 0);
}

void test_write_valid_req(void) {
    const char *req = "GET /plaintext HTTP/1.1\r\nHost: localhost\r\n\r\n";
    ssize_t w = send(g_sv[1], req, 44, MSG_NOSIGNAL);
    (void)w;
}

void test_drain_client_rx(void) {
    char buf[4096];
    while (recv(g_sv[1], buf, sizeof(buf), 0) > 0) {}
}

/* 2. recv() == 0 (EOF) with partial_rx populated (touches stk->top then rolls back) */
int32_t test_prep_eof_fd(void) {
    int cfd = dup(g_eof_sv[0]);
    if (cfd < 0) return -1;
    honk_test_register_fd(cfd, 1, 0);
    return cfd;
}

/* 3. recv() == -1 (fatal non-EAGAIN error / peer reset) with partial_rx populated */
int32_t test_prep_err_fd(int32_t simulate_reset) {
    int cfd = dup(g_unconn_fd);
    if (cfd < 0) return -1;
    (void)simulate_reset;
    honk_test_register_fd(cfd, 1, 0);
    return cfd;
}

/* 4. 431 Request Header Fields Too Large (> 8192 bytes) */
int32_t test_prep_431_fd(void) {
    int cfd = dup(g_sv[0]);
    if (cfd < 0) return -1;
    honk_test_register_fd(cfd, 0, 0);
    size_t len = strlen(g_oversize_hdr);
    ssize_t w = send(g_sv[1], g_oversize_hdr, len, MSG_NOSIGNAL);
    (void)w;
    return cfd;
}

/* 5. 413 Payload Too Large (Content-Length > 1048576) */
int32_t test_prep_413_fd(void) {
    int cfd = dup(g_sv[0]);
    if (cfd < 0) return -1;
    honk_test_register_fd(cfd, 0, 0);
    const char *req = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2000000\r\n\r\nhello";
    ssize_t w = send(g_sv[1], req, strlen(req), MSG_NOSIGNAL);
    (void)w;
    return cfd;
}

/* 6. 501 Not Implemented (Transfer-Encoding: chunked) */
int32_t test_prep_501_fd(void) {
    int cfd = dup(g_sv[0]);
    if (cfd < 0) return -1;
    honk_test_register_fd(cfd, 0, 0);
    const char *req = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    ssize_t w = send(g_sv[1], req, strlen(req), MSG_NOSIGNAL);
    (void)w;
    return cfd;
}

/* 7. 400 Bad Request (malformed request line) */
int32_t test_prep_400_fd(void) {
    int cfd = dup(g_sv[0]);
    if (cfd < 0) return -1;
    honk_test_register_fd(cfd, 0, 0);
    const char *req = "BAD REQUEST LINE\r\n\r\n";
    ssize_t w = send(g_sv[1], req, strlen(req), MSG_NOSIGNAL);
    (void)w;
    return cfd;
}

/* 8. Partial header followed by timeout sweep */
int32_t test_prep_timeout_fd(void) {
    int cfd = dup(g_sv[0]);
    if (cfd < 0) return -1;
    honk_test_register_fd(cfd, 0, 0);
    const char *partial = "GET /slow HTTP/1.1\r\nHost: loc";
    ssize_t w = send(g_sv[1], partial, strlen(partial), MSG_NOSIGNAL);
    (void)w;
    return cfd;
}

void test_expire_and_sweep_fd(int32_t cfd) {
    honk_test_register_fd(cfd, -1, 1);
    honk_test_sweep_now();
}
