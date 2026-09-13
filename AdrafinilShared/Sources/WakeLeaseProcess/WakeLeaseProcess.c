#include "WakeLeaseProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/time.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t child_pid;
static volatile sig_atomic_t heartbeat_due;

static void forward_signal(int value) {
    pid_t pid = (pid_t)child_pid;
    if (pid > 0) kill(-pid, value);
}

static void timer_signal(int value) {
    (void)value;
    heartbeat_due = 1;
}

static void foreground(pid_t from, pid_t to) {
    if (!isatty(STDIN_FILENO) || tcgetpgrp(STDIN_FILENO) != from) return;
    sigset_t blocked, previous;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGTTOU);
    sigprocmask(SIG_BLOCK, &blocked, &previous);
    tcsetpgrp(STDIN_FILENO, to);
    sigprocmask(SIG_SETMASK, &previous, NULL);
}

int wakelease_run(char *const arguments[], void *context, wakelease_process_callback callback) {
    if (!arguments || !arguments[0] || child_pid != 0) return 125;
    int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGALRM};
    struct sigaction saved[5], action = {0};
    sigset_t blocked, prior_mask, empty, defaults;
    sigemptyset(&blocked);
    sigemptyset(&empty);
    sigemptyset(&defaults);
    for (int index = 0; index < 5; index++) sigaddset(&blocked, signals[index]);
    sigprocmask(SIG_BLOCK, &blocked, &prior_mask);
    sigemptyset(&action.sa_mask);
    for (int index = 0; index < 5; index++) {
        action.sa_handler = signals[index] == SIGALRM ? timer_signal : forward_signal;
        sigaction(signals[index], &action, &saved[index]);
        sigaddset(&defaults, signals[index]);
    }
    sigaddset(&defaults, SIGPIPE);
    sigaddset(&defaults, SIGTSTP);
    sigaddset(&defaults, SIGTTIN);
    sigaddset(&defaults, SIGTTOU);
    sigaddset(&defaults, SIGCHLD);
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_init(&attributes);
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawnattr_setpgroup(&attributes, 0);
    posix_spawnattr_setsigmask(&attributes, &empty);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    for (int fd = 0; fd < 3; fd++) {
        if (fcntl(fd, F_GETFD) != -1) posix_spawn_file_actions_adddup2(&actions, fd, fd);
    }
    pid_t pid = 0;
    int error = posix_spawnp(&pid, arguments[0], &actions, &attributes, arguments, environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    pid_t parent_group = getpgrp();
    struct itimerval prior_timer = {0}, timer = {0};
    int result = error == ENOENT ? 127 : 126;
    if (error == 0) {
        child_pid = pid;
        heartbeat_due = 0;
        foreground(parent_group, pid);
        timer.it_interval.tv_sec = 30;
        timer.it_value.tv_sec = 30;
        setitimer(ITIMER_REAL, &timer, &prior_timer);
    }
    sigprocmask(SIG_SETMASK, &prior_mask, NULL);
    if (error == 0) {
        if (callback) callback(1, pid, context);
        int status = 0;
        for (;;) {
            if (heartbeat_due) {
                heartbeat_due = 0;
                if (callback) callback(2, pid, context);
            }
            pid_t waited = waitpid(pid, &status, WUNTRACED);
            if (waited < 0 && errno == EINTR) continue;
            if (waited < 0) { result = 125; break; }
            if (WIFSTOPPED(status)) {
                foreground(pid, parent_group);
                if (callback) callback(3, pid, context);
                kill(getpid(), SIGSTOP);
                foreground(parent_group, pid);
                if (callback) callback(4, pid, context);
                kill(-pid, SIGCONT);
                continue;
            }
            if (WIFEXITED(status)) { result = WEXITSTATUS(status); break; }
            if (WIFSIGNALED(status)) { result = 128 + WTERMSIG(status); break; }
        }
        foreground(pid, parent_group);
        setitimer(ITIMER_REAL, &prior_timer, NULL);
    }
    sigprocmask(SIG_BLOCK, &blocked, NULL);
    child_pid = 0;
    for (int index = 0; index < 5; index++) sigaction(signals[index], &saved[index], NULL);
    sigprocmask(SIG_SETMASK, &prior_mask, NULL);
    return result;
}

static volatile sig_atomic_t watch_signal;

static void cancel_watch(int value) {
    watch_signal = value;
}

int wakelease_watch(pid_t pid, void *context, wakelease_watch_callback check) {
    if (pid <= 0 || !check) return 125;
    int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};
    struct sigaction saved[4], action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_handler = cancel_watch;
    watch_signal = 0;
    for (int index = 0; index < 4; index++) sigaction(signals[index], &action, &saved[index]);
    int result = 0;
    int fd = kqueue();
    if (fd < 0) { result = 125; goto cleanup; }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct kevent registration, event;
    EV_SET(&registration, pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (!check(pid, context)) goto cleanup;
    if (kevent(fd, &registration, 1, NULL, 0, NULL) < 0) {
        result = errno == ESRCH ? 0 : 125;
        goto cleanup;
    }
    while (!watch_signal && check(pid, context)) {
        struct timespec timeout = {30, 0};
        int count = kevent(fd, NULL, 0, &event, 1, &timeout);
        if (count > 0) break;
        if (count < 0 && errno != EINTR) { result = 125; break; }
    }
cleanup:
    if (fd >= 0) close(fd);
    if (watch_signal) result = 128 + watch_signal;
    for (int index = 0; index < 4; index++) sigaction(signals[index], &saved[index], NULL);
    return result;
}
