# Android libnode 构建需求

本文档记录基于 `node-24.20.0` 源码构建 Android 版 `libnode.so` 的目标、约束和推荐构建方式。

## 目标

- 目标平台为 Android，优先目标架构为 `arm64` / `aarch64`。
- 只交付 Node.js 动态库产物，不交付 `node` 可执行文件。
- 构建模式固定为 `Release`。
- Android target 编译优化固定为 `-Os`，包括 V8 的 Android Release 覆盖项。
- 动态库使用 Node.js bundled dependencies，避免运行或二次集成时依赖额外第三方动态库。
- 交付两个 `libnode.so` 版本：
  - 带符号表版本，用于调试、崩溃符号化和问题定位。
  - strip 后版本，用于正式集成和发布。
- 对外只公开稳定的 C ABI：
  - `node_android_run`
  - `napi_*`
  - `node_api_*`
  - `node_module_register`
- Node.js embedding API、V8、OpenSSL、libuv 和其他 C++ ABI 只在 `libnode.so`
  内部使用，不进入动态导出表。

## 非目标

- 不构建或交付静态库。
- 不对外暴露 Node.js C++ embedding API；调用方通过 `node_android_run()` 启动
  Node.js。
- 不向外承诺 V8、OpenSSL、libuv 等内部实现 API 的稳定性。
- 不使用 `--shared-openssl`、`--shared-libuv`、`--shared-zlib`、`--shared-nghttp2` 等选项把 bundled dependencies 拆成额外第三方动态库。

## 可行性结论

该方案可行。Node.js 源码支持 `--shared`，会生成用于 embedding 的 `libnode.so`。在不启用各类 `--shared-*` 依赖选项时，V8、OpenSSL、libuv、zlib、nghttp2、brotli、sqlite 等 Node bundled dependencies 会被链接进 `libnode.so`。

这里的“独立唯一包”指对 Node bundled dependencies 不再要求额外交付第三方动态库。`libnode.so` 仍会依赖 Android 系统库，例如 libc、libm、libdl、liblog、libandroid-support 相关运行库等，具体以 NDK 链接结果为准。

## 推荐 API 边界

动态库只导出以下符号：

- `node_android_run`
- `napi_*`
- `node_api_*`
- `node_module_register`

`node_android_run()` 的声明位于 `src/node_android.h`：

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

调用方可以通过 `argv` 传入 Node 参数和 JS 入口，通过 `cwd`、`home`、
`tmpdir`、`module_path` 配置运行目录，并通过 `envp` 传入以 `KEY=VALUE`
表示的环境变量数组。函数内部调用 Node 的 embedding API，但这些 C++ 符号
不会被外部链接。

构建产物会将该头文件和 Node-API 所需头文件复制到
`dist/android-arm64/include/`。`node_android.h` 包含最小调用示例，宿主
可按以下方式使用：

```c
#include <node_android.h>

const char* argv[] = { "node", "/data/user/0/example/files/main.js" };
const char* envp[] = { "NODE_ENV=production", NULL };
int exit_code = node_android_run(
    2, argv,
    "/data/user/0/example/files",
    "/data/user/0/example/files/home",
    "/data/user/0/example/cache",
    "/data/user/0/example/files/node_modules",
    envp);
```

该接口同步阻塞，直到脚本执行完成且 event loop 没有活动句柄才返回。应从专用
native 线程调用，且不可并发调用：接口会修改进程级环境变量、工作目录和
stdout/stderr。

`node_android_run()` 返回 Node.js 退出码；参数或进程环境配置失败时返回
`-1`，并通过 `errno` 指示原因。环境变量和工作目录修改是进程级的。

在 Android 平台上，`node_android_run()` 运行期间会将 fd 1（stdout）转发到
logcat 的 `INFO` 级别，将 fd 2（stderr）转发到 `ERROR` 级别。因此
JavaScript 的 `console.log()`、`console.error()`、`process.stdout.write()`、
`process.stderr.write()` 以及 Node 原生写入 stdout/stderr 的诊断信息都会
进入 logcat，而不是直接写宿主 stdout/stderr。默认 tag 为 `nodejs`，可以在
启动前通过 `NODE_ANDROID_LOG_TAG` 覆盖。

Node 返回后，宿主进程原来的 stdout/stderr 会被恢复。由于 stdout/stderr 是
进程级文件描述符，`node_android_run()` 运行期间宿主其他线程写入这两个 fd
的内容也会进入 logcat。

## npm 包兼容性

- 纯 JS npm 包：通常不受 `libnode.so` 形态影响，主要受 `cwd`、模块路径、环境变量、文件权限和 Android 沙箱限制影响。
- Node-API / N-API 原生包：可以支持，但必须为目标 Android ABI 重新编译，例如 `arm64-v8a`。
- 旧式 V8 C++ addon：不建议承诺兼容。它们依赖 V8/Node 内部 ABI，跨版本和跨平台风险较高。
- 依赖 shell、外部可执行文件、系统路径、证书路径、`child_process` 或动态库搜索路径的包：可能需要 Android 侧适配。

## Release 动态库构建

`android-configure` 当前只封装了可执行文件默认构建参数，不能直接追加 `--shared`。构建 `libnode.so` 时建议显式设置 Android NDK 编译器环境，然后直接运行 `./configure --shared`。

如果使用本目录提供的一键脚本，可以直接执行：

```bash
/Users/clark/dev/cproject/home/node-android/build-android-libnode.sh
```

脚本会在 `node-24.20.0` 不存在时从 GitHub 下载
`v24.20.0` 源码归档，默认 URL 为：

```text
https://github.com/nodejs/node/archive/refs/tags/v24.20.0.tar.gz
```

源码归档会临时保存到 `.cache/node-v24.20.0.tar.gz`，解压并确认源码完整后
会自动删除该压缩包，然后应用 `patchs/node-24.20.0-android-libnode.patch`，
完成配置、构建和产物导出。
如需使用镜像或内部缓存，可设置 `NODE_SOURCE_URL` 或
`NODE_SOURCE_ARCHIVE` 覆盖默认值。

以 macOS / Linux host 构建 Android arm64 为例：

```bash
cd /Users/clark/dev/cproject/home/node-android/node-24.20.0

export ANDROID_NDK="$NDK"
export ANDROID_API=24
export ANDROID_ARCH=arm64

case "$(uname -s)" in
  Darwin) export ANDROID_HOST_TAG=darwin-x86_64 ;;
  Linux) export ANDROID_HOST_TAG=linux-x86_64 ;;
  *) echo "unsupported host" >&2; exit 1 ;;
esac

export ANDROID_TOOLCHAIN="$ANDROID_NDK/toolchains/llvm/prebuilt/$ANDROID_HOST_TAG"
export PATH="$ANDROID_TOOLCHAIN/bin:$PATH"
export CC="$ANDROID_TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang"
export CXX="$ANDROID_TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang++"
export GYP_DEFINES="target_arch=arm64 v8_target_arch=arm64 android_target_arch=arm64 host_os=mac OS=android android_ndk_path=$ANDROID_NDK"

./configure \
  --dest-cpu=arm64 \
  --dest-os=android \
  --cross-compiling \
  --shared \
  --openssl-no-asm \
  --without-npm \
  --without-corepack \
  --without-inspector

# Host tools must use the macOS compiler; only target objects use the NDK
# compiler. Static-linking the C++ runtime avoids a libc++_shared.so dependency.
export CC_host=/usr/bin/clang
export CXX_host=/usr/bin/clang++
export LINK_host=/usr/bin/clang++
export AR_host=/usr/bin/ar
export LDFLAGS_target=-static-libstdc++

make -C out BUILDTYPE=Release \
  CC.host="$CC_host" \
  CXX.host="$CXX_host" \
  LINK.host="$LINK_host" \
  AR.host="$AR_host" \
  AR.target="$ANDROID_TOOLCHAIN/bin/llvm-ar" \
  LDFLAGS.target="$LDFLAGS_target" \
  libnode -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"
```

这里的 `host_os=mac` 用于让跨编译生成的 host 辅助工具使用 macOS
平台源文件，例如 V8 的 POSIX trap handler。`CC_host` / `CXX_host` 必须
与 Android target 编译器分开，否则 host 侧 libuv 会被错误地按 Android
编译并找不到 macOS SDK 头文件。

如果已经生成 Makefile，也可以直接重复执行上面的 `make` 命令；无需构建
`node` 可执行文件。

构建过程可能仍生成 host 端辅助工具，例如 `node_js2c`。这不影响最终只交付 `libnode.so` 的目标。

## 符号版与 strip 版产物

构建完成后，保留一份未 strip 的 `libnode.so`，再复制并 strip 另一份用于发布：

```bash
mkdir -p dist/android-arm64

cp out/Release/libnode.so dist/android-arm64/libnode.symbols.so
cp out/Release/libnode.so dist/android-arm64/libnode.so

"$ANDROID_TOOLCHAIN/bin/llvm-strip" --strip-unneeded dist/android-arm64/libnode.so
```

建议交付：

- `dist/android-arm64/libnode.so`：strip 后发布版本。
- `dist/android-arm64/libnode.symbols.so`：带符号表调试版本，不随正式包发布到用户设备。
- `dist/android-arm64/include/`：公开 ABI 对应头文件，可直接加入宿主或
  Node-API addon 的 include path：
  `node_android.h`、`node_api.h`、`node_api_types.h`、
  `js_native_api.h`、`js_native_api_types.h` 和 `node_version.h`。

链接阶段使用显式 version script 白名单链接 `libnode.so`。因此动态导出表
只保留 `node_android_run`、Node-API/N-API 和 `node_module_register`；
Node embedding API、V8、OpenSSL、libuv、ICU、SQLite 以及 C++ ABI 辅助符号
不会进入 `.dynsym`。最终的 `llvm-strip --strip-unneeded` 只用于移除发布包
中的非必要符号和调试信息，不承担公共 ABI 白名单功能。

2026-09-08 在 macOS + Android NDK 27.3.13750724 上实测 Android arm64
构建成功。strip 版本约 92 MB，带符号版本约 122 MB，动态导出符号 163 个；
运行时依赖为 `libc.so`、`libm.so`、`libdl.so` 和 `liblog.so`。

本次 arm64 Release 构建的 `libnode.so` 动态依赖为 Android 系统库：
`libc.so`、`libm.so`、`libdl.so` 和 `liblog.so`。通过
`-static-libstdc++` 已避免额外交付 `libc++_shared.so`。

## 验证项

建议按三层验证构建后的可用性。

第一层是 ELF 和动态依赖检查：

```bash
file dist/android-arm64/libnode.so
file dist/android-arm64/libnode.symbols.so

"$ANDROID_TOOLCHAIN/bin/llvm-readelf" -d dist/android-arm64/libnode.so | grep NEEDED
"$ANDROID_TOOLCHAIN/bin/llvm-nm" -D dist/android-arm64/libnode.so | grep -E ' node_module_register$| napi_| node_api_'
```

第二层是宿主集成 smoke test：Android App / JNI 先 `dlopen` 或通过系统 loader
加载 `libnode.so`，再调用 `node_android_run()`，并把
`../docs/android-smoke-test.js` 作为 JS 入口传入。

第三层是 JS API smoke test。`../docs/android-smoke-test.js` 会验证：

- `process.platform`、`process.arch`、`process.versions` 等运行时元信息。
- `module.builtinModules` 和常见 core modules 的加载能力。
- `Buffer`、`URL`、`fs`、`crypto`、`zlib`、`timers/promises`、`stream/promises` 等基础 API。
- 可选 HTTP loopback；设置 `NODE_ANDROID_SMOKE_NETWORK=1` 后启用。

Android App 集成时，宿主应在启动 Node 前设置合理的 `cwd`、`HOME`、`TMPDIR` 和业务所需环境变量。`fs` smoke test 会使用 `os.tmpdir()` 创建临时文件，如果 `TMPDIR` 指向不可写目录，该项会失败。

该脚本默认按 Android arm64 / Node 24 校验。若需要在构建机上先验证脚本自身逻辑，可用以下环境变量覆盖期望值：

```bash
NODE_ANDROID_EXPECT_PLATFORM=darwin \
NODE_ANDROID_EXPECT_ARCH=arm64 \
NODE_ANDROID_EXPECT_NODE_MAJOR=26 \
node ../docs/android-smoke-test.js
```

如果需要验证 native npm 包，还应增加一个 Android ABI 的 Node-API addon smoke test。该测试不应替代 JS smoke test，而应作为额外验收项，因为 native addon 还涉及 Android ABI、`.node` 动态库搜索路径和符号导出。
