# Node Android Patches

`node-24.20.0-android-libnode.patch` is generated against the clean
`node-24.20.0` source tree and must be applied from the source root:

```bash
patch -p1 < /path/to/node-android/patchs/node-24.20.0-android-libnode.patch
```

The patch fixes:

- host/target libuv source selection during Android cross-compilation;
- Android zlib CPU feature compilation;
- macOS host archive and link rules in GYP Makefiles;
- V8 host platform and trap-handler source selection.
- Release target optimization and visibility defaults for Android;
- a stable `node_android_run` C ABI wrapper around Node startup;
- linker-time export filtering for `node_android_run`, Node-API/N-API, and
  `node_module_register`.

The recommended one-shot build entry point is:

```bash
/path/to/node-android/build-android-libnode.sh
```

If `node-24.20.0` does not exist under the `node-android` directory, the script
downloads the clean `v24.20.0` source archive from GitHub and caches it under
`.cache/node-v24.20.0.tar.gz`; the archive is removed after successful
extraction. Set `NODE_SOURCE_URL` or
`NODE_SOURCE_ARCHIVE` to use a mirror or a pre-downloaded archive.
It is safe to rerun against an already patched source tree; it detects and
skips an already applied patch.

The resulting shared library does not expose Node's C++ embedding API. Consumers
should include `src/node_android.h` and call `node_android_run()`. The dynamic
symbol allowlist is limited to `node_android_run`, `napi_*`, `node_api_*`, and
`node_module_register`.

On Android, `node_android_run()` redirects stdout/stderr to logcat during the
Node run. The default tag is `nodejs`; set `NODE_ANDROID_LOG_TAG` to override it.
