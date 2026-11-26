/* Interposes the libc calls Godot 4.3 uses for token files.
 * A path-based stat can be made to report owner-only mode while the
 * descriptor that is actually read or created still has group or other
 * bits. fstat is left honest so a check on the same descriptor is not fooled.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* glibc's x86_64 stat64 ABI version. Headers no longer export _STAT_VER. */
#define STAT_VER 1

static int initializing = 1;

static int (*real_open)(const char *, int, ...);
static int (*real_open64)(const char *, int, ...);
static int (*real_openat)(int, const char *, int, ...);
static int (*real_openat64)(int, const char *, int, ...);
static FILE *(*real_fopen)(const char *, const char *);
static FILE *(*real_fopen64)(const char *, const char *);
static int (*real_mkdir)(const char *, mode_t);
static int (*real_chmod)(const char *, mode_t);
static int (*real_fchmod)(int, mode_t);
static int (*real_xstat64)(int, const char *, struct stat64 *);
static int (*real_lxstat64)(int, const char *, struct stat64 *);
static int (*real_fxstat64)(int, int, struct stat64 *);
static int (*real_stat)(const char *, struct stat *);
static int (*real_stat64)(const char *, struct stat64 *);
static int (*real_lstat)(const char *, struct stat *);
static int (*real_lstat64)(const char *, struct stat64 *);
static int (*real_fchmodat)(int, const char *, mode_t, int);

static int raw_open(const char *path, int flags, mode_t mode) {
	return (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
}

__attribute__((constructor)) static void init_syms(void) {
	real_open = dlsym(RTLD_NEXT, "open");
	real_open64 = dlsym(RTLD_NEXT, "open64");
	real_openat = dlsym(RTLD_NEXT, "openat");
	real_openat64 = dlsym(RTLD_NEXT, "openat64");
	real_fopen = dlsym(RTLD_NEXT, "fopen");
	real_fopen64 = dlsym(RTLD_NEXT, "fopen64");
	real_mkdir = dlsym(RTLD_NEXT, "mkdir");
	real_chmod = dlsym(RTLD_NEXT, "chmod");
	real_fchmod = dlsym(RTLD_NEXT, "fchmod");
	real_xstat64 = dlsym(RTLD_NEXT, "__xstat64");
	real_lxstat64 = dlsym(RTLD_NEXT, "__lxstat64");
	real_fxstat64 = dlsym(RTLD_NEXT, "__fxstat64");
	real_stat = dlsym(RTLD_NEXT, "stat");
	real_stat64 = dlsym(RTLD_NEXT, "stat64");
	real_lstat = dlsym(RTLD_NEXT, "lstat");
	real_lstat64 = dlsym(RTLD_NEXT, "lstat64");
	real_fchmodat = dlsym(RTLD_NEXT, "fchmodat");
	initializing = 0;
}

static int path_listed(const char *path) {
	const char *list;
	const char *cursor;
	size_t length;
	if (path == NULL || path[0] == '\0') {
		return 0;
	}
	list = getenv("TOKEN_EXPOSURE_WATCH");
	if (list == NULL || list[0] == '\0') {
		return 0;
	}
	length = strlen(path);
	cursor = list;
	while (*cursor) {
		const char *colon = strchr(cursor, ':');
		size_t entry = colon ? (size_t)(colon - cursor) : strlen(cursor);
		if (entry == length && memcmp(cursor, path, length) == 0) {
			return 1;
		}
		if (colon == NULL) {
			break;
		}
		cursor = colon + 1;
	}
	return 0;
}

static int lied(const char *path) {
	const char *lie = getenv("TOKEN_EXPOSURE_LIE");
	return lie != NULL && lie[0] != '\0' && path != NULL && strcmp(lie, path) == 0;
}

static void note(const char *why, const char *path, mode_t mode) {
	const char *flagpath;
	char line[1024];
	int fd;
	int count;
	if (initializing || path == NULL || (mode & 077) == 0 || !path_listed(path)) {
		return;
	}
	flagpath = getenv("TOKEN_EXPOSURE_FLAG");
	if (flagpath == NULL || flagpath[0] == '\0' || strcmp(flagpath, path) == 0) {
		return;
	}
	count = snprintf(line, sizeof(line), "%s %s %o\n", why, path, (unsigned)(mode & 0777));
	if (count < 0) {
		return;
	}
	fd = raw_open(flagpath, O_WRONLY | O_CREAT | O_APPEND, 0600);
	if (fd < 0) {
		return;
	}
	if (write(fd, line, (size_t)count) < 0) {
		close(fd);
		return;
	}
	close(fd);
}

static void note_fd(const char *why, int fd) {
	struct stat64 status;
	char link[64];
	char path[4096];
	ssize_t length;
	if (initializing || fd < 0 || real_fxstat64 == NULL) {
		return;
	}
	if (real_fxstat64(STAT_VER, fd, &status) != 0) {
		return;
	}
	snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
	length = readlink(link, path, sizeof(path) - 1);
	if (length < 0) {
		return;
	}
	path[length] = '\0';
	note(why, path, status.st_mode);
}

static int write_flags(int flags) {
	return (flags & (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND)) != 0;
}

static int call_open(int (*fn)(const char *, int, ...), const char *path, int flags, mode_t mode) {
	if (fn == NULL) {
		return raw_open(path, flags, mode);
	}
	if (flags & O_CREAT) {
		return fn(path, flags, mode);
	}
	return fn(path, flags);
}

static int call_openat(int (*fn)(int, const char *, int, ...), int dirfd, const char *path, int flags, mode_t mode) {
	if (fn == NULL) {
		errno = ENOSYS;
		return -1;
	}
	if (flags & O_CREAT) {
		return fn(dirfd, path, flags, mode);
	}
	return fn(dirfd, path, flags);
}

int open(const char *path, int flags, ...) {
	mode_t mode = 0;
	int fd;
	if (flags & O_CREAT) {
		va_list args;
		va_start(args, flags);
		mode = (mode_t)va_arg(args, int);
		va_end(args);
	}
	fd = call_open(real_open, path, flags, mode);
	if (fd >= 0 && write_flags(flags)) {
		note_fd("open", fd);
	}
	return fd;
}

int open64(const char *path, int flags, ...) {
	mode_t mode = 0;
	int fd;
	if (flags & O_CREAT) {
		va_list args;
		va_start(args, flags);
		mode = (mode_t)va_arg(args, int);
		va_end(args);
	}
	fd = call_open(real_open64 != NULL ? real_open64 : real_open, path, flags, mode);
	if (fd >= 0 && write_flags(flags)) {
		note_fd("open64", fd);
	}
	return fd;
}

int openat(int dirfd, const char *path, int flags, ...) {
	mode_t mode = 0;
	int fd;
	if (flags & O_CREAT) {
		va_list args;
		va_start(args, flags);
		mode = (mode_t)va_arg(args, int);
		va_end(args);
	}
	fd = call_openat(real_openat, dirfd, path, flags, mode);
	if (fd >= 0 && path != NULL && path[0] == '/' && write_flags(flags)) {
		note_fd("openat", fd);
	}
	return fd;
}

int openat64(int dirfd, const char *path, int flags, ...) {
	mode_t mode = 0;
	int fd;
	if (flags & O_CREAT) {
		va_list args;
		va_start(args, flags);
		mode = (mode_t)va_arg(args, int);
		va_end(args);
	}
	fd = call_openat(real_openat64 != NULL ? real_openat64 : real_openat, dirfd, path, flags, mode);
	if (fd >= 0 && path != NULL && path[0] == '/' && write_flags(flags)) {
		note_fd("openat64", fd);
	}
	return fd;
}

static int writing_stdio(const char *mode) {
	return mode != NULL && (strchr(mode, 'w') != NULL || strchr(mode, 'a') != NULL || strchr(mode, '+') != NULL);
}

FILE *fopen(const char *path, const char *mode) {
	FILE *file = real_fopen != NULL ? real_fopen(path, mode) : NULL;
	if (file != NULL && writing_stdio(mode)) {
		note_fd("fopen", fileno(file));
	}
	return file;
}

FILE *fopen64(const char *path, const char *mode) {
	FILE *(*fn)(const char *, const char *) = real_fopen64 != NULL ? real_fopen64 : real_fopen;
	FILE *file = fn != NULL ? fn(path, mode) : NULL;
	if (file != NULL && writing_stdio(mode)) {
		note_fd("fopen64", fileno(file));
	}
	return file;
}

int mkdir(const char *path, mode_t mode) {
	int result = real_mkdir != NULL ? real_mkdir(path, mode) : -1;
	struct stat64 status;
	if (result == 0 && real_xstat64 != NULL && real_xstat64(STAT_VER, path, &status) == 0) {
		note("mkdir", path, status.st_mode);
	}
	return result;
}

int chmod(const char *path, mode_t mode) {
	int result = real_chmod != NULL ? real_chmod(path, mode) : -1;
	if (result == 0) {
		note("chmod", path, mode);
	}
	return result;
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags) {
	int result = real_fchmodat != NULL ? real_fchmodat(dirfd, path, mode, flags) : -1;
	if (result == 0 && path != NULL && path[0] == '/') {
		note("fchmodat", path, mode);
	}
	return result;
}

int fchmod(int fd, mode_t mode) {
	int result = real_fchmod != NULL ? real_fchmod(fd, mode) : -1;
	char link[64];
	char path[4096];
	ssize_t length;
	if (result != 0) {
		return result;
	}
	snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
	length = readlink(link, path, sizeof(path) - 1);
	if (length >= 0) {
		path[length] = '\0';
		note("fchmod", path, mode);
	}
	return result;
}

static void mask_mode(struct stat64 *status) {
	if (status != NULL) {
		status->st_mode = (status->st_mode & ~0777) | 0600;
	}
}

static void mask_mode32(struct stat *status) {
	if (status != NULL) {
		status->st_mode = (status->st_mode & ~0777) | 0600;
	}
}

int stat(const char *path, struct stat *status) {
	int result = real_stat != NULL ? real_stat(path, status) : -1;
	if (result == 0 && lied(path)) {
		mask_mode32(status);
	}
	return result;
}

int stat64(const char *path, struct stat64 *status) {
	int result = real_stat64 != NULL ? real_stat64(path, status) : -1;
	if (result == 0 && lied(path)) {
		mask_mode(status);
	}
	return result;
}

int lstat(const char *path, struct stat *status) {
	int result = real_lstat != NULL ? real_lstat(path, status) : -1;
	if (result == 0 && lied(path)) {
		mask_mode32(status);
	}
	return result;
}

int lstat64(const char *path, struct stat64 *status) {
	int result = real_lstat64 != NULL ? real_lstat64(path, status) : -1;
	if (result == 0 && lied(path)) {
		mask_mode(status);
	}
	return result;
}

int __xstat64(int version, const char *path, struct stat64 *status) {
	int result = real_xstat64 != NULL ? real_xstat64(version, path, status) : -1;
	if (result == 0 && lied(path)) {
		mask_mode(status);
	}
	return result;
}

int __lxstat64(int version, const char *path, struct stat64 *status) {
	int result = real_lxstat64 != NULL ? real_lxstat64(version, path, status) : -1;
	if (result == 0 && lied(path)) {
		mask_mode(status);
	}
	return result;
}
