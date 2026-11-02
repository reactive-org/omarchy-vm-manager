// Minimal exec trampoline, invoked only with an admitted target and explicit env.
// Darwin posix_spawn establishes SETSID after file actions. Claim the controlling
// tty here, after image activation, without fork/Swift runtime work in a child.
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    if (argc < 2 || argv[1][0] != '/' || getsid(0) != getpid() ||
        !isatty(0) || !isatty(1) || !isatty(2) || ioctl(0, TIOCSCTTY, 0) ||
        tcsetpgrp(0, getpgrp())) return 125;
    execve(argv[1], argv + 1, environ);
    return 126;
}
