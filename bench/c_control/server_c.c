/* server_c.c -- Bare-C epoll + picohttpparser reference server (transport baseline).
 * Matches Honk's exact work per turn (1 Hz Date cache, monotonic timestamp,
 * direct recv into turn buffer with lazy per-connection partial_rx and pending_tx,
 * strict Content-Length / Transfer-Encoding / header & body size checks,
 * dynamic Content-Length formatting, and identical HTTP/1.1 headers and payload).
 */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "../../src/shim/picohttpparser.h"

#define MAX_EVENTS       256
#define MAX_CONNS        4096
#define MAX_FD           16384
#define READ_BUF_SIZE    65536
#define WRITE_BUF_SIZE   65536
#define MAX_HEADER_SIZE  8192
#define MAX_BODY_SIZE    1048576
#define MAX_PARTIAL_RX   (MAX_HEADER_SIZE + MAX_BODY_SIZE)
#define MAX_PENDING_TX   1048576

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
} c_conn_t;

static __thread int tls_listen_fd = -1;
static __thread int tls_epfd = -1;
static __thread time_t tls_last_sec = 0;
static __thread char tls_date_str[32] = "Thu, 01 Jan 1970 00:00:00 GMT";
static __thread c_conn_t *tls_conns = NULL;
static __thread int32_t tls_active_conns = 0;
static __thread int32_t tls_max_fd_seen = 0;
static __thread int64_t tls_now_ms = 0;
static __thread int64_t tls_last_sweep_ms = 0;
static __thread int32_t tls_idle_timeout_ms = 30000;
static __thread int32_t tls_header_timeout_ms = 10000;

static int64_t monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

static void update_clock_and_date(void) {
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
    if (fd < 0 || fd >= MAX_FD || !tls_conns) return;
    c_conn_t *c = &tls_conns[fd];
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
    c->active = 0;
    c->close_after_tx = 0;
    c->fd = -1;
    c->epoll_events = 0;
    c->last_active_ms = 0;
    c->rx_start_ms = 0;
    tls_active_conns--;
}

static void mod_conn_epoll(c_conn_t *c, uint32_t events) {
    if (!c->active || c->epoll_events == events) return;
    struct epoll_event ev;
    ev.events = events;
    ev.data.fd = c->fd;
    if (epoll_ctl(tls_epfd, EPOLL_CTL_MOD, c->fd, &ev) == 0) {
        c->epoll_events = events;
    }
}

static int flush_pending_tx(int fd) {
    if (fd < 0 || fd >= MAX_FD || !tls_conns) return -1;
    c_conn_t *c = &tls_conns[fd];
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
    if (c->close_after_tx) {
        close_conn_fd(fd);
        return -1;
    }
    mod_conn_epoll(c, EPOLLIN | EPOLLRDHUP);
    return 0;
}

static int queue_pending_tx(c_conn_t *c, const uint8_t *bytes, size_t len) {
    if (len == 0) return 0;
    size_t unread = c->pending_tx_len - c->pending_tx_off;
    if (unread + len > MAX_PENDING_TX) {
        close_conn_fd(c->fd);
        return -1;
    }
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
        if (new_cap > MAX_PENDING_TX) new_cap = MAX_PENDING_TX;
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
    mod_conn_epoll(c, EPOLLIN | EPOLLOUT | EPOLLRDHUP);
    return 0;
}

static int send_or_queue(int fd, const uint8_t *data, size_t len) {
    if (len == 0) return 0;
    c_conn_t *c = &tls_conns[fd];
    if (!c->active) return -1;
    if (c->pending_tx && c->pending_tx_off < c->pending_tx_len) {
        if (queue_pending_tx(c, data, len) < 0) return -1;
        return flush_pending_tx(fd);
    }
    size_t sent_off = 0;
    while (sent_off < len) {
        ssize_t n = send(fd, data + sent_off, len - sent_off, MSG_NOSIGNAL);
        if (n > 0) {
            sent_off += (size_t)n;
            c->last_active_ms = tls_now_ms;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            return queue_pending_tx(c, data + sent_off, len - sent_off);
        }
        close_conn_fd(fd);
        return -1;
    }
    return 0;
}

static void sweep_timeouts(void) {
    if (!tls_conns || tls_active_conns <= 0) return;
    for (int fd = 0; fd <= tls_max_fd_seen; fd++) {
        c_conn_t *c = &tls_conns[fd];
        if (!c->active) continue;
        if ((tls_idle_timeout_ms > 0 && (tls_now_ms - c->last_active_ms >= tls_idle_timeout_ms)) ||
            (tls_header_timeout_ms > 0 && c->rx_start_ms > 0 && (tls_now_ms - c->rx_start_ms >= tls_header_timeout_ms))) {
            close_conn_fd(fd);
        }
    }
}

static inline int fmt_u64(char *dst, uint64_t v) {
    char tmp[24];
    int n = 0;
    do {
        tmp[n++] = (char)('0' + (v % 10));
        v /= 10;
    } while (v > 0);
    for (int i = 0; i < n; i++) {
        dst[i] = tmp[n - 1 - i];
    }
    return n;
}

static size_t build_response(uint8_t *out, int status, const char *status_text,
                             const char *content_type, const uint8_t *body, size_t body_len,
                             int keep_alive) {
    uint8_t *p = out;
    memcpy(p, "HTTP/1.1 ", 9); p += 9;
    p += fmt_u64((char *)p, (uint64_t)status);
    *p++ = ' ';
    size_t st_len = strlen(status_text);
    memcpy(p, status_text, st_len); p += st_len;
    memcpy(p, "\r\nContent-Type: ", 16); p += 16;
    size_t ct_len = strlen(content_type);
    memcpy(p, content_type, ct_len); p += ct_len;
    memcpy(p, "\r\nDate: ", 8); p += 8;
    memcpy(p, tls_date_str, 29); p += 29;
    if (!keep_alive) {
        memcpy(p, "\r\nConnection: close", 19); p += 19;
    }
    memcpy(p, "\r\nContent-Length: ", 18); p += 18;
    p += fmt_u64((char *)p, (uint64_t)body_len);
    memcpy(p, "\r\n\r\n", 4); p += 4;
    if (body_len > 0) {
        memcpy(p, body, body_len);
        p += body_len;
    }
    return (size_t)(p - out);
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

static int create_listener(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (fd < 0) { perror("socket"); exit(1); }
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
        perror("bind"); exit(1);
    }
    if (listen(fd, 4096) < 0) {
        perror("listen"); exit(1);
    }
    return fd;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    int port = argc > 1 ? atoi(argv[1]) : 18080;

    /* Lazy calloc: zeroed pages are not faulted until an fd slot is used */
    tls_conns = (c_conn_t *)calloc(MAX_FD, sizeof(c_conn_t));
    if (!tls_conns) { perror("calloc"); exit(1); }

    tls_listen_fd = create_listener(port);
    tls_epfd = epoll_create1(0);
    if (tls_epfd < 0) { perror("epoll_create1"); exit(1); }

    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = tls_listen_fd;
    epoll_ctl(tls_epfd, EPOLL_CTL_ADD, tls_listen_fd, &ev);

    struct epoll_event events[MAX_EVENTS];
    uint8_t *rx_turn = (uint8_t *)malloc(MAX_PARTIAL_RX + READ_BUF_SIZE);
    uint8_t *tx_buf = (uint8_t *)malloc(MAX_PARTIAL_RX + WRITE_BUF_SIZE);
    const uint8_t hello_body[] = "Hello, World!";
    const uint8_t not_found_body[] = "Not Found";

    update_clock_and_date();
    tls_last_sweep_ms = tls_now_ms;
    printf("bare-C control server listening on port %d\n", port);
    fflush(stdout);

    for (;;) {
        int nfds = epoll_wait(tls_epfd, events, MAX_EVENTS, 100);
        update_clock_and_date();
        if (nfds < 0) {
            if (errno == EINTR) nfds = 0;
            else { perror("epoll_wait"); break; }
        }

        for (int i = 0; i < nfds; i++) {
            int fd = events[i].data.fd;
            uint32_t rev = events[i].events;

            if (fd == tls_listen_fd) {
                for (;;) {
                    struct sockaddr_in caddr;
                    socklen_t clen = sizeof(caddr);
                    int cfd = accept4(tls_listen_fd, (struct sockaddr *)&caddr, &clen, SOCK_NONBLOCK);
                    if (cfd < 0) break;
                    if (tls_active_conns >= MAX_CONNS || cfd >= MAX_FD) {
                        close(cfd);
                        continue;
                    }
                    int one = 1;
                    setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
                    c_conn_t *c = &tls_conns[cfd];
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
                    c->last_active_ms = tls_now_ms;
                    c->rx_start_ms = 0;
                    tls_active_conns++;
                    if (cfd > tls_max_fd_seen) tls_max_fd_seen = cfd;
                    struct epoll_event cev;
                    cev.events = c->epoll_events;
                    cev.data.fd = cfd;
                    epoll_ctl(tls_epfd, EPOLL_CTL_ADD, cfd, &cev);
                }
                continue;
            }

            if (fd < 0 || fd >= MAX_FD || !tls_conns[fd].active) continue;

            if (rev & EPOLLERR) {
                close_conn_fd(fd);
                continue;
            }
            if (rev & EPOLLOUT) {
                if (flush_pending_tx(fd) < 0) continue;
            }
            if (!(rev & EPOLLIN)) {
                if (rev & (EPOLLHUP | EPOLLRDHUP)) close_conn_fd(fd);
                continue;
            }

            c_conn_t *c = &tls_conns[fd];
            size_t rx_len = 0;
            if (c->partial_rx_len > 0) {
                memcpy(rx_turn, c->partial_rx, c->partial_rx_len);
                rx_len = c->partial_rx_len;
            }

            size_t total_new = 0;
            int read_err = 0;
            for (;;) {
                ssize_t n = recv(fd, rx_turn + rx_len, READ_BUF_SIZE, 0);
                if (n > 0) {
                    rx_len += (size_t)n;
                    total_new += (size_t)n;
                    if (n < READ_BUF_SIZE || rx_len >= MAX_PARTIAL_RX) break;
                    continue;
                }
                if (n == 0) {
                    if (total_new > 0) break;
                    close_conn_fd(fd);
                    read_err = 1;
                    break;
                }
                if (n < 0 && errno == EINTR) continue;
                if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    if (total_new == 0) read_err = 1;
                    break;
                }
                close_conn_fd(fd);
                read_err = 1;
                break;
            }
            if (read_err) continue;

            if (c->partial_rx) {
                free(c->partial_rx);
                c->partial_rx = NULL;
                c->partial_rx_len = 0;
                c->partial_rx_cap = 0;
            }
            c->last_active_ms = tls_now_ms;

            size_t cursor = 0;
            size_t tx_len = 0;
            int close_conn = 0;

            while (cursor < rx_len) {
                const char *method = NULL, *path = NULL;
                size_t method_len = 0, path_len = 0;
                int minor_version = 1;
                struct phr_header headers[64];
                size_t num_headers = 64;

                size_t rem_len = rx_len - cursor;
                size_t scan_len = rem_len > (MAX_HEADER_SIZE + 1) ? (MAX_HEADER_SIZE + 1) : rem_len;
                int pret = phr_parse_request((const char *)(rx_turn + cursor),
                                             scan_len,
                                             &method, &method_len,
                                             &path, &path_len,
                                             &minor_version,
                                             headers, &num_headers, 0);
                if (pret == -2) {
                    if (rem_len > MAX_HEADER_SIZE) {
                        tx_len += build_response(tx_buf + tx_len, 431, "Request Header Fields Too Large",
                                                 "text/plain", (const uint8_t *)"Request Header Fields Too Large", 31, 0);
                        close_conn = 1;
                    } else if (scan_len >= 4 && memmem(rx_turn + cursor, scan_len, "\r\n\r\n", 4) != NULL) {
                        tx_len += build_response(tx_buf + tx_len, 400, "Bad Request",
                                                 "text/plain", (const uint8_t *)"Bad Request", 11, 0);
                        close_conn = 1;
                    }
                    break;
                }
                if (pret < 0 || pret > MAX_HEADER_SIZE) {
                    if (pret > MAX_HEADER_SIZE || rem_len > MAX_HEADER_SIZE) {
                        tx_len += build_response(tx_buf + tx_len, 431, "Request Header Fields Too Large",
                                                 "text/plain", (const uint8_t *)"Request Header Fields Too Large", 31, 0);
                    } else {
                        tx_len += build_response(tx_buf + tx_len, 400, "Bad Request",
                                                 "text/plain", (const uint8_t *)"Bad Request", 11, 0);
                    }
                    close_conn = 1;
                    break;
                }

                int keep_alive = (minor_version >= 1) ? 1 : 0;
                size_t content_len = 0;
                int has_cl = 0;
                int err_code = 0;

                for (size_t h = 0; h < num_headers; h++) {
                    if (headers[h].name == NULL) continue;
                    if (headers[h].name_len == 17 &&
                        strncasecmp(headers[h].name, "Transfer-Encoding", 17) == 0) {
                        err_code = 501;
                        break;
                    } else if (headers[h].name_len == 14 &&
                               strncasecmp(headers[h].name, "Content-Length", 14) == 0) {
                        size_t parsed_cl = 0;
                        if (parse_strict_content_length(headers[h].value, headers[h].value_len, &parsed_cl) < 0 ||
                            (has_cl && parsed_cl != content_len)) {
                            err_code = 400;
                            break;
                        }
                        has_cl = 1;
                        content_len = parsed_cl;
                        if (content_len > MAX_BODY_SIZE) {
                            err_code = 413;
                            break;
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

                if (err_code != 0) {
                    if (err_code == 413) {
                        tx_len += build_response(tx_buf + tx_len, 413, "Payload Too Large",
                                                 "text/plain", (const uint8_t *)"Payload Too Large", 17, 0);
                    } else if (err_code == 501) {
                        tx_len += build_response(tx_buf + tx_len, 501, "Not Implemented",
                                                 "text/plain", (const uint8_t *)"Not Implemented", 15, 0);
                    } else {
                        tx_len += build_response(tx_buf + tx_len, 400, "Bad Request",
                                                 "text/plain", (const uint8_t *)"Bad Request", 11, 0);
                    }
                    close_conn = 1;
                    break;
                }

                size_t total_req = (size_t)pret + content_len;
                if (cursor + total_req > rx_len) break;

                if (method_len == 3 && memcmp(method, "GET", 3) == 0 &&
                    ((path_len == 1 && path[0] == '/') ||
                     (path_len == 10 && memcmp(path, "/plaintext", 10) == 0))) {
                    tx_len += build_response(tx_buf + tx_len, 200, "OK", "text/plain",
                                             hello_body, sizeof(hello_body) - 1, keep_alive);
                } else if (method_len == 4 && memcmp(method, "POST", 4) == 0 &&
                           path_len == 5 && memcmp(path, "/echo", 5) == 0) {
                    tx_len += build_response(tx_buf + tx_len, 200, "OK", "text/plain",
                                             rx_turn + cursor + pret, content_len, keep_alive);
                } else {
                    tx_len += build_response(tx_buf + tx_len, 404, "Not Found", "text/plain",
                                             not_found_body, sizeof(not_found_body) - 1, keep_alive);
                }

                cursor += total_req;
                if (!keep_alive) {
                    close_conn = 1;
                    break;
                }
            }

            if (tx_len > 0) {
                send_or_queue(fd, tx_buf, tx_len);
            }

            if (!tls_conns[fd].active) continue;
            if (close_conn) {
                if (c->pending_tx && c->pending_tx_off < c->pending_tx_len) {
                    c->close_after_tx = 1;
                } else {
                    close_conn_fd(fd);
                }
            } else if (cursor < rx_len) {
                size_t rem = rx_len - cursor;
                if (rem > MAX_PARTIAL_RX) {
                    close_conn_fd(fd);
                    continue;
                }
                if (rem > c->partial_rx_cap) {
                    size_t new_cap = c->partial_rx_cap ? c->partial_rx_cap : 1024;
                    while (new_cap < rem) new_cap *= 2;
                    if (new_cap > MAX_PARTIAL_RX) new_cap = MAX_PARTIAL_RX;
                    uint8_t *nb = (uint8_t *)realloc(c->partial_rx, new_cap);
                    if (!nb) { close_conn_fd(fd); continue; }
                    c->partial_rx = nb;
                    c->partial_rx_cap = new_cap;
                }
                memcpy(c->partial_rx, rx_turn + cursor, rem);
                c->partial_rx_len = rem;
                if (cursor > 0 || c->rx_start_ms == 0) {
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
        }

        if (nfds == 0 || (tls_now_ms - tls_last_sweep_ms >= 50)) {
            tls_last_sweep_ms = tls_now_ms;
            sweep_timeouts();
        }
    }
    return 0;
}
