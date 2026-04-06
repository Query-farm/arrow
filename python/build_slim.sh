#!/bin/bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# Build script for query_farm_pyarrow_slim - a slim PyArrow wheel
# with only core Arrow types, compute, IPC/Feather, filesystem, and zstd.
#
# Builds in an isolated temp directory — the source tree is never modified.
#
# Usage:
#   bash python/build_slim.sh [--skip-cpp]
#
# Options:
#   --skip-cpp    Skip the Arrow C++ build (use existing ARROW_HOME)
#
# Environment:
#   ARROW_HOME       Arrow C++ install prefix (default: <repo>/dist-slim)
#   CPP_BUILD_DIR    Arrow C++ build directory (default: <repo>/cpp/build-slim)
#   NPROC            Parallel jobs (default: auto-detect)
#   SETUPTOOLS_SCM_PRETEND_VERSION
#                    Override version string (e.g., "18.1.0.post20260406")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARROW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CPP_SOURCE_DIR="$ARROW_ROOT/cpp"
CPP_BUILD_DIR="${CPP_BUILD_DIR:-$ARROW_ROOT/cpp/build-slim}"
ARROW_HOME="${ARROW_HOME:-$ARROW_ROOT/dist-slim}"
NPROC="${NPROC:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

SKIP_CPP=0
for arg in "$@"; do
  case "$arg" in
    --skip-cpp) SKIP_CPP=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

echo "=== Building query_farm_pyarrow_slim ==="
echo "Arrow root:     $ARROW_ROOT"
echo "C++ build dir:  $CPP_BUILD_DIR"
echo "Install prefix: $ARROW_HOME"
echo "Parallel jobs:  $NPROC"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Build Arrow C++ with minimal features
# ---------------------------------------------------------------------------
if [ "$SKIP_CPP" -eq 0 ]; then
  echo "--- Step 1: Building Arrow C++ (minimal) ---"
  mkdir -p "$CPP_BUILD_DIR"
  cmake -S "$CPP_SOURCE_DIR" -B "$CPP_BUILD_DIR" \
    -DCMAKE_INSTALL_PREFIX="$ARROW_HOME" \
    -DCMAKE_BUILD_TYPE=Release \
    -DARROW_BUILD_SHARED=ON \
    -DARROW_BUILD_STATIC=OFF \
    -DARROW_IPC=ON \
    -DARROW_COMPUTE=ON \
    -DARROW_FILESYSTEM=ON \
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
    -DARROW_CSV=ON \
    -DARROW_JSON=ON \
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

  cmake --build "$CPP_BUILD_DIR" --target install -j "$NPROC"
  echo "Arrow C++ installed to $ARROW_HOME"
  echo ""
else
  echo "--- Step 1: Skipping Arrow C++ build (--skip-cpp) ---"
  echo "Using ARROW_HOME=$ARROW_HOME"
  echo ""
fi

# ---------------------------------------------------------------------------
# Step 2: Build the slim PyArrow wheel in an isolated temp directory
# ---------------------------------------------------------------------------
echo "--- Step 2: Building slim PyArrow wheel ---"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Work directory: $WORK_DIR"

# Copy python source to temp dir (exclude build artifacts, resolve symlinks)
rsync -aL \
  --exclude='build/' \
  --exclude='dist/' \
  --exclude='__pycache__/' \
  --exclude='*.egg-info/' \
  --exclude='.eggs/' \
  "$SCRIPT_DIR/" "$WORK_DIR/python/"

# The .git directory is needed by setuptools_scm (unless PRETEND_VERSION is set)
# Link the repo root so setuptools_scm can find git tags
if [ -z "${SETUPTOOLS_SCM_PRETEND_VERSION:-}" ]; then
  # setuptools_scm needs the git repo; root = '..' in pyproject.toml
  # Create a parent dir structure so the relative root works
  mkdir -p "$WORK_DIR/python/.git"
  # Actually, just point setuptools_scm at the real repo
  rm -rf "$WORK_DIR/python/.git"
  ln -sf "$ARROW_ROOT/.git" "$WORK_DIR/.git"
fi

# Use the slim pyproject.toml
cp "$WORK_DIR/python/pyproject.slim.toml" "$WORK_DIR/python/pyproject.toml"

# Point to our minimal Arrow C++ build
export ARROW_HOME
export CMAKE_PREFIX_PATH="$ARROW_HOME"

# Bundle Arrow C++ libs into the wheel
export PYARROW_BUNDLE_ARROW_CPP=1

# Disable all excluded PyArrow features
export PYARROW_WITH_PARQUET=0
export PYARROW_WITH_PARQUET_ENCRYPTION=0
export PYARROW_WITH_FLIGHT=0
export PYARROW_WITH_SUBSTRAIT=0
export PYARROW_WITH_DATASET=0
export PYARROW_WITH_ACERO=0
export PYARROW_WITH_ORC=0
export PYARROW_WITH_CSV=0
export PYARROW_WITH_JSON=0
export PYARROW_WITH_AZURE=0
export PYARROW_WITH_GCS=0
export PYARROW_WITH_S3=0
export PYARROW_WITH_HDFS=0

cd "$WORK_DIR/python"
python -m build --wheel

# Copy wheels back to the source tree's dist/
mkdir -p "$SCRIPT_DIR/dist"
cp "$WORK_DIR/python/dist/"*.whl "$SCRIPT_DIR/dist/"

echo ""
echo "=== Done ==="
echo "Wheel(s) in: $SCRIPT_DIR/dist/"
ls -lh "$SCRIPT_DIR/dist/"*.whl 2>/dev/null || echo "(no wheels found)"
