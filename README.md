# Node Android libnode

本项目用于基于 Node.js `v24.20.0` 源码构建 Android 平台的
`libnode.so`。目标不是构建 Node.js 命令行可执行文件，而是提供一个可被
Android App、JNI 或其他 native 宿主加载的 Node.js runtime 动态库。

## 项目目标

- 目标平台：Android `arm64-v8a` / AArch64。
- 构建模式：`Release`。
- Android target 优化：`-Os`，优先减小发布包体积。
- 不构建或交付 Node.js 可执行文件。
- 不交付静态库。
- Node bundled dependencies 静态链接进 `libnode.so`。
- 避免额外交付 `libc++_shared.so`，使用 `-static-libstdc++`。
- 同时生成带符号版本和 strip 发布版本。
- 通过链接期 version script 严格控制动态导出符号。

## 当前 ABI

动态库只导出以下符号：

- `node_android_run`
- `napi_*`
- `node_api_*`
- `node_module_register`

Node.js C++ embedding API、V8、OpenSSL、libuv、ICU、SQLite 以及 C++ ABI
辅助符号不会进入动态导出表。调用方不需要直接依赖 `node.h` 或 V8 API，
只需要包含 `node-24.20.0/src/node_android.h`。

入口声明：

```c
int node_android_run(
    int argc,
    const char* const* argv,
    const char* cwd,
    const char* home,
    const char* tmpdir,
    const char* module_path,
    const char* const* envp);
```

该函数是同步阻塞接口，行为类似执行 `node script.js`：

- JS 脚本执行完成且事件循环没有活动句柄时返回。
- 定时器、网络连接、Worker 等保持活跃时会继续阻塞。
- 返回值是 Node.js 退出码。
- 参数或进程环境配置失败时返回 `-1`，并通过 `errno` 指示错误。

## Android 日志

Android 平台运行期间：

- stdout 转发到 logcat `INFO`。
- stderr 转发到 logcat `ERROR`。
- 覆盖 `console.log()`、`console.error()`、`process.stdout.write()`、
  `process.stderr.write()` 以及 Node 原生 stdout/stderr 诊断输出。
- 默认 logcat tag 为 `nodejs`。
- 可通过 `NODE_ANDROID_LOG_TAG` 自定义 tag。

`node_android_run()` 返回后会恢复宿主原来的 stdout/stderr。由于 stdout 和
stderr 是进程级文件描述符，Node 运行期间宿主其他线程写入这两个 fd 的内容
也会进入 logcat。

## 构建

直接运行一键构建脚本：

```bash
./build-android-libnode.sh
```

脚本行为：

1. 如果 `node-24.20.0` 不存在，从 GitHub 下载源码：

   ```text
   https://github.com/nodejs/node/archive/refs/tags/v24.20.0.tar.gz
   ```

2. 下载期间显示实时进度。
3. 解压源码并应用 `patchs/node-24.20.0-android-libnode.patch`。
4. 先构建 host 侧辅助工具和 `node_base`。
5. 生成显式动态导出白名单。
6. 构建 Android `libnode.so`。
7. 生成带符号版本和 strip 版本。
8. 源码归档确认解压成功后自动删除。

源码目录不完整时，脚本会停止并要求先删除该目录，避免覆盖半成品。

默认环境：

- Android API：`24`
- macOS NDK 路径：`$HOME/Library/Android/sdk/ndk/27.3.13750724`
- Linux NDK 路径：`$HOME/Android/Sdk/ndk/27.3.13750724`

可通过环境变量覆盖：

```bash
ANDROID_NDK=/path/to/ndk
ANDROID_API=24
JOBS=8
NODE_SOURCE_URL=https://mirror.example/node-v24.20.0.tar.gz
NODE_SOURCE_ARCHIVE=/path/to/node-v24.20.0.tar.gz
DIST_DIR=/path/to/dist
./build-android-libnode.sh
```

如果源码目录已存在但需要重新开始：

```bash
rm -rf node-24.20.0
./build-android-libnode.sh
```

## 构建产物

产物目录：

```text
dist/android-arm64/
```

- `libnode.so`：strip 后发布版本，约 92 MB。
- `libnode.symbols.so`：带符号调试版本，约 122 MB。

当前已验证的 Android arm64 Release 构建状态（2026-09-08）：

- ELF 类型：AArch64 shared object。
- 动态导出符号：163 个。
- 白名单之外的动态导出符号：0 个。
- 系统动态依赖：`libc.so`、`libm.so`、`libdl.so`、`liblog.so`。
- Android 日志实现已链接 `liblog.so`。

## 验证

JS API smoke test 位于：

```text
docs/android-smoke-test.js
```

它用于验证 `process`、core modules、Buffer、URL、fs、crypto、zlib、timers
和 stream 等 Node API。Android 宿主集成时，应通过 `node_android_run()` 加载
该脚本执行验证。

建议同时检查动态依赖和导出表：

```bash
NDK="$ANDROID_NDK"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"

"$TOOLCHAIN/bin/llvm-readelf" -d dist/android-arm64/libnode.so | grep NEEDED
"$TOOLCHAIN/bin/llvm-nm" -D --defined-only \
  dist/android-arm64/libnode.so
```

当前尚未在真实 Android 设备或模拟器上完成完整的 `adb logcat` 运行验收；
需要宿主 App/JNI 集成后验证 Node-API addon、文件路径、Android 沙箱权限和
logcat 输出。

## npm 包兼容性

- 纯 JavaScript npm 包通常可以工作。
- Node-API / N-API 原生包需要针对 Android `arm64-v8a` 重新编译。
- 使用 V8 API、`nan` 或旧式 Node C++ ABI 的 addon 不在稳定兼容范围内。
- 依赖 shell、外部可执行文件、Linux 路径或桌面系统能力的包需要额外适配。

## 关键文件

- [build-android-libnode.sh](build-android-libnode.sh)：一键构建脚本。
- [docs/android-libnode.md](docs/android-libnode.md)：完整构建和集成说明。
- [docs/android-smoke-test.js](docs/android-smoke-test.js)：JS API smoke test。
- [patchs/node-24.20.0-android-libnode.patch](patchs/node-24.20.0-android-libnode.patch)：源码补丁。
- [node-24.20.0/src/node_android.h](node-24.20.0/src/node_android.h)：公开 C ABI 头文件。
