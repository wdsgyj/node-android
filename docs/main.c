/*
 * Android libnode smoke-test launcher.
 *
 * Build this file against dist/android-arm64/include and libnode.so, then run:
 *
 *   node_android_smoke <runtime-dir> [--network]
 *
 * The runtime directory must contain android-smoke-test.js. This launcher
 * creates <runtime-dir>/home and <runtime-dir>/tmp for Node's HOME and TMPDIR.
 * The optional --network flag enables the smoke test's HTTP loopback check.
 *
 * Example runtime directory in an Android App:
 *
 *   /data/user/0/com.example.app/files/node/
 *     android-smoke-test.js
 *     home/
 *     tmp/
 */

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "node_android.h"

static void PrintUsage(const char* program) {
  fprintf(stderr, "usage: %s <runtime-dir> [--network]\n", program);
}

static int JoinPath(char* output,
                    size_t output_size,
                    const char* directory,
                    const char* name) {
  const size_t directory_length = strlen(directory);
  if (directory_length == 0) {
    errno = EINVAL;
    return -1;
  }

  const char* separator =
      directory[directory_length - 1] == '/' ? "" : "/";
  const int written =
      snprintf(output, output_size, "%s%s%s", directory, separator, name);
  if (written < 0 || (size_t) written >= output_size) {
    errno = ENAMETOOLONG;
    return -1;
  }
  return 0;
}

static int EnsureDirectory(const char* path) {
  if (mkdir(path, 0700) == 0) {
    return 0;
  }
  if (errno != EEXIST) {
    return -1;
  }

  struct stat status;
  if (stat(path, &status) != 0) {
    return -1;
  }
  if (!S_ISDIR(status.st_mode)) {
    errno = ENOTDIR;
    return -1;
  }
  return 0;
}

int main(int argc, char* argv[]) {
  if (argc != 2 && argc != 3) {
    PrintUsage(argv[0]);
    return EXIT_FAILURE;
  }

  const char* runtime_dir = argv[1];
  bool enable_network = false;
  if (argc == 3) {
    if (strcmp(argv[2], "--network") != 0) {
      PrintUsage(argv[0]);
      return EXIT_FAILURE;
    }
    enable_network = true;
  }

  char script_path[PATH_MAX];
  char home_path[PATH_MAX];
  char tmp_path[PATH_MAX];
  if (JoinPath(script_path, sizeof(script_path), runtime_dir,
               "android-smoke-test.js") != 0 ||
      JoinPath(home_path, sizeof(home_path), runtime_dir, "home") != 0 ||
      JoinPath(tmp_path, sizeof(tmp_path), runtime_dir, "tmp") != 0) {
    perror("runtime path is too long");
    return EXIT_FAILURE;
  }

  if (access(script_path, R_OK) != 0) {
    perror(script_path);
    return EXIT_FAILURE;
  }
  if (EnsureDirectory(home_path) != 0 || EnsureDirectory(tmp_path) != 0) {
    perror("creating Node runtime directory");
    return EXIT_FAILURE;
  }

  const char* node_argv[] = {
      "node",
      script_path,
  };
  const char* standard_envp[] = {
      "NODE_ANDROID_LOG_TAG=node-smoke",
      NULL,
  };
  const char* network_envp[] = {
      "NODE_ANDROID_LOG_TAG=node-smoke",
      "NODE_ANDROID_SMOKE_NETWORK=1",
      NULL,
  };
  const char* const* envp = enable_network ? network_envp : standard_envp;

  const int exit_code = node_android_run(
      2, node_argv, runtime_dir, home_path, tmp_path, NULL, envp);
  if (exit_code == -1) {
    const int saved_errno = errno;
    fprintf(stderr, "node_android_run failed: %s\n", strerror(saved_errno));
    return EXIT_FAILURE;
  }
  return exit_code;
}
