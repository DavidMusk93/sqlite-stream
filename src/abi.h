#define _GNU_SOURCE 1
#include <sqlite3.h>
#include <zstd.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <poll.h>

int64_t ss_monotonic_ms(void);
int ss_errno(void);
int ss_cancelled(void);
void ss_signals(void);
int ss_file_size(const char *path, uint64_t *size);
int ss_regular(int fd);
int ss_exists(const char *path);
