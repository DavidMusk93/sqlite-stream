#include "abi.h"
#include <string.h>

/* Keep descriptor-relative paths intact. Canonicalizing /proc/self/fd would
 * allow an unmounted data path to resolve to its underlying root filesystem.
 * The caller serializes registration; all IO and locking use SQLite's VFS. */
static int fd_fullpath(sqlite3_vfs *vfs, const char *path, int size, char *out) {
    (void)vfs;
    if (strncmp(path, "/proc/self/fd/", 14) || strlen(path) >= (size_t)size)
        return SQLITE_CANTOPEN;
    memcpy(out, path, strlen(path) + 1);
    return SQLITE_OK;
}
int ss_register_fd_vfs(void) {
    static sqlite3_vfs fd_vfs;
    if (sqlite3_initialize() != SQLITE_OK) return SQLITE_ERROR;
    if (sqlite3_vfs_find("ss-fd")) return SQLITE_OK;
    sqlite3_vfs *base = sqlite3_vfs_find(0);
    if (!base) return SQLITE_ERROR;
    fd_vfs = *base;
    fd_vfs.zName = "ss-fd";
    fd_vfs.pNext = 0;
    fd_vfs.xFullPathname = fd_fullpath;
    return sqlite3_vfs_register(&fd_vfs, 0);
}

static volatile sig_atomic_t cancelled;
static void cancel(int signal_number) { (void)signal_number; cancelled = 1; }
int ss_cancelled(void) { return cancelled != 0; }
void ss_signals(void) {
    struct sigaction action = {0};
    action.sa_handler = cancel;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, 0);
    sigaction(SIGTERM, &action, 0);
    signal(SIGPIPE, SIG_IGN);
}
int ss_errno(void) { return errno; }
int64_t ss_monotonic_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return -1;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
int ss_file_size(const char *path, uint64_t *size) {
    struct stat s;
    if (stat(path, &s)) return errno == ENOENT ? 1 : -1;
    if (s.st_size < 0) return -1;
    *size = (uint64_t)s.st_size;
    return 0;
}
int ss_exists(const char *path) {
    struct stat s;
    if (lstat(path, &s) == 0) return 1;
    return errno == ENOENT ? 0 : -1;
}
