#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*open_fn)(const char *, int, ...);
typedef int (*openat_fn)(int, const char *, int, ...);
typedef int (*creat_fn)(const char *, mode_t);
typedef int (*path_int_fn)(const char *);
typedef int (*path_mode_fn)(const char *, mode_t);
typedef int (*rename_fn)(const char *, const char *);
typedef int (*renameat_fn)(int, const char *, int, const char *);
typedef int (*unlinkat_fn)(int, const char *, int);

static void *real_symbol(const char *name) {
  return dlsym(RTLD_NEXT, name);
}

static int append_component(char *out, size_t out_size, const char *component) {
  size_t len = strlen(out);
  size_t component_len = strlen(component);
  if (component_len == 0 || strcmp(component, ".") == 0) {
    return 0;
  }
  if (strcmp(component, "..") == 0) {
    if (len > 1) {
      char *last = strrchr(out, '/');
      if (last != 0 && last != out) {
        *last = '\0';
      } else {
        strcpy(out, "/");
      }
    }
    return 0;
  }
  if (len > 1) {
    if (len + 1 >= out_size) return -1;
    strcat(out, "/");
    len += 1;
  }
  if (len + component_len >= out_size) return -1;
  strcat(out, component);
  return 0;
}

static int normalize_absolute_path(const char *input, char *out, size_t out_size) {
  char temp[PATH_MAX];
  char *save = 0;
  char *token = 0;

  if (input == 0 || input[0] != '/' || out_size < 2) return -1;
  if (strlen(input) >= sizeof(temp)) return -1;
  strcpy(temp, input);
  strcpy(out, "/");

  token = strtok_r(temp, "/", &save);
  while (token != 0) {
    if (append_component(out, out_size, token) != 0) return -1;
    token = strtok_r(0, "/", &save);
  }
  return 0;
}

static int dirfd_base(int dirfd, char *out, size_t out_size) {
  if (dirfd == AT_FDCWD) {
    return getcwd(out, out_size) == 0 ? -1 : 0;
  }

  char fd_path[64];
  ssize_t count = 0;
  snprintf(fd_path, sizeof(fd_path), "/proc/self/fd/%d", dirfd);
  count = readlink(fd_path, out, out_size - 1);
  if (count < 0) return -1;
  out[count] = '\0';
  return 0;
}

static int absolute_path_for(int dirfd, const char *path, char *out, size_t out_size) {
  char base[PATH_MAX];
  char combined[PATH_MAX];

  if (path == 0 || path[0] == '\0') return -1;
  if (path[0] == '/') {
    return normalize_absolute_path(path, out, out_size);
  }
  if (dirfd_base(dirfd, base, sizeof(base)) != 0) return -1;
  if (snprintf(combined, sizeof(combined), "%s/%s", base, path) >= (int)sizeof(combined)) return -1;
  return normalize_absolute_path(combined, out, out_size);
}

static int canonical_or_parent_path(int dirfd, const char *path, char *out, size_t out_size) {
  char absolute[PATH_MAX];
  char probe[PATH_MAX];
  char suffix[PATH_MAX] = "";
  char resolved[PATH_MAX];

  if (absolute_path_for(dirfd, path, absolute, sizeof(absolute)) != 0) return -1;
  if (realpath(absolute, resolved) != 0) {
    return normalize_absolute_path(resolved, out, out_size);
  }

  strcpy(probe, absolute);
  while (strcmp(probe, "/") != 0) {
    char *slash = strrchr(probe, '/');
    char next_suffix[PATH_MAX];
    if (slash == 0) return -1;
    snprintf(next_suffix, sizeof(next_suffix), "/%s%s", slash + 1, suffix);
    strcpy(suffix, next_suffix);
    if (slash == probe) {
      strcpy(probe, "/");
    } else {
      *slash = '\0';
    }
    if (realpath(probe, resolved) != 0) {
      char combined[PATH_MAX];
      if (snprintf(combined, sizeof(combined), "%s%s", resolved, suffix) >= (int)sizeof(combined)) return -1;
      return normalize_absolute_path(combined, out, out_size);
    }
  }
  return -1;
}

static int path_has_root_prefix(const char *path, const char *root) {
  size_t root_len = strlen(root);
  if (root_len == 0) return 0;
  if (strcmp(path, root) == 0) return 1;
  return strncmp(path, root, root_len) == 0 && path[root_len] == '/';
}

static int target_allowed(int dirfd, const char *path) {
  const char *raw = getenv("CLASP_FILESYSTEM_WRITE_ALLOWED_ROOTS");
  const char *cursor = raw;
  char target[PATH_MAX];

  if (raw == 0 || raw[0] == '\0') return 0;
  if (canonical_or_parent_path(dirfd, path, target, sizeof(target)) != 0) return 0;

  while (cursor != 0 && cursor[0] != '\0') {
    char root[PATH_MAX];
    size_t index = 0;
    while (cursor[0] != '\0' && cursor[0] != ';' && index + 1 < sizeof(root)) {
      root[index++] = cursor[0];
      cursor += 1;
    }
    root[index] = '\0';
    if (path_has_root_prefix(target, root)) return 1;
    while (cursor[0] != '\0' && cursor[0] != ';') cursor += 1;
    if (cursor[0] == ';') cursor += 1;
  }
  return 0;
}

static int flags_write_filesystem(int flags) {
  return (flags & O_WRONLY) || (flags & O_RDWR) || (flags & O_CREAT) || (flags & O_TRUNC) || (flags & O_APPEND);
}

static int deny_if_disallowed(int dirfd, const char *path) {
  if (target_allowed(dirfd, path)) return 0;
  errno = EACCES;
  return -1;
}

int open(const char *path, int flags, ...) {
  static open_fn real_open = 0;
  mode_t mode = 0;
  va_list args;
  if (real_open == 0) real_open = (open_fn)real_symbol("open");
  if ((flags & O_CREAT) != 0) {
    va_start(args, flags);
    mode = (mode_t)va_arg(args, int);
    va_end(args);
  }
  if (flags_write_filesystem(flags) && deny_if_disallowed(AT_FDCWD, path) != 0) return -1;
  if ((flags & O_CREAT) != 0) return real_open(path, flags, mode);
  return real_open(path, flags);
}

int open64(const char *path, int flags, ...) {
  static open_fn real_open64 = 0;
  mode_t mode = 0;
  va_list args;
  if (real_open64 == 0) real_open64 = (open_fn)real_symbol("open64");
  if ((flags & O_CREAT) != 0) {
    va_start(args, flags);
    mode = (mode_t)va_arg(args, int);
    va_end(args);
  }
  if (flags_write_filesystem(flags) && deny_if_disallowed(AT_FDCWD, path) != 0) return -1;
  if ((flags & O_CREAT) != 0) return real_open64(path, flags, mode);
  return real_open64(path, flags);
}

int openat(int dirfd, const char *path, int flags, ...) {
  static openat_fn real_openat = 0;
  mode_t mode = 0;
  va_list args;
  if (real_openat == 0) real_openat = (openat_fn)real_symbol("openat");
  if ((flags & O_CREAT) != 0) {
    va_start(args, flags);
    mode = (mode_t)va_arg(args, int);
    va_end(args);
  }
  if (flags_write_filesystem(flags) && deny_if_disallowed(dirfd, path) != 0) return -1;
  if ((flags & O_CREAT) != 0) return real_openat(dirfd, path, flags, mode);
  return real_openat(dirfd, path, flags);
}

int openat64(int dirfd, const char *path, int flags, ...) {
  static openat_fn real_openat64 = 0;
  mode_t mode = 0;
  va_list args;
  if (real_openat64 == 0) real_openat64 = (openat_fn)real_symbol("openat64");
  if ((flags & O_CREAT) != 0) {
    va_start(args, flags);
    mode = (mode_t)va_arg(args, int);
    va_end(args);
  }
  if (flags_write_filesystem(flags) && deny_if_disallowed(dirfd, path) != 0) return -1;
  if ((flags & O_CREAT) != 0) return real_openat64(dirfd, path, flags, mode);
  return real_openat64(dirfd, path, flags);
}

int creat(const char *path, mode_t mode) {
  static creat_fn real_creat = 0;
  if (real_creat == 0) real_creat = (creat_fn)real_symbol("creat");
  if (deny_if_disallowed(AT_FDCWD, path) != 0) return -1;
  return real_creat(path, mode);
}

int truncate(const char *path, off_t length) {
  static int (*real_truncate)(const char *, off_t) = 0;
  if (real_truncate == 0) real_truncate = (int (*)(const char *, off_t))real_symbol("truncate");
  if (deny_if_disallowed(AT_FDCWD, path) != 0) return -1;
  return real_truncate(path, length);
}

int unlink(const char *path) {
  static path_int_fn real_unlink = 0;
  if (real_unlink == 0) real_unlink = (path_int_fn)real_symbol("unlink");
  if (deny_if_disallowed(AT_FDCWD, path) != 0) return -1;
  return real_unlink(path);
}

int unlinkat(int dirfd, const char *path, int flags) {
  static unlinkat_fn real_unlinkat = 0;
  if (real_unlinkat == 0) real_unlinkat = (unlinkat_fn)real_symbol("unlinkat");
  if (deny_if_disallowed(dirfd, path) != 0) return -1;
  return real_unlinkat(dirfd, path, flags);
}

int rename(const char *old_path, const char *new_path) {
  static rename_fn real_rename = 0;
  if (real_rename == 0) real_rename = (rename_fn)real_symbol("rename");
  if (deny_if_disallowed(AT_FDCWD, old_path) != 0) return -1;
  if (deny_if_disallowed(AT_FDCWD, new_path) != 0) return -1;
  return real_rename(old_path, new_path);
}

int renameat(int old_dirfd, const char *old_path, int new_dirfd, const char *new_path) {
  static renameat_fn real_renameat = 0;
  if (real_renameat == 0) real_renameat = (renameat_fn)real_symbol("renameat");
  if (deny_if_disallowed(old_dirfd, old_path) != 0) return -1;
  if (deny_if_disallowed(new_dirfd, new_path) != 0) return -1;
  return real_renameat(old_dirfd, old_path, new_dirfd, new_path);
}

int mkdir(const char *path, mode_t mode) {
  static path_mode_fn real_mkdir = 0;
  if (real_mkdir == 0) real_mkdir = (path_mode_fn)real_symbol("mkdir");
  if (deny_if_disallowed(AT_FDCWD, path) != 0) return -1;
  return real_mkdir(path, mode);
}

int rmdir(const char *path) {
  static path_int_fn real_rmdir = 0;
  if (real_rmdir == 0) real_rmdir = (path_int_fn)real_symbol("rmdir");
  if (deny_if_disallowed(AT_FDCWD, path) != 0) return -1;
  return real_rmdir(path);
}
