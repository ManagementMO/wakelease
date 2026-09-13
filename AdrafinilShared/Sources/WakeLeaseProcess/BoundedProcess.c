#include "WakeLeaseProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static double continuous_seconds(void) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return (double)mach_continuous_time() * (double)info.numer / (double)info.denom / 1e9;
}

int wakelease_capture(char *const arguments[], double timeout, unsigned char *output, size_t capacity, size_t *length, pid_t *child) {
    int pipefd[2];
    *length = 0;
    *child = 0;
    if (pipe(pipefd) != 0) return -errno;
    fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);
    fcntl(pipefd[0], F_SETFL, O_NONBLOCK);
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attributes);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGINT);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    posix_spawnattr_setsigmask(&attributes, &empty);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", NULL};
    int error = posix_spawn(child, arguments[0], &actions, &attributes, arguments, environment);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);
    if (error) { close(pipefd[0]); return -error; }
    double deadline = continuous_seconds() + timeout;
    int timed_out = 0, eof = 0, status = 0, result = 0;
    for (;;) {
        unsigned char buffer[4096];
        for (int pass = 0; pass < 16; pass++) {
            ssize_t count = read(pipefd[0], buffer, sizeof(buffer));
            if (count <= 0) { if (count == 0) eof = 1; break; }
            size_t available = capacity - *length;
            size_t keep = (size_t)count < available ? (size_t)count : available;
            memcpy(output + *length, buffer, keep);
            *length += keep;
        }
        pid_t waited = waitpid(*child, &status, WNOHANG);
        if (waited == *child) {
            result = timed_out ? -ETIMEDOUT : (WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
            break;
        }
        if (waited < 0 && errno != EINTR) { result = -errno; break; }
        double now = continuous_seconds();
        if (now >= deadline) {
            if (timed_out) { result = -EBUSY; break; }
            kill(*child, SIGKILL);
            timed_out = 1;
            deadline = now + 2;
        }
        if (eof) usleep(10000);
        else {
            struct pollfd descriptor = {pipefd[0], POLLIN, 0};
            int milliseconds = (int)((deadline - now) * 1000);
            if (milliseconds < 1) milliseconds = 1;
            if (milliseconds > 50) milliseconds = 50;
            poll(&descriptor, 1, milliseconds);
        }
    }
    close(pipefd[0]);
    return result;
}
