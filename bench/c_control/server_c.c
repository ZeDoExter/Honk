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
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "../../src/shim/picohttpparser.h"

#define MAX_EVENTS 256
#define MAX_CONNS 4096
#define READ_BUF_SIZE 65536
#define WRITE_BUF_SIZE 65536

typedef struct {
    int fd;
    size_t rx_len;
    uint8_t rx_buf[16384];
} c_conn_t;

static __thread time_t tls_last_sec = 0;
static __thread char tls_date_str[32] = "Thu, 01 Jan 1970 00:00:00 GMT";
static __thread c_conn_t *tls_conns = NULL;

static void update_date_cache(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    if (ts.tv_sec != tls_last_sec) {
        tls_last_sec = ts.tv_sec;
        struct tm tm_val;
        gmtime_r(&tls_last_sec, &tm_val);
        strftime(tls_date_str, sizeof(tls_date_str), "%a, %d %b %Y %H:%M:%S GMT", &tm_val);
    }
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
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

    tls_conns = (c_conn_t *)calloc(MAX_CONNS, sizeof(c_conn_t));
    for (int i = 0; i < MAX_CONNS; i++) tls_conns[i].fd = -1;

    int listen_fd = create_listener(port);
    int epfd = epoll_create1(0);
    if (epfd < 0) { perror("epoll_create1"); exit(1); }

    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = listen_fd;
    epoll_ctl(epfd, EPOLL_CTL_ADD, listen_fd, &ev);

    struct epoll_event events[MAX_EVENTS];
    uint8_t tx_buf[WRITE_BUF_SIZE];
    const uint8_t hello_body[] = "Hello, World!";
    const uint8_t not_found_body[] = "Not Found";

    update_date_cache();
    printf("bare-C control server listening on port %d\n", port);
    fflush(stdout);

    for (;;) {
        int nfds = epoll_wait(epfd, events, MAX_EVENTS, 500);
        if (nfds < 0) {
            if (errno == EINTR) continue;
            perror("epoll_wait");
            break;
        }
        update_date_cache();

        for (int i = 0; i < nfds; i++) {
            int fd = events[i].data.fd;
            if (fd == listen_fd) {
                for (;;) {
                    struct sockaddr_in caddr;
                    socklen_t clen = sizeof(caddr);
                    int cfd = accept4(listen_fd, (struct sockaddr *)&caddr, &clen, SOCK_NONBLOCK);
                    if (cfd < 0) {
                        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                        break;
                    }
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
                    epoll_ctl(epfd, EPOLL_CTL_ADD, cfd, &cev);
                }
                continue;
            }

            if (events[i].events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) {
                epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL);
                close(fd);
                tls_conns[fd].fd = -1;
                tls_conns[fd].rx_len = 0;
                continue;
            }

            c_conn_t *c = &tls_conns[fd];
            ssize_t n = recv(fd, c->rx_buf + c->rx_len, sizeof(c->rx_buf) - c->rx_len, 0);
            if (n <= 0) {
                if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
                epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL);
                close(fd);
                c->fd = -1;
                c->rx_len = 0;
                continue;
            }
            c->rx_len += (size_t)n;

            size_t cursor = 0;
            size_t tx_len = 0;
            int close_conn = 0;

            while (cursor < c->rx_len) {
                const char *method = NULL, *path = NULL;
                size_t method_len = 0, path_len = 0;
                int minor_version = 1;
                struct phr_header headers[32];
                size_t num_headers = 32;

                int pret = phr_parse_request((const char *)(c->rx_buf + cursor),
                                             c->rx_len - cursor,
                                             &method, &method_len,
                                             &path, &path_len,
                                             &minor_version,
                                             headers, &num_headers, 0);
                if (pret == -2) break;
                if (pret < 0) {
                    close_conn = 1;
                    break;
                }

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
                if (cursor + total_req > c->rx_len) break;

                if (method_len == 3 && memcmp(method, "GET", 3) == 0 &&
                    ((path_len == 1 && path[0] == '/') ||
                     (path_len == 10 && memcmp(path, "/plaintext", 10) == 0))) {
                    tx_len += build_response(tx_buf + tx_len, 200, "OK", "text/plain",
                                             hello_body, sizeof(hello_body) - 1, keep_alive);
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
                ssize_t sent = send(fd, tx_buf, tx_len, MSG_NOSIGNAL);
                (void)sent;
            }

            if (close_conn) {
                epoll_ctl(epfd, EPOLL_CTL_DEL, fd, NULL);
                close(fd);
                c->fd = -1;
                c->rx_len = 0;
            } else if (cursor == c->rx_len) {
                c->rx_len = 0;
            } else if (cursor > 0) {
                size_t rem = c->rx_len - cursor;
                memmove(c->rx_buf, c->rx_buf + cursor, rem);
                c->rx_len = rem;
            }
        }
    }
    return 0;
}
