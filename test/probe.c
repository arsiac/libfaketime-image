/* Measures what a preloaded libfaketime does in the environment it runs in.
 *
 * Driver mode runs every check in its own child process: a call that deadlocks
 * must not take the rest of the report with it. Each child gets its own
 * FAKETIME because the library reads it once at startup, so a new value needs
 * a new process.
 *
 * Real time is read with raw syscalls. libfaketime interposes the libc
 * symbols, so only the kernel path shows what actually happened.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define ANCHOR_EPOCH 1577836800L
#define CHECK_TIMEOUT 4
#define PROBE_FILE "/tmp/.libfaketime-probe"

#define F_NO_PRELOAD   1
#define F_KEEP_MONOTONIC 2

static double mono_real(void)
{
  struct timespec ts;

  if (syscall(SYS_clock_gettime, CLOCK_MONOTONIC, &ts) != 0)
    return 0;
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static double real_now(void)
{
  struct timespec ts;

  if (syscall(SYS_clock_gettime, CLOCK_REALTIME, &ts) != 0)
    return 0;
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static long round_l(double v)
{
  return (long)(v < 0 ? v - 0.5 : v + 0.5);
}

static void sleep_real(long ns)
{
  struct timespec req, rem;

  req.tv_sec = ns / 1000000000L;
  req.tv_nsec = ns % 1000000000L;
  while (syscall(SYS_nanosleep, &req, &rem) != 0 && errno == EINTR)
    req = rem;
}

static void emit_offset(const char *key, double fake)
{
  printf("%s=%ld\n", key, round_l(fake - real_now()));
}

#ifdef SYS_newfstatat
#define RAW_FSTATAT SYS_newfstatat
#else
#define RAW_FSTATAT SYS_fstatat
#endif

static int make_file(const char *path)
{
  struct timespec ts[2];
  int fd;

  fd = (int)syscall(SYS_openat, AT_FDCWD, path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
  if (fd < 0)
    return -1;
  close(fd);

  if (syscall(SYS_clock_gettime, CLOCK_REALTIME, &ts[0]) != 0)
    return -1;
  ts[1] = ts[0];
  return (int)syscall(SYS_utimensat, AT_FDCWD, path, ts, 0);
}

static long raw_mtime(const char *path)
{
  struct stat st;

  if (syscall(RAW_FSTATAT, AT_FDCWD, path, &st, 0) != 0)
    return -1;
  return (long)st.st_mtime;
}

static void c_time(void)
{
  emit_offset("time", (double)time(NULL));
}

static void c_gtod(void)
{
  struct timeval tv;

  if (gettimeofday(&tv, NULL) != 0) {
    printf("gtod=error\n");
    return;
  }
  emit_offset("gtod", (double)tv.tv_sec + (double)tv.tv_usec / 1e6);
}

/* glibc ignores the argument since 2.31, so only the call outcome is judged. */
static void c_gtod_tz(void)
{
  struct timeval tv;
  struct timezone tz;

  memset(&tz, 0, sizeof tz);
  printf("gtod_tz=%s\n", gettimeofday(&tv, &tz) == 0 ? "yes" : "no");
}

static void c_clock_rt(void)
{
  struct timespec ts;

  if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
    printf("clock_rt=error\n");
    return;
  }
  emit_offset("clock_rt", (double)ts.tv_sec + (double)ts.tv_nsec / 1e9);
}

static void c_timespec_get(void)
{
  struct timespec ts;

  if (timespec_get(&ts, TIME_UTC) != TIME_UTC) {
    printf("timespec_get=error\n");
    return;
  }
  emit_offset("timespec_get", (double)ts.tv_sec + (double)ts.tv_nsec / 1e9);
}

static void mono_delta(const char *key)
{
  struct timespec a, b;
  double d;

  clock_gettime(CLOCK_MONOTONIC, &a);
  sleep_real(1000000000L);
  clock_gettime(CLOCK_MONOTONIC, &b);
  d = (double)(b.tv_sec - a.tv_sec) + (double)(b.tv_nsec - a.tv_nsec) / 1e9;
  printf("%s=%ld\n", key, round_l(d * 1000));
}

static void c_clock_mono(void)
{
  mono_delta("clock_mono");
}

static void c_mono_default(void)
{
  mono_delta("mono_default");
}

static void c_offset_neg(void)
{
  emit_offset("offset_neg", (double)time(NULL));
}

static void c_freeze(void)
{
  struct timespec a, b;
  double d;

  clock_gettime(CLOCK_REALTIME, &a);
  sleep_real(2000000000L);
  clock_gettime(CLOCK_REALTIME, &b);
  d = (double)(b.tv_sec - a.tv_sec) + (double)(b.tv_nsec - a.tv_nsec) / 1e9;
  printf("freeze_epoch=%ld\n", (long)a.tv_sec);
  printf("freeze=%s\n", d > -1.0 && d < 1.0 ? "yes" : "no");
}

static void c_anchor(void)
{
  struct timespec a, b;
  double d;
  int at_anchor;

  clock_gettime(CLOCK_REALTIME, &a);
  sleep_real(2000000000L);
  clock_gettime(CLOCK_REALTIME, &b);
  d = (double)(b.tv_sec - a.tv_sec) + (double)(b.tv_nsec - a.tv_nsec) / 1e9;
  at_anchor = a.tv_sec > ANCHOR_EPOCH - 5 && a.tv_sec < ANCHOR_EPOCH + 5;
  printf("anchor_epoch=%ld\n", (long)a.tv_sec);
  printf("anchor=%s\n", at_anchor && d > 1.0 ? "yes" : "no");
}

static void c_rate(void)
{
  struct timespec a, b;
  double d;

  clock_gettime(CLOCK_REALTIME, &a);
  sleep_real(1000000000L);
  clock_gettime(CLOCK_REALTIME, &b);
  d = (double)(b.tv_sec - a.tv_sec) + (double)(b.tv_nsec - a.tv_nsec) / 1e9;
  printf("rate=%ld\n", round_l(d * 1000));
}

/* A POSIX TZ string keeps the check independent of an installed tzdata. */
static void c_tz(void)
{
  struct timespec ts;
  struct tm tm;
  int utc_hour, shifted_hour;

  clock_gettime(CLOCK_REALTIME, &ts);

  setenv("TZ", "UTC", 1);
  tzset();
  if (localtime_r(&ts.tv_sec, &tm) == NULL) {
    printf("tz=error\n");
    return;
  }
  utc_hour = tm.tm_hour;

  setenv("TZ", "XXX-3", 1);
  tzset();
  if (localtime_r(&ts.tv_sec, &tm) == NULL) {
    printf("tz=error\n");
    return;
  }
  shifted_hour = tm.tm_hour;

  printf("tz=%s\n", (shifted_hour - utc_hour + 24) % 24 == 3 ? "yes" : "no");
}

static void c_stat(void)
{
  struct stat st;
  long raw, shift;

  if (make_file(PROBE_FILE) != 0 || (raw = raw_mtime(PROBE_FILE)) < 0) {
    printf("stat=error\n");
    return;
  }
  if (stat(PROBE_FILE, &st) != 0) {
    printf("stat=error\n");
    unlink(PROBE_FILE);
    return;
  }
  shift = (long)st.st_mtime - raw;
  printf("stat_shift=%ld\n", shift);
  printf("stat=%s\n", shift > 3600 ? "yes" : "no");
  unlink(PROBE_FILE);
}

static void c_statx(void)
{
#if defined(STATX_MTIME)
  struct statx sx;
  long raw, shift;

  if (make_file(PROBE_FILE) != 0 || (raw = raw_mtime(PROBE_FILE)) < 0) {
    printf("statx=error\n");
    return;
  }
  if (statx(AT_FDCWD, PROBE_FILE, 0, STATX_MTIME, &sx) != 0) {
    printf("statx=error\n");
    unlink(PROBE_FILE);
    return;
  }
  shift = (long)sx.stx_mtime.tv_sec - raw;
  printf("statx=%s\n", shift > 3600 ? "yes" : "no");
  unlink(PROBE_FILE);
#else
  printf("statx=n/a\n");
#endif
}

static void c_sleep_ms(void)
{
  struct timespec req, rem;
  double t0;

  t0 = mono_real();
  req.tv_sec = 1;
  req.tv_nsec = 0;
  while (nanosleep(&req, &rem) != 0 && errno == EINTR)
    req = rem;
  printf("sleep_ms=%ld\n", round_l((mono_real() - t0) * 1000));
}

static void *mt_worker(void *arg)
{
  long *out = arg;
  time_t first = 0;
  int i;

  for (i = 0; i < 1000; i++) {
    struct timeval tv;

    if (i == 0)
      first = time(NULL);
    (void)gettimeofday(&tv, NULL);
  }
  *out = (long)first;
  return NULL;
}

/* The multi-threaded variant is the only one that may be tested this way. */
static void c_mt_thread(void)
{
  pthread_t tid[4];
  long val[4] = {0, 0, 0, 0};
  long lo, hi;
  int i;

  for (i = 0; i < 4; i++) {
    if (pthread_create(&tid[i], NULL, mt_worker, &val[i]) != 0) {
      printf("mt_thread=error\n");
      return;
    }
  }
  for (i = 0; i < 4; i++)
    pthread_join(tid[i], NULL);

  lo = hi = val[0];
  for (i = 1; i < 4; i++) {
    if (val[i] < lo)
      lo = val[i];
    if (val[i] > hi)
      hi = val[i];
  }
  printf("mt_thread=%s\n", hi - lo <= 2 ? "yes" : "no");
}

static void c_cli(void)
{
  const char *wrapper = "/usr/local/bin/faketime";
  int fds[2];
  pid_t pid;
  char buf[64];
  ssize_t n;
  long fake, off;

  if (access(wrapper, X_OK) != 0) {
    printf("cli=n/a\n");
    return;
  }
  if (pipe(fds) != 0) {
    printf("cli=error\n");
    return;
  }
  pid = fork();
  if (pid == 0) {
    dup2(fds[1], STDOUT_FILENO);
    close(fds[0]);
    close(fds[1]);
    execl(wrapper, "faketime", "-f", "+1d", "date", "+%s", (char *)NULL);
    _exit(127);
  }
  close(fds[1]);
  n = read(fds[0], buf, sizeof buf - 1);
  close(fds[0]);
  if (n <= 0) {
    waitpid(pid, NULL, 0);
    printf("cli=error\n");
    return;
  }
  buf[n] = '\0';
  waitpid(pid, NULL, 0);
  fake = strtol(buf, NULL, 10);
  off = fake - (long)real_now();
  printf("cli=%ld\n", off);
}

struct spec {
  const char *key;
  const char *faketime;
  unsigned flags;
  void (*run)(void);
};

static const struct spec specs[] = {
  {"time", "+1d", 0, c_time},
  {"gtod", "+1d", 0, c_gtod},
  {"gtod_tz", "+1d", 0, c_gtod_tz},
  {"clock_rt", "+1d", 0, c_clock_rt},
  {"timespec_get", "+1d", 0, c_timespec_get},
  {"clock_mono", "+1d", 0, c_clock_mono},
  {"mono_default", "+1d", F_KEEP_MONOTONIC, c_mono_default},
  {"offset_neg", "-1d", 0, c_offset_neg},
  {"freeze", "2020-01-01 00:00:00", 0, c_freeze},
  {"anchor", "@2020-01-01 00:00:00", 0, c_anchor},
  {"rate", "+0 x2", 0, c_rate},
  {"tz", "2020-01-01 00:00:00", 0, c_tz},
  {"stat", "+1d", 0, c_stat},
  {"statx", "+1d", 0, c_statx},
  {"sleep_ms", "+1d", 0, c_sleep_ms},
  {"mt_thread", "+1d", 0, c_mt_thread},
  {"cli", "", F_NO_PRELOAD, c_cli},
};

#define NSPECS (sizeof specs / sizeof specs[0])

static int run_child(const char *self, const struct spec *s, char *out, size_t cap)
{
  int fds[2];
  pid_t pid;
  size_t len = 0;
  double deadline;
  int status = 0;

  if (pipe(fds) != 0)
    return -1;
  pid = fork();
  if (pid == 0) {
    dup2(fds[1], STDOUT_FILENO);
    close(fds[0]);
    close(fds[1]);
    execl(self, "probe", "--check", s->key, (char *)NULL);
    _exit(127);
  }
  close(fds[1]);

  deadline = mono_real() + CHECK_TIMEOUT;
  for (;;) {
    struct pollfd pfd;
    double left = deadline - mono_real();
    ssize_t n;
    int ready;

    if (left <= 0) {
      kill(pid, SIGKILL);
      waitpid(pid, &status, 0);
      return -2;
    }
    pfd.fd = fds[0];
    pfd.events = POLLIN;
    pfd.revents = 0;
    ready = poll(&pfd, 1, (int)(left * 1000) + 1);
    if (ready < 0) {
      if (errno == EINTR)
        continue;
      close(fds[0]);
      waitpid(pid, &status, 0);
      return -1;
    }
    if (ready == 0)
      continue;
    n = read(fds[0], out + len, cap - 1 - len);
    if (n <= 0)
      break;
    len += (size_t)n;
    if (len >= cap - 1)
      break;
  }
  close(fds[0]);
  waitpid(pid, &status, 0);
  out[len] = '\0';
  if (len == 0 && !WIFEXITED(status))
    return -1;
  return 0;
}

static int check_main(const char *key)
{
  size_t i;

  if (strcmp(key, "date") == 0) {
    printf("child_time=%ld\n", (long)time(NULL));
    return 0;
  }
  for (i = 0; i < NSPECS; i++) {
    if (strcmp(specs[i].key, key) != 0)
      continue;
    specs[i].run();
    return 0;
  }
  fprintf(stderr, "unknown check: %s\n", key);
  return 2;
}

static char saved_faketime[128];
static int had_faketime;
static int had_monotonic;

/* FAKETIME is read when the library initialises, so it has to be in the
 * environment of the exec, not set afterwards in the check process. */
static void apply_env(const struct spec *s)
{
  const char *v = getenv("FAKETIME");

  had_faketime = v != NULL;
  if (v != NULL) {
    snprintf(saved_faketime, sizeof saved_faketime, "%s", v);
  }
  had_monotonic = getenv("DONT_FAKE_MONOTONIC") != NULL;

  if (s->flags & F_NO_PRELOAD) {
    unsetenv("LD_PRELOAD");
    unsetenv("FAKETIME");
  } else {
    setenv("FAKETIME", s->faketime, 1);
    if (s->flags & F_KEEP_MONOTONIC)
      unsetenv("DONT_FAKE_MONOTONIC");
    else
      setenv("DONT_FAKE_MONOTONIC", "1", 1);
  }
}

static void restore_env(void)
{
  if (had_faketime)
    setenv("FAKETIME", saved_faketime, 1);
  else
    unsetenv("FAKETIME");
  if (had_monotonic)
    setenv("DONT_FAKE_MONOTONIC", "1", 1);
  else
    unsetenv("DONT_FAKE_MONOTONIC");
}

static int driver_main(int argc, char **argv)
{
  const char *only = NULL;
  const char *skip = NULL;
  char self[4096];
  size_t i;

  if (argc > 2 && strcmp(argv[1], "--only") == 0)
    only = argv[2];
  if (argc > 2 && strcmp(argv[1], "--skip") == 0)
    skip = argv[2];

  if (readlink("/proc/self/exe", self, sizeof self - 1) <= 0) {
    fprintf(stderr, "cannot resolve own path\n");
    return 1;
  }

  for (i = 0; i < NSPECS; i++) {
    char out[8192];
    int rc;

    if (only != NULL && strcmp(only, specs[i].key) != 0)
      continue;
    if (skip != NULL && strcmp(skip, specs[i].key) == 0)
      continue;

    out[0] = '\0';
    apply_env(&specs[i]);
    rc = run_child(self, &specs[i], out, sizeof out);
    restore_env();
    if (rc == -2)
      printf("%s=hangs\n", specs[i].key);
    else if (rc != 0)
      printf("%s=error\n", specs[i].key);
    else if (out[0] == '\0')
      printf("%s=error\n", specs[i].key);
    else
      fputs(out, stdout);
    fflush(stdout);
  }
  return 0;
}

int main(int argc, char **argv)
{
  if (argc >= 3 && strcmp(argv[1], "--check") == 0)
    return check_main(argv[2]);
  return driver_main(argc, argv);
}
