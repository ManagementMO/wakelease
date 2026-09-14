#ifndef WAKELEASE_PROCESS_H
#define WAKELEASE_PROCESS_H
#include <sys/types.h>

typedef void (*wakelease_process_callback)(int event, pid_t pid, void *context);
int wakelease_run(char *const arguments[], void *context, wakelease_process_callback callback);
typedef int (*wakelease_watch_callback)(pid_t pid, void *context);
int wakelease_watch(pid_t pid, void *context, wakelease_watch_callback check);
int wakelease_capture(char *const arguments[], double timeout, unsigned char *output, size_t capacity, size_t *length, pid_t *child);
int wakelease_clear_directory_acl(int descriptor);
int wakelease_acl_allows_writing(int descriptor);
int wakelease_grant_removal(int descriptor, uid_t uid);
#endif
