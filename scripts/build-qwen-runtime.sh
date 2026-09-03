#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-macos-arm64}"
CRISPASR_COMMIT="5c3e1ffa7fc18a241d0861f7b8b9c3bd436df2f8"
CRISPASR_REPOSITORY="https://github.com/CrispStrobe/CrispASR.git"
MACOS_DEPLOYMENT_TARGET="13.0"
SOURCE_DIR="${CRISPASR_SOURCE_DIR:-$ROOT/.runtime/source/CrispASR}"
BUILD_DIR="${CRISPASR_BUILD_DIR:-$ROOT/.runtime/build/$TARGET}"
OUTPUT_DIR="$ROOT/.runtime/$TARGET"

case "$TARGET" in
  macos-arm64)
    CMAKE_ARCH="arm64"
    METAL="ON"
    ;;
  macos-x86_64)
    CMAKE_ARCH="x86_64"
    METAL="OFF"
    ;;
  *)
    echo "usage: $0 [macos-arm64|macos-x86_64]" >&2
    exit 2
    ;;
esac

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  mkdir -p "$(dirname "$SOURCE_DIR")"
  git clone --filter=blob:none "$CRISPASR_REPOSITORY" "$SOURCE_DIR"
fi

if [[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" != "$CRISPASR_COMMIT" ]]; then
  if ! git -C "$SOURCE_DIR" diff --quiet || ! git -C "$SOURCE_DIR" diff --cached --quiet; then
    echo "CrispASR source has local changes: $SOURCE_DIR" >&2
    exit 1
  fi
  git -C "$SOURCE_DIR" fetch --depth 1 origin "$CRISPASR_COMMIT"
  git -C "$SOURCE_DIR" checkout --detach "$CRISPASR_COMMIT"
fi
git -C "$SOURCE_DIR" submodule update --init --recursive --depth 1

CMAKE_ARGS=(
  "-DCMAKE_BUILD_TYPE=Release"
  "-DCMAKE_OSX_ARCHITECTURES=$CMAKE_ARCH"
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_DEPLOYMENT_TARGET"
  # CrispASR enables Accelerate's macOS 13.3 ILP64 headers; use the legacy ABI on Ventura 13.0.
  "-DCMAKE_C_FLAGS=-UACCELERATE_NEW_LAPACK -UACCELERATE_LAPACK_ILP64"
  "-DCMAKE_CXX_FLAGS=-UACCELERATE_NEW_LAPACK -UACCELERATE_LAPACK_ILP64"
  "-DBUILD_SHARED_LIBS=OFF"
  "-DCRISPASR_BUILD_TESTS=OFF"
  "-DCRISPASR_BUILD_EXAMPLES=ON"
  "-DCRISPASR_BUILD_SERVER=OFF"
  "-DGGML_ACCELERATE=ON"
  "-DGGML_METAL=$METAL"
  "-DGGML_NATIVE=OFF"
  "-DGGML_OPENMP=OFF"
)
if [[ "$TARGET" == "macos-x86_64" ]]; then
  CMAKE_ARGS+=(
    "-DGGML_SSE42=ON"
    "-DGGML_AVX=ON"
    "-DGGML_AVX2=ON"
    "-DGGML_BMI2=ON"
    "-DGGML_FMA=ON"
    "-DGGML_F16C=ON"
  )
fi

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"
cmake --build "$BUILD_DIR" --config Release --target crispasr-cli -j "$(sysctl -n hw.ncpu)"

BINARY="$BUILD_DIR/bin/crispasr"
lipo "$BINARY" -verify_arch "$CMAKE_ARCH"
if otool -L "$BINARY" | tail -n +2 | grep -Eq '/(opt/homebrew|usr/local|Users)/'; then
  echo "qwen-asr contains a developer-machine dependency" >&2
  exit 1
fi
mkdir -p "$OUTPUT_DIR"
cp "$BINARY" "$OUTPUT_DIR/qwen-asr"
chmod +x "$OUTPUT_DIR/qwen-asr"
echo "$OUTPUT_DIR/qwen-asr"
