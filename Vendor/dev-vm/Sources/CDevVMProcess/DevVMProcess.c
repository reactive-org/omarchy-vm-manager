#include "DevVMProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/proc.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static int relocate(int fd) {
    if (fd < 0) return -1;
    int next = fcntl(fd, F_DUPFD_CLOEXEC, 10);
    close(fd);
    return next;
}
static int channel(int fds[2]) {
    int pair[2];
    if (pipe(pair)) return -1;
    fds[0] = relocate(pair[0]); fds[1] = relocate(pair[1]);
    return fds[0] < 0 || fds[1] < 0 ? -1 : 0;
}
static int nonblocking(int fd) {
    return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}
int devvm_spawn(const char *path, char *const argv[], char *const env[],
                const char *cwd, int terminal, int rows, int columns,
                devvm_child *child) {
    int in[2] = {-1,-1}, out[2] = {-1,-1}, err[2] = {-1,-1};
    int master = -1, slave = -1, result = EIO;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int has_attr = 0, has_actions = 0;
    child->pid = -1; child->input_fd = child->output_fd = child->error_fd = -1;
#define TRY(call) do { result = (call); if (result) goto done; } while (0)
    TRY(posix_spawnattr_init(&attr)); has_attr = 1;
    TRY(posix_spawn_file_actions_init(&actions)); has_actions = 1;
    sigset_t empty, defaults;
    sigemptyset(&empty); sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP);
    TRY(posix_spawnattr_setsigmask(&attr, &empty));
    TRY(posix_spawnattr_setsigdefault(&attr, &defaults));
    TRY(posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF));
    TRY(posix_spawn_file_actions_addchdir_np(&actions, cwd));
    if (terminal) {
        char name[128];
        struct winsize size = {.ws_row = rows, .ws_col = columns};
        if (openpty(&master, &slave, name, NULL, &size)) { result = errno; goto done; }
        master = relocate(master); slave = relocate(slave);
        if (master < 0 || slave < 0 || devvm_noecho(slave)) { result = errno; goto done; }
        // File actions precede SETSID on Darwin. The exec trampoline claims
        // the controlling terminal after spawn completes its session setup.
        TRY(posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0));
        TRY(posix_spawn_file_actions_adddup2(&actions, 0, 1));
        TRY(posix_spawn_file_actions_adddup2(&actions, 0, 2));
        if (nonblocking(master)) { result = errno; goto done; }
    } else {
        if (channel(in) || channel(out) || channel(err)) { result = errno; goto done; }
        TRY(posix_spawn_file_actions_adddup2(&actions, in[0], 0));
        TRY(posix_spawn_file_actions_adddup2(&actions, out[1], 1));
        TRY(posix_spawn_file_actions_adddup2(&actions, err[1], 2));
        if (nonblocking(in[1]) || nonblocking(out[0]) || nonblocking(err[0]) ||
            fcntl(in[1], F_SETNOSIGPIPE, 1)) { result = errno; goto done; }
    }
    TRY(posix_spawn(&child->pid, path, &actions, &attr, argv, env));
    if (terminal) {
        child->input_fd = child->output_fd = master; master = -1;
    } else {
        child->input_fd = in[1]; in[1] = -1;
        child->output_fd = out[0]; out[0] = -1;
        child->error_fd = err[0]; err[0] = -1;
    }
done:
    if (has_actions) posix_spawn_file_actions_destroy(&actions);
    if (has_attr) posix_spawnattr_destroy(&attr);
    for (int i=0; i<2; i++) {
        if (in[i]>=0) close(in[i]); if (out[i]>=0) close(out[i]); if (err[i]>=0) close(err[i]);
    }
    if (master>=0) close(master); if (slave>=0) close(slave);
    return result;
#undef TRY
}
int devvm_observe(pid_t pid, int *status) {
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT)) return errno == EINTR ? 0 : -1;
    if (!info.si_pid) return 0;
    *status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
    return 1; // Keep the leader waitable to reserve its PID/group identity.
}
int devvm_group_live(pid_t leader) {
    pid_t values[4096];
    int n = proc_listpids(PROC_PGRP_ONLY, (uint32_t)leader, values, sizeof(values));
    if (n <= 0 || n >= (int)sizeof(values)) return -1;
    int live = 0;
    for (int i=0; i<n/(int)sizeof(pid_t); i++) {
        if (values[i] <= 0 || values[i] == leader) continue;
        struct proc_bsdinfo info;
        int count = proc_pidinfo(values[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info));
        if (!count && (errno == ESRCH || errno == ENOENT)) continue;
        if (count != sizeof(info)) return -1;
        if (info.pbi_pgid != (uint32_t)leader) continue;
        if (info.pbi_status != SZOMB) live++;
    }
    return live;
}
int devvm_reap(pid_t pid) {
    int status;
    pid_t result;
    do { result = waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    return result == pid ? 0 : -1;
}
int devvm_resize(int fd, int rows, int columns) {
    struct winsize size = {.ws_row = rows, .ws_col = columns};
    return ioctl(fd, TIOCSWINSZ, &size);
}
int devvm_noecho(int fd) {
    struct termios attributes;
    if (tcgetattr(fd, &attributes)) return -1;
    cfmakeraw(&attributes);
    return tcsetattr(fd, TCSANOW, &attributes);
}
