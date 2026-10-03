#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int executable(const char *path) {
    return access(path, X_OK) == 0;
}

int main(int argc, char **argv) {
    (void)argc;

    char executable_path[PATH_MAX];
    if (realpath(argv[0], executable_path) == NULL) {
        return 1;
    }

    char *slash = strrchr(executable_path, '/');
    if (slash == NULL) {
        return 1;
    }
    *slash = '\0'; // Contents/MacOS
    slash = strrchr(executable_path, '/');
    if (slash == NULL) {
        return 1;
    }
    *slash = '\0'; // Contents
    slash = strrchr(executable_path, '/');
    if (slash == NULL) {
        return 1;
    }
    *slash = '\0'; // Application bundle root

    char script_path[PATH_MAX];
    int written = snprintf(
        script_path,
        sizeof(script_path),
        "%s/Contents/Resources/mac_app.py",
        executable_path
    );
    if (written < 0 || (size_t)written >= sizeof(script_path)) {
        return 1;
    }

    const char *python_candidates[] = {
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        "/usr/bin/python3",
        NULL,
    };

    for (size_t i = 0; python_candidates[i] != NULL; ++i) {
        if (executable(python_candidates[i])) {
            freopen("/dev/null", "w", stdout);
            freopen("/dev/null", "w", stderr);
            execl(python_candidates[i], python_candidates[i], script_path, (char *)NULL);
            return 1;
        }
    }

    return 1;
}
