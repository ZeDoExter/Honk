/* honk_shim.c -- C epoll + picohttpparser shim for Honk.
 *
 * Enforces:
 *  - Amendment A / D-003: Design (iii) direct-to-Goose-data-stack recv() fast
 *    path + lazy per-connection partial_rx and pending_tx buffers in C.
 *  - Amendment B / D-004: Zero mutable shared globals; all worker state is
 *    thread-local (__thread).
 *  - Amendment C: split recv(), pipelined requests, partial send() (EAGAIN +
 *    EPOLLOUT), max header size (431), max body size (413), chunked (501),
 *    malformed (400), idle & slowloris timeouts, clean peer close/reset,
 *    Content-Length bodies, dynamic Content-Length, 1 Hz per-worker Date cache.
 *  - Requirement E: All gs_rref / stk->top access isolated in honk_rref.h;
 *    every code path restores/preserves stack top baseline.
 *  - Requirement F: 4096 active connection cap per worker (clean reject above
 *    cap), explicit rx and pending-tx caps, lazy buffer allocation freed on
 *    drain and on close.
 */

#define _GNU_SOURCE
#include "honk_rref.h"
#include "picohttpparser.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <limits.h>
#include <sys/epoll.h>
#include <sys/sendfile.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#define HONK_MAX_EVENTS       256
#define HONK_MAX_CONNS        4096
#define HONK_MAX_FD           16384
#define HONK_RECV_CHUNK       65536

#define HONK_MAX_HEADER_SIZE  8192
#define HONK_MAX_BODY_SIZE    1048576
#define HONK_MAX_PARTIAL_RX   (HONK_MAX_HEADER_SIZE + HONK_MAX_BODY_SIZE)
#define HONK_MAX_PENDING_TX   1048576

#pragma pack(push, 1)
typedef struct {
    uint8_t *data;
    int64_t len;
} sl_u8_shim;

typedef struct {
    int32_t method_off_g;
    int32_t method_end_g;
    int32_t path_off_g;
    int32_t path_end_g;
    int32_t body_off_g;
    int32_t body_end_g;
    int32_t consumed_g;
    int32_t keep_alive_g;
} RawReq_g;
#pragma pack(pop)

typedef struct {
    int fd;
    uint8_t active;
    uint8_t close_after_tx;
    uint16_t _pad;
    uint32_t epoll_events;
    uint8_t *partial_rx;
    size_t partial_rx_len;
    size_t partial_rx_cap;
    uint8_t *pending_tx;
    size_t pending_tx_off;
    size_t pending_tx_len;
    size_t pending_tx_cap;
    int64_t last_active_ms;
    int64_t rx_start_ms;
    /* Static files (sendfile): at most one active sendfile per conn.
     * file_remain > 0 means file_fd is open and owned by this slot. */
    int sendfile_fd;
    int _file_pad;
    int64_t sendfile_off;
    int64_t sendfile_remain;
} honk_conn_t;

/* Per-worker thread-local state (Amendment B: zero mutable shared globals) */
static __thread int tls_listen_fd = -1;
static __thread int tls_epfd = -1;
static __thread time_t tls_last_sec = 0;
static __thread char tls_date_str[32] = "Thu, 01 Jan 1970 00:00:00 GMT";
static __thread honk_conn_t *tls_conns = NULL;
static __thread struct epoll_event tls_events[HONK_MAX_EVENTS];

static __thread int32_t tls_active_conns = 0;
static __thread int32_t tls_max_fd_seen = 0;
static __thread int64_t tls_accepted_total = 0;
static __thread int64_t tls_rejected_conns = 0;
static __thread int64_t tls_timed_out_conns = 0;
static __thread int64_t tls_tx_queued_count = 0;

static __thread int32_t tls_idle_timeout_ms = 30000;
static __thread int32_t tls_header_timeout_ms = 10000;
static __thread int64_t tls_now_ms = 0;
static __thread int64_t tls_last_sweep_ms = 0;

static int64_t monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

static void update_tls_clock_and_date(void) {
    tls_now_ms = monotonic_ms();
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    if (ts.tv_sec != tls_last_sec) {
        tls_last_sec = ts.tv_sec;
        struct tm tm_val;
        gmtime_r(&tls_last_sec, &tm_val);
        strftime(tls_date_str, sizeof(tls_date_str), "%a, %d %b %Y %H:%M:%S GMT", &tm_val);
    }
}

static void close_conn_fd(int fd) {
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns) return;
    honk_conn_t *c = &tls_conns[fd];
    if (!c->active) return;

    if (tls_epfd >= 0) {
        epoll_ctl(tls_epfd, EPOLL_CTL_DEL, fd, NULL);
    }
    close(fd);

    if (c->partial_rx) {
        free(c->partial_rx);
        c->partial_rx = NULL;
    }
    c->partial_rx_len = 0;
    c->partial_rx_cap = 0;

    if (c->pending_tx) {
        free(c->pending_tx);
        c->pending_tx = NULL;
    }
    c->pending_tx_off = 0;
    c->pending_tx_len = 0;
    c->pending_tx_cap = 0;

    /* Deterministic sendfile fd cleanup: every open is closed exactly once,
     * on completion (fast path / resume), error, timeout, or shutdown. */
    if (c->sendfile_remain > 0 && c->sendfile_fd >= 0) {
        close(c->sendfile_fd);
    }
    c->sendfile_fd = -1;
    c->sendfile_off = 0;
    c->sendfile_remain = 0;

    c->active = 0;
    c->close_after_tx = 0;
    c->fd = -1;
    c->epoll_events = 0;
    c->last_active_ms = 0;
    c->rx_start_ms = 0;
    tls_active_conns--;
}

static void mod_conn_epoll(honk_conn_t *c, uint32_t events) {
    if (!c->active || c->epoll_events == events) return;
    struct epoll_event ev;
    ev.events = events;
    ev.data.fd = c->fd;
    if (epoll_ctl(tls_epfd, EPOLL_CTL_MOD, c->fd, &ev) == 0) {
        c->epoll_events = events;
    }
}

/* Push file bytes via sendfile() until done or EAGAIN. fd is the socket.
 * Returns 1 if more remains (EPOLLOUT armed), 0 if complete (file_fd closed
 * here), -1 if the connection was closed on fatal error. */
static int sendfile_push(honk_conn_t *c) {
    while (c->sendfile_remain > 0) {
        off_t off = (off_t)c->sendfile_off;
        /* Cap single calls at 1 MiB so one huge file cannot monopolize a turn. */
        size_t chunk = (size_t)c->sendfile_remain;
        if (chunk > (size_t)1048576) chunk = (size_t)1048576;
        ssize_t n = sendfile(c->fd, c->sendfile_fd, &off, chunk);
        if (n > 0) {
            c->sendfile_off += (int64_t)n;
            c->sendfile_remain -= (int64_t)n;
            c->last_active_ms = tls_now_ms;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            mod_conn_epoll(c, EPOLLIN | EPOLLOUT | EPOLLRDHUP);
            return 1;
        }
        /* n == 0 (truncated?) or fatal error: close everything cleanly. */
        close_conn_fd(c->fd);
        return -1;
    }
    close(c->sendfile_fd);
    c->sendfile_fd = -1;
    c->sendfile_off = 0;
    c->sendfile_remain = 0;
    return 0;
}

/* Attempt to drain pending_tx on EPOLLOUT or after queuing, then resume any
 * active sendfile (headers always precede file bytes on the wire).
 * Returns 0 if connection remains open, -1 if connection was closed. */
static int flush_pending_tx(int fd) {
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns) return -1;
    honk_conn_t *c = &tls_conns[fd];
    if (!c->active) return -1;

    while (c->pending_tx && c->pending_tx_off < c->pending_tx_len) {
        size_t rem = c->pending_tx_len - c->pending_tx_off;
        ssize_t n = send(fd, c->pending_tx + c->pending_tx_off, rem, MSG_NOSIGNAL);
        if (n > 0) {
            c->pending_tx_off += (size_t)n;
            c->last_active_ms = tls_now_ms;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
            if (errno == EINTR) continue;
            mod_conn_epoll(c, EPOLLIN | EPOLLOUT | EPOLLRDHUP);
            return 0;
        }
        close_conn_fd(fd);
        return -1;
    }

    if (c->pending_tx) {
        free(c->pending_tx);
        c->pending_tx = NULL;
        c->pending_tx_off = 0;
        c->pending_tx_len = 0;
        c->pending_tx_cap = 0;
    }

    /* Headers fully flushed: resume file bytes, if any. */
    if (c->sendfile_remain > 0) {
        int r = sendfile_push(c);
        if (r != 0) return r;   /* 1 = armed for EPOLLOUT, -1 = closed */
    }

    if (c->close_after_tx) {
        close_conn_fd(fd);
        return -1;
    }

    mod_conn_epoll(c, EPOLLIN | EPOLLRDHUP);
    return 0;
}

static void sweep_timeouts(void) {
    if (!tls_conns || tls_active_conns <= 0) return;
    for (int fd = 0; fd <= tls_max_fd_seen; fd++) {
        honk_conn_t *c = &tls_conns[fd];
        if (!c->active) continue;

        int timed_out = 0;
        if (tls_idle_timeout_ms > 0 &&
            (tls_now_ms - c->last_active_ms >= (int64_t)tls_idle_timeout_ms)) {
            timed_out = 1;
        } else if (tls_header_timeout_ms > 0 && c->rx_start_ms > 0 &&
                   (tls_now_ms - c->rx_start_ms >= (int64_t)tls_header_timeout_ms)) {
            timed_out = 1;
        }

        if (timed_out) {
            tls_timed_out_conns++;
            close_conn_fd(fd);
        }
    }
}

void honk_set_timeouts(int32_t idle_timeout_ms, int32_t header_timeout_ms) {
    tls_idle_timeout_ms = idle_timeout_ms;
    tls_header_timeout_ms = header_timeout_ms;
}

int32_t honk_worker_init(int32_t port) {
    signal(SIGPIPE, SIG_IGN);
    if (!tls_conns) {
        /* calloc zeroes all slots lazily without faulting untouched pages */
        tls_conns = (honk_conn_t *)calloc(HONK_MAX_FD, sizeof(honk_conn_t));
        if (!tls_conns) return -1;
    }

    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 4096) < 0) {
        close(fd);
        return -1;
    }

    int epfd = epoll_create1(0);
    if (epfd < 0) {
        close(fd);
        return -1;
    }

    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = fd;
    epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);

    tls_listen_fd = fd;
    tls_epfd = epfd;
    tls_active_conns = 0;
    tls_max_fd_seen = 0;
    tls_accepted_total = 0;
    tls_rejected_conns = 0;
    tls_timed_out_conns = 0;
    update_tls_clock_and_date();
    tls_last_sweep_ms = tls_now_ms;
    return 0;
}

void honk_worker_shutdown(void) {
    if (tls_conns) {
        for (int fd = 0; fd <= tls_max_fd_seen; fd++) {
            if (tls_conns[fd].active) {
                close_conn_fd(fd);
            }
        }
        free(tls_conns);
        tls_conns = NULL;
    }
    if (tls_listen_fd >= 0) {
        close(tls_listen_fd);
        tls_listen_fd = -1;
    }
    if (tls_epfd >= 0) {
        close(tls_epfd);
        tls_epfd = -1;
    }
}

int32_t honk_wait(int32_t *out_fds, uint8_t *out_date29, int32_t timeout_ms) {
    int nfds = epoll_wait(tls_epfd, tls_events, HONK_MAX_EVENTS, (int)timeout_ms);
    update_tls_clock_and_date();
    memcpy(out_date29, tls_date_str, 29);

    if (nfds < 0) {
        if (errno == EINTR) {
            nfds = 0;
        } else {
            return -1;
        }
    }

    int32_t ready_count = 0;
    for (int i = 0; i < nfds; i++) {
        int fd = tls_events[i].data.fd;
        uint32_t ev = tls_events[i].events;

        if (fd == tls_listen_fd) {
            for (;;) {
                struct sockaddr_in caddr;
                socklen_t clen = sizeof(caddr);
                int cfd = accept4(tls_listen_fd, (struct sockaddr *)&caddr, &clen, SOCK_NONBLOCK);
                if (cfd < 0) break;

                /* Requirement F: cleanly reject connections exceeding 4096 cap */
                if (tls_active_conns >= HONK_MAX_CONNS || cfd >= HONK_MAX_FD) {
                    close(cfd);
                    tls_rejected_conns++;
                    continue;
                }

                int one = 1;
                setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

                honk_conn_t *c = &tls_conns[cfd];
                c->fd = cfd;
                c->active = 1;
                c->close_after_tx = 0;
                c->epoll_events = EPOLLIN | EPOLLRDHUP;
                c->partial_rx = NULL;
                c->partial_rx_len = 0;
                c->partial_rx_cap = 0;
                c->pending_tx = NULL;
                c->pending_tx_off = 0;
                c->pending_tx_len = 0;
                c->pending_tx_cap = 0;
                c->sendfile_fd = -1;
                c->sendfile_off = 0;
                c->sendfile_remain = 0;
                c->last_active_ms = tls_now_ms;
                c->rx_start_ms = 0;

                tls_active_conns++;
                tls_accepted_total++;
                if (cfd > tls_max_fd_seen) tls_max_fd_seen = cfd;

                struct epoll_event cev;
                cev.events = c->epoll_events;
                cev.data.fd = cfd;
                epoll_ctl(tls_epfd, EPOLL_CTL_ADD, cfd, &cev);
            }
            continue;
        }

        if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns[fd].active) continue;

        if (ev & EPOLLERR) {
            close_conn_fd(fd);
            continue;
        }

        if (ev & EPOLLOUT) {
            if (flush_pending_tx(fd) < 0) continue;
        }

        if (ev & EPOLLIN) {
            out_fds[ready_count++] = (int32_t)fd;
        } else if (ev & (EPOLLHUP | EPOLLRDHUP)) {
            close_conn_fd(fd);
        }
    }

    /* Periodic timeout sweep (every 50 ms or when epoll_wait times out) */
    if (nfds == 0 || (tls_now_ms - tls_last_sweep_ms >= 50)) {
        tls_last_sweep_ms = tls_now_ms;
        sweep_timeouts();
    }

    return ready_count;
}

/* Read available bytes from fd into Goose's scoped rx_buf: u8[>..]& via honk_rref.h.
 * Returns:
 *   > 0 : total bytes in rx_buf (stashed partial_rx + newly received bytes)
 *     0 : EAGAIN / EWOULDBLOCK (no new bytes; rx_buf is reset to empty)
 *    -1 : EOF or error (connection closed; rx_buf is reset to empty)
 */
int32_t honk_conn_read(int32_t fd, gs_rref rx_buf) {
    honk_rref_reset(rx_buf);
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) {
        return -1;
    }

    honk_conn_t *c = &tls_conns[fd];
    if (c->partial_rx_len > 0) {
        honk_rref_append(rx_buf, c->partial_rx, (int64_t)c->partial_rx_len);
    }

    int64_t total_new = 0;
    for (;;) {
        ssize_t n = recv(fd, honk_rref_write_ptr(rx_buf), HONK_RECV_CHUNK, 0);
        if (n > 0) {
            honk_rref_commit(rx_buf, (int64_t)n);
            total_new += (int64_t)n;
            /* Fast path: if recv returned < HONK_RECV_CHUNK, socket buffer is drained */
            if (n < HONK_RECV_CHUNK || honk_rref_len(rx_buf) >= (HONK_MAX_PARTIAL_RX + HONK_RECV_CHUNK)) {
                break;
            }
            continue;
        }
        if (n == 0) {
            if (total_new > 0) {
                break;
            }
            honk_rref_reset(rx_buf);
            close_conn_fd(fd);
            return -1;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (total_new == 0) {
                /* No new bytes read: roll back any prepended partial_rx so stk->top == hdr->base */
                honk_rref_reset(rx_buf);
                return 0;
            }
            break;
        }
        /* Fatal recv error (ECONNRESET, etc.): reset stack top and close */
        honk_rref_reset(rx_buf);
        close_conn_fd(fd);
        return -1;
    }

    /* New bytes arrived: free stashed partial_rx if one existed */
    if (c->partial_rx) {
        free(c->partial_rx);
        c->partial_rx = NULL;
        c->partial_rx_len = 0;
        c->partial_rx_cap = 0;
    }
    c->last_active_ms = tls_now_ms;
    return (int32_t)honk_rref_len(rx_buf);
}

static int parse_strict_content_length(const char *val, size_t len, size_t *out_cl) {
    size_t i = 0;
    while (i < len && (val[i] == ' ' || val[i] == '\t')) i++;
    if (i == len) return -1;

    uint64_t acc = 0;
    int digits = 0;
    while (i < len && val[i] >= '0' && val[i] <= '9') {
        digits++;
        uint64_t d = (uint64_t)(val[i] - '0');
        if (acc > (UINT64_MAX - d) / 10) return -1;
        acc = acc * 10 + d;
        i++;
    }
    while (i < len && (val[i] == ' ' || val[i] == '\t')) i++;
    if (digits == 0 || i != len) return -1;

    *out_cl = (size_t)acc;
    return 0;
}

static int header_contains_token_ci(const char *val, size_t len, const char *tok, size_t tok_len) {
    if (len < tok_len) return 0;
    for (size_t i = 0; i + tok_len <= len; i++) {
        if (strncasecmp(val + i, tok, tok_len) == 0) return 1;
    }
    return 0;
}

/* Parse one HTTP request at the start of `buf` via picohttpparser.
 * Returns:
 *   > 0   : total request bytes consumed (headers + Content-Length body)
 *   -2    : incomplete request (headers <= 8192 and body <= 1048576, need more bytes)
 *   -400  : malformed request (400 Bad Request)
 *   -413  : Content-Length > HONK_MAX_BODY_SIZE (413 Payload Too Large)
 *   -431  : header size > HONK_MAX_HEADER_SIZE (431 Request Header Fields Too Large)
 *   -501  : Transfer-Encoding: chunked (501 Not Implemented)
 */
int32_t honk_parse_req(sl_u8_shim buf, RawReq_g *out) {
    if (buf.len <= 0) return -2;
    const char *method = NULL, *path = NULL;
    size_t method_len = 0, path_len = 0;
    int minor_version = 1;
    struct phr_header headers[64];
    size_t num_headers = 64;

    /* Only let picohttpparser scan up to HONK_MAX_HEADER_SIZE + 1 bytes for the header boundary */
    size_t scan_len = (size_t)buf.len;
    if (scan_len > HONK_MAX_HEADER_SIZE + 1) {
        scan_len = HONK_MAX_HEADER_SIZE + 1;
    }

    int pret = phr_parse_request((const char *)buf.data, scan_len,
                                 &method, &method_len,
                                 &path, &path_len,
                                 &minor_version,
                                 headers, &num_headers, 0);
    if (pret == -2) {
        if (buf.len > HONK_MAX_HEADER_SIZE) {
            return -431;
        }
        if (scan_len >= 4 && memmem(buf.data, scan_len, "\r\n\r\n", 4) != NULL) {
            return -400;
        }
        return -2;
    }
    if (pret < 0) {
        /* If num_headers == 64 caused -1 and buf is huge, check 431 vs 400 */
        if (buf.len > HONK_MAX_HEADER_SIZE) {
            return -431;
        }
        return -400;
    }
    if (pret > HONK_MAX_HEADER_SIZE) {
        return -431;
    }

    int keep_alive = (minor_version >= 1) ? 1 : 0;
    size_t content_len = 0;
    int has_content_len = 0;

    for (size_t h = 0; h < num_headers; h++) {
        if (headers[h].name == NULL) continue; /* multiline continuation */
        if (headers[h].name_len == 17 &&
            strncasecmp(headers[h].name, "Transfer-Encoding", 17) == 0) {
            if (header_contains_token_ci(headers[h].value, headers[h].value_len, "chunked", 7)) {
                return -501;
            }
            return -501;
        } else if (headers[h].name_len == 14 &&
                   strncasecmp(headers[h].name, "Content-Length", 14) == 0) {
            size_t parsed_cl = 0;
            if (parse_strict_content_length(headers[h].value, headers[h].value_len, &parsed_cl) < 0) {
                return -400;
            }
            if (has_content_len && parsed_cl != content_len) {
                return -400;
            }
            has_content_len = 1;
            content_len = parsed_cl;
            if (content_len > HONK_MAX_BODY_SIZE) {
                return -413;
            }
        } else if (headers[h].name_len == 10 &&
                   strncasecmp(headers[h].name, "Connection", 10) == 0) {
            if (header_contains_token_ci(headers[h].value, headers[h].value_len, "close", 5)) {
                keep_alive = 0;
            } else if (header_contains_token_ci(headers[h].value, headers[h].value_len, "keep-alive", 10)) {
                keep_alive = 1;
            }
        }
    }

    size_t total_req = (size_t)pret + content_len;
    if (total_req > (size_t)buf.len) {
        return -2;
    }

    const char *base = (const char *)buf.data;
    int32_t m_off = (int32_t)(method - base);
    int32_t p_off = (int32_t)(path - base);
    out->method_off_g = m_off;
    out->method_end_g = m_off + (int32_t)method_len;
    out->path_off_g = p_off;
    out->path_end_g = p_off + (int32_t)path_len;
    out->body_off_g = (int32_t)pret;
    out->body_end_g = (int32_t)total_req;
    out->consumed_g = (int32_t)total_req;
    out->keep_alive_g = keep_alive;
    return (int32_t)total_req;
}

static int queue_pending_tx(honk_conn_t *c, const uint8_t *bytes, size_t len) {
    if (len == 0) return 0;
    size_t unread = c->pending_tx_len - c->pending_tx_off;
    if (unread + len > HONK_MAX_PENDING_TX) {
        /* Peer is not reading responses and exceeded pending-tx cap */
        close_conn_fd(c->fd);
        return -1;
    }

    /* Compact existing unread bytes if offset > 0 */
    if (c->pending_tx_off > 0 && unread > 0) {
        memmove(c->pending_tx, c->pending_tx + c->pending_tx_off, unread);
        c->pending_tx_off = 0;
        c->pending_tx_len = unread;
    } else if (unread == 0) {
        c->pending_tx_off = 0;
        c->pending_tx_len = 0;
    }

    size_t needed = unread + len;
    if (needed > c->pending_tx_cap) {
        size_t new_cap = c->pending_tx_cap ? c->pending_tx_cap : 4096;
        while (new_cap < needed) new_cap *= 2;
        if (new_cap > HONK_MAX_PENDING_TX) new_cap = HONK_MAX_PENDING_TX;
        uint8_t *nb = (uint8_t *)realloc(c->pending_tx, new_cap);
        if (!nb) {
            close_conn_fd(c->fd);
            return -1;
        }
        c->pending_tx = nb;
        c->pending_tx_cap = new_cap;
    }

    memcpy(c->pending_tx + c->pending_tx_len, bytes, len);
    c->pending_tx_len += len;
    tls_tx_queued_count++;
    mod_conn_epoll(c, EPOLLIN | EPOLLOUT | EPOLLRDHUP);
    return 0;
}

/* Send response bytes on fd, queueing any unsent tail on EAGAIN and arming EPOLLOUT.
 * Returns:
 *   >= 0 : bytes accepted (sent immediately or queued for EPOLLOUT)
 *   -1   : error or cap exceeded (connection closed)
 */
int32_t honk_send(int32_t fd, sl_u8_shim data) {
    if (data.len <= 0) return 0;
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) return -1;

    honk_conn_t *c = &tls_conns[fd];

    /* If pending_tx already exists, preserve TCP byte order by appending and flushing */
    if (c->pending_tx && c->pending_tx_off < c->pending_tx_len) {
        if (queue_pending_tx(c, data.data, (size_t)data.len) < 0) return -1;
        if (flush_pending_tx(fd) < 0) return -1;
        return (int32_t)data.len;
    }

    size_t total = (size_t)data.len;
    size_t sent_off = 0;
    while (sent_off < total) {
        ssize_t n = send(fd, data.data + sent_off, total - sent_off, MSG_NOSIGNAL);
        if (n > 0) {
            sent_off += (size_t)n;
            c->last_active_ms = tls_now_ms;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (queue_pending_tx(c, data.data + sent_off, total - sent_off) < 0) {
                return -1;
            }
            return (int32_t)data.len;
        }
        close_conn_fd(fd);
        return -1;
    }
    return (int32_t)data.len;
}

/* Static files: secure open + size + zero-copy send.
 *
 * honk_file_open(root, rel): opens root/rel read-only. rel must already be
 * validated by the caller (relative, decoded, no NUL/backslash/.. segments).
 * O_NOFOLLOW rejects symlinks; fstat requires a regular file. Returns the fd
 * (>= 0, owned by the caller) or -1.
 */
int32_t honk_file_open(sl_u8_shim root, sl_u8_shim rel) {
    if (root.len <= 0 || rel.len <= 0) return -1;
    if (root.len + rel.len + 2 > 4096) return -1;
    /* Defensive re-checks (Goose validates first; never trust across FFI). */
    for (int64_t i = 0; i < rel.len; i++) {
        if (rel.data[i] == '\0' || rel.data[i] == '\\') return -1;
    }
    if (rel.data[0] == '/') return -1;
    char path[4096];
    memcpy(path, root.data, (size_t)root.len);
    path[root.len] = '/';
    memcpy(path + root.len + 1, rel.data, (size_t)rel.len);
    path[root.len + 1 + rel.len] = '\0';
    /* O_NONBLOCK: opening a FIFO for read would block forever (DoS); fstat
     * below rejects anything that is not a regular file anyway. */
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return -1;
    }
    return (int32_t)fd;
}

/* Size of an open regular file, or -1. */
int64_t honk_file_size(int32_t file_fd) {
    if (file_fd < 0) return -1;
    struct stat st;
    if (fstat(file_fd, &st) < 0 || !S_ISREG(st.st_mode)) return -1;
    return (int64_t)st.st_size;
}

void honk_file_close(int32_t file_fd) {
    if (file_fd >= 0) close(file_fd);
}

/* Queue file bytes behind any pending headers and push via sendfile().
 * The turn MUST have flushed earlier tx_buf bytes first (headers precede
 * file bytes). At most one active transfer per connection: a second file
 * while one is in flight closes the connection cleanly (documented).
 * Returns 0 (accepted: sent or resumed via EPOLLOUT), -1 (closed).
 * Ownership: once accepted with remain > 0 the conn owns file_fd; it is
 * closed exactly once (on completion, error, timeout, or shutdown).
 */
int32_t honk_sendfile_data(int32_t fd, int32_t file_fd, int64_t count) {
    if (count <= 0 || file_fd < 0) {
        if (file_fd >= 0) close(file_fd);
        return 0;
    }
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) {
        close(file_fd);
        return -1;
    }
    honk_conn_t *c = &tls_conns[fd];
    if (c->sendfile_remain > 0) {
        /* Pipelined second file under backpressure: close cleanly. */
        close(file_fd);
        close_conn_fd(fd);
        return -1;
    }
    c->sendfile_fd = file_fd;
    c->sendfile_off = 0;
    c->sendfile_remain = count;
    /* Headers (pending_tx) always flush first; then file bytes. */
    if (flush_pending_tx(fd) < 0) return -1;
    return 0;
}

/* Complete the turn for fd: stash any unparsed tail in c->partial_rx (lazily allocated),
 * handle connection close, and ALWAYS reset rx_buf.stk->top back to rx_buf.hdr->base. */
void honk_conn_finish(int32_t fd, gs_rref rx_buf, int32_t consumed, int32_t close_conn) {
    int64_t total_len = honk_rref_len(rx_buf);
    uint8_t *base = honk_rref_data(rx_buf);

    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) {
        honk_rref_reset(rx_buf);
        return;
    }

    honk_conn_t *c = &tls_conns[fd];
    if (close_conn) {
        honk_rref_reset(rx_buf);
        if ((c->pending_tx && c->pending_tx_off < c->pending_tx_len) ||
            c->sendfile_remain > 0) {
            c->close_after_tx = 1;
        } else {
            close_conn_fd(fd);
        }
        return;
    }

    int64_t rem = total_len - (int64_t)consumed;
    if (rem > 0) {
        if (rem > HONK_MAX_PARTIAL_RX) {
            honk_rref_reset(rx_buf);
            close_conn_fd(fd);
            return;
        }
        if ((size_t)rem > c->partial_rx_cap) {
            size_t new_cap = c->partial_rx_cap ? c->partial_rx_cap : 1024;
            while (new_cap < (size_t)rem) new_cap *= 2;
            if (new_cap > HONK_MAX_PARTIAL_RX) new_cap = HONK_MAX_PARTIAL_RX;
            uint8_t *nb = (uint8_t *)realloc(c->partial_rx, new_cap);
            if (!nb) {
                honk_rref_reset(rx_buf);
                close_conn_fd(fd);
                return;
            }
            c->partial_rx = nb;
            c->partial_rx_cap = new_cap;
        }
        memcpy(c->partial_rx, base + consumed, (size_t)rem);
        c->partial_rx_len = (size_t)rem;
        if (consumed > 0 || c->rx_start_ms == 0) {
            c->rx_start_ms = tls_now_ms;
        }
    } else {
        if (c->partial_rx) {
            free(c->partial_rx);
            c->partial_rx = NULL;
        }
        c->partial_rx_len = 0;
        c->partial_rx_cap = 0;
        c->rx_start_ms = 0;
    }

    honk_rref_reset(rx_buf);
}

void honk_close(int32_t fd) {
    close_conn_fd(fd);
}

static __thread int32_t tls_worker_id = 0;
static __thread int32_t tls_should_stop = 0;

void honk_request_stop(void) {
    tls_should_stop = 1;
}

int32_t honk_should_stop(void) {
    return tls_should_stop;
}

int32_t honk_pin_thread_cpu(int32_t worker_id, int32_t cpu_id) {
    tls_worker_id = worker_id;
    if (cpu_id < 0) return 0;
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET((size_t)cpu_id, &cpuset);
    return pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
}

int32_t honk_worker_id(void) {
    return tls_worker_id;
}

/* Telemetry & stack-discipline inspection helpers for tests */
int64_t honk_debug_stack_top(gs_rref r) {
    return honk_rref_top_addr(r);
}

int64_t honk_debug_stack_base(gs_rref r) {
    return honk_rref_base_addr(r);
}

int32_t honk_active_conns(void) {
    return tls_active_conns;
}

int64_t honk_accepted_total(void) {
    return tls_accepted_total;
}

int64_t honk_rejected_conns(void) {
    return tls_rejected_conns;
}

int64_t honk_timed_out_conns(void) {
    return tls_timed_out_conns;
}

int64_t honk_tx_queued_count(void) {
    return tls_tx_queued_count;
}

void honk_shrink_sndbuf(int32_t fd) {
    int sndbuf = 16384;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
}

/* Test hooks for test/test_stack_discipline.goose (100k+ iterations per path) */
int32_t honk_test_register_fd(int32_t cfd, int32_t with_partial_rx, int32_t force_expired) {
    if (cfd < 0 || cfd >= HONK_MAX_FD || !tls_conns) return -1;
    honk_conn_t *c = &tls_conns[cfd];
    if (!c->active) {
        c->fd = cfd;
        c->active = 1;
        c->close_after_tx = 0;
        c->epoll_events = 0;
        c->partial_rx = NULL;
        c->partial_rx_len = 0;
        c->partial_rx_cap = 0;
        c->pending_tx = NULL;
        c->pending_tx_off = 0;
        c->pending_tx_len = 0;
        c->pending_tx_cap = 0;
        c->sendfile_fd = -1;
        c->sendfile_off = 0;
        c->sendfile_remain = 0;
        c->last_active_ms = tls_now_ms;
        c->rx_start_ms = 0;
        tls_active_conns++;
        if (cfd > tls_max_fd_seen) tls_max_fd_seen = cfd;
    }
    if (with_partial_rx == 1) {
        const char *p = "GET /partial HTTP/1.1\r\nHost: loc";
        size_t plen = 32;
        if (c->partial_rx_cap < plen) {
            uint8_t *nb = (uint8_t *)realloc(c->partial_rx, 64);
            if (!nb) return -1;
            c->partial_rx = nb;
            c->partial_rx_cap = 64;
        }
        memcpy(c->partial_rx, p, plen);
        c->partial_rx_len = plen;
        c->rx_start_ms = tls_now_ms;
    } else if (with_partial_rx == 0) {
        if (c->partial_rx) {
            free(c->partial_rx);
            c->partial_rx = NULL;
        }
        c->partial_rx_len = 0;
        c->partial_rx_cap = 0;
        c->rx_start_ms = 0;
    }
    if (force_expired) {
        c->last_active_ms = tls_now_ms - (int64_t)tls_idle_timeout_ms - 1000;
        if (c->rx_start_ms > 0) {
            c->rx_start_ms = tls_now_ms - (int64_t)tls_header_timeout_ms - 1000;
        }
    }
    return 0;
}

void honk_test_sweep_now(void) {
    sweep_timeouts();
}
