// Fills two gaps between zenoh-pico's Unix platform code and Android's C library (bionic). Force-included
// into the zenoh-pico sources for Android only (see CMakeLists.txt); nothing here changes other builds.
#pragma once
#ifdef __ANDROID__
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/types.h>

#if __ANDROID_API__ < 28
// getrandom() arrived in API 28; the app supports API 24. arc4random_buf is in every bionic version and
// never fails or blocks.
static inline ssize_t getrandom(void *buf, size_t len, unsigned int flags) {
  (void)flags;
  arc4random_buf(buf, len);
  return (ssize_t)len;
}
#endif

// bionic has no pthread_cancel. zenoh-pico uses it only in _z_task_cancel, which nothing calls in this
// build (sessions stop their tasks by flag and join them), so an error return is enough.
static inline int pthread_cancel(pthread_t thread) {
  (void)thread;
  return ENOSYS;
}
#endif
