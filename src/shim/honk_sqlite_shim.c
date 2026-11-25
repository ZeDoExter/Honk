/* honk_sqlite_shim.c -- tiny slice-friendly SQLite wrapper for honk_sqlite.goose.
 *
 * Goose `extern fn` cannot pass NUL-terminated strings or receive foreign
 * pointers, so this shim translates: paths/SQL arrive as {data,len} slices
 * (copied + NUL-terminated here), opaque sqlite handles travel as u64, and
 * column text is appended once into a caller-owned Goose builder (single
 * copy into request scope, zero heap Strings).
 *
 * Threading: one sqlite3* per worker thread, opened NOMUTEX (zero cross-
 * thread contention). A handle must only be used on its opener thread.
 * Shutdown order per worker: finalize all stmts -> sqlite3_close -> (once
 * per process, after every worker joined) sqlite3_shutdown() for LSan-clean
 * exit. This file never touches gs_rref internals directly; builder appends
 * go through honk_rref.h like the rest of the shim.
 */

#include "honk_rref.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <sqlite3.h>

#pragma pack(push, 1)
typedef struct {
    uint8_t *data;
    int64_t len;
} sl_u8_sqlite;
#pragma pack(pop)

/* Copy a slice + NUL into malloc'd storage (caller frees). NULL on OOM. */
static char *dup_nul(const uint8_t *data, int64_t len) {
    if (!data || len < 0 || len > (int64_t)1048576) return NULL;
    char *s = (char *)malloc((size_t)len + 1);
    if (!s) return NULL;
    if (len > 0) memcpy(s, data, (size_t)len);
    s[len] = '\0';
    return s;
}

uint64_t hsql_open(sl_u8_sqlite path, int32_t flags) {
    char *p = dup_nul(path.data, path.len);
    if (!p) return 0;
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(p, &db, (int)flags, NULL);
    free(p);
    if (rc != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return 0;
    }
    return (uint64_t)(uintptr_t)db;
}

int32_t hsql_close(uint64_t db_h) {
    if (!db_h) return 0;
    return (int32_t)sqlite3_close((sqlite3 *)(uintptr_t)db_h);
}

int32_t hsql_shutdown(void) {
    return (int32_t)sqlite3_shutdown();
}

/* Run setup/DDL SQL with no result rows (PRAGMAs, CREATE TABLE, ...). */
int32_t hsql_exec(uint64_t db_h, sl_u8_sqlite sql) {
    if (!db_h) return -1;
    char *s = dup_nul(sql.data, sql.len);
    if (!s) return -1;
    char *errmsg = NULL;
    int rc = sqlite3_exec((sqlite3 *)(uintptr_t)db_h, s, NULL, NULL, &errmsg);
    if (errmsg) sqlite3_free(errmsg);
    free(s);
    return (int32_t)rc;
}

uint64_t hsql_prepare(uint64_t db_h, sl_u8_sqlite sql) {
    if (!db_h) return 0;
    char *s = dup_nul(sql.data, sql.len);
    if (!s) return 0;
    sqlite3_stmt *st = NULL;
    int rc = sqlite3_prepare_v2((sqlite3 *)(uintptr_t)db_h, s, -1, &st, NULL);
    free(s);
    if (rc != SQLITE_OK) {
        if (st) sqlite3_finalize(st);
        return 0;
    }
    return (uint64_t)(uintptr_t)st;
}

int32_t hsql_finalize(uint64_t st_h) {
    if (!st_h) return 0;
    return (int32_t)sqlite3_finalize((sqlite3_stmt *)(uintptr_t)st_h);
}

int32_t hsql_step(uint64_t st_h) {
    if (!st_h) return -1;
    return (int32_t)sqlite3_step((sqlite3_stmt *)(uintptr_t)st_h);
}

int32_t hsql_reset(uint64_t st_h) {
    if (!st_h) return -1;
    return (int32_t)sqlite3_reset((sqlite3_stmt *)(uintptr_t)st_h);
}

int32_t hsql_clear_bindings(uint64_t st_h) {
    if (!st_h) return -1;
    return (int32_t)sqlite3_clear_bindings((sqlite3_stmt *)(uintptr_t)st_h);
}

int32_t hsql_bind_int(uint64_t st_h, int32_t idx, int64_t v) {
    if (!st_h || idx < 1) return -1;
    return (int32_t)sqlite3_bind_int64((sqlite3_stmt *)(uintptr_t)st_h, (int)idx,
                                       (sqlite3_int64)v);
}

int32_t hsql_bind_float(uint64_t st_h, int32_t idx, double v) {
    if (!st_h || idx < 1) return -1;
    return (int32_t)sqlite3_bind_double((sqlite3_stmt *)(uintptr_t)st_h, (int)idx, v);
}

/* is_transient != 0: SQLITE_TRANSIENT (sqlite copies; always safe).
 * is_transient == 0: SQLITE_STATIC (caller guarantees the bytes outlive the
 * next step+reset; use only for static/request-scoped slices you control). */
int32_t hsql_bind_text(uint64_t st_h, int32_t idx, sl_u8_sqlite v, int32_t is_transient) {
    if (!st_h || idx < 1 || !v.data || v.len < 0 || v.len > (int64_t)1048576) return -1;
    void (*dtor)(void *) = is_transient ? SQLITE_TRANSIENT : SQLITE_STATIC;
    return (int32_t)sqlite3_bind_text((sqlite3_stmt *)(uintptr_t)st_h, (int)idx,
                                      (const char *)v.data, (int)v.len, dtor);
}

int32_t hsql_bind_null(uint64_t st_h, int32_t idx) {
    if (!st_h || idx < 1) return -1;
    return (int32_t)sqlite3_bind_null((sqlite3_stmt *)(uintptr_t)st_h, (int)idx);
}

int64_t hsql_col_int(uint64_t st_h, int32_t idx) {
    if (!st_h || idx < 0) return 0;
    return (int64_t)sqlite3_column_int64((sqlite3_stmt *)(uintptr_t)st_h, (int)idx);
}

double hsql_col_float(uint64_t st_h, int32_t idx) {
    if (!st_h || idx < 0) return 0.0;
    return sqlite3_column_double((sqlite3_stmt *)(uintptr_t)st_h, (int)idx);
}

int32_t hsql_col_is_null(uint64_t st_h, int32_t idx) {
    if (!st_h || idx < 0) return 1;
    return sqlite3_column_type((sqlite3_stmt *)(uintptr_t)st_h, (int)idx) == SQLITE_NULL ? 1 : 0;
}

int64_t hsql_col_bytes(uint64_t st_h, int32_t idx) {
    if (!st_h || idx < 0) return 0;
    return (int64_t)sqlite3_column_bytes((sqlite3_stmt *)(uintptr_t)st_h, (int)idx);
}

int32_t hsql_col_count(uint64_t st_h) {
    if (!st_h) return -1;
    return (int32_t)sqlite3_column_count((sqlite3_stmt *)(uintptr_t)st_h);
}

int32_t hsql_col_type(uint64_t st_h, int32_t idx) {
    if (!st_h || idx < 0) return -1;
    return (int32_t)sqlite3_column_type((sqlite3_stmt *)(uintptr_t)st_h, (int)idx);
}

/* Append the column's name once into the caller's builder. Returns bytes
 * appended, or -1 on misuse. */
int64_t hsql_col_name(uint64_t st_h, int32_t idx, gs_rref out) {
    if (!st_h || idx < 0) return -1;
    const char *name = sqlite3_column_name((sqlite3_stmt *)(uintptr_t)st_h, (int)idx);
    if (!name) return -1;
    int64_t n = (int64_t)strlen(name);
    if (n > 0) honk_rref_append(out, name, n);
    return n;
}

/* Append the column's text bytes once into the caller's builder. The returned
 * slice (builder range) is valid for the whole request scope. Returns the
 * number of bytes appended, or -1 on misuse. */
int64_t hsql_col_text(uint64_t st_h, int32_t idx, gs_rref out) {
    if (!st_h || idx < 0) return -1;
    const unsigned char *txt = sqlite3_column_text((sqlite3_stmt *)(uintptr_t)st_h, (int)idx);
    int n = sqlite3_column_bytes((sqlite3_stmt *)(uintptr_t)st_h, (int)idx);
    if (!txt || n < 0) return 0;
    if (n > 0) honk_rref_append(out, txt, (int64_t)n);
    return (int64_t)n;
}

int64_t hsql_last_id(uint64_t db_h) {
    if (!db_h) return 0;
    return (int64_t)sqlite3_last_insert_rowid((sqlite3 *)(uintptr_t)db_h);
}

int64_t hsql_changes(uint64_t db_h) {
    if (!db_h) return 0;
    return (int64_t)sqlite3_changes((sqlite3 *)(uintptr_t)db_h);
}

int32_t hsql_errcode(uint64_t db_h) {
    if (!db_h) return -1;
    return (int32_t)sqlite3_errcode((sqlite3 *)(uintptr_t)db_h);
}

/* Append the current error message into the caller's builder (debugging). */
int64_t hsql_errmsg(uint64_t db_h, gs_rref out) {
    if (!db_h) return -1;
    const char *msg = sqlite3_errmsg((sqlite3 *)(uintptr_t)db_h);
    if (!msg) return 0;
    int64_t n = (int64_t)strlen(msg);
    if (n > 0) honk_rref_append(out, msg, n);
    return n;
}
