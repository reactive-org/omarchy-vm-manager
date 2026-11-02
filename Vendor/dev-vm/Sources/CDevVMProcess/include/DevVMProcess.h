#ifndef DEVVM_PROCESS_H
#define DEVVM_PROCESS_H
#include <sys/types.h>
#include <stddef.h>
typedef struct {
    pid_t pid;
    int input_fd, output_fd, error_fd;
} devvm_child;
// Darwin-only syscall bridge; no fork into a Swift/multithreaded runtime.
int devvm_spawn(const char *path, char *const argv[], char *const env[],
                const char *cwd, int terminal, int rows, int columns,
                devvm_child *child);
int devvm_observe(pid_t pid, int *status);
int devvm_group_live(pid_t leader);
int devvm_reap(pid_t pid);
int devvm_resize(int fd, int rows, int columns);
int devvm_noecho(int fd);
#endif
