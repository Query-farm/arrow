#!/bin/bash
# Build Arrow C++ with minimal features for query_farm_pyarrow_slim.
#
# Usage:
#   ci/scripts/build_slim_cpp.sh <source_dir> <build_dir> <install_prefix>
#
# Environment:
#   NPROC    Parallel jobs (default: auto-detect)

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <source_dir> <build_dir> <install_prefix>"
  exit 1
fi

SOURCE_DIR="$1"
BUILD_DIR="$2"
INSTALL_PREFIX="$3"
NPROC="${NPROC:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "=== Building Arrow C++ (slim) ==="
echo "Source:  $SOURCE_DIR"
echo "Build:   $BUILD_DIR"
echo "Install: $INSTALL_PREFIX"
echo "Jobs:    $NPROC"

mkdir -p "$BUILD_DIR"

cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DARROW_BUILD_SHARED=ON \
  -DARROW_BUILD_STATIC=OFF \
  -DARROW_IPC=ON \
  -DARROW_COMPUTE=ON \
  -DARROW_FILESYSTEM=ON \
  -DARROW_CSV=ON \
  -DARROW_JSON=ON \
  -DARROW_WITH_ZSTD=ON \
  -DARROW_WITH_BROTLI=OFF \
  -DARROW_WITH_SNAPPY=OFF \
  -DARROW_WITH_BZ2=OFF \
  -DARROW_WITH_LZ4=OFF \
  -DARROW_WITH_ZLIB=OFF \
  -DARROW_WITH_RE2=OFF \
  -DARROW_PARQUET=OFF \
  -DARROW_FLIGHT=OFF \
  -DARROW_FLIGHT_SQL=OFF \
  -DARROW_DATASET=OFF \
  -DARROW_ACERO=OFF \
  -DARROW_ORC=OFF \
  -DARROW_SUBSTRAIT=OFF \
  -DARROW_GANDIVA=OFF \
  -DARROW_S3=OFF \
  -DARROW_GCS=OFF \
  -DARROW_AZURE=OFF \
  -DARROW_HDFS=OFF \
  -DARROW_CUDA=OFF \
  -DARROW_JEMALLOC=OFF \
  -DARROW_SIMD_LEVEL=DEFAULT \
  -DARROW_RUNTIME_SIMD_LEVEL=MAX \
  -DARROW_BUILD_TESTS=OFF \
  -DARROW_BUILD_BENCHMARKS=OFF \
  -DARROW_BUILD_EXAMPLES=OFF

cmake --build "$BUILD_DIR" --target install -j "$NPROC"

echo "=== Arrow C++ (slim) installed to $INSTALL_PREFIX ==="
