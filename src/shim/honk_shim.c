/* honk_shim.c -- C epoll + picohttpparser shim for Honk.
 *
 * Enforces:
 *  - Amendment A / D-003: Design (iii) direct-to-Goose-data-stack recv() fast
 *    path + lazy per-connection partial_rx and pending_tx buffers in C.
 *  - Amendment B / D-004: Zero mutable shared globals; all worker state is
 *    thread-local (__thread).
 *  - Amendment C: split recv(), pipelined requests, partial send() (EAGAIN +
 *    EPOLLOUT), max header size (431), max body size (413), chunked request
 *    decoding + unsupported TE (501), malformed (400), idle & slowloris
 *    timeouts, clean peer close/reset, Content-Length bodies, dynamic
 *    Content-Length, 1 Hz per-worker Date cache.
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
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <limits.h>
#include <stddef.h>
#include <sys/epoll.h>
#include <sys/sendfile.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
/* Forward declarations: these are called before their definitions below;
 * GCC 14+ turns implicit declarations into hard errors. */
int32_t honk_should_stop(void);
#define HONK_MAX_EVENTS       256
#define HONK_MAX_CONNS        4096
#define HONK_MAX_FD           16384
#define HONK_RECV_CHUNK       65536
#define HONK_MAX_WORKERS      64
#define HONK_DRAIN_MS         2000

#define HONK_MAX_HEADER_SIZE    8192
#define HONK_MAX_BODY_SIZE      1048576
#define HONK_MAX_CHUNK_OVERHEAD 16384
#define HONK_MAX_PARTIAL_RX     (HONK_MAX_HEADER_SIZE + HONK_MAX_BODY_SIZE + HONK_MAX_CHUNK_OVERHEAD)
#define HONK_MAX_PENDING_TX     1048576
#define HONK_WS_MAX_MSG         1048576

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
    char peer_ip_str[46];   /* "127.0.0.1", "::1", "2001:db8::1", or "unix"; "" = unknown */
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
    /* Non-blocking WebSockets: Goose slot index (-1 = plain HTTP) plus lazy
     * message/aux buffers (NULL when idle; freed exactly once on close). */
    int32_t ws_slot;
    int32_t _ws_pad;
    uint8_t *ws_msg;
    size_t ws_msg_len;
    size_t ws_msg_cap;
    uint8_t *ws_aux;
    size_t ws_aux_len;
} honk_conn_t;

typedef struct {
    uint64_t key;
    int64_t reset_ms;
    int32_t count;
    int32_t _pad;
} honk_rl_slot_t;

#define HONK_RL_SLOTS 2048

/* Per-worker thread-local state (Amendment B: zero mutable shared globals) */
static __thread int tls_listen_fd = -1;
static __thread int tls_epfd = -1;
static __thread time_t tls_last_sec = 0;
static __thread char tls_date_str[32] = "Thu, 01 Jan 1970 00:00:00 GMT";
static __thread honk_conn_t *tls_conns = NULL;
static __thread honk_rl_slot_t *tls_rl_table = NULL;
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
static __thread int32_t tls_worker_id = 0;
static __thread int32_t tls_should_stop = 0;

/* Process-wide async-signal-safe stop flags & pre-epoll fork supervision. */
static volatile sig_atomic_t g_sigint_count = 0;
static volatile sig_atomic_t g_sigterm_flag = 0;
static atomic_int g_sig_installed = 0;
static atomic_int g_open_dbs = 0;

static int32_t g_fork_initialized = 0;
static int32_t g_is_fork_parent = 0;
static int32_t g_num_children = 0;
static pid_t g_parent_pid = 0;
static pid_t g_child_pids[HONK_MAX_WORKERS];
/* Explicit bind spec from honk_set_bind ("", $HONK_BIND fallback, or "::"). */
static char g_bind_spec[256] = {0};
/* Pre-fork Unix listener: bound once in the parent, accept4()ed by all. */
static char g_unix_path[108] = {0};
static int g_unix_listen_fd = -1;
static pid_t g_unix_owner_pid = 0;

static void honk_sig_handler(int sig) {
    if (sig == SIGINT) {
        if (g_sigint_count < 2) g_sigint_count++;
    } else {
        g_sigterm_flag = 1;
    }
}

static void install_signal_handlers(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_sig_installed, &expected, 1)) {
        return;
    }
    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = honk_sig_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0; /* no SA_RESTART: wake epoll_wait with EINTR immediately */
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

void honk_note_db_open(int32_t delta) {
    atomic_fetch_add(&g_open_dbs, (int)delta);
}

static int64_t monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

int64_t honk_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

int64_t honk_unix_sec(void) {
    return (int64_t)time(NULL);
}
/* Single-shot log line to stdout (NDJSON access logs): one write() per call
 * in the common case so forked workers sharing stdout never interleave. */
void honk_log_line(sl_u8_shim data) {
    if (data.len <= 0) return;
    size_t off = 0;
    while (off < (size_t)data.len) {
        ssize_t n = write(STDOUT_FILENO, data.data + off, (size_t)data.len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        return;
    }
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
    if (c->ws_msg) {
        free(c->ws_msg);
        c->ws_msg = NULL;
    }
    c->ws_msg_len = 0;
    c->ws_msg_cap = 0;
    if (c->ws_aux) {
        free(c->ws_aux);
        c->ws_aux = NULL;
    }
    c->ws_aux_len = 0;
    c->ws_slot = -1;
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

static const char *honk_resolve_bind(void) {
    if (g_bind_spec[0] != '\0') return g_bind_spec;
    const char *env = getenv("HONK_BIND");
    if (env && env[0] != '\0') return env;
    return "::";
}

void honk_set_bind(sl_u8_shim spec) {
    size_t n = (size_t)spec.len < sizeof(g_bind_spec) - 1
        ? (size_t)spec.len : sizeof(g_bind_spec) - 1;
    memcpy(g_bind_spec, spec.data, n);
    g_bind_spec[n] = '\0';
}

/* Bind+listen a Unix socket path (stale S_ISSOCK files unlinked, regular
 * files never touched; 0660 perms). Idempotent for the same live path. */
static int honk_unix_bind_inner(const char *path) {
    if (!path || !path[0]) return -1;
    size_t plen = strlen(path);
    if (plen >= sizeof(((struct sockaddr_un *)0)->sun_path)) return -1;
    if (g_unix_listen_fd >= 0 && strcmp(g_unix_path, path) == 0) return 0;
    struct stat st;
    if (lstat(path, &st) == 0) {
        if (!S_ISSOCK(st.st_mode)) return -1;
        unlink(path);
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path, plen + 1);
    socklen_t alen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + plen + 1);
    if (bind(fd, (struct sockaddr *)&addr, alen) < 0) {
        close(fd);
        return -1;
    }
    /* NOTE: fchmod() on the fd is a no-op for socket files on Linux; the
     * path-based chmod() below is what actually sets 0660. */
    if (chmod(path, 0660) < 0 || listen(fd, 4096) < 0) {
        close(fd);
        unlink(path);
        return -1;
    }
    if (g_unix_listen_fd >= 0) close(g_unix_listen_fd);
    g_unix_listen_fd = fd;
    snprintf(g_unix_path, sizeof(g_unix_path), "%s", path);
    g_unix_owner_pid = getpid();
    return 0;
}

int32_t honk_unix_listen(sl_u8_shim path) {
    char buf[108];
    if (path.len <= 0 || path.len >= (int64_t)sizeof(buf)) return -1;
    memcpy(buf, path.data, (size_t)path.len);
    buf[path.len] = '\0';
    return (int32_t)honk_unix_bind_inner(buf);
}

/* Create a bound+listening TCP fd for a spec: "0.0.0.0"/"127.0.0.1" (v4),
 * "::"/"::1"/v6-literal (v6, dual-stack unless "v6only:" prefixed).
 * Wildcard "::" falls back to v4 on kernels without AF_INET6. */
static int make_tcp_listener(const char *spec, int port) {
    int v6only = 0;
    if (strncmp(spec, "v6only:", 7) == 0) {
        v6only = 1;
        spec += 7;
    }
    int is_v6 = (strchr(spec, ':') != NULL);
    if (!is_v6) {
        struct in_addr a4;
        if (inet_pton(AF_INET, spec, &a4) != 1) return -1;
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
        if (fd < 0) return -1;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr = a4;
        addr.sin_port = htons((uint16_t)port);
        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
            listen(fd, 4096) < 0) {
            close(fd);
            return -1;
        }
        return fd;
    }
    struct in6_addr a6;
    if (inet_pton(AF_INET6, spec, &a6) != 1) return -1;
    int fd = socket(AF_INET6, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (fd < 0) {
        if ((errno == EAFNOSUPPORT || errno == EPROTONOSUPPORT) &&
            IN6_IS_ADDR_UNSPECIFIED(&a6)) {
            return make_tcp_listener("0.0.0.0", port);
        }
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    int off = v6only ? 1 : 0;
    if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof(off)) < 0) {
        close(fd);
        return -1;
    }
    struct sockaddr_in6 addr6;
    memset(&addr6, 0, sizeof(addr6));
    addr6.sin6_family = AF_INET6;
    addr6.sin6_addr = a6;
    addr6.sin6_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr6, sizeof(addr6)) < 0 ||
        listen(fd, 4096) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int32_t honk_worker_init(int32_t port) {
    install_signal_handlers();
    tls_should_stop = 0;
    if (!tls_conns) {
        /* calloc zeroes all slots lazily without faulting untouched pages */
        tls_conns = (honk_conn_t *)calloc(HONK_MAX_FD, sizeof(honk_conn_t));
        if (!tls_conns) return -1;
    }

    /* Bind spec: explicit honk_set_bind, else $HONK_BIND, else dual-stack "::".
     * Unix sockets reuse the pre-fork listener shared by all workers. */
    const char *spec = honk_resolve_bind();
    int fd = -1;
    if (strncmp(spec, "unix:", 5) == 0) {
        if (g_unix_listen_fd < 0 && honk_unix_bind_inner(spec + 5) < 0) {
            return -1;
        }
        fd = g_unix_listen_fd;
    } else {
        fd = make_tcp_listener(spec, (int)port);
        if (fd < 0) return -1;
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
    if (g_is_fork_parent && g_num_children > 0) {
        for (int32_t i = 0; i < g_num_children; i++) {
            if (g_child_pids[i] > 0) {
                kill(g_child_pids[i], SIGTERM);
            }
        }
    }
    /* Unix-socket owner unlinks the path; children inherit the fd and skip.
     * Accepted connections survive (fd-based); only new connects stop. */
    if (g_unix_path[0] != '\0' && getpid() == g_unix_owner_pid) {
        unlink(g_unix_path);
        g_unix_path[0] = '\0';
    }
    if (tls_listen_fd >= 0) {
        if (tls_epfd >= 0) {
            epoll_ctl(tls_epfd, EPOLL_CTL_DEL, tls_listen_fd, NULL);
        }
        close(tls_listen_fd);
        tls_listen_fd = -1;
    }
    if (tls_conns) {
        int draining = 0;
        update_tls_clock_and_date();
        for (int fd = 0; fd <= tls_max_fd_seen; fd++) {
            honk_conn_t *c = &tls_conns[fd];
            if (!c->active) continue;
            int has_tx = (c->pending_tx && c->pending_tx_off < c->pending_tx_len) ||
                         c->sendfile_remain > 0;
            if (has_tx && g_sigint_count < 2 && tls_epfd >= 0) {
                c->close_after_tx = 1;
                mod_conn_epoll(c, EPOLLOUT | EPOLLRDHUP);
                flush_pending_tx(fd);
                if (c->active) draining++;
            } else {
                close_conn_fd(fd);
            }
        }
        if (draining > 0 && tls_epfd >= 0 && g_sigint_count < 2) {
            int64_t deadline_ms = monotonic_ms() + HONK_DRAIN_MS;
            while (tls_active_conns > 0 && g_sigint_count < 2) {
                int64_t rem = deadline_ms - monotonic_ms();
                if (rem <= 0) break;
                int wait_ms = (int)(rem > 50 ? 50 : rem);
                int n = epoll_wait(tls_epfd, tls_events, HONK_MAX_EVENTS, wait_ms);
                update_tls_clock_and_date();
                if (n < 0) {
                    if (errno == EINTR) continue;
                    break;
                }
                for (int i = 0; i < n; i++) {
                    int fd = tls_events[i].data.fd;
                    uint32_t ev = tls_events[i].events;
                    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns[fd].active) continue;
                    if ((ev & EPOLLERR) || ((ev & (EPOLLHUP | EPOLLRDHUP)) && !(ev & EPOLLOUT))) {
                        close_conn_fd(fd);
                    } else {
                        flush_pending_tx(fd);
                    }
                }
            }
        }
        for (int fd = 0; fd <= tls_max_fd_seen; fd++) {
            if (tls_conns[fd].active) {
                close_conn_fd(fd);
            }
        }
        free(tls_conns);
        tls_conns = NULL;
    }
    if (tls_epfd >= 0) {
        close(tls_epfd);
        tls_epfd = -1;
    }
    if (tls_rl_table) {
        free(tls_rl_table);
        tls_rl_table = NULL;
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
                struct sockaddr_storage caddr;
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
                c->peer_ip_str[0] = '\0';
                if (caddr.ss_family == AF_INET) {
                    struct sockaddr_in *a4 = (struct sockaddr_in *)&caddr;
                    inet_ntop(AF_INET, &a4->sin_addr, c->peer_ip_str, sizeof(c->peer_ip_str));
                } else if (caddr.ss_family == AF_INET6) {
                    struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&caddr;
                    if (IN6_IS_ADDR_V4MAPPED(&a6->sin6_addr)) {
                        /* Backward compat: plain dotted IPv4, never ::ffff:a.b.c.d. */
                        inet_ntop(AF_INET, a6->sin6_addr.s6_addr + 12,
                                  c->peer_ip_str, sizeof(c->peer_ip_str));
                    } else {
                        inet_ntop(AF_INET6, &a6->sin6_addr,
                                  c->peer_ip_str, sizeof(c->peer_ip_str));
                    }
                }
                else if (caddr.ss_family == AF_UNIX) {
                    memcpy(c->peer_ip_str, "unix", 5);
                }
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
                c->ws_slot = -1;
                c->ws_msg = NULL;
                c->ws_msg_len = 0;
                c->ws_msg_cap = 0;
                c->ws_aux = NULL;
                c->ws_aux_len = 0;
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
/* Claim fd for non-blocking WebSockets: Goose owns slot SI (its fixed pool),
 * the C conn records it as source of truth (stale Goose slots revalidate). */
void honk_ws_upgrade(int32_t fd, int32_t slot) {
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) return;
    if (slot < 0) return;
    tls_conns[fd].ws_slot = slot;
}

/* Goose slot index for fd, or -1 when the conn is plain HTTP/dead.
 * Doubles as the upgraded check for the serve loop branch. */
int32_t honk_conn_ws_slot(int32_t fd) {
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) return -1;
    return tls_conns[fd].ws_slot;
}

/* Raw non-blocking read for upgraded connections. Appends available bytes to
 * the turn's rx_buf (no partial_rx stash; the caller owns cross-turn state).
 * Returns bytes appended (>0), 0 on EAGAIN (fd stays open), or -1 on
 * EOF/error (connection closed). Caps one turn at 1 MiB (level-triggered
 * epoll re-fires for the rest). */
int32_t honk_ws_poll(int32_t fd, gs_rref rx_buf) {
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) {
        return -1;
    }
    honk_conn_t *c = &tls_conns[fd];
    int64_t total = 0;
    for (;;) {
        ssize_t n = recv(fd, honk_rref_write_ptr(rx_buf), HONK_RECV_CHUNK, 0);
        if (n > 0) {
            honk_rref_commit(rx_buf, (int64_t)n);
            total += (int64_t)n;
            if (n < HONK_RECV_CHUNK || honk_rref_len(rx_buf) >= 1048576) break;
            continue;
        }
        if (n == 0) {
            if (total > 0) break;
            close_conn_fd(fd);
            return -1;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        close_conn_fd(fd);
        return -1;
    }
    if (total > 0) c->last_active_ms = tls_now_ms;
    return (int32_t)total;
}

/* Append frame payload to the assembling message (lazy realloc, 1 MiB cap).
 * Returns the new total, -1 when closed, -2 over cap (caller sends 1009). */
int32_t honk_ws_msg_append(int32_t fd, sl_u8_shim bytes) {
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) return -1;
    honk_conn_t *c = &tls_conns[fd];
    if ((size_t)bytes.len > HONK_WS_MAX_MSG - c->ws_msg_len) return -2;
    size_t need = c->ws_msg_len + (size_t)bytes.len;
    if (need > c->ws_msg_cap) {
        size_t cap = c->ws_msg_cap ? c->ws_msg_cap : 1024;
        while (cap < need) cap *= 2;
        if (cap > HONK_WS_MAX_MSG) cap = HONK_WS_MAX_MSG;
        uint8_t *nb = (uint8_t *)realloc(c->ws_msg, cap);
        if (!nb) return -1;
        c->ws_msg = nb;
        c->ws_msg_cap = cap;
    }
    memcpy(c->ws_msg + c->ws_msg_len, bytes.data, (size_t)bytes.len);
    c->ws_msg_len = need;
    return (int32_t)need;
}

/* Move the assembled message into the turn buffer and reset (keeps the
 * allocation for reuse; freed on close). Returns bytes moved, -1 if closed. */
int64_t honk_ws_msg_take(int32_t fd, gs_rref out) {
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) return -1;
    honk_conn_t *c = &tls_conns[fd];
    if (c->ws_msg_len > 0) {
        honk_rref_append(out, c->ws_msg, (int64_t)c->ws_msg_len);
    }
    int64_t n = (int64_t)c->ws_msg_len;
    c->ws_msg_len = 0;
    return n;
}

/* Store the immutable handshake blob (path bytes ++ user bytes, exact-size).
 * Returns 0, or -1 when closed. */
int32_t honk_ws_aux_set(int32_t fd, sl_u8_shim blob) {
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) return -1;
    honk_conn_t *c = &tls_conns[fd];
    if (c->ws_aux) {
        free(c->ws_aux);
        c->ws_aux = NULL;
        c->ws_aux_len = 0;
    }
    if (blob.len <= 0) return 0;
    uint8_t *nb = (uint8_t *)malloc((size_t)blob.len);
    if (!nb) return -1;
    memcpy(nb, blob.data, (size_t)blob.len);
    c->ws_aux = nb;
    c->ws_aux_len = (size_t)blob.len;
    return 0;
}

/* Copy the handshake blob into the turn buffer. Returns bytes, -1 if closed. */
int64_t honk_ws_aux_get(int32_t fd, gs_rref out) {
    if (fd < 0 || fd >= HONK_MAX_FD || !tls_conns || !tls_conns[fd].active) return -1;
    honk_conn_t *c = &tls_conns[fd];
    if (c->ws_aux_len > 0) {
        honk_rref_append(out, c->ws_aux, (int64_t)c->ws_aux_len);
    }
    return (int64_t)c->ws_aux_len;
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

static int is_exact_token_ci(const char *val, size_t len, const char *tok, size_t tok_len) {
    size_t s = 0;
    while (s < len && (val[s] == ' ' || val[s] == '\t')) s++;
    while (len > s && (val[len - 1] == ' ' || val[len - 1] == '\t')) len--;
    return (len - s == tok_len) && (strncasecmp(val + s, tok, tok_len) == 0);
}

/* Two-pass RFC 9112 §7.1 chunked body decoder:
 *  - Pass 1 scans framing without mutating `base`, so incomplete (-2) split
 *    recvs preserve raw wire bytes in partial_rx and pipelined bytes past the
 *    terminal chunk are never touched.
 *  - Pass 2 compacts chunk payloads in-place into base[0..*out_decoded_len]. */
static int decode_chunked_body(uint8_t *base, size_t avail,
                               size_t *out_decoded_len, size_t *out_wire_len) {
    size_t pos = 0;
    size_t decoded_total = 0;

    for (;;) {
        if (pos - decoded_total > HONK_MAX_CHUNK_OVERHEAD) return -400;
        if (pos == avail) return -2;

        uint64_t chunk_sz = 0;
        int hex_digits = 0;
        while (pos < avail) {
            uint8_t ch = base[pos];
            int hv = -1;
            if (ch >= '0' && ch <= '9') hv = ch - '0';
            else if (ch >= 'a' && ch <= 'f') hv = (ch - 'a') + 10;
            else if (ch >= 'A' && ch <= 'F') hv = (ch - 'A') + 10;
            if (hv < 0) break;
            if (hex_digits >= 16) return -400;
            chunk_sz = (chunk_sz << 4) | (uint64_t)hv;
            hex_digits++;
            pos++;
            if (chunk_sz > HONK_MAX_BODY_SIZE ||
                decoded_total + (size_t)chunk_sz > HONK_MAX_BODY_SIZE) {
                return -413;
            }
        }
        if (pos == avail) return -2;
        if (hex_digits == 0) return -400;

        uint8_t sep = base[pos];
        if (sep != '\r' && sep != ';' && sep != ' ' && sep != '\t') {
            return -400;
        }
        while (pos < avail && base[pos] != '\r') {
            if (base[pos] == '\n') return -400;
            pos++;
            if (pos - decoded_total > HONK_MAX_CHUNK_OVERHEAD) return -400;
        }
        if (pos + 1 >= avail) return -2;
        if (base[pos + 1] != '\n') return -400;
        pos += 2;

        if (chunk_sz == 0) {
            /* Consume optional trailer lines up to the terminating CRLF. */
            for (;;) {
                if (pos - decoded_total > HONK_MAX_CHUNK_OVERHEAD) return -400;
                if (pos + 1 >= avail) {
                    if (pos < avail && base[pos] == '\n') return -400;
                    return -2;
                }
                if (base[pos] == '\r' && base[pos + 1] == '\n') {
                    pos += 2;
                    goto scan_complete;
                }
                if (base[pos] == '\r' || base[pos] == '\n') return -400;
                while (pos < avail && base[pos] != '\r') {
                    if (base[pos] == '\n') return -400;
                    pos++;
                    if (pos - decoded_total > HONK_MAX_CHUNK_OVERHEAD) return -400;
                }
                if (pos + 1 >= avail) return -2;
                if (base[pos + 1] != '\n') return -400;
                pos += 2;
            }
        }

        size_t csz = (size_t)chunk_sz;
        if (avail - pos < csz + 2) {
            if (avail - pos > csz && base[pos + csz] != '\r') return -400;
            return -2;
        }
        if (base[pos + csz] != '\r' || base[pos + csz + 1] != '\n') {
            return -400;
        }
        decoded_total += csz;
        pos += csz + 2;
    }

scan_complete:;
    size_t wire_end = pos;
    size_t src = 0;
    size_t dst = 0;
    while (src < wire_end) {
        size_t csz = 0;
        while (src < wire_end) {
            uint8_t ch = base[src];
            size_t hv;
            if (ch >= '0' && ch <= '9') hv = (size_t)(ch - '0');
            else if (ch >= 'a' && ch <= 'f') hv = (size_t)(ch - 'a') + 10;
            else if (ch >= 'A' && ch <= 'F') hv = (size_t)(ch - 'A') + 10;
            else break;
            csz = (csz << 4) | hv;
            src++;
        }
        while (base[src] != '\r') src++;
        src += 2;
        if (csz == 0) break;
        if (dst != src) {
            memmove(base + dst, base + src, csz);
        }
        dst += csz;
        src += csz + 2;
    }
    *out_decoded_len = dst;
    *out_wire_len = wire_end;
    return 0;
}

/* Parse one HTTP request at the start of `buf` via picohttpparser.
 * Returns:
 *   > 0   : total wire bytes consumed (headers + Content-Length or chunked body)
 *   -2    : incomplete request (headers <= 8192 and body <= 1048576, need more bytes)
 *   -400  : malformed request or CL+TE smuggling attempt (400 Bad Request)
 *   -413  : body > HONK_MAX_BODY_SIZE (413 Payload Too Large)
 *   -431  : header size > HONK_MAX_HEADER_SIZE (431 Request Header Fields Too Large)
 *   -501  : unsupported Transfer-Encoding (501 Not Implemented)
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
    int has_te = 0;
    int is_chunked = 0;

    for (size_t h = 0; h < num_headers; h++) {
        if (headers[h].name == NULL) continue; /* multiline continuation */
        if (headers[h].name_len == 17 &&
            strncasecmp(headers[h].name, "Transfer-Encoding", 17) == 0) {
            if (has_te) return -400;
            has_te = 1;
            if (is_exact_token_ci(headers[h].value, headers[h].value_len, "chunked", 7)) {
                is_chunked = 1;
            } else {
                return -501;
            }
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

    /* RFC 9112 §6.1: reject requests carrying both Transfer-Encoding and Content-Length. */
    if (has_te && has_content_len) {
        return -400;
    }

    const char *base = (const char *)buf.data;
    int32_t m_off = (int32_t)(method - base);
    int32_t p_off = (int32_t)(path - base);

    if (is_chunked) {
        size_t decoded_len = 0;
        size_t wire_len = 0;
        int cret = decode_chunked_body(buf.data + pret, (size_t)buf.len - (size_t)pret,
                                       &decoded_len, &wire_len);
        if (cret < 0) return (int32_t)cret;
        size_t total_wire = (size_t)pret + wire_len;
        out->method_off_g = m_off;
        out->method_end_g = m_off + (int32_t)method_len;
        out->path_off_g = p_off;
        out->path_end_g = p_off + (int32_t)path_len;
        out->body_off_g = (int32_t)pret;
        out->body_end_g = (int32_t)((size_t)pret + decoded_len);
        out->consumed_g = (int32_t)total_wire;
        out->keep_alive_g = keep_alive;
        return (int32_t)total_wire;
    }

    size_t total_req = (size_t)pret + content_len;
    if (total_req > (size_t)buf.len) {
        return -2;
    }

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
 * validated by the caller (relative, decoded, no NUL/backslash/.. segments);
 * the checks below re-enforce that across FFI so a future caller cannot
 * regress into traversal. O_NOFOLLOW rejects symlinks; fstat requires a
 * regular file. Returns the fd (>= 0, owned by the caller) or -1.
 */
int32_t honk_file_open(sl_u8_shim root, sl_u8_shim rel) {
    if (root.len <= 0 || rel.len <= 0) return -1;
    if (root.len + rel.len + 2 > 4096) return -1;
    /* Defensive re-checks (Goose validates first; never trust across FFI). */
    for (int64_t i = 0; i < rel.len; i++) {
        if (rel.data[i] == '\0' || rel.data[i] == '\\') return -1;
    }
    if (rel.data[0] == '/') return -1;
    /* Reject `..` as a full segment (standalone, leading, middle, trailing). */
    for (int64_t i = 0; i < rel.len; i++) {
        if (rel.data[i] == '.' && i + 1 < rel.len && rel.data[i + 1] == '.' &&
            (i == 0 || rel.data[i - 1] == '/') &&
            (i + 2 >= rel.len || rel.data[i + 2] == '/')) {
            return -1;
        }
    }
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

int64_t honk_file_mtime(int32_t file_fd) {
    if (file_fd < 0) return 0;
    struct stat st;
    if (fstat(file_fd, &st) < 0) return 0;
    return (int64_t)st.st_mtime;
}

/* Append the stored peer IP string (`"127.0.0.1"`, `"::1"`, `"2001:db8::1"`,
 * or `"unix"`; defaults to 127.0.0.1 for in-memory tests). */
int64_t honk_conn_ip(int32_t fd, gs_rref out) {
    const char *ip = "127.0.0.1";
    if (fd >= 0 && fd < HONK_MAX_FD && tls_conns && tls_conns[fd].active &&
        tls_conns[fd].peer_ip_str[0] != '\0') {
        ip = tls_conns[fd].peer_ip_str;
    }
    size_t n = strlen(ip);
    if (n > 0) honk_rref_append(out, ip, (int64_t)n);
    return (int64_t)n;
}

/* Lazy thread-local fixed-window rate limiter:
 * Returns remaining quota (>= 0) when allowed, or -retry_after_sec (< 0) when exceeded. */
int32_t honk_rate_allow(int64_t key_hash, int32_t max_reqs, int32_t window_ms) {
    if (max_reqs <= 0 || window_ms <= 0) return 0;
    if (!tls_rl_table) {
        tls_rl_table = (honk_rl_slot_t *)calloc(HONK_RL_SLOTS, sizeof(honk_rl_slot_t));
        if (!tls_rl_table) return 0;
    }
    int64_t now = monotonic_ms();
    uint64_t ukey = ((uint64_t)key_hash) | 1ULL;
    honk_rl_slot_t *s = &tls_rl_table[(uint32_t)(ukey ^ (ukey >> 32)) & (HONK_RL_SLOTS - 1)];
    if (s->key != ukey || now >= s->reset_ms) {
        s->key = ukey;
        s->reset_ms = now + (int64_t)window_ms;
        s->count = 1;
        return max_reqs - 1;
    }
    if (s->count < max_reqs) {
        s->count++;
        return max_reqs - s->count;
    }
    int64_t rem_ms = s->reset_ms - now;
    int32_t retry_s = (int32_t)((rem_ms + 999) / 1000);
    if (retry_s < 1) retry_s = 1;
    return -retry_s;
}

void honk_rate_reset(void) {
    if (tls_rl_table) {
        free(tls_rl_table);
        tls_rl_table = NULL;
    }
}

void honk_file_close(int32_t file_fd) {
    if (file_fd >= 0) close(file_fd);
}

void honk_buf_reset(gs_rref buf) {
    honk_rref_reset(buf);
}

/* Queue file bytes [offset, offset + count) behind any pending headers and
 * push via sendfile(). The turn MUST have flushed earlier tx_buf bytes first
 * (headers precede file bytes). At most one active transfer per connection:
 * a second file while one is in flight closes the connection cleanly
 * (documented). Returns 0 (accepted: sent or resumed via EPOLLOUT), -1 (closed).
 * Ownership: once accepted with remain > 0 the conn owns file_fd; it is
 * closed exactly once (on completion, error, timeout, or shutdown).
 */
int32_t honk_sendfile_data(int32_t fd, int32_t file_fd, int64_t offset, int64_t count) {
    if (count <= 0 || offset < 0 || file_fd < 0) {
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
    c->sendfile_off = offset;
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

void honk_request_stop(void) {
    tls_should_stop = 1;
    if (g_is_fork_parent && g_num_children > 0) {
        for (int32_t i = 0; i < g_num_children; i++) {
            if (g_child_pids[i] > 0) kill(g_child_pids[i], SIGTERM);
        }
    } else if (g_parent_pid > 0) {
        kill(g_parent_pid, SIGTERM);
    }
}

int32_t honk_should_stop(void) {
    return (tls_should_stop || g_sigint_count > 0 || g_sigterm_flag != 0) ? 1 : 0;
}

static int32_t detect_cpu_count(void) {
    cpu_set_t mask;
    CPU_ZERO(&mask);
    if (sched_getaffinity(0, sizeof(mask), &mask) == 0) {
        int n = CPU_COUNT(&mask);
        if (n > HONK_MAX_WORKERS) n = HONK_MAX_WORKERS;
        if (n >= 1) return (int32_t)n;
    }
    long sc = sysconf(_SC_NPROCESSORS_ONLN);
    if (sc > HONK_MAX_WORKERS) sc = HONK_MAX_WORKERS;
    return sc >= 1 ? (int32_t)sc : 1;
}

int32_t honk_fork_workers(int32_t n) {
    install_signal_handlers();
    if (g_fork_initialized) {
        return g_is_fork_parent ? (g_num_children + 1) : 1;
    }
    if (n == 0) {
        n = detect_cpu_count();
    }
    if (n < 1 || n > HONK_MAX_WORKERS) {
        fprintf(stderr, "honk: worker count %d out of range (expected 0=auto or 1..%d)\n",
                (int)n, HONK_MAX_WORKERS);
        fflush(stderr);
        _exit(1);
    }
    if (n > 1 && atomic_load(&g_open_dbs) > 0) {
        fprintf(stderr, "honk: cannot fork %d workers with an open SQLite handle; "
                        "call honk::workers() / honk::workers_env() before db_open()\n",
                (int)n);
        fflush(stderr);
        _exit(1);
    }
    /* Unix sockets: bind once here so every forked worker accept4()s on the
     * single shared listen fd (per-worker bind would hit EADDRINUSE). */
    const char *bspec = honk_resolve_bind();
    if (strncmp(bspec, "unix:", 5) == 0 && honk_unix_bind_inner(bspec + 5) < 0) {
        fprintf(stderr, "honk: cannot bind unix socket '%s'\n", bspec + 5);
        fflush(stderr);
        _exit(1);
    }
    g_fork_initialized = 1;
    tls_worker_id = 0;
    if (n == 1) {
        return 1;
    }
    fflush(NULL);
    pid_t parent_pid = getpid();
    g_is_fork_parent = 1;
    g_num_children = 0;
    for (int32_t i = 1; i < n; i++) {
        pid_t pid = fork();
        if (pid < 0) {
            for (int32_t k = 0; k < g_num_children; k++) {
                if (g_child_pids[k] > 0) kill(g_child_pids[k], SIGTERM);
            }
            fprintf(stderr, "honk: fork() failed\n");
            fflush(stderr);
            _exit(1);
        }
        if (pid == 0) {
            g_is_fork_parent = 0;
            g_num_children = 0;
            g_parent_pid = parent_pid;
            tls_worker_id = i;
            return n;
        }
        g_child_pids[g_num_children++] = pid;
    }
    return n;
}

int32_t honk_fork_env(void) {
    if (g_fork_initialized) {
        return g_is_fork_parent ? (g_num_children + 1) : 1;
    }
    const char *env = getenv("HONK_WORKERS");
    if (!env || env[0] == '\0') {
        return honk_fork_workers(1);
    }
    if (strcmp(env, "auto") == 0 || strcmp(env, "0") == 0) {
        return honk_fork_workers(0);
    }
    char *end = NULL;
    long v = strtol(env, &end, 10);
    if (!end || *end != '\0' || v < 1 || v > HONK_MAX_WORKERS) {
        fprintf(stderr, "honk: invalid HONK_WORKERS='%s' (expected 1..%d or 'auto')\n",
                env, HONK_MAX_WORKERS);
        fflush(stderr);
        _exit(1);
    }
    return honk_fork_workers((int32_t)v);
}

void honk_fork_join(void) {
    if (!g_is_fork_parent || g_num_children <= 0) {
        return;
    }
    int fail_code = 0;
    for (int32_t i = 0; i < g_num_children; i++) {
        pid_t pid = g_child_pids[i];
        if (pid <= 0) continue;
        int status = 0;
        while (waitpid(pid, &status, 0) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        g_child_pids[i] = 0;
        if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
            fail_code = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            int sig = WTERMSIG(status);
            if (sig != SIGTERM && sig != SIGINT) {
                fail_code = 128 + sig;
            }
        }
    }
    g_num_children = 0;
    g_is_fork_parent = 0;
    if (fail_code != 0) {
        fprintf(stderr, "honk: worker child exited with failure (%d)\n", fail_code);
        _exit(fail_code);
    }
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
        c->ws_slot = -1;
        c->ws_msg = NULL;
        c->ws_msg_len = 0;
        c->ws_msg_cap = 0;
        c->ws_aux = NULL;
        c->ws_aux_len = 0;
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
