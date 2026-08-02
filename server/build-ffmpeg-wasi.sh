#!/usr/bin/env bash
set -euo pipefail

# Build a standards-compliant WASI Preview 1 FFmpeg command module.
# This intentionally keeps FFmpeg's built-in codecs/formats enabled. Only
# features that cannot work in the iOS sandbox (network, devices, threads,
# assembly and desktop UI) are disabled.

# FFmpeg 6+ makes the ffmpeg CLI depend on POSIX threads. WasmKit's iOS
# interpreter intentionally has no pthread host implementation, so use the
# latest maintained 5.1 release whose command scheduler remains single-threaded.
FFMPEG_VERSION="${FFMPEG_VERSION:-5.1.7}"
WASI_SDK_VERSION="${WASI_SDK_VERSION:-33}"
BUILD_ROOT="${BUILD_ROOT:-/opt/ffmpeg-wasi-build}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"

WASI_ARCHIVE="wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux.tar.gz"
WASI_URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/${WASI_ARCHIVE}"
FFMPEG_ARCHIVE="ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_ARCHIVE}"

mkdir -p "${BUILD_ROOT}/downloads" "${BUILD_ROOT}/output"
cd "${BUILD_ROOT}"

if [[ ! -f "downloads/${WASI_ARCHIVE}" ]]; then
  curl --fail --location --retry 3 --output "downloads/${WASI_ARCHIVE}" "${WASI_URL}"
fi

if [[ ! -d "wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux" ]]; then
  tar -xzf "downloads/${WASI_ARCHIVE}"
fi

if [[ ! -f "downloads/${FFMPEG_ARCHIVE}" ]]; then
  curl --fail --location --retry 3 --output "downloads/${FFMPEG_ARCHIVE}" "${FFMPEG_URL}"
fi

rm -rf "ffmpeg-${FFMPEG_VERSION}"
tar -xJf "downloads/${FFMPEG_ARCHIVE}"

WASI_SDK="${BUILD_ROOT}/wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux"
WASI_SYSROOT="${WASI_SDK}/share/wasi-sysroot"
FFMPEG_SOURCE="${BUILD_ROOT}/ffmpeg-${FFMPEG_VERSION}"

cd "${FFMPEG_SOURCE}"

# FFmpeg 5.1 predates the upstream WASI build fix. wasi-libc does not expose
# tempnam(), so apply the same guard accepted upstream in June 2024 before
# configuring the source tree.
sed -i '0,/^#if !HAVE_MKSTEMP$/s//#if HAVE_TEMPNAM/' libavutil/file_open.c

./configure \
  --prefix="${BUILD_ROOT}/install" \
  --cc="${WASI_SDK}/bin/clang" \
  --cxx="${WASI_SDK}/bin/clang++" \
  --ar="${WASI_SDK}/bin/llvm-ar" \
  --nm="${WASI_SDK}/bin/llvm-nm" \
  --ranlib="${WASI_SDK}/bin/llvm-ranlib" \
  --strip="${WASI_SDK}/bin/llvm-strip" \
  --arch=wasm32 \
  --target-os=none \
  --enable-cross-compile \
  --extra-cflags="--target=wasm32-wasi --sysroot=${WASI_SYSROOT} -O2 -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS" \
  --extra-ldflags="--target=wasm32-wasi --sysroot=${WASI_SYSROOT} -mexec-model=command -Wl,--stack-first -Wl,-z,stack-size=16777216" \
  --extra-libs="-lwasi-emulated-signal -lwasi-emulated-process-clocks" \
  --disable-asm \
  --disable-inline-asm \
  --disable-x86asm \
  --disable-network \
  --disable-pthreads \
  --disable-w32threads \
  --disable-os2threads \
  --disable-runtime-cpudetect \
  --disable-indevs \
  --disable-outdevs \
  --disable-ffplay \
  --disable-ffprobe \
  --disable-doc \
  --disable-debug

make -j"${JOBS}" ffmpeg

cp -f "ffmpeg" "${BUILD_ROOT}/output/ffmpeg-${FFMPEG_VERSION}.wasm"
"${WASI_SDK}/bin/llvm-strip" "${BUILD_ROOT}/output/ffmpeg-${FFMPEG_VERSION}.wasm"
sha256sum "${BUILD_ROOT}/output/ffmpeg-${FFMPEG_VERSION}.wasm"
stat --printf='bytes=%s\n' "${BUILD_ROOT}/output/ffmpeg-${FFMPEG_VERSION}.wasm"
