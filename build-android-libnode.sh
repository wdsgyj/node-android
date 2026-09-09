#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR=${1:-"$ROOT_DIR/node-24.20.0"}
PATCH_FILE="$ROOT_DIR/patchs/node-24.20.0-android-libnode.patch"
SOURCE_URL=${NODE_SOURCE_URL:-"https://github.com/nodejs/node/archive/refs/tags/v24.20.0.tar.gz"}
SOURCE_ARCHIVE=${NODE_SOURCE_ARCHIVE:-"$ROOT_DIR/.cache/node-v24.20.0.tar.gz"}

ANDROID_API=${ANDROID_API:-24}
ANDROID_NDK=${ANDROID_NDK:-}
DIST_DIR=${DIST_DIR:-"$ROOT_DIR/dist/android-arm64"}
JOBS=${JOBS:-}

case "$(uname -s)" in
  Darwin)
    HOST_OS=mac
    ANDROID_HOST_TAG=darwin-x86_64
    HOST_CC=/usr/bin/clang
    HOST_CXX=/usr/bin/clang++
    HOST_AR=/usr/bin/ar
    if [ -z "$ANDROID_NDK" ]; then
      ANDROID_NDK=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}/ndk/27.3.13750724
    fi
    ;;
  Linux)
    HOST_OS=linux
    ANDROID_HOST_TAG=linux-x86_64
    HOST_CC=${HOST_CC:-clang}
    HOST_CXX=${HOST_CXX:-clang++}
    HOST_AR=${HOST_AR:-ar}
    if [ -z "$ANDROID_NDK" ]; then
      ANDROID_NDK=${ANDROID_HOME:-"$HOME/Android/Sdk"}/ndk/27.3.13750724
    fi
    ;;
  *)
    echo "unsupported host: $(uname -s)" >&2
    exit 1
    ;;
esac

if [ ! -f "$SOURCE_DIR/node.gyp" ]; then
  if [ -e "$SOURCE_DIR" ]; then
    echo "source directory exists but is incomplete: $SOURCE_DIR" >&2
    echo "remove it and rerun the build to download a clean source tree" >&2
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to download Node.js sources" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$SOURCE_ARCHIVE")"
  if [ ! -s "$SOURCE_ARCHIVE" ]; then
    echo "downloading source: $SOURCE_URL"
    curl --fail --location --retry 3 --retry-delay 2 --progress-bar \
      --output "$SOURCE_ARCHIVE" "$SOURCE_URL"
    printf '\nsource download completed: '
    ls -lh "$SOURCE_ARCHIVE"
  else
    echo "using cached source archive: $SOURCE_ARCHIVE"
  fi

  echo "extracting source archive"
  mkdir -p "$SOURCE_DIR"
  tar -xzf "$SOURCE_ARCHIVE" --strip-components=1 -C "$SOURCE_DIR"
  if [ ! -f "$SOURCE_DIR/node.gyp" ]; then
    echo "downloaded archive does not contain a Node.js source tree: $SOURCE_URL" >&2
    exit 1
  fi
  echo "source extraction completed: $SOURCE_DIR"
  rm -f "$SOURCE_ARCHIVE"
fi

if [ ! -f "$PATCH_FILE" ]; then
  echo "patch file not found: $PATCH_FILE" >&2
  exit 1
fi

if [ ! -d "$ANDROID_NDK" ]; then
  echo "Android NDK not found: $ANDROID_NDK" >&2
  echo "Set ANDROID_NDK to an installed NDK directory." >&2
  exit 1
fi

ANDROID_TOOLCHAIN="$ANDROID_NDK/toolchains/llvm/prebuilt/$ANDROID_HOST_TAG"
CC_TARGET="$ANDROID_TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang"
CXX_TARGET="$ANDROID_TOOLCHAIN/bin/aarch64-linux-android${ANDROID_API}-clang++"
AR_TARGET="$ANDROID_TOOLCHAIN/bin/llvm-ar"
LLVM_STRIP="$ANDROID_TOOLCHAIN/bin/llvm-strip"
LLVM_READELF="$ANDROID_TOOLCHAIN/bin/llvm-readelf"
LLVM_NM="$ANDROID_TOOLCHAIN/bin/llvm-nm"
EXPORT_MAP="$SOURCE_DIR/out/android-libnode.exports.map"

for tool in "$CC_TARGET" "$CXX_TARGET" "$AR_TARGET" "$LLVM_STRIP" \
            "$LLVM_READELF" "$LLVM_NM"; do
  if [ ! -x "$tool" ]; then
    echo "required tool not found: $tool" >&2
    exit 1
  fi
done

if [ -z "$JOBS" ]; then
  if [ "$HOST_OS" = mac ]; then
    JOBS=$(sysctl -n hw.ncpu)
  else
    JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')
  fi
fi

echo "source: $SOURCE_DIR"
echo "ndk:    $ANDROID_NDK"
echo "host:   $HOST_OS"
echo "api:    $ANDROID_API"

if patch --dry-run -p1 --forward --batch -d "$SOURCE_DIR" \
    < "$PATCH_FILE" >/dev/null 2>&1; then
  patch -p1 --forward --batch -d "$SOURCE_DIR" < "$PATCH_FILE"
elif patch --dry-run -p1 --reverse --batch -d "$SOURCE_DIR" \
    < "$PATCH_FILE" >/dev/null 2>&1; then
  echo "patch already applied"
else
  echo "source tree is neither clean nor already patched: $SOURCE_DIR" >&2
  exit 1
fi

export ANDROID_NDK
export ANDROID_API
export ANDROID_HOST_TAG
export ANDROID_TOOLCHAIN
export PATH="$ANDROID_TOOLCHAIN/bin:$PATH"

# Configure checks use the target compiler. GYP gets explicit host variables so
# host tools such as node_js2c and mksnapshot never use the Android compiler.
export CC="$CC_TARGET"
export CXX="$CXX_TARGET"
export AR="$AR_TARGET"
export CC_target="$CC_TARGET"
export CXX_target="$CXX_TARGET"
export LINK_target="$CXX_TARGET"
export AR_target="$AR_TARGET"
export CC_host="$HOST_CC"
export CXX_host="$HOST_CXX"
export LINK_host="$HOST_CXX"
export AR_host="$HOST_AR"
export GYP_DEFINES="target_arch=arm64 v8_target_arch=arm64 android_target_arch=arm64 host_os=$HOST_OS OS=android android_ndk_path=$ANDROID_NDK android_libnode_export_map=$EXPORT_MAP"

(
  cd "$SOURCE_DIR"
  ./configure \
    --dest-cpu=arm64 \
    --dest-os=android \
    --cross-compiling \
    --shared \
    --openssl-no-asm \
    --without-npm \
    --without-corepack \
    --without-inspector

  make -C out BUILDTYPE=Release \
    CC.target="$CC_TARGET" \
    CXX.target="$CXX_TARGET" \
    LINK.target="$CXX_TARGET" \
    AR.target="$AR_TARGET" \
    CC.host="$HOST_CC" \
    CXX.host="$HOST_CXX" \
    LINK.host="$HOST_CXX" \
    AR.host="$HOST_AR" \
    CFLAGS.target=-Os \
    CXXFLAGS.target=-Os \
    LDFLAGS.target=-static-libstdc++ \
    node_base -j"$JOBS"

  sh tools/android-libnode-export-map.sh "$EXPORT_MAP"

  make -C out BUILDTYPE=Release \
    CC.target="$CC_TARGET" \
    CXX.target="$CXX_TARGET" \
    LINK.target="$CXX_TARGET" \
    AR.target="$AR_TARGET" \
    CC.host="$HOST_CC" \
    CXX.host="$HOST_CXX" \
    LINK.host="$HOST_CXX" \
    AR.host="$HOST_AR" \
    CFLAGS.target=-Os \
    CXXFLAGS.target=-Os \
    LDFLAGS.target=-static-libstdc++ \
    libnode -j"$JOBS"

  mkdir -p "$DIST_DIR"
  cp out/Release/libnode.so "$DIST_DIR/libnode.symbols.so"
  cp out/Release/libnode.so "$DIST_DIR/libnode.so"
  "$LLVM_STRIP" --strip-unneeded "$DIST_DIR/libnode.so"

  # Keep the complete C ABI header closure beside the binary artifacts.
  mkdir -p "$DIST_DIR/include"
  cp src/node_android.h \
     src/node_api.h \
     src/node_api_types.h \
     src/js_native_api.h \
     src/js_native_api_types.h \
     src/node_version.h \
     "$DIST_DIR/include/"

  "$LLVM_READELF" -h "$DIST_DIR/libnode.so" | sed -n '1,24p'
  "$LLVM_READELF" -d "$DIST_DIR/libnode.so" | grep -E 'NEEDED|SONAME'
  "$LLVM_NM" -D --defined-only "$DIST_DIR/libnode.so" |
    grep -E ' (node_module_register|napi_|node_api_)' | sed -n '1,20p'
  if "$LLVM_NM" -D --defined-only "$DIST_DIR/libnode.so" |
      awk '{ print $3 }' |
      grep -Ev '^(node_android_run|node_module_register|napi_[A-Za-z0-9_]+|node_api_[A-Za-z0-9_]+)$' |
      grep -q .; then
    echo "unexpected internal symbols exported from libnode.so" >&2
    exit 1
  fi

  echo "artifacts:"
  ls -lh "$DIST_DIR/libnode.so" "$DIST_DIR/libnode.symbols.so"
  echo "public headers:"
  find "$DIST_DIR/include" -maxdepth 1 -type f -print | sort
)
