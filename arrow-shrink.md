# query_farm_pyarrow_slim: Build Findings

## Goal

Create a smaller PyArrow wheel (`query_farm_pyarrow_slim`) that drops unused features to reduce install size for Query Farm's use case. The package installs as `pyarrow` (same import name) but is distributed under a different PyPI name.

## Size Results

| Build | Wheel Size | Installed Size |
|---|---|---|
| Official PyPI pyarrow 23.0.1 (linux x86_64) | 45 MB | 144 MB |
| Our full build (macOS arm64) | 17 MB | 69.5 MB |
| Slim v1 (no parquet/flight/fs/etc) | 11 MB | 45.4 MB |
| **Slim final (+ no RE2)** | **10 MB** | **~43 MB** |

The official PyPI wheel is so large because it statically links all third-party dependencies (gRPC, protobuf, AWS SDK, Google Cloud SDK, Azure SDK, OpenSSL, etc.) into the shared libraries. `libarrow_flight.so` alone is 25 MB on the official wheel due to bundled gRPC/protobuf.

## What's Disabled

### PyArrow extensions not compiled

| Feature | Extensions Removed | C++ Libraries Removed |
|---|---|---|
| Parquet | `_parquet.so`, `_parquet_encryption.so` | `libarrow_python_parquet_encryption`, `libparquet` |
| Flight | `_flight.so` | `libarrow_python_flight`, `libarrow_flight` |
| Substrait | `_substrait.so` | `libarrow_substrait` |
| Dataset | `_dataset.so`, `_dataset_parquet.so`, `_dataset_parquet_encryption.so`, `_dataset_orc.so` | `libarrow_dataset` |
| Acero | `_acero.so` | `libarrow_acero` |
| ORC | `_orc.so` | (none) |
| CSV | `_csv.so` | (none) |
| JSON | `_json.so` | (none) |
| Azure FS | `_azurefs.so` | (none) |
| GCS FS | `_gcsfs.so` | (none) |
| S3 FS | `_s3fs.so` | (none) |
| HDFS | `_hdfs.so` | (none) |

### Arrow C++ build flags

```
ARROW_COMPUTE=ON       (required - libarrow_python depends on full compute)
ARROW_IPC=ON
ARROW_FILESYSTEM=ON
ARROW_CSV=ON           (headers needed by Cython declarations in libarrow.pxd)
ARROW_JSON=ON          (headers needed by Cython declarations in libarrow.pxd)
ARROW_WITH_ZSTD=ON
ARROW_WITH_RE2=OFF     (removes regex string kernels)
ARROW_WITH_BROTLI=OFF
ARROW_WITH_SNAPPY=OFF
ARROW_WITH_BZ2=OFF
ARROW_WITH_LZ4=OFF
ARROW_WITH_ZLIB=OFF
ARROW_PARQUET=OFF
ARROW_FLIGHT=OFF
ARROW_FLIGHT_SQL=OFF
ARROW_DATASET=OFF
ARROW_ACERO=OFF
ARROW_ORC=OFF
ARROW_SUBSTRAIT=OFF
ARROW_GANDIVA=OFF
ARROW_S3=OFF
ARROW_GCS=OFF
ARROW_AZURE=OFF
ARROW_HDFS=OFF
ARROW_CUDA=OFF
ARROW_JEMALLOC=OFF
```

### What's kept

- Core Arrow types, arrays, tables, scalars, buffers, memory pools
- Compute functions (arithmetic, aggregation, casting, sorting, etc. — but no regex)
- IPC / Feather read/write
- Local filesystem
- zstd compression
- Pandas integration
- NumPy integration

## What We Learned

### ARROW_COMPUTE=OFF doesn't work

`libarrow_python` (the C++ Python bridge) depends on 34 symbols from the full compute library including `Grouper::MakeGroupings`, `HashAggregateFunction`, `DictionaryEncode`, `FunctionRegistry`, etc. These are not in the baseline compute (which only has cast/filter/take). The CMakeLists.txt comment "Currently PyArrow cannot be built without ARROW_COMPUTE" is correct.

### ARROW_CSV=OFF and ARROW_JSON=OFF at the C++ level don't work

`libarrow.pxd` (the shared Cython declarations included by every module) contains `cdef extern from "arrow/csv/api.h"` and `cdef extern from "arrow/json/options.h"` blocks. These headers must exist at Cython compile time even if the CSV/JSON features aren't used. Additionally, `gdb.cc` (compiled into `libarrow_python`) unconditionally includes `arrow/json/from_string.h`.

**Solution:** Build Arrow C++ with `ARROW_CSV=ON` and `ARROW_JSON=ON` (the C++ code is small), but don't build the `_csv.so` and `_json.so` PyArrow Cython extensions.

### The unconditional FATAL_ERROR for ARROW_CSV had to go

`CMakeLists.txt` had an unconditional check that required `ARROW_CSV=ON` to compile `csv.cc` into `libarrow_python`. We made this conditional — `csv.cc` is only added to `PYARROW_CPP_SRCS` when `ARROW_CSV` is available. Same for `gdb.cc` which depends on `ARROW_JSON`.

## Files Changed

### New files

- **`python/pyproject.slim.toml`** — Copy of `pyproject.toml` with `name = "query_farm_pyarrow_slim"` and cmake.define entries to force all excluded features OFF
- **`python/build_slim.sh`** — Build script: builds minimal Arrow C++, swaps pyproject.toml, builds wheel, restores original

### Modified files

- **`python/CMakeLists.txt`**
  - Added `define_option()` for CSV and JSON (lines after 348)
  - Moved `_csv` and `_json` from hardcoded `CYTHON_EXTENSIONS` list to conditional blocks
  - Made `csv.cc` inclusion conditional on `ARROW_CSV` (was unconditional with FATAL_ERROR)
  - Made `gdb.cc` inclusion conditional on `ARROW_JSON` (depends on `arrow/json/from_string.h`)
  - Added validation: if `PYARROW_BUILD_CSV=ON` but `ARROW_CSV=OFF`, fail with clear message (same for JSON)

- **`python/pyarrow/__init__.py`**
  - Added conflict detection guard: warns if both `pyarrow` and `query_farm_pyarrow_slim` are installed

## Test Results

2550 passed, 10 failed (all regex-related), 574 skipped.

The 10 failures are all in `test_compute.py` and all require RE2:
- `test_count_substring` (ignore_case)
- `test_count_substring_regex`
- `test_find_substring`
- `test_match_like`
- `test_match_substring`
- `test_match_substring_regex`
- `test_split_pattern_regex`
- `test_replace_regex`
- `test_extract_regex`
- `test_extract_regex_span`

Core functionality (arrays, tables, IPC, feather, compute arithmetic/aggregates/casts, pandas, filesystem) all passes.

## Further Size Reduction Opportunities (not implemented)

| Opportunity | Estimated Savings | Trade-off |
|---|---|---|
| Strip debug symbols (`strip -x`) | ~5 MB | No functionality loss |
| Remove C++ headers from wheel | ~3.4 MB | Can't build C extensions against pyarrow |
| Remove test suite from wheel | ~2.3 MB | Can't run `pytest pyarrow` |
| Remove Python files for disabled features | ~0.5 MB | Cosmetic |
| LTO (`CMAKE_INTERPROCEDURAL_OPTIMIZATION=ON`) | ~3-5 MB | Much slower builds |
| `ARROW_MIMALLOC=OFF` | ~0.5 MB | Slightly worse allocation performance |
| `ARROW_WITH_UTF8PROC=OFF` | ~0.5 MB | Lose Unicode normalization in string functions |
