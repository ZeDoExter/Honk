#define _GNU_SOURCE
#include "goose.h"
#include "picohttpparser.h"

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
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_EVENTS 256
#define MAX_CONNS 4096
#define CONN_BUF_CAP 16384

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

/* Matches Goose `struct ConnBuf { fd: i32, rx: u8[..16384] }`
   Note: for u8[..16384], 16384 fits in u16 (<= 65535), so length field is uint16_t! */
typedef struct {
    int32_t fd_g;
    uint16_t rx_len_g;
    uint8_t rx_data_g[16384];
} ConnBuf_g;
#pragma pack(pop)

typedef struct {
    int fd;
    size_t rx_len;
    uint8_t rx_buf[CONN_BUF_CAP];
} shim_conn_t;

/* Per-worker thread-local state (Amendment B: zero mutable shared globals) */
static __thread int tls_listen_fd = -1;
static __thread int tls_epfd = -1;
static __thread time_t tls_last_sec = 0;
static __thread char tls_date_str[32] = "Thu, 01 Jan 1970 00:00:00 GMT";
static __thread shim_conn_t *tls_conns = NULL;
static __thread struct epoll_event tls_events[MAX_EVENTS];

static void update_tls_date(void) {
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
    if (fd >= 0 && fd < MAX_CONNS) {
        epoll_ctl(tls_epfd, EPOLL_CTL_DEL, fd, NULL);
        close(fd);
        if (tls_conns) {
            tls_conns[fd].fd = -1;
            tls_conns[fd].rx_len = 0;
        }
    }
}

int32_t honk_worker_init(int32_t port) {
    signal(SIGPIPE, SIG_IGN);
    if (!tls_conns) {
        tls_conns = (shim_conn_t *)calloc(MAX_CONNS, sizeof(shim_conn_t));
        if (!tls_conns) return -1;
        for (int i = 0; i < MAX_CONNS; i++) tls_conns[i].fd = -1;
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
    update_tls_date();
    return 0;
}

int32_t honk_wait(int32_t *out_fds, uint8_t *out_date29, int32_t timeout_ms) {
    int nfds = epoll_wait(tls_epfd, tls_events, MAX_EVENTS, (int)timeout_ms);
    if (nfds < 0) {
        if (errno == EINTR) return 0;
        return -1;
    }
    update_tls_date();
    memcpy(out_date29, tls_date_str, 29);

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
                if (cfd >= MAX_CONNS) {
                    close(cfd);
                    continue;
                }
                int one = 1;
                setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
                tls_conns[cfd].fd = cfd;
                tls_conns[cfd].rx_len = 0;
                struct epoll_event cev;
                cev.events = EPOLLIN | EPOLLRDHUP;
                cev.data.fd = cfd;
                epoll_ctl(tls_epfd, EPOLL_CTL_ADD, cfd, &cev);
            }
            continue;
        }
        if (ev & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) {
            close_conn_fd(fd);
            continue;
        }
        out_fds[ready_count++] = (int32_t)fd;
    }
    return ready_count;
}

/* Design (i): recv directly into a Goose fixed-capacity ConnBuf { fd: i32, rx: u8[..16384] } */
int32_t honk_d1_read(int32_t fd, ConnBuf_g *cb) {
    cb->fd_g = fd;
    size_t cur = cb->rx_len_g;
    if (cur >= 16384) return -1;
    ssize_t n = recv(fd, cb->rx_data_g + cur, 16384 - cur, 0);
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        close_conn_fd(fd);
        cb->rx_len_g = 0;
        return -1;
    }
    cb->rx_len_g = (uint16_t)(cur + (size_t)n);
    return (int32_t)cb->rx_len_g;
}

/* Design (ii): recv into C per-connection buffer, then copy into Goose rx_buf: u8[>..]& */
int32_t honk_d2_read(int32_t fd, gs_rref rx_buf) {
    shim_conn_t *c = &tls_conns[fd];
    ssize_t n = recv(fd, c->rx_buf + c->rx_len, CONN_BUF_CAP - c->rx_len, 0);
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        close_conn_fd(fd);
        return -1;
    }
    c->rx_len += (size_t)n;
    gs_bld_append(rx_buf, c->rx_buf, (int64_t)c->rx_len);
    return (int32_t)c->rx_len;
}

void honk_d2_consume(int32_t fd, int32_t consumed, int32_t close_conn) {
    if (close_conn) {
        close_conn_fd(fd);
        return;
    }
    shim_conn_t *c = &tls_conns[fd];
    if ((size_t)consumed >= c->rx_len) {
        c->rx_len = 0;
    } else if (consumed > 0) {
        size_t rem = c->rx_len - (size_t)consumed;
        memmove(c->rx_buf, c->rx_buf + consumed, rem);
        c->rx_len = rem;
    }
}

/* Design (iii): recv directly into Goose rx_buf.stk->top (zero-copy fast path),
   with C partial-tail stash across epoll events when a request is split across recv() calls */
int32_t honk_d3_read(int32_t fd, gs_rref rx_buf) {
    shim_conn_t *c = &tls_conns[fd];
    if (c->rx_len > 0) {
        gs_bld_append(rx_buf, c->rx_buf, (int64_t)c->rx_len);
        c->rx_len = 0;
    }
    ssize_t n = recv(fd, rx_buf.stk->top, 65536, 0);
    if (n <= 0) {
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return (int32_t)rx_buf.hdr->len;
        close_conn_fd(fd);
        return -1;
    }
    rx_buf.stk->top += n;
    rx_buf.hdr->len += n;
    return (int32_t)rx_buf.hdr->len;
}

void honk_d3_StashTail(int32_t fd, sl_u8_shim unparsed_tail, int32_t close_conn) {
    if (close_conn) {
        close_conn_fd(fd);
        return;
    }
    shim_conn_t *c = &tls_conns[fd];
    if (unparsed_tail.len > 0 && (size_t)unparsed_tail.len <= CONN_BUF_CAP) {
        memcpy(c->rx_buf, unparsed_tail.data, (size_t)unparsed_tail.len);
        c->rx_len = (size_t)unparsed_tail.len;
    } else {
        c->rx_len = 0;
    }
}

/* Parse one HTTP request at the start of `buf` via picohttpparser.
   Returns:
     > 0 : total request bytes consumed (headers + Content-Length body)
     -2  : incomplete request (need more bytes)
     -1  : malformed request */
int32_t honk_parse_req(sl_u8_shim buf, RawReq_g *out) {
    if (buf.len <= 0) return -2;
    const char *method = NULL, *path = NULL;
    size_t method_len = 0, path_len = 0;
    int minor_version = 1;
    struct phr_header headers[32];
    size_t num_headers = 32;

    int pret = phr_parse_request((const char *)buf.data, (size_t)buf.len,
                                 &method, &method_len,
                                 &path, &path_len,
                                 &minor_version,
                                 headers, &num_headers, 0);
    if (pret == -2) return -2;
    if (pret < 0) return -1;

    int keep_alive = (minor_version >= 1) ? 1 : 0;
    size_t content_len = 0;
    for (size_t h = 0; h < num_headers; h++) {
        if (headers[h].name_len == 14 &&
            strncasecmp(headers[h].name, "Content-Length", 14) == 0) {
            content_len = (size_t)strtoull(headers[h].value, NULL, 10);
        } else if (headers[h].name_len == 10 &&
                   strncasecmp(headers[h].name, "Connection", 10) == 0) {
            if (headers[h].value_len >= 5 &&
                strncasecmp(headers[h].value, "close", 5) == 0) {
                keep_alive = 0;
            } else if (headers[h].value_len >= 10 &&
                       strncasecmp(headers[h].value, "keep-alive", 10) == 0) {
                keep_alive = 1;
            }
        }
    }

    size_t total_req = (size_t)pret + content_len;
    if (total_req > (size_t)buf.len) return -2;

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

int32_t honk_send(int32_t fd, sl_u8_shim data) {
    if (data.len <= 0) return 0;
    ssize_t sent = send(fd, data.data, (size_t)data.len, MSG_NOSIGNAL);
    return (int32_t)sent;
}

void honk_close(int32_t fd) {
    close_conn_fd(fd);
}
