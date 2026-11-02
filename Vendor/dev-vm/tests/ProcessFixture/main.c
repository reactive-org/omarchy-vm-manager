// Test-only executable. Copied into disposable UUID directories before launch.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

static volatile sig_atomic_t resized;
static void winch(int signal) { (void)signal; resized = 1; }
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "exact")) {
        char cwd[4096]; if (!getcwd(cwd, sizeof(cwd))) return 3;
        printf("%s\n%s\n%s\n", argc > 2 ? argv[2] : "", getenv("FIXTURE") ?: "absent", getenv("SSH_AUTH_SOCK") ?: "absent");
        fflush(stdout); write(2, "separate-error", 14); return 7;
    }
    if (!strcmp(argv[1], "stdin")) {
        char buffer[4096]; ssize_t n; size_t total=0;
        while ((n=read(0, buffer, sizeof(buffer))) > 0) total += n;
        printf("bytes=%zu", total); return 0;
    }
    if (!strcmp(argv[1], "flood")) {
        char buffer[4096]; memset(buffer, 'x', sizeof(buffer));
        for (int i=0; i<1024; i++) { if (write(1,buffer,sizeof(buffer)) < 0) break; if (write(2,buffer,sizeof(buffer)) < 0) break; }
        return 0;
    }
    if (!strcmp(argv[1], "ansi")) {
        const unsigned char text[] = "\033[32mworking\033[0m\rprogress \xe2\x98\x83\n";
        for (size_t i=0; i<sizeof(text)-1; i++) { write(1,text+i,1); usleep(1000); }
        return 0;
    }
    if (!strcmp(argv[1], "tty")) {
        struct winsize size; struct termios attributes;
        int controlling=open("/dev/tty", O_RDWR);
        if (controlling < 0) return 40;
        if (!isatty(0) || !isatty(1) || !isatty(2)) return 41;
        if (getsid(0)!=getpid()) return 42;
        if (getpgrp()!=getpid()) return 43;
        if (tcgetpgrp(0)!=getpgrp()) return 44;
        if (ioctl(0,TIOCGWINSZ,&size) || tcgetattr(0,&attributes)) return 45;
        close(controlling);
        if (attributes.c_lflag & ECHO) return 5;
        signal(SIGWINCH,winch);
        printf("READY %u %u noecho\n",size.ws_row,size.ws_col); fflush(stdout);
        char byte;
        for (;;) {
            if (resized) { resized=0; ioctl(0,TIOCGWINSZ,&size); printf("SIZE %u %u\n",size.ws_row,size.ws_col); fflush(stdout); }
            if (read(0,&byte,1)==1 && byte=='\n') break;
            if (errno==EINTR) continue;
        }
        printf("RECEIVED\n"); return 0;
    }
    if (!strcmp(argv[1], "linger") || !strcmp(argv[1], "parent-exit")) {
        signal(SIGTERM,SIG_IGN);
        pid_t child=fork(); if (child<0) return 6;
        if (!child) { for (;;) pause(); }
        FILE *f=fopen("child.pid","w"); if (!f) return 8; fprintf(f,"%d",child); fclose(f);
        write(1,"RUNNING",7);
        if (!strcmp(argv[1],"parent-exit")) return 0;
        for (;;) pause();
    }
    if (!strcmp(argv[1], "detached-pipe")) {
        int ready[2]; if (pipe(ready)) return 12;
        pid_t child=fork(); if (child<0) return 6;
        if (!child) {
            close(ready[0]);
            if (setsid()<0) _exit(11);
            write(ready[1], "r", 1); close(ready[1]);
            usleep(4*1000*1000); _exit(0); // Hard bounded, test-owned escape.
        }
        close(ready[1]); char byte;
        if (read(ready[0],&byte,1)!=1) return 13;
        close(ready[0]);
        FILE *f=fopen("child.pid","w"); if (!f) return 8; fprintf(f,"%d",child); fclose(f);
        return 0;
    }
    if (!strcmp(argv[1], "wait")) {
        signal(SIGTERM,SIG_IGN); write(1,"RUNNING",7); for (;;) pause();
    }
    if (!strcmp(argv[1], "exit")) return 0;
    if (!strcmp(argv[1], "fdcheck")) return argc == 3 && fcntl(atoi(argv[2]),F_GETFD) == -1 && errno == EBADF ? 0 : 10;
    if (!strcmp(argv[1], "signal")) { raise(SIGTERM); return 9; }
    return 2;
}
