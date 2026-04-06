#!/usr/bin/env python3
"""Test script for query_farm_pyarrow_slim wheels.

Runs smoke tests and optionally the full pytest suite.

Usage:
    python ci/scripts/test_slim_wheel.py [--quick]

Options:
    --quick    Only run smoke tests (skip pytest suite)
"""

import subprocess
import sys


def smoke_tests():
    """Core functionality smoke tests."""
    import pyarrow as pa

    print(f"PyArrow version: {pa.__version__}")
    print()

    # --- Array creation ---
    arr = pa.array([1, 2, 3, None, 5])
    assert arr.type == pa.int64()
    assert len(arr) == 5
    assert arr.null_count == 1
    print("PASS: Array creation")

    # --- Table creation ---
    table = pa.table({"a": [1, 2, 3], "b": ["x", "y", "z"]})
    assert table.num_rows == 3
    assert table.num_columns == 2
    print("PASS: Table creation")

    # --- IPC roundtrip ---
    sink = pa.BufferOutputStream()
    writer = pa.ipc.new_stream(sink, table.schema)
    writer.write_table(table)
    writer.close()
    reader = pa.ipc.open_stream(sink.getvalue())
    table_rt = reader.read_all()
    assert table_rt.equals(table)
    print("PASS: IPC stream roundtrip")

    # --- Feather roundtrip ---
    import pyarrow.feather as feather
    import tempfile
    import os

    with tempfile.NamedTemporaryFile(suffix=".feather", delete=False) as f:
        feather.write_feather(table, f.name)
        table_rt2 = feather.read_table(f.name)
        os.unlink(f.name)
    assert table_rt2.equals(table)
    print("PASS: Feather roundtrip")

    # --- Compute ---
    import pyarrow.compute as pc

    result = pc.add(pa.array([1, 2, 3]), pa.array([4, 5, 6]))
    assert result.to_pylist() == [5, 7, 9]
    print("PASS: Compute (add)")

    result = pc.sum(pa.array([1, 2, 3, 4, 5]))
    assert result.as_py() == 15
    print("PASS: Compute (sum)")

    casted = pc.cast(pa.array([1, 2, 3]), pa.float64())
    assert casted.type == pa.float64()
    print("PASS: Compute (cast)")

    # --- Filesystem ---
    import pyarrow.fs as fs

    local = fs.LocalFileSystem()
    info = local.get_file_info("/")
    assert info.type.name == "Directory"
    print("PASS: Local filesystem")

    # --- Compression ---
    codec = pa.Codec("zstd")
    data = b"hello world " * 1000
    compressed = codec.compress(data)
    decompressed = codec.decompress(compressed, len(data))
    assert decompressed == data
    print("PASS: zstd compression")

    # --- Disabled features raise ImportError ---
    disabled_modules = [
        "parquet", "flight", "substrait", "_dataset",
        "_acero", "_orc", "_csv", "_json",
        "_s3fs", "_gcsfs", "_azurefs", "_hdfs",
    ]
    for mod in disabled_modules:
        try:
            __import__(f"pyarrow.{mod}")
            # Some wrapper modules (parquet, flight, substrait) import fine
            # but raise when you try to use them — that's OK.
            # The Cython extensions (_dataset, _acero, etc.) should ImportError.
            if mod.startswith("_"):
                print(f"FAIL: pyarrow.{mod} should not be importable")
                sys.exit(1)
        except ImportError:
            pass
    print("PASS: Disabled Cython extensions raise ImportError")

    # --- show_info ---
    print()
    pa.show_info()
    print()
    print("=== All smoke tests passed ===")


def run_pytest():
    """Run the relevant subset of the PyArrow test suite."""
    import pyarrow

    test_dir = str(pyarrow.__path__[0]) + "/tests"

    test_files = [
        "test_array.py",
        "test_table.py",
        "test_ipc.py",
        "test_feather.py",
        "test_types.py",
        "test_compute.py",
        "test_pandas.py",
        "test_convert_builtin.py",
        "test_scalars.py",
        "test_fs.py",
    ]

    # Known failures: regex tests require RE2 which we disabled
    re2_tests = [
        "test_count_substring",
        "test_count_substring_regex",
        "test_find_substring",
        "test_match_like",
        "test_match_substring",
        "test_match_substring_regex",
        "test_split_pattern_regex",
        "test_replace_regex",
        "test_extract_regex",
        "test_extract_regex_span",
    ]

    args = [
        sys.executable, "-m", "pytest",
        "-q", "--no-header",
        # Use -k to exclude RE2-dependent tests
        "-k", "not (" + " or ".join(re2_tests) + ")",
    ] + [f"{test_dir}/{f}" for f in test_files]

    print("=== Running pytest suite ===")
    result = subprocess.run(args)
    return result.returncode


def main():
    quick = "--quick" in sys.argv

    smoke_tests()

    if quick:
        print("Skipping pytest suite (--quick)")
        sys.exit(0)

    rc = run_pytest()
    sys.exit(rc)


if __name__ == "__main__":
    main()
