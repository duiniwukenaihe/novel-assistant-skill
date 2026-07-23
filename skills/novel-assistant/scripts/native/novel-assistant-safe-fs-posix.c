#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

#ifndef O_NOFOLLOW
#error "O_NOFOLLOW is required"
#endif

#define HELPER_VERSION "1"
#define MAX_COMPONENTS 1024

struct relative_path {
    char *storage;
    char *parts[MAX_COMPONENTS];
    size_t count;
};

static int errorf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    fputs("novel-assistant-safe-fs: ", stderr);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
    return 1;
}

static int parse_relative_path(const char *value, struct relative_path *parsed) {
    size_t length;
    char *cursor;

    memset(parsed, 0, sizeof(*parsed));
    if (value == NULL || value[0] == '\0' || value[0] == '/') {
        return errorf("invalid project-relative path");
    }
    length = strlen(value);
    if (length >= PATH_MAX || value[length - 1] == '/') {
        return errorf("invalid project-relative path: %s", value);
    }
    parsed->storage = strdup(value);
    if (parsed->storage == NULL) return errorf("out of memory");

    cursor = parsed->storage;
    while (cursor != NULL) {
        char *slash = strchr(cursor, '/');
        if (slash != NULL) *slash = '\0';
        if (cursor[0] == '\0' || strcmp(cursor, ".") == 0 || strcmp(cursor, "..") == 0 || strlen(cursor) > NAME_MAX) {
            free(parsed->storage);
            parsed->storage = NULL;
            return errorf("invalid project-relative path: %s", value);
        }
        if (parsed->count >= MAX_COMPONENTS) {
            free(parsed->storage);
            parsed->storage = NULL;
            return errorf("project-relative path has too many components");
        }
        parsed->parts[parsed->count++] = cursor;
        cursor = slash == NULL ? NULL : slash + 1;
    }
    return 0;
}

static void free_relative_path(struct relative_path *parsed) {
    free(parsed->storage);
    parsed->storage = NULL;
    parsed->count = 0;
}

static int open_project_root(const char *root) {
    struct stat status;
    char *storage;
    char *cursor;
    int current;

    if (root == NULL || root[0] != '/') {
        errorf("project root must be an absolute path");
        return -1;
    }
    if (strlen(root) >= PATH_MAX) {
        errorf("project root path is too long");
        return -1;
    }
    current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (current < 0) {
        errorf("cannot open filesystem root without following links: %s", strerror(errno));
        return -1;
    }
    if (fstat(current, &status) != 0 || !S_ISDIR(status.st_mode)) {
        errorf("filesystem root is not a directory");
        close(current);
        return -1;
    }

    storage = strdup(root + 1);
    if (storage == NULL) {
        errorf("out of memory");
        close(current);
        return -1;
    }
    cursor = storage;
    while (cursor != NULL) {
        char *slash;
        int next;

        while (*cursor == '/') cursor += 1;
        if (*cursor == '\0') break;
        slash = strchr(cursor, '/');
        if (slash != NULL) *slash = '\0';
        next = openat(current, cursor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) {
            errorf("cannot open project root component without following links: %s", strerror(errno));
            free(storage);
            close(current);
            return -1;
        }
        if (fstat(next, &status) != 0 || !S_ISDIR(status.st_mode)) {
            errorf("project root component is not a directory");
            close(next);
            free(storage);
            close(current);
            return -1;
        }
        close(current);
        current = next;
        cursor = slash == NULL ? NULL : slash + 1;
    }
    free(storage);
    return current;
}

/* Returns 1 when a non-created parent is missing, -1 on error, and 0 on success. */
static int open_parent(int root_fd, const struct relative_path *parsed, bool create, int *parent_fd) {
    int current = dup(root_fd);
    size_t index;
    if (current < 0) return errorf("cannot duplicate project root descriptor: %s", strerror(errno)), -1;

    for (index = 0; index + 1 < parsed->count; index += 1) {
        int next = openat(current, parsed->parts[index], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0 && errno == ENOENT && create) {
            if (mkdirat(current, parsed->parts[index], 0700) != 0 && errno != EEXIST) {
                errorf("cannot create project directory component: %s", strerror(errno));
                close(current);
                return -1;
            }
            next = openat(current, parsed->parts[index], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        }
        if (next < 0) {
            int saved = errno;
            close(current);
            if (saved == ENOENT && !create) return 1;
            errno = saved;
            errorf("cannot open project directory component without following links: %s", strerror(errno));
            return -1;
        }
        close(current);
        current = next;
    }
    *parent_fd = current;
    return 0;
}

static int require_regular_or_missing(int parent_fd, const char *name) {
    struct stat status;
    if (fstatat(parent_fd, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) return 0;
        return errorf("cannot inspect managed target: %s", strerror(errno));
    }
    if (!S_ISREG(status.st_mode)) return errorf("managed target is not a regular file");
    return 0;
}

static int copy_bytes(int source_fd, int destination_fd) {
    unsigned char buffer[64 * 1024];
    for (;;) {
        ssize_t received = read(source_fd, buffer, sizeof(buffer));
        size_t offset = 0;
        if (received == 0) return 0;
        if (received < 0) {
            if (errno == EINTR) continue;
            return errorf("cannot read source bytes: %s", strerror(errno));
        }
        while (offset < (size_t)received) {
            ssize_t written = write(destination_fd, buffer + offset, (size_t)received - offset);
            if (written < 0) {
                if (errno == EINTR) continue;
                return errorf("cannot write managed bytes: %s", strerror(errno));
            }
            offset += (size_t)written;
        }
    }
}

static int atomic_write_from_fd(int root_fd, const char *relative, int source_fd, mode_t mode, bool replace) {
    struct relative_path parsed;
    char temporary[NAME_MAX + 1];
    int parent_fd = -1;
    int temporary_fd = -1;
    int result = 1;
    unsigned int attempt;

    temporary[0] = '\0';
    if (parse_relative_path(relative, &parsed) != 0) return 1;
    if (open_parent(root_fd, &parsed, true, &parent_fd) != 0) goto cleanup;
    if (require_regular_or_missing(parent_fd, parsed.parts[parsed.count - 1]) != 0) goto cleanup;

    for (attempt = 0; attempt < 100; attempt += 1) {
        int length = snprintf(temporary, sizeof(temporary), ".novel-assistant-safe-fs-%ld-%u", (long)getpid(), attempt);
        if (length < 0 || (size_t)length >= sizeof(temporary)) {
            errorf("cannot construct atomic temporary name");
            goto cleanup;
        }
        temporary_fd = openat(parent_fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (temporary_fd >= 0) break;
        if (errno != EEXIST) {
            errorf("cannot create atomic temporary file: %s", strerror(errno));
            goto cleanup;
        }
    }
    if (temporary_fd < 0) {
        errorf("cannot allocate atomic temporary file");
        goto cleanup;
    }
    if (copy_bytes(source_fd, temporary_fd) != 0) goto cleanup;
    if (fchmod(temporary_fd, mode & 0777) != 0) {
        errorf("cannot set managed file mode: %s", strerror(errno));
        goto cleanup;
    }
    if (fsync(temporary_fd) != 0) {
        errorf("cannot sync managed file: %s", strerror(errno));
        goto cleanup;
    }
    if (close(temporary_fd) != 0) {
        temporary_fd = -1;
        errorf("cannot close managed file: %s", strerror(errno));
        goto cleanup;
    }
    temporary_fd = -1;

    if (require_regular_or_missing(parent_fd, parsed.parts[parsed.count - 1]) != 0) goto cleanup;
    if (replace) {
        if (renameat(parent_fd, temporary, parent_fd, parsed.parts[parsed.count - 1]) != 0) {
            errorf("cannot atomically replace managed file: %s", strerror(errno));
            goto cleanup;
        }
    } else {
        if (linkat(parent_fd, temporary, parent_fd, parsed.parts[parsed.count - 1], 0) != 0) {
            if (errno != EEXIST || require_regular_or_missing(parent_fd, parsed.parts[parsed.count - 1]) != 0) {
                errorf("cannot atomically create runtime metadata: %s", strerror(errno));
                goto cleanup;
            }
        }
        if (unlinkat(parent_fd, temporary, 0) != 0) {
            errorf("cannot remove runtime metadata temporary file: %s", strerror(errno));
            goto cleanup;
        }
    }
    temporary[0] = '\0';
    if (fsync(parent_fd) != 0) {
        errorf("cannot sync managed parent directory: %s", strerror(errno));
        goto cleanup;
    }
    result = 0;

cleanup:
    if (temporary_fd >= 0) close(temporary_fd);
    if (parent_fd >= 0 && temporary[0] != '\0') unlinkat(parent_fd, temporary, 0);
    if (parent_fd >= 0) close(parent_fd);
    free_relative_path(&parsed);
    return result;
}

static int open_relative_regular(int root_fd, const char *relative) {
    struct relative_path parsed;
    struct stat status;
    int parent_fd = -1;
    int source_fd = -1;
    int parent_result;

    if (parse_relative_path(relative, &parsed) != 0) return -1;
    parent_result = open_parent(root_fd, &parsed, false, &parent_fd);
    if (parent_result != 0) {
        if (parent_result == 1) errorf("project-relative source is missing");
        free_relative_path(&parsed);
        return -1;
    }
    source_fd = openat(parent_fd, parsed.parts[parsed.count - 1], O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (source_fd < 0 || fstat(source_fd, &status) != 0 || !S_ISREG(status.st_mode)) {
        if (source_fd >= 0) close(source_fd);
        source_fd = -1;
        errorf("project-relative source is not a regular file");
    }
    close(parent_fd);
    free_relative_path(&parsed);
    return source_fd;
}

static int write_stdin_command(int root_fd, const char *relative, const char *mode_text) {
    char *end = NULL;
    long mode = strtol(mode_text, &end, 8);
    if (end == mode_text || *end != '\0' || mode < 0 || mode > 0777) return errorf("invalid file mode");
    return atomic_write_from_fd(root_fd, relative, STDIN_FILENO, (mode_t)mode, true);
}

static int external_copy_command(int root_fd, const char *relative, const char *source, const char *mode_text, bool replace) {
    struct stat status;
    char *end = NULL;
    long mode = strtol(mode_text, &end, 8);
    int source_fd;
    int result;
    if (end == mode_text || *end != '\0' || mode < 0 || mode > 0777) return errorf("invalid file mode");
    source_fd = open(source, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (source_fd < 0 || fstat(source_fd, &status) != 0 || !S_ISREG(status.st_mode)) {
        if (source_fd >= 0) close(source_fd);
        return errorf("managed source is not a regular file");
    }
    result = atomic_write_from_fd(root_fd, relative, source_fd, (mode_t)mode, replace);
    close(source_fd);
    return result;
}

static int copy_command(int root_fd, const char *source, const char *destination, const char *mode_text) {
    char *end = NULL;
    long mode = strtol(mode_text, &end, 8);
    int source_fd;
    int result;
    if (end == mode_text || *end != '\0' || mode < 0 || mode > 0777) return errorf("invalid file mode");
    source_fd = open_relative_regular(root_fd, source);
    if (source_fd < 0) return 1;
    result = atomic_write_from_fd(root_fd, destination, source_fd, (mode_t)mode, true);
    close(source_fd);
    return result;
}

static int delete_file_command(int root_fd, const char *relative) {
    struct relative_path parsed;
    struct stat status;
    int parent_fd = -1;
    int parent_result;
    int result = 1;

    if (parse_relative_path(relative, &parsed) != 0) return 1;
    parent_result = open_parent(root_fd, &parsed, false, &parent_fd);
    if (parent_result == 1) {
        free_relative_path(&parsed);
        return 0;
    }
    if (parent_result != 0) goto cleanup;
    if (fstatat(parent_fd, parsed.parts[parsed.count - 1], &status, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) result = 0;
        else errorf("cannot inspect managed deletion target: %s", strerror(errno));
        goto cleanup;
    }
    if (!S_ISREG(status.st_mode)) {
        errorf("managed deletion target is not a regular file");
        goto cleanup;
    }
    if (unlinkat(parent_fd, parsed.parts[parsed.count - 1], 0) != 0) {
        errorf("cannot delete managed file: %s", strerror(errno));
        goto cleanup;
    }
    if (fsync(parent_fd) != 0) {
        errorf("cannot sync managed parent directory: %s", strerror(errno));
        goto cleanup;
    }
    result = 0;

cleanup:
    if (parent_fd >= 0) close(parent_fd);
    free_relative_path(&parsed);
    return result;
}

static int validate_tree(int directory_fd) {
    DIR *directory;
    struct dirent *entry;
    if (lseek(directory_fd, 0, SEEK_SET) < 0) return errorf("cannot rewind snapshot directory");
    directory = fdopendir(dup(directory_fd));
    if (directory == NULL) return errorf("cannot inspect snapshot directory: %s", strerror(errno));
    while ((entry = readdir(directory)) != NULL) {
        struct stat status;
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (fstatat(directory_fd, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
            closedir(directory);
            return errorf("cannot inspect snapshot entry: %s", strerror(errno));
        }
        if (S_ISDIR(status.st_mode)) {
            int child = openat(directory_fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            int child_result;
            if (child < 0) {
                closedir(directory);
                return errorf("cannot open snapshot directory without following links");
            }
            child_result = validate_tree(child);
            close(child);
            if (child_result != 0) {
                closedir(directory);
                return 1;
            }
        } else if (!S_ISREG(status.st_mode)) {
            closedir(directory);
            return errorf("snapshot tree contains a non-regular entry");
        }
    }
    closedir(directory);
    return 0;
}

static int delete_tree_contents(int directory_fd) {
    DIR *directory;
    struct dirent *entry;
    if (lseek(directory_fd, 0, SEEK_SET) < 0) return errorf("cannot rewind snapshot directory");
    directory = fdopendir(dup(directory_fd));
    if (directory == NULL) return errorf("cannot open snapshot directory for deletion");
    while ((entry = readdir(directory)) != NULL) {
        struct stat status;
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        if (fstatat(directory_fd, entry->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
            closedir(directory);
            return errorf("cannot revalidate snapshot entry before deletion");
        }
        if (S_ISDIR(status.st_mode)) {
            int child = openat(directory_fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            int child_result;
            if (child < 0) {
                closedir(directory);
                return errorf("cannot open snapshot directory before deletion");
            }
            child_result = delete_tree_contents(child);
            close(child);
            if (child_result != 0 || unlinkat(directory_fd, entry->d_name, AT_REMOVEDIR) != 0) {
                closedir(directory);
                return errorf("cannot delete snapshot directory: %s", strerror(errno));
            }
        } else if (S_ISREG(status.st_mode)) {
            if (unlinkat(directory_fd, entry->d_name, 0) != 0) {
                closedir(directory);
                return errorf("cannot delete snapshot file: %s", strerror(errno));
            }
        } else {
            closedir(directory);
            return errorf("snapshot entry changed to a non-regular type");
        }
    }
    closedir(directory);
    return 0;
}

static int remove_tree_command(int root_fd, const char *relative) {
    struct relative_path parsed;
    struct stat status;
    int parent_fd = -1;
    int directory_fd = -1;
    int parent_result;
    int result = 1;

    if (parse_relative_path(relative, &parsed) != 0) return 1;
    parent_result = open_parent(root_fd, &parsed, false, &parent_fd);
    if (parent_result == 1) {
        free_relative_path(&parsed);
        return 0;
    }
    if (parent_result != 0) goto cleanup;
    if (fstatat(parent_fd, parsed.parts[parsed.count - 1], &status, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) result = 0;
        else errorf("cannot inspect snapshot deletion target");
        goto cleanup;
    }
    if (!S_ISDIR(status.st_mode)) {
        errorf("snapshot deletion target is not a directory");
        goto cleanup;
    }
    directory_fd = openat(parent_fd, parsed.parts[parsed.count - 1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory_fd < 0) {
        errorf("cannot open snapshot deletion target without following links");
        goto cleanup;
    }
    if (validate_tree(directory_fd) != 0 || delete_tree_contents(directory_fd) != 0) goto cleanup;
    close(directory_fd);
    directory_fd = -1;
    if (unlinkat(parent_fd, parsed.parts[parsed.count - 1], AT_REMOVEDIR) != 0) {
        errorf("cannot delete snapshot root: %s", strerror(errno));
        goto cleanup;
    }
    if (fsync(parent_fd) != 0) {
        errorf("cannot sync snapshot parent directory: %s", strerror(errno));
        goto cleanup;
    }
    result = 0;

cleanup:
    if (directory_fd >= 0) close(directory_fd);
    if (parent_fd >= 0) close(parent_fd);
    free_relative_path(&parsed);
    return result;
}

int main(int argc, char **argv) {
    int root_fd;
    int result;

    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts(HELPER_VERSION);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "root-preflight") == 0) {
        root_fd = open_project_root(argv[2]);
        if (root_fd < 0) return 1;
        close(root_fd);
        return 0;
    }
    if (argc < 4) return errorf("invalid command");
    root_fd = open_project_root(argv[2]);
    if (root_fd < 0) return 1;

    if (strcmp(argv[1], "write-stdin") == 0 && argc == 5) {
        result = write_stdin_command(root_fd, argv[3], argv[4]);
    } else if (strcmp(argv[1], "external-copy") == 0 && argc == 6) {
        result = external_copy_command(root_fd, argv[3], argv[4], argv[5], true);
    } else if (strcmp(argv[1], "external-copy-if-missing") == 0 && argc == 6) {
        result = external_copy_command(root_fd, argv[3], argv[4], argv[5], false);
    } else if (strcmp(argv[1], "copy-file") == 0 && argc == 6) {
        result = copy_command(root_fd, argv[3], argv[4], argv[5]);
    } else if (strcmp(argv[1], "delete-file") == 0 && argc == 4) {
        result = delete_file_command(root_fd, argv[3]);
    } else if (strcmp(argv[1], "remove-tree") == 0 && argc == 4) {
        result = remove_tree_command(root_fd, argv[3]);
    } else {
        result = errorf("invalid command or arguments");
    }
    close(root_fd);
    return result;
}
