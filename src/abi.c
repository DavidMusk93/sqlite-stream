#include "abi.h"

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
