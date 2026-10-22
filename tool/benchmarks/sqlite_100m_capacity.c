// Synthetic-only single-file SQLite scale test; never opens real user data.
// Reproduce on disposable storage:
// gcc -O3 -Wall -o capacity tool/benchmarks/sqlite_100m_capacity.c -lsqlite3 -lm
// ./capacity /tmp/new-empty-folder/synthetic.sqlite 100000000 1
// Linux host measurements do NOT establish performance on POCO X7 Pro.
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sys/statvfs.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void must(int rc, sqlite3 *db, const char *where) {
    if (rc != SQLITE_OK && rc != SQLITE_DONE && rc != SQLITE_ROW) {
        fprintf(stderr, "ERROR %s (%d): %s\n", where, rc, sqlite3_errmsg(db));
        exit(2);
    }
}
static void sql(sqlite3 *db, const char *text) {
    must(sqlite3_exec(db, text, NULL, NULL, NULL), db, text);
}
static long long filelen(const char *f) {
    struct stat s;
    return stat(f, &s) == 0 ? s.st_size : 0;
}
static long long available(const char *folder) {
    struct statvfs v;
    return statvfs(folder, &v) == 0 ? (long long)v.f_bavail * v.f_frsize : -1;
}
static int cmpd(const void *a, const void *b) {
    double x = *(double *)a, y = *(double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}
static void bench(sqlite3 *db, const char *key, const char *statement, const char *arg) {
    sqlite3_stmt *st;
    must(sqlite3_prepare_v2(db, statement, -1, &st, NULL), db, "prepare-query");
    double x[15];
    for (int i = 0; i < 15; i++) {
        sqlite3_reset(st);
        sqlite3_clear_bindings(st);
        if (arg) sqlite3_bind_text(st, 1, arg, -1, SQLITE_STATIC);
        double t = now();
        int rc = sqlite3_step(st);
        while (rc == SQLITE_ROW) rc = sqlite3_step(st);
        must(rc, db, key);
        x[i] = (now() - t) * 1000;
    }
    qsort(x, 15, sizeof(double), cmpd);
    printf("QUERY %s p50_ms=%.5f p95_ms=%.5f\n", key, x[7], x[14]);
    sqlite3_finalize(st);
    sqlite3_stmt *pl;
    char q[2048];
    snprintf(q, sizeof(q), "EXPLAIN QUERY PLAN %s", statement);
    must(sqlite3_prepare_v2(db, q, -1, &pl, NULL), db, "plan");
    if (arg) sqlite3_bind_text(pl, 1, arg, -1, SQLITE_STATIC);
    printf("PLAN %s:", key);
    while (sqlite3_step(pl) == SQLITE_ROW) {
        printf(" %s;", sqlite3_column_text(pl, 3));
    }
    puts("");
    sqlite3_finalize(pl);
}
int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s /tmp/emptydir/synthetic.sqlite ROWS FTS(0|1)\n", argv[0]);
        return 1;
    }
    const char *file = argv[1];
    long long total = atoll(argv[2]);
    int usefts = atoi(argv[3]);
    if (total < 1 || total > 100000000) {
        fputs("bad record count\n", stderr);
        return 1;
    }
    if (access(file, F_OK) == 0) {
        fputs("refusing to overwrite existing DB\n", stderr);
        return 1;
    }
    sqlite3 *db = NULL;
    must(sqlite3_open_v2(file, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL), db, "open");
    sqlite3_busy_timeout(db, 30000);
    sql(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; "
            "PRAGMA cache_size=-12000; PRAGMA wal_autocheckpoint=2000;");
    sql(db, "CREATE TABLE records(id INTEGER PRIMARY KEY, normalized_name TEXT NOT NULL, "
            "mobile TEXT NOT NULL, national_code TEXT NOT NULL);");
    sql(db, "CREATE INDEX idx_mobile ON records(mobile,id);"
            "CREATE INDEX idx_national ON records(national_code,id);");
    sqlite3_stmt *ins;
    must(sqlite3_prepare_v2(db, "INSERT INTO records(id,normalized_name,mobile,national_code) "
            "VALUES(?,?,?,?)", -1, &ins, NULL), db, "insert prepare");
    const char *names[] = {
        "نمونه ساختگی حسینی", "نمونه ساختگی رضایی", "نمونه ساختگی احمدی",
        "نمونه ساختگی کریمی", "نمونه ساختگی محمدی", "نمونه ساختگی نژاد",
        "نمونه ساختگی مرادی", "نمونه ساختگی اکبری"
    };
    char mobile[32], national[32];
    double begun = now(), checkpoint = begun;
    for (long long i = 1; i <= total; i++) {
        if ((i-1) % 20000 == 0) sql(db, "BEGIN IMMEDIATE");
        sqlite3_bind_int64(ins, 1, i);
        sqlite3_bind_text(ins, 2, names[i % 8], -1, SQLITE_STATIC);
        snprintf(mobile, sizeof(mobile), "09%09lld", (i-1) % 1000000000LL);
        snprintf(national, sizeof(national), "%011lld", i);
        sqlite3_bind_text(ins, 3, mobile, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(ins, 4, national, -1, SQLITE_TRANSIENT);
        must(sqlite3_step(ins), db, "insert");
        sqlite3_reset(ins);
        sqlite3_clear_bindings(ins);
        if (i % 20000 == 0 || i == total) sql(db, "COMMIT");
        if (i % 1000000 == 0 || i == total) {
            double t = now();
            printf("INSERT_PROGRESS %lld/%lld elapsed_s=%.2f "
                    "interval_rows_sec=%.0f db_bytes=%lld free_bytes=%lld\n",
                    i, total, t - begun, 1000000.0/(t-checkpoint),
                    filelen(file), available("/mnt/data"));
            fflush(stdout);
            checkpoint = t;
            if (available("/mnt/data") < 3000000000LL) {
                fputs("STOP free disk <3GB\n", stderr);
                exit(3);
            }
        }
    }
    sqlite3_finalize(ins);
    double insert_seconds = now() - begun;
    sql(db, "PRAGMA wal_checkpoint(TRUNCATE)");
    printf("INSERT_SUMMARY rows=%lld insert_seconds=%.3f rows_sec=%.0f db_bytes=%lld\n",
            total, insert_seconds, total / insert_seconds, filelen(file));
    fflush(stdout);
    if (usefts) {
        double ft = now();
        sql(db, "CREATE VIRTUAL TABLE name_fts USING "
                "fts4(normalized_name, tokenize=unicode61, order=DESC)");
        sqlite3_stmt *fill;
        must(sqlite3_prepare_v2(db,
            "INSERT INTO name_fts(docid,normalized_name) "
            "SELECT id,normalized_name FROM records WHERE id>? AND id<=? ORDER BY id",
            -1, &fill, NULL), db, "prepare FTS");
        for (long long begin=0; begin<total; begin+=1000000) {
            sql(db, "BEGIN IMMEDIATE");
            sqlite3_bind_int64(fill, 1, begin);
            sqlite3_bind_int64(fill, 2, begin+1000000);
            must(sqlite3_step(fill), db, "FTS populate");
            sqlite3_reset(fill);
            sqlite3_clear_bindings(fill);
            sql(db, "COMMIT");
            if (((begin / 1000000) % 5) == 4 || begin + 1000000 >= total) {
                printf("FTS_PROGRESS %lld/%lld sec=%.1f db_bytes=%lld free_bytes=%lld\n",
                    begin + 1000000 < total ? begin + 1000000 : total,
                    total, now()-ft, filelen(file), available("/mnt/data"));
                fflush(stdout);
                if (available("/mnt/data") < 2500000000LL) {
                    fputs("STOP fts disk <2.5GB\n", stderr);
                    exit(3);
                }
            }
        }
        sqlite3_finalize(fill);
        sql(db, "PRAGMA wal_checkpoint(TRUNCATE)");
        printf("FTS_SUMMARY seconds=%.2f db_bytes=%lld\n", now()-ft, filelen(file));
        fflush(stdout);
    }
    sqlite3_stmt *n;
    must(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM records", -1, &n, NULL), db, "count");
    if (sqlite3_step(n) == SQLITE_ROW)
        printf("VERIFIED_ROWS %lld\n", sqlite3_column_int64(n, 0));
    sqlite3_finalize(n);
    bench(db, "mobile_prefix",
        "SELECT id FROM records WHERE mobile>=? AND mobile<'09000000130' "
        "ORDER BY id DESC LIMIT 20", "09000000100");
    bench(db, "national_prefix",
        "SELECT id FROM records WHERE national_code>=? AND national_code<'00001000020' "
        "ORDER BY id DESC LIMIT 20", "00001000000");
    bench(db, "keyset_last_page",
        "SELECT id FROM records WHERE id<100 ORDER BY id DESC LIMIT 20", NULL);
    if (usefts) {
        bench(db, "fts_absent",
            "SELECT r.id FROM name_fts f JOIN records r ON r.id=f.docid "
            "WHERE name_fts MATCH ? ORDER BY f.docid DESC LIMIT 20",
            "\"نامناموجود*\"");
        bench(db, "fts_common_prefix",
            "SELECT r.id FROM name_fts f JOIN records r ON r.id=f.docid "
            "WHERE name_fts MATCH ? ORDER BY f.docid DESC LIMIT 20",
            "\"حسی*\"");
    }
    printf("DONE rows=%lld final_db_bytes=%lld sqlite=%s free_bytes=%lld\n",
           total, filelen(file), sqlite3_libversion(), available("/mnt/data"));
    fflush(stdout);
    sqlite3_close(db);
    return 0;
}
